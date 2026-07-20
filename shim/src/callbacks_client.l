//! src/callbacks_client.l — CloudAgents.Shim.Callbacks: the long-poll state
//! machine behind all three MCP tools (docs/phase6-mcp-callbacks.md §3-4).
//!
//! Every entry point here is fail-closed: a transport error, a malformed
//! host response, or a client-side timeout all resolve to the same
//! conservative outcome (`Deny`/`Err`) rather than propagating an exception
//! up into Mcp.Server's dispatch loop. Fully synchronous, same reasoning as
//! CloudAgents.Shim.Transport's module doc.
package CloudAgents.Shim.Callbacks

import Std.Core
import Std.Time
import CloudAgents.Shim.Transport

/// The outcome of `requestPermission` — mirrors the two JSON shapes
/// Claude Code's `--permission-prompt-tool` contract expects
/// (CloudAgents.Shim.Tools builds the actual payload string).
pub union PermissionOutcome {
  case Allow(updatedInputJson: String)
  case Deny(message: String)
}

// ─── Clock (#540) ─────────────────────────────────────────────────────────────
// Injectable wall-clock seam for the long-poll deadline below. Before this,
// the deadline was tracked as an iteration count (`elapsedMs += interval`
// each loop), which understates real elapsed time whenever a poll itself is
// slow — a single sluggish `pollPermission` call could push the shim well
// past its documented `timeoutMs` before the loop even noticed. `Clock`
// makes "now" an explicit, testable input: production reads real epoch
// milliseconds (`SystemClock`), tests drive a `ManualClock` instead of
// sleeping in real time.
//
// Mirrors lyric-cache's `Clock` (lyric-cache/src/cache.l) deliberately,
// including keeping every `impl Clock for ...` in this same package:
// implementing an interface imported from another package fails on the
// current self-hosted MSIL backend (`Msil.Lowering: MPImpl interface type
// '<consumer pkg>.Clock' has no TypeDef or TypeRef row`, per lyric-cache's
// own module doc with an isolated repro) — so `SystemClock`/`ManualClock`
// ship here rather than leaving callers to write their own `impl`.
pub interface Clock {
  /// Return the current time as epoch milliseconds.
  func nowMillis(): Long
}

/// The real clock, backed by `Std.Time.nowEpochMillis()` — NOT
/// `Std.Time.Instant.now()`, which is broken at runtime in the current
/// toolchain (docs/lyric/gotchas.md: `Method not found: 'Void
/// System.DateTime.now()'`). `nowEpochMillis()` is a separate binding
/// (`hostEpochMillis` → `DateTimeOffset.UtcNow.ToUnixTimeMilliseconds`,
/// the same BCL path this repo's own `CloudAgents.Repository.nowMillis`
/// hand-binds) and is unaffected.
pub record SystemClock {
}

impl Clock for SystemClock {
  func nowMillis(): Long {
    return nowEpochMillis()
  }
}

/// A controllable clock for deterministic timeout tests. Construct with
/// `manualClock(startMillis)`, then advance `.millis` directly (a plain
/// field write — no real wall-clock wait) to simulate the passage of time.
/// `millis` is deliberately not `pub`: a `pub record` with private fields
/// cannot be constructed outside this package (docs/lyric/gotchas.md), which
/// is exactly why `manualClock` exists as the cross-package constructor —
/// field *access/mutation* on an already-constructed instance is
/// unrestricted (confirmed by lyric-cache's own `cache_tests.l`, a
/// different package, writing `clock.millis = ...` directly).
pub record ManualClock {
  var millis: Long
}

impl Clock for ManualClock {
  func nowMillis(): Long {
    return self.millis
  }
}

/// Create a `ManualClock` starting at `startMillis`.
pub func manualClock(startMillis: in Long): ManualClock {
  return ManualClock(millis = startMillis)
}

/// A pending-status guard: never loop forever on a pathological
/// pollIntervalMs of 0 (would spin with the sleep bound stuck at 0).
func safePollIntervalMs(pollIntervalMs: in Int): Int {
  if pollIntervalMs > 0 {
    pollIntervalMs
  } else {
    1
  }
}

/// Create a permission request, then long-poll for a human decision, using
/// the real wall clock. `pollIntervalMs` is the delay between GET polls
/// (docs/phase6 §3: 25s in production); `timeoutMs` is this call's own
/// client-side deadline — separate from, and in addition to, the host's own
/// fail-closed timeout backstop (CloudAgents.Callbacks.callbackTimeoutMillis)
/// — so a shim that never gets a fresh poll response (host unreachable, host
/// bug) still fails closed instead of hanging Claude Code's tool call
/// indefinitely. Thin `SystemClock` wrapper over `requestPermissionWithClock`
/// so CloudAgents.Shim.Tools/main.l keep calling this exact 5-arg signature;
/// tests call `requestPermissionWithClock` directly with a `ManualClock`.
pub func requestPermission(
  transport: in CallbackTransport,
  toolName: in String,
  inputJson: in String,
  pollIntervalMs: in Int,
  timeoutMs: in Int,
): PermissionOutcome {
  val clock: Clock = SystemClock()
  return requestPermissionWithClock(transport, toolName, inputJson, pollIntervalMs, timeoutMs, clock)
}

