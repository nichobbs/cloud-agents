//! Offline tests for CloudAgents.Capture (docs/capture-stream-json.md §6).
//! No Docker/DB/network, no wall-clock reads — fixtures are literal NDJSON.
//! Covers parsing a representative turn, the hash chain + determinism, malformed
//! and blank lines, chunked == whole parsing, the empty case, and verifyChain
//! tamper detection (mutation / reorder / drop).
@test_module
package CloudAgents.CaptureTests

import Std.Core
import Std.Collections
import Std.Testing
import CloudAgents.Capture

// ── Fixture NDJSON lines (a representative claude stream-json turn) ──
func lSystem(): String {
  return "{\"type\":\"system\",\"subtype\":\"init\"}"
}

func lAssistant(): String {
  return "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\"}}"
}

func lUser(): String {
  return "{\"type\":\"user\",\"message\":{\"role\":\"user\"}}"
}

func lResult(): String {
  return "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}"
}

func turnNdjson(): String {
  return lSystem() + "\n" + lAssistant() + "\n" + lUser() + "\n" + lResult() + "\n"
}

// ── Test 1: a representative turn ──
test "a stream-json turn parses to typed, seq-ordered, verbatim events" {
  val b = parseStreamJson(turnNdjson(), 0.toLong(), "")
  assertEqualInt(b.events.length.toInt(), 4, "four lines -> four events")
  assertEqualInt(b.events[0].seq.toInt(), 0, "seq starts at 0")
  assertEqualInt(b.events[3].seq.toInt(), 3, "seq is monotonic")
  assertEqual(b.events[0].eventType, "system", "type 0")
  assertEqual(b.events[1].eventType, "assistant", "type 1")
  assertEqual(b.events[2].eventType, "user", "type 2")
  assertEqual(b.events[3].eventType, "result", "type 3")
  assertEqual(b.events[0].payload, lSystem(), "payload is the verbatim line")
  assertEqual(b.events[3].payload, lResult(), "last payload verbatim")
  assertEqualInt(b.nextSeq.toInt(), 4, "nextSeq is one past the last")
  assertEqual(b.lastHash, b.events[3].hash, "lastHash is the final event's hash")
}

// ── Test 2: hash chain links + determinism ──
test "the hash chain links events and is deterministic" {
  val b1 = parseStreamJson(turnNdjson(), 0.toLong(), "")
  assertEqual(b1.events[0].prevHash, "", "genesis prevHash is empty")
  assertEqual(b1.events[1].prevHash, b1.events[0].hash, "each prevHash is the prior hash")
  assertEqual(b1.events[2].prevHash, b1.events[1].hash, "chain continues (2)")
  assertEqual(b1.events[3].prevHash, b1.events[2].hash, "chain continues (3)")
  assertTrue(b1.events[0].hash.length.toInt() == 64, "sha-256 hex is 64 chars")
  // Same input -> identical hashes.
  val b2 = parseStreamJson(turnNdjson(), 0.toLong(), "")
  assertEqual(b2.events[0].hash, b1.events[0].hash, "deterministic hash (0)")
  assertEqual(b2.events[3].hash, b1.events[3].hash, "deterministic hash (3)")
  assertTrue(verifyChain(b1.events, ""), "an intact chain verifies")
}

// ── Test 3: malformed lines are captured, never dropped ──
test "a non-JSON line and a type-less JSON line are captured as malformed" {
  val nd = "this is not json" + "\n" + "{\"foo\":\"bar\"}" + "\n" + lResult() + "\n"
  val b = parseStreamJson(nd, 0.toLong(), "")
  assertEqualInt(b.events.length.toInt(), 3, "all three lines captured (none dropped)")
  assertEqual(b.events[0].eventType, "malformed", "non-JSON -> malformed")
  assertEqual(b.events[0].payload, "this is not json", "raw payload kept")
  assertEqual(b.events[1].eventType, "malformed", "JSON without a string type -> malformed")
  assertEqual(b.events[2].eventType, "result", "a well-formed line after malformed still parses")
  assertTrue(verifyChain(b.events, ""), "the chain spans malformed events too")
}

// ── Test 4: blank lines are skipped ──
test "leading, interior, and trailing blank lines are skipped" {
  val nd = "\n" + lSystem() + "\n\n" + lAssistant() + "\n"
  val b = parseStreamJson(nd, 0.toLong(), "")
  assertEqualInt(b.events.length.toInt(), 2, "only the two non-blank lines become events")
  assertEqual(b.events[0].eventType, "system", "first non-blank")
  assertEqual(b.events[1].eventType, "assistant", "second non-blank")
}

