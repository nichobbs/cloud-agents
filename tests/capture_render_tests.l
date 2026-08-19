//! Offline tests for CloudAgents.Capture.Render (docs/capture-display-render.md
//! §4). No Docker/DB/network, no wall-clock reads. The first two tests are
//! GROUNDED on REAL harness output: they read the checked-in fixtures captured
//! from `claude -p --output-format stream-json --verbose` against a live harness
//! (tests/fixtures/stream-json/, sanitized only for session-identifying
//! ids/paths), parse them with the real capture core, and assert the display
//! reconstruction reproduces the visible assistant transcript. The remaining
//! tests cover the render contract on synthetic and adversarial events.
@test_module
package CloudAgents.CaptureRenderTests

import Std.Core
import Std.Collections
import Std.File
import Std.Testing
import CloudAgents.Capture
import CloudAgents.Capture.Render
import CloudAgents.Text
import extern System.Text.Encoding as Encoding

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

// Bytes -> string for reading the real fixtures (mirrors library_seed_tests'
// own private helper — not pub on either side, one-FFI-surface-per-file).
@externInstance
@externTarget("System.Text.Encoding.GetString")
func utf8FromBytes(enc: in Encoding, bytes: in slice[Byte]): String = ""

// Read a checked-in fixture (relative to the repo root, lyric test's CWD — the
// same resolution seed/ uses in library_seed_tests).
func readFixture(path: in String): String {
  return match Std.File.readBytes(path) {
    case Ok(bytes) -> utf8FromBytes(utf8Encoding(), bytes.toArray())
    case Err(_) -> ""
  }
}

func simpleFixture(): String {
  return readFixture("tests/fixtures/stream-json/simple-turn.ndjson")
}

func toolUseFixture(): String {
  return readFixture("tests/fixtures/stream-json/tool-use-turn.ndjson")
}

// A synthetic assistant CaptureEvent carrying the given content-array JSON.
func assistantEvent(seq: in Long, contentJson: in String): CaptureEvent {
  return CaptureEvent(
    seq = seq,
    eventType = "assistant",
    payload = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":" + contentJson + "}}",
    prevHash = "",
    hash = ""
  )
}

func rawEvent(seq: in Long, etype: in String, payload: in String): CaptureEvent {
  return CaptureEvent(seq = seq, eventType = etype, payload = payload, prevHash = "", hash = "")
}

func resultText(o: in Option[String]): String {
  return match o {
    case Some(s) -> s
    case None -> "<none>"
  }
}

// ── Test 1: REAL simple turn ──
test "a real stream-json turn renders to its visible reply text (fixture)" {
  val nd = simpleFixture()
  assertTrue(nd.length.toInt() > 0, "fixture loaded")
  val b = parseStreamJson(nd, 0.toLong(), "")
  assertEqualInt(b.events.length.toInt(), 8, "simple fixture has 8 events")
  assertTrue(verifyChain(b.events, ""), "real fixture chain verifies")
  assertEqual(renderDisplayText(b.events), "pong", "reconstructed transcript is the reply")
  assertEqual(resultText(finalResultText(b.events)), "pong", "final result text is the reply")
}

// ── Test 2: REAL tool-use turn (thinking/tool_use/tool_result excluded) ──
test "a real tool-use turn renders only the visible text block (fixture)" {
  val nd = toolUseFixture()
  assertTrue(nd.length.toInt() > 0, "fixture loaded")
  val b = parseStreamJson(nd, 0.toLong(), "")
  assertEqualInt(b.events.length.toInt(), 13, "tool-use fixture has 13 events")
  assertTrue(verifyChain(b.events, ""), "real fixture chain verifies")
  // The turn contains assistant events with thinking + tool_use blocks and a
  // user event with a tool_result block; only the final text block is visible.
  assertEqual(renderDisplayText(b.events), "3", "only the visible text block renders")
  assertEqual(resultText(finalResultText(b.events)), "3", "final result text")
}

// ── Test 3: multiple text blocks in one event concatenate ──
test "multiple text blocks in one assistant event concatenate in order" {
  val ev = assistantEvent(0.toLong(), "[{\"type\":\"text\",\"text\":\"foo\"},{\"type\":\"text\",\"text\":\"bar\"}]")
  assertEqual(displayTextOf(ev), "foobar", "text blocks concatenate")
}

// ── Test 4: thinking / tool_use blocks are excluded ──
test "thinking and tool_use blocks contribute no display text" {
  val thinking = assistantEvent(0.toLong(), "[{\"type\":\"thinking\",\"thinking\":\"secret\"}]")
  assertEqual(displayTextOf(thinking), "", "thinking excluded")
  val toolUse = assistantEvent(1.toLong(), "[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Read\",\"input\":{}}]")
  assertEqual(displayTextOf(toolUse), "", "tool_use excluded")
  val mixed = assistantEvent(2.toLong(), "[{\"type\":\"thinking\",\"thinking\":\"x\"},{\"type\":\"text\",\"text\":\"hi\"}]")
  assertEqual(displayTextOf(mixed), "hi", "only the text block of a mixed turn renders")
}

