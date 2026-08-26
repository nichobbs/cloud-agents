//! LIVE end-to-end capture verification (docs/capture-checkpoint.md §8 "runner
//! live flow"; Testamur ADR-0016). GROUNDED on a FRESH real session: a live
//! `claude -p --output-format stream-json --verbose` run was pointed at a real
//! git workspace and told to add a function to `app.py`; it used the Edit tool
//! and actually changed the file. Both the raw NDJSON transcript
//! (`tests/fixtures/stream-json/live-edit-turn.ndjson`) and the real
//! `git diff HEAD` (`tests/fixtures/stream-json/live-edit.diff`) were captured
//! verbatim (sanitized only for the session id and absolute paths, per this
//! repo's fixture policy) and are exercised here through the ACTUAL runner
//! pipeline — `parseStreamJson` → `verifyChain` → `emitFromCaptureWithDiff` —
//! the same calls the runner makes at end of a session.
//!
//! Unlike the existing capture/bridge suites (synthetic or conversation-only
//! fixtures), this proves the whole capture→checkpoint chain works on a session
//! that REALLY edited a file: the emitted checkpoint carries an agent-origin
//! `file_change` step whose new-side hunk matches the real diff, which is exactly
//! what makes Testamur's Q4 answer on a runner session. No Docker/DB/network at
//! test time — the live harness produced the fixtures; the pipeline is pure.
@test_module
package CloudAgents.LiveCaptureE2eTests

import Std.Core
import Std.Collections
import Std.File
import Std.Testing
import CloudAgents.Capture
import CloudAgents.CheckpointBridge
import Testamur.CheckpointFormat.Model
import extern System.Text.Encoding as Encoding

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func utf8FromBytes(enc: in Encoding, bytes: in slice[Byte]): String = ""

func readFixture(path: in String): String {
  return match Std.File.readBytes(path) {
    case Ok(bytes) -> utf8FromBytes(utf8Encoding(), bytes.toArray())
    case Err(_) -> ""
  }
}

func liveNdjson(): String {
  return readFixture("tests/fixtures/stream-json/live-edit-turn.ndjson")
}

func liveDiff(): String {
  return readFixture("tests/fixtures/stream-json/live-edit.diff")
}

// The invocation context the runner would have had for this session — literals
// (data, never the wall clock), built through the bridge's own helper. The tree
// hash is a placeholder for the workspace git tree the runner snapshots; its
// presence is what makes a terminal checkpoint be emitted.
func ctx(): InvocationContext {
  return runnerContext(
    "agent:cloud-agents-runner",
    "cloud-agents runner",
    "/workspace",
    "2026-08-22T11:35:00Z",
    "Add a new function farewell(name) to app.py that returns \"bye \" + name.",
    "claude-sonnet-5",
    "auto",
    Some(value = "0f79b1731289bfc1c66399b9db0dd42e838cba25")
  )
}

// The PRODUCTION call shape (#1021): the runner's emitRunnerCheckpoint passes
// treeHash = None (the workspace git tree id isn't captured yet), and the
// agent-convention principal id "agent:<harness>". Mirrors that exactly.
func ctxNoTree(): InvocationContext {
  return runnerContext(
    "agent:claude",
    "claude",
    "/workspace",
    "2026-08-22T11:35:00Z",
    "Add a new function farewell(name) to app.py that returns \"bye \" + name.",
    "claude-sonnet-5",
    "auto",
    None
  )
}

func parseLive(): slice[CaptureEvent] {
  return parseStreamJson(liveNdjson(), 0.toLong(), "").events
}

// Count file_change steps in the emitted objects and, for the first one, return
// its (path, start, lines) plus whether the blob hashes are absent.
record FileChangeProbe {
  count: Int
  path: String
  start: Long
  lines: Long
  hashesAbsent: Bool
}

func probeFileChange(m: in StreamJsonMapping): FileChangeProbe {
  var count = 0
  var path = ""
  var start = 0.toLong()
  var lines = 0.toLong()
  var hashesAbsent = false
  var i = 0
  while i < m.objects.count {
    match m.objects[i] {
      case StepObject(step) -> match step.body {
        case FileChangeBody(files) -> {
          count = count + 1
          if count == 1 and files.count > 0 {
            path = files[0].path
            val before = match files[0].beforeSha256 { case Some(_) -> false; case None -> true }
            val after = match files[0].afterSha256 { case Some(_) -> false; case None -> true }
            hashesAbsent = before and after
            if files[0].hunks.count > 0 {
              start = files[0].hunks[0].start
              lines = files[0].hunks[0].lines
            }
          }
        }
        case _ -> ()
      }
      case _ -> ()
    }
    i = i + 1
  }
  return FileChangeProbe(count = count, path = path, start = start, lines = lines, hashesAbsent = hashesAbsent)
}

// ── The real capture is a well-formed, verifiable hash chain ──
test "LIVE: a fresh real claude -p capture parses and verifies as a hash chain" {
  val events = parseLive()
  assertTrue(events.length.toInt() >= 1, "the live transcript produced captured events")
  assertTrue(verifyChain(events, ""), "the captured chain verifies (continuous, untampered)")
}

