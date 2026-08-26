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
//! `Testamur.CheckpointFormat.Adapt.mapStreamJsonWithFileChanges` (of which
//! `mapStreamJson` is the empty-diff case) — the reviewed `cloud-agents-runner`
//! adapter (fidelity: events) — vendored verbatim under
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
import Testamur.CheckpointFormat.Canon
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
/// Delegates to `emitFromCaptureWithFileChanges` with NO file deltas — so this
/// is the transcript-only path (verify → reconstruct → the vendored mapper). Its
/// steps and content addresses are unchanged from before the file_change work:
///   1. `verifyChain(events, genesisPrevHash)` — reject a tampered capture as
///      `ChainInvalid` before it can become false provenance.
///   2. reconstruct the stream-json transcript from the event payloads (verbatim,
///      in order).
///   3. delegate to the vendored mapper (`mapStreamJsonWithFileChanges` with an
///      empty delta list == the classic `mapStreamJson`) under `context`.
///
/// Returns the mapper's `StreamJsonMapping` (session/step/checkpoint objects in
/// dependency order, the per-event kind labels, the mapped/note accounting, the
/// session id, and the checkpoint id when `context.tree` is present). Never
/// panics; every failure is a typed `BridgeError`. For capturing workspace file
/// changes (so Q4 attributes a hunk to this session), use
/// `emitFromCaptureWithDiff` / `emitFromCaptureWithFileChanges` instead.
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

/// The runner's end-of-run seam: parse a whole captured `claude -p
/// --output-format stream-json` run (the raw NDJSON the container produced) AND
/// its workspace `git diff HEAD`, and emit the checkpoint-format objects in one
/// call — `parseStreamJson` (from seq 0, genesis prev "") composed with
/// `emitFromCaptureWithDiff`. This is what `docker_manager.l` calls after a
/// successful run: the raw NDJSON is `cell.output`, the diff comes from the
/// inspect container. A malformed/empty diff parses to no deltas ⇒ byte-identical
/// to `emitFromTranscript` (no `file_change` step, fails safe). Pure — the caller
/// supplies the two strings + context; no Docker/DB/IO here.
pub func emitFromRunnerCapture(
  rawNdjson: in String, gitDiff: in String, context: in InvocationContext
): Result[StreamJsonMapping, BridgeError] {
  val batch = parseStreamJson(rawNdjson, 0.toLong(), "")
  return emitFromCaptureWithDiff(batch.events, "", context, gitDiff)
}

// ─── Ingest serialization (runtime graph handoff, M1.2) ──────────────────────
/// Serialize emitted provenance objects as the canonical JSON body the platform's
/// `POST /api/ingest` **objects form** consumes: `{"objects":[<object JSON>, …]}`,
/// ingested via `GraphIngest.ingestObjects`. Each object is encoded with the
/// reviewed `Model.encodeObject` (the SAME encoder the platform hashes with, so
/// bytes/ids agree — the cross-repo content-address contract), collected into a
/// `JArray` under the `objects` key, and `encodeCanonical`'d. A `ModelError` on
/// any object (e.g. an unsignable checkpoint envelope) fails the WHOLE batch as a
/// typed `Err` — never a partial body. The mapper's dependency order (session →
/// steps → terminal checkpoint) is preserved verbatim; do not sort or dedupe
/// (§6 idempotency rides the content ids).
///
/// The objects form (not the `session_events` envelope form) is what the runner
/// POSTs: its objects already carry the `file_change` step and — when a workspace
/// tree was captured — the terminal checkpoint, the exact things that make Q4
/// answer; the envelope form would re-map via `mapStreamJson` and drop both.
///
/// Pure and offline (no Docker/DB/HTTP) so it is unit-testable from a
/// `@test_module` — the runner (`docker_manager.l` `emitRunnerCheckpoint`) calls
/// it synchronously after a successful emit, then POSTs the returned body.
pub func objectsToIngestJson(objects: in List[ProvenanceObject]): Result[String, BridgeError] {
  val items: List[JsonValue] = newList()
  var i = 0
  while i < objects.count {
    match encodeObject(objects[i]) {
      case Ok(jv) -> items.add(jv)
      case Err(e) -> return Err(error = MapFailed(detail = "encode object " + toString(i) + ": " + modelErrorMessage(e)))
    }
    i = i + 1
  }
  val entries: List[JsonEntry] = newList()
  entries.add(JsonEntry(key = "objects", value = JArray(items = items)))
  return Ok(value = encodeCanonical(JObject(entries = entries)))
}
