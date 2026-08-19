//! CloudAgents.CheckpointBridge — capture → Testamur checkpoint format (WP6)
//! (docs/capture-checkpoint.md; docs/CAPABILITY_AUDIT.md WP4; Testamur §4.1 /
//! ADR-0004). The missing cross-repo link in the provenance slice: it turns a
//! captured `claude -p` session (the hash-chained `CaptureEvent`s produced by
//! `CloudAgents.Capture`) into the Testamur checkpoint-format provenance objects
//! (a `Session`, its `Step`s, and a terminal `Checkpoint`), content-addressed
//! exactly as the platform computes them, so the graph can ingest a real session.
//!
//! ## Not a second mapper
//!
//! The event → step mapping (honest origins, tool_use/tool_result pairing,
//! gaps-become-note-steps, the timestamp policy, content addressing) is the
//! platform's, not ours: this bridge delegates to
//! `Testamur.CheckpointFormat.Adapt.mapStreamJson` — the reviewed
//! `cloud-agents-runner` adapter (fidelity: events) — vendored verbatim under
//! `vendor/testamur-checkpoint-format/` (see its `VENDORED.md`; migrates to a
//! NuGet dependency later). Keeping the mapping in one place is what guarantees
//! the checkpoint ids emitted here are byte-identical to the ones testamur
//! derives for the same session — the property the cross-repo drift-guard test
//! pins.
//!
//! ## What the bridge itself adds
//!
//! 1. **Verify before trust.** The capture chain is checked with
//!    `CloudAgents.Capture.verifyChain` first; a tampered/discontinuous stream is
//!    rejected as a typed `ChainInvalid`, never mapped.
//! 2. **Reconstruct the transcript.** `CaptureEvent.payload` is the raw NDJSON
//!    line verbatim; the ordered payloads ARE the stream-json transcript the
//!    mapper expects (blank lines were already dropped at capture, so the line
//!    set matches what the platform's own `splitLines` would produce — the basis
//!    for identical content addresses). Malformed-captured lines are passed
//!    through too: the mapper turns an unparseable line into a `note` step, so
//!    nothing is silently dropped.
//!
//! This package does no Docker, DB, or HTTP work — it is pure, offline, and
//! unit-tested (`tests/checkpoint_bridge_tests.l`). Persisting the emitted
//! objects, serving them, wiring the runner to `--output-format stream-json`, and
//! handing the objects to the platform graph are sequenced follow-ups (see
//! `docs/capture-checkpoint.md` §7 and AGENTS.md).
@runtime_checked
package CloudAgents.CheckpointBridge

import Std.Core
import Std.Collections
import CloudAgents.Capture
import CloudAgents.Capture.GitDiff
import Testamur.CheckpointFormat.Model
import Testamur.CheckpointFormat.Adapt

// ─── Errors ──────────────────────────────────────────────────────────────────
/// Typed bridge failures. A capture with no mappable events is NOT an error —
/// the mapper yields a session with a synthesized prompt step (and note steps);
/// these cover only a broken chain or a structural map failure.
pub union BridgeError {
  /// `verifyChain` failed: the captured stream is discontinuous or was mutated
  /// (edit/insert/reorder/drop), so it is not trustworthy provenance.
  case ChainInvalid(detail: String)
  /// The vendored mapper returned a typed `AdaptError` (e.g. ill-formed UTF-16
  /// in a transcript string, rejected before hashing); `detail` is its message.
  case MapFailed(detail: String)
}

/// Human-readable rendering of a `BridgeError`.
pub func bridgeErrorMessage(e: in BridgeError): String {
  return match e {
    case ChainInvalid(detail) -> "capture chain invalid: " + detail
    case MapFailed(detail) -> "checkpoint mapping failed: " + detail
  }
}

// ─── Context helpers ─────────────────────────────────────────────────────────
/// Build the runner's `InvocationContext` from primitive values, so a caller
/// need not import the vendored `Model`/`Adapt` records directly. The session's
/// principal is the agent that ran (`agent:<principalId>` semantics are the
/// caller's — pass the id verbatim); `startedAt` is the RFC 3339 UTC invocation
/// time (data, never the wall clock); `promptText` is the CLI prompt (not a
/// stream event in `-p` mode); `treeHash` is the workspace git tree the runner
/// snapshotted, or `None` to stop the mapping at steps (no terminal checkpoint).
/// `permission` is the runner's tool-permission mode: "granted" | "denied" |
/// "auto" (anything else falls back to "auto", the least-claiming value).
pub func runnerContext(
  principalId: in String,
  principalDisplay: in String,
  workspace: in String,
  startedAt: in String,
  promptText: in String,
  model: in String,
  permission: in String,
  treeHash: in Option[String],
): InvocationContext {
  var display: Option[String] = None
  if principalDisplay != "" {
    display = Some(value = principalDisplay)
  }
  return InvocationContext(
    principal = Principal(kind = AgentPrincipal, id = principalId, display = display),
    workspace = workspace,
    taskRef = None,
    startedAt = startedAt,
    promptText = promptText,
    model = model,
    permission = permissionOf(permission),
    tree = treeHash
  )
}

