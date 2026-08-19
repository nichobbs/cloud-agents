//! Offline tests for CloudAgents.CheckpointBridge (docs/capture-checkpoint.md
//! §6). No Docker/DB/network, no wall-clock reads — the transcript is literal
//! NDJSON and every timestamp is a fixed literal.
//!
//! The headline is the **cross-repo drift guard**: a fixed captured transcript,
//! mapped through the bridge (CloudAgents.Capture → vendored
//! Testamur.CheckpointFormat.Adapt), must produce the exact content addresses
//! that testamur computes for the same input. The expected `sess-`/`ckpt-` ids
//! below were computed by running `Adapt.mapStreamJson` on this identical
//! transcript + context in the testamur repo (main @ 0aac550); if the vendored
//! copy ever drifts from upstream behavior, these assertions fail — which is the
//! whole point of pinning them.
@test_module
package CloudAgents.CheckpointBridgeTests

import Std.Core
import Std.Collections
import Std.Testing
import CloudAgents.Capture
import CloudAgents.CheckpointBridge
import Testamur.CheckpointFormat.Adapt
import Testamur.CheckpointFormat.Model

// ── Fixed captured transcript (a small, realistic claude -p stream-json run) ──
// One assistant text turn, one tool_use + its tool_result (they merge into a
// single tool_use step), and one unmappable system event (→ a note step).
func lText(): String {
  return "{\"type\":\"assistant\",\"timestamp\":\"2026-08-14T10:50:50Z\",\"message\":{\"model\":\"claude-sonnet-5\",\"usage\":{\"input_tokens\":2,\"output_tokens\":1},\"content\":[{\"type\":\"text\",\"text\":\"Hello, reading it now.\"}]}}"
}

func lToolUse(): String {
  return "{\"type\":\"assistant\",\"timestamp\":\"2026-08-14T10:50:51Z\",\"message\":{\"model\":\"claude-sonnet-5\",\"content\":[{\"type\":\"tool_use\",\"id\":\"tu-1\",\"name\":\"Read\",\"input\":{\"file_path\":\"notes.txt\"}}]}}"
}

func lToolResult(): String {
  return "{\"type\":\"user\",\"timestamp\":\"2026-08-14T10:50:52Z\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu-1\",\"content\":\"file body\"}]}}"
}

func lSystemNote(): String {
  return "{\"type\":\"system\",\"subtype\":\"status\",\"timestamp\":\"2026-08-14T10:50:53Z\"}"
}

func transcript(): String {
  return lText() + "\n" + lToolUse() + "\n" + lToolResult() + "\n" + lSystemNote() + "\n"
}

// The invocation context the runner would have had — all literals (data, never
// wall clock). Built through the bridge's own helper so the test exercises it.
func ctx(): InvocationContext {
  return runnerContext(
    "agent:cloud-agents-runner",
    "cloud-agents runner",
    "https://github.com/nichobbs/cloud-agents#dev",
    "2026-08-14T10:50:45Z",
    "Summarize notes.txt.",
    "claude-sonnet-5",
    "auto",
    Some(value = "0f79b1731289bfc1c66399b9db0dd42e838cba25")
  )
}

// The authoritative content addresses, computed by testamur@0aac550 for the
// transcript + context above (see the module doc).
func expectedSessionId(): String {
  return "sess-76b24263d29d4ce72032bab4dc30f876ea7982fb29bc46e51f2dcdbb90c58273"
}

func expectedCheckpointId(): String {
  return "ckpt-1288124a8af3ecd0b8e86f1c633d952d35c96ab411cceb4115642c7eaabac3c7"
}

func mustEmit(): StreamJsonMapping {
  return match emitFromTranscript(transcript(), ctx()) {
    case Ok(m) -> m
    case Err(e) -> panic("emitFromTranscript failed: " + bridgeErrorMessage(e))
  }
}

func kindsString(m: in StreamJsonMapping): String {
  var s = ""
  var i = 0
  while i < m.eventKinds.count {
    s = s + "[" + m.eventKinds[i] + "]"
    i = i + 1
  }
  return s
}

// ── Test 1: cross-repo drift guard — exact content addresses ──
test "captured transcript maps to the exact ids testamur computes" {
  val m = mustEmit()
  assertEqual(m.sessionId, expectedSessionId(), "session id matches testamur's content address")
  match m.checkpointId {
    case Some(c) -> assertEqual(c, expectedCheckpointId(), "checkpoint id matches testamur's content address")
    case None -> assertTrue(false, "expected a terminal checkpoint (context carried a tree)")
  }
}