// ── The real session + real diff emit a file_change-bearing checkpoint ──
test "LIVE: the real edit session emits a checkpoint whose file_change hunk matches the real git diff" {
  val events = parseLive()
  val m = match emitFromCaptureWithDiff(events, "", ctx(), liveDiff()) {
    case Ok(mm) -> mm
    case Err(e) -> panic("emitFromCaptureWithDiff failed on the live capture: " + bridgeErrorMessage(e))
  }
  // A terminal checkpoint is present (context carried a workspace tree).
  match m.checkpointId {
    case Some(c) -> assertTrue(c.length.toInt() > 5, "a content-addressed checkpoint id was emitted: " + c)
    case None -> assertTrue(false, "expected a terminal checkpoint from the real session")
  }
  // The workspace diff became exactly one agent-origin file_change step whose
  // new-side hunk is the real diff's `@@ -1,2 +1,6 @@` (start 1, 6 lines).
  val probe = probeFileChange(m)
  assertEqualInt(probe.count, 1, "exactly one file_change step (the captured workspace diff)")
  assertEqual(probe.path, "app.py", "the changed file is app.py")
  assertEqual(toString(probe.start), "1", "new-side hunk start line matches the diff (+1)")
  assertEqual(toString(probe.lines), "6", "new-side hunk line count matches the diff (,6)")
  assertTrue(probe.hashesAbsent, "blob sha256s stay None (git blob ids are SHA-1; Q4 needs only ranges)")
  // Nothing was silently dropped in the transcript mapping.
  assertEqualInt(m.mappedEvents + m.noteEvents, m.totalEvents, "every captured event is mapped or noted")
}

// ── Without the diff, the same session emits no file_change (fails safe) ──
test "LIVE: the same capture with no diff emits no file_change step" {
  val events = parseLive()
  val m = match emitFromCaptureWithDiff(events, "", ctx(), "") {
    case Ok(mm) -> mm
    case Err(e) -> panic("emitFromCaptureWithDiff failed: " + bridgeErrorMessage(e))
  }
  assertEqualInt(probeFileChange(m).count, 0, "an empty diff adds no file_change step")
}

// ── The runner's actual end-of-run call: emitFromRunnerCapture(rawNdjson, diff) ──
// This is exactly what docker_manager.l's emitRunnerCheckpoint delegates to — the
// raw NDJSON string (cell.output) + the workspace diff, in one call. It must match
// the explicit parse+emit path above.
test "LIVE: emitFromRunnerCapture (the runner's end-of-run seam) matches parse + diff-threaded emit" {
  val m = match emitFromRunnerCapture(liveNdjson(), liveDiff(), ctx()) {
    case Ok(mm) -> mm
    case Err(e) -> panic("emitFromRunnerCapture failed on the live capture: " + bridgeErrorMessage(e))
  }
  val probe = probeFileChange(m)
  assertEqualInt(probe.count, 1, "one agent-origin file_change step from the workspace diff")
  assertEqual(probe.path, "app.py", "the changed file is app.py")
  assertEqual(toString(probe.start), "1", "new-side hunk start (+1)")
  assertEqual(toString(probe.lines), "6", "new-side hunk lines (,6)")
  match m.checkpointId {
    case Some(c) -> assertTrue(c.length.toInt() > 5, "terminal checkpoint emitted (ctx carries a tree): " + c)
    case None -> assertTrue(false, "expected a terminal checkpoint")
  }
  assertEqualInt(m.mappedEvents + m.noteEvents, m.totalEvents, "no captured event dropped")
}

// ── The exact production shape: treeHash=None (steps-only, no terminal checkpoint) ──
test "LIVE: emitFromRunnerCapture with treeHash=None (the production call shape) yields the file_change step but no terminal checkpoint" {
  val m = match emitFromRunnerCapture(liveNdjson(), liveDiff(), ctxNoTree()) {
    case Ok(mm) -> mm
    case Err(e) -> panic("emitFromRunnerCapture failed: " + bridgeErrorMessage(e))
  }
  // The runner passes treeHash=None today, so the mapping stops at steps — no
  // terminal checkpoint is produced (matches emitRunnerCheckpoint's runtime call).
  match m.checkpointId {
    case Some(c) -> assertTrue(false, "no terminal checkpoint expected with treeHash=None, got: " + c)
    case None -> assertTrue(true, "steps-only mapping, as in production")
  }
  // The agent-origin file_change step is still emitted from the diff (this is what
  // Q4 will attribute once the objects reach the graph).
  val probe = probeFileChange(m)
  assertEqualInt(probe.count, 1, "the file_change step is present even without a tree")
  assertEqual(probe.path, "app.py", "changed file is app.py")
  assertEqual(toString(probe.start), "1", "new-side hunk start (+1)")
  assertEqual(toString(probe.lines), "6", "new-side hunk lines (,6)")
}