// ── Test 5: control and user events contribute nothing ──
test "control and non-assistant events render empty" {
  val sys = rawEvent(0.toLong(), "system", "{\"type\":\"system\",\"subtype\":\"init\",\"cwd\":\"/workspace\"}")
  assertEqual(displayTextOf(sys), "", "system event empty")
  val goal = rawEvent(1.toLong(), "active_goal", "{\"type\":\"active_goal\",\"value\":\"x\"}")
  assertEqual(displayTextOf(goal), "", "active_goal event empty")
  val usr = rawEvent(2.toLong(), "user", "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"out\"}]}}")
  assertEqual(displayTextOf(usr), "", "user/tool_result event empty")
}

// ── Test 6: renderDisplayText joins successive assistant turns with a newline ──
test "successive assistant text events are newline-joined" {
  val events: List[CaptureEvent] = newList()
  events.add(rawEvent(0.toLong(), "system", "{\"type\":\"system\"}"))
  events.add(assistantEvent(1.toLong(), "[{\"type\":\"text\",\"text\":\"first\"}]"))
  events.add(rawEvent(2.toLong(), "active_goal", "{\"type\":\"active_goal\"}"))
  events.add(assistantEvent(3.toLong(), "[{\"type\":\"text\",\"text\":\"second\"}]"))
  assertEqual(renderDisplayText(events.toArray()), "first\nsecond", "two turns joined by one newline, controls skipped")
}

// ── Test 7: totality on adversarial input ──
test "malformed and non-string payloads render empty, never throw" {
  val notJson = rawEvent(0.toLong(), "assistant", "this is not json")
  assertEqual(displayTextOf(notJson), "", "non-JSON assistant payload -> empty")
  val nonStringText = assistantEvent(1.toLong(), "[{\"type\":\"text\",\"text\":123}]")
  assertEqual(displayTextOf(nonStringText), "", "non-string text -> empty (guarded getString)")
  val contentNotArray = rawEvent(2.toLong(), "assistant", "{\"type\":\"assistant\",\"message\":{\"content\":\"oops\"}}")
  assertEqual(displayTextOf(contentNotArray), "", "non-array content -> empty")
  // A valid-JSON but non-object root (only reachable via a mislabeled event):
  // tryGetProperty would throw on it, so the valueKind guard must catch it.
  val arrayRoot = rawEvent(3.toLong(), "assistant", "[1,2,3]")
  assertEqual(displayTextOf(arrayRoot), "", "JSON-array root -> empty, no throw")
  val stringRoot = rawEvent(4.toLong(), "assistant", "\"just a string\"")
  assertEqual(displayTextOf(stringRoot), "", "JSON-string root -> empty, no throw")
  val messageNotObject = rawEvent(5.toLong(), "assistant", "{\"type\":\"assistant\",\"message\":[1,2]}")
  assertEqual(displayTextOf(messageNotObject), "", "non-object message -> empty, no throw")
  // finalResultText is equally total on a non-object result root.
  val resultArrayRoot: List[CaptureEvent] = newList()
  resultArrayRoot.add(rawEvent(0.toLong(), "result", "[1,2,3]"))
  assertEqual(resultText(finalResultText(resultArrayRoot.toArray())), "<none>", "non-object result root -> None, no throw")
}

// ── Test 8: finalResultText None when no result event ──
test "finalResultText is None when the turn has no result event" {
  val events: List[CaptureEvent] = newList()
  events.add(assistantEvent(0.toLong(), "[{\"type\":\"text\",\"text\":\"hi\"}]"))
  assertEqual(resultText(finalResultText(events.toArray())), "<none>", "no result event -> None")
  // And renderDisplayText of an all-control batch is empty.
  val controls: List[CaptureEvent] = newList()
  controls.add(rawEvent(0.toLong(), "system", "{\"type\":\"system\"}"))
  controls.add(rawEvent(1.toLong(), "rate_limit_event", "{\"type\":\"rate_limit_event\"}"))
  assertEqual(renderDisplayText(controls.toArray()), "", "all-control batch renders empty")
}

// ── renderLogDelta: incremental NDJSON log → (display + capture) ──
test "renderLogDelta renders a whole newline-terminated log in one pass" {
  val log = simpleFixture()   // ends with a trailing newline
  val rd = renderLogDelta(log, 0, 0.toLong(), "", false)
  assertEqualInt(rd.events.length.toInt(), 8, "all 8 events consumed")
  assertEqual(rd.displayText, "pong", "the reply is rendered")
  assertEqualInt(rd.consumed, log.length.toInt(), "the whole log is consumed (ends on a line boundary)")
  assertTrue(verifyChain(rd.events, ""), "the rendered events chain-verify")
}

