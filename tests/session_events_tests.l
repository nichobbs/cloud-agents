//! Round-trip tests for the session_events store (docs/session-events-store.md
//! §4) over Postgres. Each test runs as a fresh user (its own tenant), so the
//! fixed session ids below never collide across tests or runs. No network, no
//! wall-clock reads in assertions.
@test_module
package CloudAgents.SessionEventsTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.Scope as EvScope
import CloudAgents.Sqlite
import CloudAgents.Capture

// ── Live Postgres ─────────────────────────────────────────────────────────────
//
// The store is Postgres (docs/phase11-postgres-tenancy.md). These tests run iff
// LYRIC_CONFIG_DB_CONNECTION_URL (cloudagents_app) and
// CLOUD_AGENTS_MIGRATE_DATABASE_URL (cloudagents_owner) are set, and fail rather
// than skip when CLOUD_AGENTS_REQUIRE_LIVE_PG=1 (CI). Each test acts as a fresh
// user with its own personal tenant, so tests, suites and repeated runs against
// the same database never see each other's rows.
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
  println("SKIP: session_events tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

/// A new user with a provisioned personal tenant. Does not change the request
/// identity.
func newUser(tag: in String): String {
  val uid = "t-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(uid) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return uid
}

/// Migrate, then make a new user the request identity (what handlers read via
/// CloudAgents.Auth.requestScope()).
func freshUser(tag: in String): String {
  migrate()
  val uid = newUser(tag)
  CloudAgents.Auth.setCurrentUserId(uid)
  return uid
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
  return match CloudAgents.Repository.appendSessionEvents(sessionId, evScope(), events) {
    case Ok(n) -> n
    case Err(e) -> panic("appendSessionEvents failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustRead(sessionId: in String, afterSeq: in String): slice[CaptureEvent] {
  return match CloudAgents.Repository.sessionEventsAfterSeq(sessionId, evScope(), afterSeq) {
    case Ok(evs) -> evs
    case Err(e) -> panic("sessionEventsAfterSeq failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustLatestCursor(sessionId: in String): CloudAgents.Repository.SessionEventCursor {
  return match CloudAgents.Repository.latestSessionEventCursor(sessionId, evScope()) {
    case Ok(c) -> c
    case Err(e) -> panic("latestSessionEventCursor failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "append then read back is verbatim, seq-ordered, and verifies the chain" {
  if not live() {
    return
  }
  val me = freshUser("se")
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
}

test "the after-seq cursor is exclusive and returns only the tail" {
  if not live() {
    return
  }
  val me = freshUser("se")
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
}

test "re-appending an already-stored prefix is an idempotent no-op" {
  if not live() {
    return
  }
  val me = freshUser("se")
  val batch = parseStreamJson(fixtureNdjson(), 0.toLong(), "")
  val _ = mustAppend("sess-C", batch.events)
  // Append the identical batch again — ON CONFLICT DO NOTHING on (session_id, seq).
  val _2 = mustAppend("sess-C", batch.events)
  assertEqualInt(mustRead("sess-C", "").length.toInt(), 3, "still exactly three rows after a duplicate append")
}

// #965: a re-append of an already-stored seq that carries DIFFERENT content
// (a diverged re-parse, or tamper/corruption) must be rejected as a typed
// DbError, not silently discarded by INSERT OR IGNORE.
test "re-appending an existing seq with a different payload/hash surfaces a DbError and does not overwrite (#965)" {
  if not live() {
    return
  }
  val me = freshUser("se")
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
  match CloudAgents.Repository.appendSessionEvents("sess-D", evScope(), [diverged]) {
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
}

// A batch that mixes a genuinely-new event with one that conflicts an existing
// seq must reject the WHOLE batch (no partial insert) — appendSessionEvents
// validates before it builds/executes the insert transaction.
test "a conflicting event anywhere in the batch rejects the whole batch, not just the conflicting row (#965)" {
  if not live() {
    return
  }
  val me = freshUser("se")
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
  match CloudAgents.Repository.appendSessionEvents("sess-E", evScope(), [diverged, newEvent]) {
    case Ok(_) -> assertTrue(false, "a batch containing a conflict must not succeed")
    case Err(_) -> assertTrue(true, "whole batch rejected")
  }

  val back = mustRead("sess-E", "")
  assertEqualInt(back.length.toInt(), 3, "the new event (seq 3) was NOT inserted alongside the conflict")
}

test "latestSessionEventCursor defaults to (0, \"\") for a session with no captured events" {
  if not live() {
    return
  }
  val me = freshUser("se")
  val cursor = mustLatestCursor("sess-does-not-exist")
  assertEqualInt(cursor.nextSeq.toInt(), 0, "a fresh session's cursor starts the chain at seq 0")
  assertEqual(cursor.lastHash, "", "a fresh session's cursor has no prevHash yet")
}

test "latestSessionEventCursor resumes one past the last stored seq, with that event's own hash" {
  if not live() {
    return
  }
  val me = freshUser("se")
  val batch = parseStreamJson(fixtureNdjson(), 0.toLong(), "")
  val _ = mustAppend("sess-F", batch.events)

  val cursor = mustLatestCursor("sess-F")
  assertEqualInt(cursor.nextSeq.toInt(), 3, "resumes at one past the last stored seq (0, 1, 2 stored)")
  assertEqual(cursor.lastHash, batch.events[2].hash, "resumes from the last stored event's own hash")
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
  if not live() {
    return
  }
  val me = freshUser("se")
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
}

func evScope(): EvScope.TenantScope {
  return CloudAgents.Auth.requestScope()
}
