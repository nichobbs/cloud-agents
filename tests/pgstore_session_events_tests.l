//! Live-Postgres tests for CloudAgents.PgStore.SessionEvents
//! (docs/phase11-postgres-tenancy.md §9 slices B/C): the captured event chain
//! appends all-or-nothing, re-appends idempotently, rejects divergent content
//! (#965), reads back verbatim in order, resumes from the right cursor, and
//! stays inside its tenant. Runs iff the Postgres DSNs are set (see
//! tests/pg_live_tests.l). Per-run unique ids keep it re-runnable.
@test_module
package CloudAgents.PgStoreSessionEventsTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.SessionEvents as Store
import CloudAgents.Repository
import CloudAgents.Db
import CloudAgents.Capture

func live(): Bool {
  val ok = CloudAgents.Pg.serviceConfigured() and
    Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "").length.toInt() > 0
  if ok {
    return true
  }
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: PgStore session-event tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
  return false
}

func migrate(): Unit {
  val conn = match CloudAgents.Pg.connectDsn(Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "")) {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(_) -> ()
    case Err(e) -> panic("migrate failed: " + CloudAgents.Pg.pgErrorMessage(e))
  }
}

func uid(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func fresh(): CloudAgents.Pg.TenantScope {
  return CloudAgents.Pg.personalScope("gh-pge-" + uid())
}

func evs(r: in Result[slice[CaptureEvent], DbError]): slice[CaptureEvent] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func int(r: in Result[Int, DbError]): Int {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func str(r: in Result[String, DbError]): String {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func fixtureNdjson(): String {
  val l0 = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
  // A single quote and non-ASCII text, to prove the payload round-trips verbatim.
  val l1 = "{\"type\":\"user\",\"message\":{\"content\":\"it's a test, café\"}}"
  val l2 = "{\"type\":\"result\",\"subtype\":\"success\"}"
  return l0 + "\n" + l1 + "\n" + l2 + "\n"
}

func tampered(e: in CaptureEvent): CaptureEvent {
  return CaptureEvent(
    seq = e.seq,
    eventType = e.eventType,
    payload = "{\"type\":\"user\",\"message\":{\"content\":\"TAMPERED\"}}",
    prevHash = e.prevHash,
    hash = "not-the-real-hash"
  )
}

test "events append, read back verbatim in order, and verify as a chain" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  assertEqual(str(Store.latestSessionEventSeq(sid, sc)), "", "no events yet")
  match Store.latestSessionEventCursor(sid, sc) {
    case Ok(c) -> assertEqual(toString(c.nextSeq) + "|" + c.lastHash, "0|", "a fresh chain's cursor")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val batch = parseStreamJson(fixtureNdjson(), 0.toLong(), "")
  assertEqualInt(int(Store.appendSessionEvents(sid, sc, batch.events)), 3, "three submitted")
  val back = evs(Store.sessionEventsAfterSeq(sid, sc, ""))
  assertEqualInt(back.length.toInt(), 3, "three stored")
  var i = 0
  while i < 3 {
    assertEqual(
      toString(back[i].seq) + back[i].eventType + back[i].payload + back[i].prevHash + back[i].hash,
      toString(batch.events[i].seq) + batch.events[i].eventType + batch.events[i].payload + batch.events[i].prevHash +
        batch.events[i].hash,
      "event " + toString(i) + " verbatim"
    )
    i = i + 1
  }
  assertTrue(verifyChain(back, ""), "the stored chain verifies")
  assertEqualInt(evs(Store.sessionEventsAfterSeq(sid, sc, "0")).length.toInt(), 2, "an after cursor is exclusive")
  assertEqualInt(evs(Store.sessionEventsInRange(sid, sc, "0", "1")).length.toInt(), 1, "a range is (from, to]")
  assertEqualInt(evs(Store.sessionEventsAfterSeqLimited(sid, sc, "", 2)).length.toInt(), 2, "the limit applies")
  assertEqual(str(Store.latestSessionEventSeq(sid, sc)), "2", "latest seq")
  match Store.latestSessionEventCursor(sid, sc) {
    case Ok(c) -> assertEqual(
      toString(c.nextSeq) + "|" + c.lastHash,
      "3|" + batch.events[2].hash,
      "resume one past the last"
    )
    case Err(e) -> panic(dbErrorMessage(e))
  }
  // A second run resumes the chain from the cursor.
  val next = parseStreamJson("{\"type\":\"result\",\"subtype\":\"success\"}\n", 3.toLong(), batch.events[2].hash)
  assertEqualInt(int(Store.appendSessionEvents(sid, sc, next.events)), 1, "one more")
  assertTrue(verifyChain(evs(Store.sessionEventsAfterSeq(sid, sc, "")), ""), "the extended chain verifies")
  assertEqualInt(evs(Store.sessionEventsAfterSeq(sid, fresh(), "")).length.toInt(), 0, "another tenant sees none")
}

test "a byte-identical re-append is a no-op; divergent content rejects the whole batch (#965)" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  val batch = parseStreamJson(fixtureNdjson(), 0.toLong(), "")
  int(Store.appendSessionEvents(sid, sc, batch.events))
  assertEqualInt(int(Store.appendSessionEvents(sid, sc, batch.events)), 3, "the retry reports what it submitted")
  assertEqualInt(evs(Store.sessionEventsAfterSeq(sid, sc, "")).length.toInt(), 3, "and stores nothing new")
  val newEvent = CaptureEvent(
    seq = 3.toLong(),
    eventType = "result",
    payload = "{}",
    prevHash = batch.events[2].hash,
    hash = "h3"
  )
  // The new event comes first, so rejecting the batch must undo an insert.
  match Store.appendSessionEvents(sid, sc, [newEvent, tampered(batch.events[1])]) {
    case Ok(_) -> assertTrue(false, "a conflicting batch must not succeed")
    case Err(e) -> assertTrue(dbErrorMessage(e).contains("conflict"), "names the conflict: " + dbErrorMessage(e))
  }
  val back = evs(Store.sessionEventsAfterSeq(sid, sc, ""))
  assertEqualInt(back.length.toInt(), 3, "the new event was rolled back with the batch")
  assertEqual(
    back[1].payload + "|" + back[1].hash,
    batch.events[1].payload + "|" + batch.events[1].hash,
    "the stored event was not overwritten"
  )
  assertEqualInt(int(Store.appendSessionEvents(sid, sc, [])), 0, "an empty append")
}