test "renderLogDelta leaves a partial trailing line unconsumed" {
  val log = simpleFixture()
  // Append a partial (newline-less) trailing line — mid-write container output.
  val partial = log + "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"half"
  val rd = renderLogDelta(partial, 0, 0.toLong(), "", false)
  assertEqualInt(rd.events.length.toInt(), 8, "only the 8 complete lines are consumed")
  assertEqualInt(rd.consumed, log.length.toInt(), "consumed stops at the last newline, before the partial line")
  assertEqual(rd.displayText, "pong", "the partial line contributes no text yet")
}

test "renderLogDelta atEnd consumes a newline-less final line (regression #973)" {
  val log = simpleFixture()
  // A trailing `result` event with NO trailing newline — the shape the harness
  // emits at end-of-stream. On a live tick it stays buffered; at end-of-stream
  // (atEnd = true) it MUST be consumed, else the terminal result is dropped.
  val tail = "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"final answer\"}"
  val withTail = log + tail
  // Live tick: the newline-less tail is held back.
  val live = renderLogDelta(withTail, 0, 0.toLong(), "", false)
  assertEqualInt(live.consumed, log.length.toInt(), "live tick stops before the newline-less tail")
  // End-of-stream: the whole delta is consumed, tail included.
  val fin = renderLogDelta(withTail, 0, 0.toLong(), "", true)
  assertEqualInt(fin.consumed, withTail.length.toInt(), "atEnd consumes the whole log, tail included")
  assertEqualInt(fin.events.length.toInt(), 9, "the 8 complete lines PLUS the newline-less result event")
  // The terminal result text is now recoverable — it would have been dropped
  // by the pre-fix truncate-at-last-newline behavior.
  match finalResultText(fin.events) {
    case Some(s) -> assertEqual(s, "final answer", "the terminal result survives to the final flush")
    case None -> assertTrue(false, "the terminal result event must be present after atEnd render")
  }
}

test "renderLogDelta is incremental: two calls equal one, chain continues" {
  val log = simpleFixture()
  // Find a mid-log line boundary to split on.
  val firstNl = CloudAgents.Text.indexOfFrom(log, "\n", 0)
  val splitAt = CloudAgents.Text.indexOfFrom(log, "\n", firstNl + 1) + 1   // after the 2nd line
  val head = log.substring(0, splitAt)
  // Tick 1: render the head (2 complete lines).
  val rd1 = renderLogDelta(log, 0, 0.toLong(), "", false)   // full log available, but we only advance by consumed
  // Simulate two ticks over the SAME growing log by parsing head then the rest.
  val a = renderLogDelta(head, 0, 0.toLong(), "", false)
  val b = renderLogDelta(log, a.consumed, a.nextSeq, a.lastHash, false)
  assertEqualInt(a.events.length.toInt() + b.events.length.toInt(), 8, "two ticks consume all 8 events")
  assertEqual(a.lastHash, rd1.events[a.events.length.toInt() - 1].hash, "tick-1 chain matches the one-pass chain")
  // The concatenation of both ticks' events chain-verifies as one run.
  val all: List[CaptureEvent] = newList()
  var i = 0
  while i < a.events.length.toInt() {
    all.add(a.events[i])
    i = i + 1
  }
  var j = 0
  while j < b.events.length.toInt() {
    all.add(b.events[j])
    j = j + 1
  }
  assertTrue(verifyChain(all.toArray(), ""), "the two-tick chain verifies end to end")
}

test "renderLogDelta consumes nothing when there is no complete line yet" {
  val rd = renderLogDelta("{\"type\":\"assistant\",\"message\":{}", 0, 5.toLong(), "seedhash", false)
  assertEqualInt(rd.consumed, 0, "a lone partial line consumes nothing")
  assertEqualInt(rd.events.length.toInt(), 0, "no events")
  assertEqualInt(rd.nextSeq.toInt(), 5, "chain state is carried through unchanged")
  assertEqual(rd.lastHash, "seedhash", "prevHash carried through")
}

test "renderFullLog renders a whole log to its transcript" {
  assertEqual(renderFullLog(simpleFixture()), "pong", "simple turn")
  assertEqual(renderFullLog(toolUseFixture()), "3", "tool-use turn, only the visible text")
}

test "renderFullLog renders a newline-less final assistant line (regression #973)" {
  // A complete log whose last line — the visible reply — has no trailing
  // newline. renderFullLog treats the finished log as authoritative and renders
  // it; the pre-fix truncate-at-last-newline behavior dropped it entirely.
  val log = "{\"type\":\"system\",\"subtype\":\"init\"}\n" +
    "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}"
  assertEqual(renderFullLog(log), "done", "the newline-less final reply is rendered, not dropped")
}
