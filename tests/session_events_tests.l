//! Live-SQLite round-trip tests for the session_events store
//! (docs/session-events-store.md §4). Same live-DB harness as
//! tests/session_tests.l / tests/prompt_tests.l: a fresh temp DB per test via
//! CLOUD_AGENTS_DB_PATH + initSchema (which runs migrations, including
//! 0030_session_events). No network, no wall-clock reads in assertions.
@test_module
package CloudAgents.SessionEventsTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.Capture
import extern System.Environment as Env

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return path
}

func cleanupTestDb(path: in String): Unit {
  try {
    fileDelete(path)
  } catch Bug as b {
    // locked or already gone — fine for a temp file
  }
}

// A small captured stream-json chunk (3 non-blank lines → seq 0,1,2).
func fixtureNdjson(): String {
  val l0 = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
  // A payload containing a single quote, to prove escaping round-trips verbatim.
  val l1 = "{\"type\":\"user\",\"message\":{\"content\":\"it's a test\"}}"
  val l2 = "{\"type\":\"result\",\"subtype\":\"success\"}"
  return l0 + "\n" + l1 + "\n" + l2 + "\n"
}

func mustAppend(sessionId: in String, events: in slice[CaptureEvent]): Int {
  return match CloudAgents.Repository.appendSessionEvents(sessionId, events) {
    case Ok(n) -> n
    case Err(e) -> panic("appendSessionEvents failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustRead(sessionId: in String, afterSeq: in String): slice[CaptureEvent] {
  return match CloudAgents.Repository.sessionEventsAfterSeq(sessionId, afterSeq) {
    case Ok(evs) -> evs
    case Err(e) -> panic("sessionEventsAfterSeq failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "append then read back is verbatim, seq-ordered, and verifies the chain" {
  val path = useFreshTestDb("sessevents-rt")
  val batch = parseStreamJson(fixtureNdjson(), 0.toLong(), "")
  assertEqualInt(batch.events.length.toInt(), 3, "fixture parses to three events")
  assertEqualInt(mustAppend("sess-A", batch.events), 3, "append reports three events submitted")

  val back = mustRead("sess-A", "")
  assertEqualInt(back.length.toInt(), 3, "all three events read back from the beginning")
  // Verbatim payloads in seq order.
  assertEqual(back[0].payload, batch.events[0].payload, "event 0 payload verbatim")
  assertEqual(back[1].payload, batch.events[1].payload, "event 1 payload verbatim (incl. the apostrophe)")
  assertEqual(back[2].payload, batch.events[2].payload, "event 2 payload verbatim")
  assertEqualInt(back[0].seq.toInt(), 0, "first event seq is 0")
  assertEqualInt(back[2].seq.toInt(), 2, "last event seq is 2")
  // The stored chain re-verifies from genesis — persistence preserved it.
  assertTrue(verifyChain(back, ""), "read-back events verify against the genesis chain")

  cleanupTestDb(path)
}

test "the after-seq cursor is exclusive and returns only the tail" {
  val path = useFreshTestDb("sessevents-cursor")
  val batch = parseStreamJson(fixtureNdjson(), 0.toLong(), "")
  val _ = mustAppend("sess-B", batch.events)

  // after=0 excludes event 0 (a real cursor), unlike "" (from the beginning).
  val tail = mustRead("sess-B", "0")
  assertEqualInt(tail.length.toInt(), 2, "after=0 returns events 1 and 2 only")
  assertEqualInt(tail[0].seq.toInt(), 1, "tail starts at seq 1")

  // A cursor past the end returns nothing.
  assertEqualInt(mustRead("sess-B", "2").length.toInt(), 0, "after=last yields no events")
  // A different session is isolated.
  assertEqualInt(mustRead("sess-does-not-exist", "").length.toInt(), 0, "unknown session yields no events")

  cleanupTestDb(path)
}

test "re-appending an already-stored prefix is an idempotent no-op" {
  val path = useFreshTestDb("sessevents-idem")
  val batch = parseStreamJson(fixtureNdjson(), 0.toLong(), "")
  val _ = mustAppend("sess-C", batch.events)
  // Append the identical batch again — INSERT OR IGNORE on (session_id, seq).
  val _2 = mustAppend("sess-C", batch.events)
  assertEqualInt(mustRead("sess-C", "").length.toInt(), 3, "still exactly three rows after a duplicate append")

  cleanupTestDb(path)
}
