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
import CloudAgents.Shim.Transport

/// The outcome of `requestPermission` — mirrors the two JSON shapes
/// Claude Code's `--permission-prompt-tool` contract expects
/// (CloudAgents.Shim.Tools builds the actual payload string).
pub union PermissionOutcome {
  case Allow(updatedInputJson: String)
  case Deny(message: String)
}

/// A pending-status guard: never loop forever on a pathological
/// pollIntervalMs of 0 (would spin with elapsedMs stuck at 0).
func safePollIntervalMs(pollIntervalMs: in Int): Int {
  if pollIntervalMs > 0 {
    pollIntervalMs
  } else {
    1
  }
}

/// Create a permission request, then long-poll for a human decision.
/// `pollIntervalMs` is the delay between GET polls (docs/phase6 §3: 25s in
/// production); `timeoutMs` is this call's own client-side deadline —
/// separate from, and in addition to, the host's own fail-closed timeout
/// backstop (CloudAgents.Callbacks.callbackTimeoutMillis) — so a shim that
/// never gets a fresh poll response (host unreachable, host bug) still
/// fails closed instead of hanging Claude Code's tool call indefinitely.
pub func requestPermission(
  transport: in CallbackTransport,
  toolName: in String,
  inputJson: in String,
  pollIntervalMs: in Int,
  timeoutMs: in Int,
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
  var elapsedMs = 0
  var decision: Option[PermissionDecision] = None
  while elapsedMs < timeoutMs {
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
    CloudAgents.Shim.Transport.sleepMillis(interval)
    elapsedMs = elapsedMs + interval
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

/// Create a question, then long-poll for a human answer. Timeout (either
/// this call's own `timeoutMs` deadline, or the host reporting its own
/// `timed_out` status — docs/phase6 §4) surfaces as `Err`, not a fabricated
/// empty answer.
pub func askUser(
  transport: in CallbackTransport,
  question: in String,
  optionsJson: in String,
  pollIntervalMs: in Int,
  timeoutMs: in Int,
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
  var elapsedMs = 0
  var decision: Option[UserQuestionAnswer] = None
  while elapsedMs < timeoutMs {
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
    CloudAgents.Shim.Transport.sleepMillis(interval)
    elapsedMs = elapsedMs + interval
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