/// Map a permission-mode string to the checkpoint-format `Permission`. Unknown
/// strings fall back to `Auto` — the closed-set value that claims the least
/// (never fabricates an explicit human grant the runner cannot evidence).
pub func permissionOf(mode: in String): Permission {
  if mode == "granted" {
    return Granted
  }
  if mode == "denied" {
    return Denied
  }
  return Auto
}

// ─── The bridge ──────────────────────────────────────────────────────────────
/// Emit the Testamur checkpoint-format provenance objects for a captured
/// session. `events` are the ordered `CaptureEvent`s of the whole session (one
/// hash chain, from `CloudAgents.Capture`); `genesisPrevHash` is the chain's
/// genesis `prevHash` (the empty string for a capture that started at seq 0).
///
/// Steps:
///   1. `verifyChain(events, genesisPrevHash)` — reject a tampered capture as
///      `ChainInvalid` before it can become false provenance.
///   2. reconstruct the stream-json transcript from the event payloads (verbatim,
///      in order).
///   3. delegate to the vendored `Adapt.mapStreamJson` under `context`.
///
/// Returns the mapper's `StreamJsonMapping` (session/step/checkpoint objects in
/// dependency order, the per-event kind labels, the mapped/note accounting, the
/// session id, and the checkpoint id when `context.tree` is present). Never
/// panics; every failure is a typed `BridgeError`.
pub func emitFromCapture(
  events: in slice[CaptureEvent], genesisPrevHash: in String, context: in InvocationContext
): Result[StreamJsonMapping, BridgeError] {
  val noDeltas: List[FileDelta] = newList()
  return emitFromCaptureWithFileChanges(events, genesisPrevHash, context, noDeltas)
}

/// As `emitFromCapture`, but ALSO threads captured workspace file diffs into the
/// mapping so Q4 attributes a PR hunk to this session (ADR-0016). The vendored
/// `Adapt.mapStreamJsonWithFileChanges` emits an agent-origin `file_change` step
/// (the checkpoint frontier tip) when `fileChanges` is non-empty; empty deltas
/// keep the mapping byte-identical to `mapStreamJson` (no content-address drift).
/// The chain is still verified before any mapping.
pub func emitFromCaptureWithFileChanges(
  events: in slice[CaptureEvent],
  genesisPrevHash: in String,
  context: in InvocationContext,
  fileChanges: in List[FileDelta],
): Result[StreamJsonMapping, BridgeError] {
  if not verifyChain(events, genesisPrevHash) {
    return Err(
      error = ChainInvalid(
        detail = "verifyChain rejected the captured stream (a discontinuity or a mutated seq/eventType/payload); refusing to map untrusted provenance"
      )
    )
  }
  val lines: List[String] = newList()
  var i = 0
  while i < events.length.toInt() {
    lines.add(events[i].payload)
    i = i + 1
  }
  return match mapStreamJsonWithFileChanges(lines, context, fileChanges) {
    case Ok(mapping) -> Ok(value = mapping)
    case Err(e) -> Err(error = MapFailed(detail = adaptErrorMessage(e)))
  }
}

/// As `emitFromCaptureWithFileChanges`, but takes the RAW `git diff` unified text
/// captured from the workspace and parses it into `FileDelta`s first
/// (`CloudAgents.Capture.GitDiff.parseUnifiedDiff`). This is the runner's seam:
/// capture the workspace diff at session end, hand it here. An empty/malformed
/// diff parses to no deltas ⇒ byte-identical to `emitFromCapture`.
pub func emitFromCaptureWithDiff(
  events: in slice[CaptureEvent],
  genesisPrevHash: in String,
  context: in InvocationContext,
  gitDiff: in String,
): Result[StreamJsonMapping, BridgeError] {
  val deltas = CloudAgents.Capture.GitDiff.parseUnifiedDiff(gitDiff)
  return emitFromCaptureWithFileChanges(events, genesisPrevHash, context, deltas)
}

/// Convenience: parse a whole captured `claude -p --output-format stream-json`
/// transcript (a single NDJSON string) and emit its checkpoint-format objects in
/// one call — `parseStreamJson` (from seq 0, genesis prev "") composed with
/// `emitFromCapture`. The intermediate `CaptureBatch` is discarded; callers that
/// persist the chain should use `parseStreamJson` + `emitFromCapture` directly so
/// they keep the `CaptureEvent`s.
pub func emitFromTranscript(ndjson: in String, context: in InvocationContext): Result[StreamJsonMapping, BridgeError] {
  val batch = parseStreamJson(ndjson, 0.toLong(), "")
  return emitFromCapture(batch.events, "", context)
}