/// `requestPermission`, with an injectable `Clock` (#540). The deadline is
/// `clock.nowMillis() + timeoutMs`, computed once at call start: re-checked
/// before every poll (the `while` condition below) and used to bound the
/// final wait (`remaining`, so the last sleep never overshoots the
/// deadline) — real elapsed wall-clock time throughout, not an iteration
/// count that could drift arbitrarily far past `timeoutMs` if a poll itself
/// was slow.
pub func requestPermissionWithClock(
  transport: in CallbackTransport,
  toolName: in String,
  inputJson: in String,
  pollIntervalMs: in Int,
  timeoutMs: in Int,
  clock: in Clock,
): PermissionOutcome {
  val createResult: Result[String, String] = transport.createPermission(toolName, inputJson)
  val created = match createResult {
    case Ok(body) -> body
    case Err(e) -> return Deny(message = "failed to reach the cloud-agents host: " + e)
  }
  val createdResp = match tryDecodeCreatePermissionRequestResponse(created) {
    case Some(r) -> r
    case None -> return Deny(message = "malformed response from the cloud-agents host when creating the permission request")
  }

  val interval = safePollIntervalMs(pollIntervalMs)
  val deadline = clock.nowMillis() + timeoutMs.toLong()
  var decision: Option[PermissionDecision] = None
  while clock.nowMillis() < deadline {
    val polled = match transport.pollPermission(createdResp.id) {
      case Ok(body) -> body
      case Err(e) -> return Deny(message = "failed to reach the cloud-agents host while polling for a decision: " + e)
    }
    val d = match tryDecodePermissionDecision(polled) {
      case Some(dd) -> dd
      case None -> return Deny(message = "malformed response from the cloud-agents host while polling for a decision")
    }
    if d.status != "pending" {
      decision = Some(value = d)
      break
    }
    val remaining = deadline - clock.nowMillis()
    if remaining <= 0i64 {
      break
    }
    val sleepFor = if remaining < interval.toLong() { remaining } else { interval.toLong() }
    CloudAgents.Shim.Transport.sleepMillis(sleepFor.toInt())
  }

  return match decision {
    case Some(d) -> {
      if d.status == "allowed" {
        Allow(updatedInputJson = d.updatedInputJson)
      } else {
        val msg = if d.note.length > 0 { d.note } else { "denied by the human reviewer" }
        Deny(message = msg)
      }
    }
    case None -> Deny(message = "timed out after " + toString(timeoutMs) + "ms waiting for a human decision")
  }
}

/// Create a question, then long-poll for a human answer, using the real
/// wall clock. Timeout (either this call's own `timeoutMs` deadline, or the
/// host reporting its own `timed_out` status — docs/phase6 §4) surfaces as
/// `Err`, not a fabricated empty answer. Thin `SystemClock` wrapper over
/// `askUserWithClock` — see `requestPermission`'s doc for why.
pub func askUser(
  transport: in CallbackTransport,
  question: in String,
  optionsJson: in String,
  pollIntervalMs: in Int,
  timeoutMs: in Int,
): Result[String, String] {
  val clock: Clock = SystemClock()
  return askUserWithClock(transport, question, optionsJson, pollIntervalMs, timeoutMs, clock)
}

/// `askUser`, with an injectable `Clock` (#540) — see
/// `requestPermissionWithClock`'s doc for the deadline/wall-clock semantics,
/// mirrored here.
pub func askUserWithClock(
  transport: in CallbackTransport,
  question: in String,
  optionsJson: in String,
  pollIntervalMs: in Int,
  timeoutMs: in Int,
  clock: in Clock,
): Result[String, String] {
  val created = match transport.createQuestion(question, optionsJson) {
    case Ok(body) -> body
    case Err(e) -> return Err(error = "failed to reach the cloud-agents host: " + e)
  }
  val createdResp = match tryDecodeCreateUserQuestionResponse(created) {
    case Some(r) -> r
    case None -> return Err(error = "malformed response from the cloud-agents host when creating the question")
  }

  val interval = safePollIntervalMs(pollIntervalMs)
  val deadline = clock.nowMillis() + timeoutMs.toLong()
  var decision: Option[UserQuestionAnswer] = None
  while clock.nowMillis() < deadline {
    val polled = match transport.pollQuestion(createdResp.id) {
      case Ok(body) -> body
      case Err(e) -> return Err(error = "failed to reach the cloud-agents host while polling for an answer: " + e)
    }
    val d = match tryDecodeUserQuestionAnswer(polled) {
      case Some(dd) -> dd
      case None -> return Err(error = "malformed response from the cloud-agents host while polling for an answer")
    }
    if d.status != "pending" {
      decision = Some(value = d)
      break
    }
    val remaining = deadline - clock.nowMillis()
    if remaining <= 0i64 {
      break
    }
    val sleepFor = if remaining < interval.toLong() { remaining } else { interval.toLong() }
    CloudAgents.Shim.Transport.sleepMillis(sleepFor.toInt())
  }

  return match decision {
    case Some(d) -> if d.status == "answered" { Ok(value = d.answer) } else { Err(error = "timed out waiting for a human answer") }
    case None -> Err(error = "timed out after " + toString(timeoutMs) + "ms waiting for a human answer")
  }
}

/// Fire-and-forget progress report: a transport failure is logged to
/// stderr (never stdout — see CloudAgents.Shim.Transport's module doc) and
/// swallowed, never surfaced to the caller. Reporting progress must never
/// block or fail an agent's turn.
pub func reportProgress(transport: in CallbackTransport, summary: in String, percentComplete: in String): Unit {
  match transport.reportProgress(summary, percentComplete) {
    case Ok(_) -> ()
    case Err(e) -> CloudAgents.Shim.Transport.eprintln("cloud-agents-shim: report_progress failed: " + e)
  }
}