// ── Test 2: event accounting + per-event kinds (no silent drops) ──
test "mapped + note counts sum to total; kinds are exactly as mapped" {
  val m = mustEmit()
  assertEqualInt(m.totalEvents, 4, "four captured events")
  assertEqualInt(m.mappedEvents, 3, "text + tool_use registration + tool_result completion map")
  assertEqualInt(m.noteEvents, 1, "the system event is the one note")
  assertEqualInt(m.mappedEvents + m.noteEvents, m.totalEvents, "no event silently dropped")
  assertEqual(kindsString(m), "[response][tool_use][tool_use][note]", "exact per-event kind sequence")
  // 1 session + 4 steps (prompt + response + tool_use + note) + 1 checkpoint.
  assertEqualInt(m.objects.count, 6, "one session, four steps, one checkpoint")
}

// ── Test 3: no workspace tree ⇒ mapping stops at steps (no checkpoint) ──
test "without a tree, no terminal checkpoint is emitted" {
  val noTree = runnerContext(
    "agent:cloud-agents-runner",
    "cloud-agents runner",
    "https://github.com/nichobbs/cloud-agents#dev",
    "2026-08-14T10:50:45Z",
    "Summarize notes.txt.",
    "claude-sonnet-5",
    "auto",
    None
  )
  val m = match emitFromTranscript(transcript(), noTree) {
    case Ok(x) -> x
    case Err(e) -> panic("emit failed: " + bridgeErrorMessage(e))
  }
  match m.checkpointId {
    case Some(_) -> assertTrue(false, "no tree ⇒ expected no checkpoint id")
    case None -> assertTrue(true, "no checkpoint emitted without a tree")
  }
  assertEqualInt(m.objects.count, 5, "one session + four steps, no checkpoint")
}

// ── Test 4: a tampered capture is rejected before mapping ──
test "emitFromCapture rejects a mutated capture chain as ChainInvalid" {
  val batch = parseStreamJson(transcript(), 0.toLong(), "")
  // Rebuild the event slice with one payload mutated but its stored hash kept —
  // exactly what a tamper looks like: verifyChain recomputes and mismatches.
  val tampered: List[CaptureEvent] = newList()
  var i = 0
  while i < batch.events.length.toInt() {
    val e = batch.events[i]
    if i == 2 {
      tampered.add(
        CaptureEvent(
          seq = e.seq,
          eventType = e.eventType,
          payload = e.payload + " TAMPERED",
          prevHash = e.prevHash,
          hash = e.hash
        )
      )
    } else {
      tampered.add(e)
    }
    i = i + 1
  }
  match emitFromCapture(tampered.toArray(), "", ctx()) {
    case Ok(_) -> assertTrue(false, "a mutated payload must not map")
    case Err(err) -> match err { case ChainInvalid(_) -> assertTrue(true, "mutation detected as ChainInvalid"); case MapFailed(_) -> assertTrue(false, "expected ChainInvalid, not MapFailed") }
  }
}

// ── Test 5: a wrong genesis prevHash is also rejected ──
test "emitFromCapture rejects a chain that does not start at the given genesis" {
  val batch = parseStreamJson(transcript(), 0.toLong(), "")
  match emitFromCapture(batch.events, "not-the-genesis", ctx()) {
    case Ok(_) -> assertTrue(false, "wrong genesis must not map")
    case Err(err) -> match err { case ChainInvalid(_) -> assertTrue(true, "genesis mismatch detected"); case MapFailed(_) -> assertTrue(false, "expected ChainInvalid, not MapFailed") }
  }
}

// ── Test 6: a malformed captured line survives as a note (no drop) ──
test "a malformed captured line becomes a note step, never dropped" {
  val nd = lText() + "\n" + "this is not json" + "\n" + lSystemNote() + "\n"
  val m = match emitFromTranscript(nd, ctx()) {
    case Ok(x) -> x
    case Err(e) -> panic("emit failed: " + bridgeErrorMessage(e))
  }
  assertEqualInt(m.totalEvents, 3, "three captured lines")
  assertEqualInt(m.mappedEvents, 1, "only the assistant text maps")
  assertEqualInt(m.noteEvents, 2, "the non-JSON line and the system event are notes")
  assertEqualInt(m.mappedEvents + m.noteEvents, m.totalEvents, "no line silently dropped")
}

// ── Test 7: permissionOf maps every mode; unknown falls back to auto (#958) ──
test "permissionOf maps granted/denied/auto and falls back to auto" {
  assertEqual(permissionName(permissionOf("granted")), "granted", "\"granted\" → Granted")
  assertEqual(permissionName(permissionOf("denied")), "denied", "\"denied\" → Denied")
  assertEqual(permissionName(permissionOf("auto")), "auto", "\"auto\" → Auto")
  assertEqual(permissionName(permissionOf("")), "auto", "empty falls back to Auto")
  assertEqual(permissionName(permissionOf("nonsense")), "auto", "unknown mode falls back to Auto (least-claiming)")
}

