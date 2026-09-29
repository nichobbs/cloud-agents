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

func mustLatestCursor(sessionId: in String): CloudAgents.Repository.SessionEventCursor {
  return match CloudAgents.Repository.latestSessionEventCursor(sessionId) {
    case Ok(c) -> c
    case Err(e) -> panic("latestSessionEventCursor failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
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

// #965: a re-append of an already-stored seq that carries DIFFERENT content
// (a diverged re-parse, or tamper/corruption) must be rejected as a typed
// DbError, not silently discarded by INSERT OR IGNORE.
test "re-appending an existing seq with a different payload/hash surfaces a DbError and does not overwrite (#965)" {
  val path = useFreshTestDb("sessevents-conflict")
  val batch = parseStreamJson(fixtureNdjson(), 0.toLong(), "")
  val _ = mustAppend("sess-D", batch.events)

  // A divergent event at the SAME seq as batch.events[1] but different payload
  // and hash — as if a bug elsewhere re-parsed the same chunk into different
  // bytes, or the stored chain was tampered with.
  val diverged = CaptureEvent(
    seq = batch.events[1].seq,
    eventType = batch.events[1].eventType,
    payload = "{\"type\":\"user\",\"message\":{\"content\":\"TAMPERED\"}}",
    prevHash = batch.events[1].prevHash,
    hash = "not-the-real-hash"
  )
  match CloudAgents.Repository.appendSessionEvents("sess-D", [diverged]) {
    case Ok(_) -> assertTrue(false, "a content mismatch at an existing seq must not succeed silently")
    case Err(e) -> {
      // ValidationFailed's message rendering (CloudAgents.Sqlite.dbErrorMessage)
      // is the message itself, with no prefix (unlike OpenFailed/ExecFailed) —
      // confirming that also confirms the DbError case, without a qualified
      // union-case match pattern (docs/lyric/gotchas.md territory).
      // .contains(), not .indexOf(...).isSome() — Option[T].isSome()/.isNone()
      // do not resolve at runtime in this toolchain (docs/lyric/gotchas.md).
      val msg = CloudAgents.Sqlite.dbErrorMessage(e)
      assertTrue(msg.contains("conflict"), "error message names the conflict: " + msg)
    }
  }

  // The original, non-tampered row must remain exactly as stored.
  val back = mustRead("sess-D", "")
  assertEqualInt(back.length.toInt(), 3, "still exactly three rows — the conflicting append inserted nothing")
  assertEqual(back[1].payload, batch.events[1].payload, "the stored row was NOT overwritten by the conflicting append")
  assertEqual(back[1].hash, batch.events[1].hash, "the stored hash was NOT overwritten by the conflicting append")

  cleanupTestDb(path)
}

// A batch that mixes a genuinely-new event with one that conflicts an existing
// seq must reject the WHOLE batch (no partial insert) — appendSessionEvents
// validates before it builds/executes the insert transaction.
test "a conflicting event anywhere in the batch rejects the whole batch, not just the conflicting row (#965)" {
  val path = useFreshTestDb("sessevents-conflict-batch")
  val batch = parseStreamJson(fixtureNdjson(), 0.toLong(), "")
  val _ = mustAppend("sess-E", batch.events)

  val diverged = CaptureEvent(
    seq = batch.events[1].seq,
    eventType = batch.events[1].eventType,
    payload = "{\"type\":\"user\",\"message\":{\"content\":\"TAMPERED\"}}",
    prevHash = batch.events[1].prevHash,
    hash = "not-the-real-hash"
  )
  val newEvent = CaptureEvent(
    seq = 3.toLong(),
    eventType = "result",
    payload = "{\"type\":\"result\",\"subtype\":\"success\"}",
    prevHash = batch.events[2].hash,
    hash = "some-new-hash-3"
  )
  match CloudAgents.Repository.appendSessionEvents("sess-E", [diverged, newEvent]) {
    case Ok(_) -> assertTrue(false, "a batch containing a conflict must not succeed")
    case Err(_) -> assertTrue(true, "whole batch rejected")
  }

  val back = mustRead("sess-E", "")
  assertEqualInt(back.length.toInt(), 3, "the new event (seq 3) was NOT inserted alongside the conflict")

  cleanupTestDb(path)
}

test "latestSessionEventCursor defaults to (0, \"\") for a session with no captured events" {
  val path = useFreshTestDb("sessevents-cursor-empty")
  val cursor = mustLatestCursor("sess-does-not-exist")
  assertEqualInt(cursor.nextSeq.toInt(), 0, "a fresh session's cursor starts the chain at seq 0")
  assertEqual(cursor.lastHash, "", "a fresh session's cursor has no prevHash yet")

  cleanupTestDb(path)
}

test "latestSessionEventCursor resumes one past the last stored seq, with that event's own hash" {
  val path = useFreshTestDb("sessevents-cursor-resume")
  val batch = parseStreamJson(fixtureNdjson(), 0.toLong(), "")
  val _ = mustAppend("sess-F", batch.events)

  val cursor = mustLatestCursor("sess-F")
  assertEqualInt(cursor.nextSeq.toInt(), 3, "resumes at one past the last stored seq (0, 1, 2 stored)")
  assertEqual(cursor.lastHash, batch.events[2].hash, "resumes from the last stored event's own hash")

  cleanupTestDb(path)
}

// Regression test for the bug this cursor fixes: every run after a session's
// first parses a BRAND NEW container's log, whose own bytes start at offset
// 0. Before this fix, docker_manager.l's streamSessionMessage always seeded
// nextSeq=0/lastHash="" for that parse, so a session's second (and every
// later) run re-derived events at seq 0.. that collided with the FIRST run's
// already-stored seq 0.. — appendSessionEvents' tamper-evidence check (#965)
// then rejected the whole batch as ValidationFailed, exactly the
// "already-stored content differs from the re-appended content" error a real
// multi-run (and retried) session hit in production. Seeding the second run's
// parse from latestSessionEventCursor instead avoids the collision entirely.
test "a second run's capture, seeded from the resumed cursor, extends the chain without conflicting the first run's events" {
  val path = useFreshTestDb("sessevents-second-run")
  // Run 1: a fresh container's log, parsed from genesis — its own log starts
  // at byte 0, so this is the correct startSeq/prevHash for a session's FIRST
  // run (exactly what latestSessionEventCursor itself returns for an empty
  // session, per the test above).
  val run1 = parseStreamJson(fixtureNdjson(), 0.toLong(), "")
  val _ = mustAppend("sess-G", run1.events)

  // Run 2: a DIFFERENT container, same session. Its log also starts at byte
  // 0, but the capture chain must resume from where run 1 left off — this is
  // exactly what streamSessionMessage now does at the start of every run.
  val cursor = mustLatestCursor("sess-G")
  val run2Ndjson = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"second run\"}]}}\n"
  val run2 = parseStreamJson(run2Ndjson, cursor.nextSeq, cursor.lastHash)
  assertEqualInt(run2.events.length.toInt(), 1, "run 2's fixture parses to one event")
  assertEqualInt(run2.events[0].seq.toInt(), 3, "run 2's event continues the seq space rather than restarting at 0")

  assertEqualInt(
    mustAppend("sess-G", run2.events),
    1,
    "run 2's event appends without conflicting run 1's stored events"
  )

  val all = mustRead("sess-G", "")
  assertEqualInt(all.length.toInt(), 4, "both runs' events are stored — three from run 1, one from run 2")
  assertTrue(verifyChain(all, ""), "the whole session's chain, spanning both runs, verifies from genesis")

  cleanupTestDb(path)
}