// ── Test 5: chunked parsing == whole-stream parsing ──
test "parsing in line-aligned chunks equals parsing the whole stream" {
  val chunkA = lSystem() + "\n" + lAssistant() + "\n"
  val chunkB = lUser() + "\n" + lResult() + "\n"
  val ba = parseStreamJson(chunkA, 0.toLong(), "")
  val bb = parseStreamJson(chunkB, ba.nextSeq, ba.lastHash)
  val whole = parseStreamJson(chunkA + chunkB, 0.toLong(), "")

  // Reassemble the chunked events in order and compare to the whole parse.
  val combined: List[CaptureEvent] = newList()
  var i = 0
  while i < ba.events.length.toInt() {
    combined.add(ba.events[i])
    i = i + 1
  }
  var j = 0
  while j < bb.events.length.toInt() {
    combined.add(bb.events[j])
    j = j + 1
  }
  assertEqualInt(combined.length.toInt(), whole.events.length.toInt(), "same event count")
  var k = 0
  while k < whole.events.length.toInt() {
    assertEqualInt(combined[k].seq.toInt(), whole.events[k].seq.toInt(), "same seq at " + toString(k))
    assertEqual(combined[k].eventType, whole.events[k].eventType, "same type at " + toString(k))
    assertEqual(combined[k].payload, whole.events[k].payload, "same payload at " + toString(k))
    assertEqual(combined[k].prevHash, whole.events[k].prevHash, "same prevHash at " + toString(k))
    assertEqual(combined[k].hash, whole.events[k].hash, "same hash at " + toString(k))
    k = k + 1
  }
  assertEqual(bb.lastHash, whole.lastHash, "chunked lastHash matches whole")
}

// ── Test 6: empty input ──
test "empty input yields no events and carries seq/hash through" {
  val b = parseStreamJson("", 5.toLong(), "carried-hash")
  assertEqualInt(b.events.length.toInt(), 0, "no events")
  assertEqualInt(b.nextSeq.toInt(), 5, "nextSeq unchanged")
  assertEqual(b.lastHash, "carried-hash", "lastHash carried through")
}

// ── Test 7: verifyChain detects tamper ──
test "verifyChain rejects payload mutation, reordering, and drops" {
  val b = parseStreamJson(turnNdjson(), 0.toLong(), "")
  assertTrue(verifyChain(b.events, ""), "baseline intact chain verifies")

  // Mutation: event 1's payload changed, its stored hash left as-is.
  val mutated: List[CaptureEvent] = newList()
  mutated.add(b.events[0])
  val e1 = b.events[1]
  mutated.add(
    CaptureEvent(seq = e1.seq, eventType = e1.eventType, payload = "TAMPERED", prevHash = e1.prevHash, hash = e1.hash)
  )
  mutated.add(b.events[2])
  mutated.add(b.events[3])
  assertFalse(verifyChain(mutated, ""), "a mutated payload breaks the chain")

  // Reorder: swap events 1 and 2.
  val reordered: List[CaptureEvent] = newList()
  reordered.add(b.events[0])
  reordered.add(b.events[2])
  reordered.add(b.events[1])
  reordered.add(b.events[3])
  assertFalse(verifyChain(reordered, ""), "a reordered pair breaks the chain")

  // Drop the middle event 1.
  val dropped: List[CaptureEvent] = newList()
  dropped.add(b.events[0])
  dropped.add(b.events[2])
  dropped.add(b.events[3])
  assertFalse(verifyChain(dropped, ""), "a dropped event breaks the chain")

  // A wrong genesis prevHash also fails.
  assertFalse(verifyChain(b.events, "wrong-genesis"), "wrong genesis prevHash fails")
}

// ── Test 8: the hash covers the whole record, not just the payload ──
test "verifyChain detects a mutated eventType (hash covers seq + type)" {
  val b = parseStreamJson(turnNdjson(), 0.toLong(), "")
  // Event 1 is "assistant"; rewrite only its stored eventType, keep payload/hash.
  val tampered: List[CaptureEvent] = newList()
  tampered.add(b.events[0])
  val e1 = b.events[1]
  tampered.add(
    CaptureEvent(seq = e1.seq, eventType = "system", payload = e1.payload, prevHash = e1.prevHash, hash = e1.hash)
  )
  tampered.add(b.events[2])
  tampered.add(b.events[3])
  assertFalse(verifyChain(tampered, ""), "mutating only the stored eventType breaks the chain")
}

// ── Test 9: CRLF-framed NDJSON parses the same as LF ──
test "CRLF line endings parse identically to LF (carriage return stripped)" {
  val crlf = lSystem() + "\r\n" + lAssistant() + "\r\n"
  val b = parseStreamJson(crlf, 0.toLong(), "")
  assertEqualInt(b.events.length.toInt(), 2, "two events despite CRLF framing")
  assertEqual(b.events[0].eventType, "system", "type parsed with CR stripped")
  assertEqual(b.events[0].payload, lSystem(), "payload has no trailing carriage return")
  assertEqual(b.events[1].eventType, "assistant", "second type parsed")
  // Identical payloads + seq + type ⇒ identical hashes to the LF parse.
  val lf = parseStreamJson(lSystem() + "\n" + lAssistant() + "\n", 0.toLong(), "")
  assertEqual(b.events[1].hash, lf.events[1].hash, "CRLF and LF yield identical hashes")
}