// ── Test 8: bridgeErrorMessage renders both error cases (#959) ──
test "bridgeErrorMessage renders ChainInvalid and MapFailed" {
  val chain = bridgeErrorMessage(ChainInvalid(detail = "discontinuity at seq 3"))
  assertTrue(chain.contains("capture chain invalid:"), "ChainInvalid names the failure class")
  assertTrue(chain.contains("discontinuity at seq 3"), "ChainInvalid carries the detail")
  val mapf = bridgeErrorMessage(MapFailed(detail = "ill-formed UTF-16"))
  assertTrue(mapf.contains("checkpoint mapping failed:"), "MapFailed names the failure class")
  assertTrue(mapf.contains("ill-formed UTF-16"), "MapFailed carries the detail")
}

// ── file_change capture through the bridge (ADR-0016; re-vendor of testamur #127) ──
func eventsOf(): slice[CaptureEvent] {
  return parseStreamJson(transcript(), 0.toLong(), "").events
}

// A real `git diff` over notes.txt (one replace + one append) — verbatim git
// unified output, the shape the runner's inspect-diff path emits.
func realDiff(): String {
  return "diff --git a/notes.txt b/notes.txt\n" +
    "index 83db48f..e0c9b5e 100644\n" +
    "--- a/notes.txt\n" +
    "+++ b/notes.txt\n" +
    "@@ -1,3 +1,4 @@\n" +
    " line1\n" +
    "-line2\n" +
    "+CHANGED\n" +
    " line3\n" +
    "+line4\n"
}

func fileChangeStepOf(m: in StreamJsonMapping): Option[Step] {
  var found: Option[Step] = None
  var i = 0
  while i < m.objects.count {
    match m.objects[i] {
      case StepObject(step) -> {
        if stepKindName(step.body) == "file_change" {
          found = Some(value = step)
        }
      }
      case SessionObject(_) -> ()
      case CheckpointObject(_) -> ()
    }
    i = i + 1
  }
  return found
}

test "emitFromCaptureWithFileChanges with EMPTY deltas keeps the exact drift-guard ids" {
  val noDelta: List[FileDelta] = newList()
  val base = match emitFromCaptureWithFileChanges(eventsOf(), "", ctx(), noDelta) {
    case Ok(m) -> m
    case Err(e) -> panic("emitFromCaptureWithFileChanges failed: " + bridgeErrorMessage(e))
  }
  assertEqual(base.sessionId, expectedSessionId(), "empty deltas: session id unchanged (no drift)")
  match base.checkpointId {
    case Some(c) -> assertEqual(c, expectedCheckpointId(), "empty deltas: checkpoint id unchanged (no drift)")
    case None -> assertTrue(false, "expected a checkpoint")
  }
  match fileChangeStepOf(base) {
    case Some(_) -> assertTrue(false, "no file_change step with empty deltas")
    case None -> assertTrue(true, "no file_change step emitted")
  }
}

test "emitFromCaptureWithDiff parses a real git diff into a file_change step and re-anchors the checkpoint" {
  val m = match emitFromCaptureWithDiff(eventsOf(), "", ctx(), realDiff()) {
    case Ok(mm) -> mm
    case Err(e) -> panic("emitFromCaptureWithDiff failed: " + bridgeErrorMessage(e))
  }
  match fileChangeStepOf(m) {
    case Some(step) -> {
      match step.body {
        case FileChangeBody(files) -> {
          assertEqualInt(files.count, 1, "one changed file")
          assertEqual(files[0].path, "notes.txt", "path parsed from the diff")
          assertEqualInt(files[0].hunks.count, 1, "one hunk")
          assertEqualInt(files[0].hunks[0].start.toInt(), 1, "new-side hunk start")
          assertEqualInt(files[0].hunks[0].lines.toInt(), 4, "new-side hunk lines")
        }
        case _ -> assertTrue(false, "the file_change step must carry a FileChangeBody")
      }
    }
    case None -> assertTrue(false, "a file_change step must be emitted from a non-empty diff")
  }
  // The checkpoint now covers the file_change step, so its id differs from the
  // no-diff drift-guard id.
  match m.checkpointId {
    case Some(c) -> assertTrue(c != expectedCheckpointId(), "checkpoint re-anchored over the file_change step")
    case None -> assertTrue(false, "expected a checkpoint")
  }
}

test "emitFromCaptureWithDiff on an empty diff is byte-identical to emitFromCapture" {
  val m = match emitFromCaptureWithDiff(eventsOf(), "", ctx(), "") {
    case Ok(mm) -> mm
    case Err(e) -> panic("emitFromCaptureWithDiff failed: " + bridgeErrorMessage(e))
  }
  assertEqual(m.sessionId, expectedSessionId(), "empty diff: session id unchanged")
  match m.checkpointId {
    case Some(c) -> assertEqual(c, expectedCheckpointId(), "empty diff: checkpoint id unchanged")
    case None -> assertTrue(false, "expected a checkpoint")
  }
}
