//! Live-Postgres tests for CloudAgents.PgStore.GraphIngest
//! (docs/phase11-postgres-tenancy.md §5.3, §5.3a): the graph-ingest outbox
//! behaves like the SQLite store within a tenant, drains claim due rows in
//! every tenant under a lease, an outcome releases the lease, and pruning
//! removes old delivered rows only. Runs iff the Postgres DSNs are set (see
//! tests/pg_live_tests.l). Per-run unique ids keep it re-runnable.
@test_module
package CloudAgents.PgStoreGraphIngestTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.GraphIngestOutbox
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.GraphIngest as Outbox
import CloudAgents.Repository
import CloudAgents.Sqlite

val url = "https://graph.example/api/ingest"

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
  println("SKIP: PgStore graph-ingest tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
  return CloudAgents.Pg.personalScope("gh-pgo-" + uid())
}

func enqueue(sc: in CloudAgents.Pg.TenantScope, session: in String, body: in String): GraphIngestOutboxRow {
  return match Outbox.enqueueGraphIngest(session, body, url, sc) {
    case Ok(r) -> r
    case Err(e) -> panic("enqueue failed: " + dbErrorMessage(e))
  }
}

func get(sc: in CloudAgents.Pg.TenantScope, id: in String): Option[GraphIngestOutboxRow] {
  return match Outbox.getGraphIngest(id, sc) {
    case Ok(r) -> r
    case Err(e) -> panic("get failed: " + dbErrorMessage(e))
  }
}

func mustGet(sc: in CloudAgents.Pg.TenantScope, id: in String): GraphIngestOutboxRow {
  return match get(sc, id) { case Some(r) -> r; case None -> panic("row " + id + " is missing") }
}

func claim(sc: in CloudAgents.Pg.TenantScope, id: in String): Bool {
  return match Outbox.claimGraphIngest(id, sc) {
    case Ok(b) -> b
    case Err(e) -> panic("claim failed: " + dbErrorMessage(e))
  }
}

func claimDue(): slice[ClaimedGraphIngest] {
  return match Outbox.claimDueGraphIngest(100) {
    case Ok(v) -> v
    case Err(e) -> panic("claimDue failed: " + dbErrorMessage(e))
  }
}

func int(r: in Result[Int, DbError]): Int {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func claimFor(claims: in slice[ClaimedGraphIngest], id: in String): Option[ClaimedGraphIngest] {
  for c in claims {
    if c.row.id == id {
      return Some(value = c)
    }
  }
  return None
}

func absent[T](o: in Option[T]): Bool {
  return match o { case Some(_) -> false; case None -> true }
}

func msAhead(millis: in Int): String {
  return toString(CloudAgents.Repository.nowMillisLong() + millis.toLong())
}

func msAgo(millis: in Int): String {
  return toString(CloudAgents.Repository.nowMillisLong() - millis.toLong())
}

test "enqueue is idempotent per session and body, and a new row is due" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val first = enqueue(sc, "s1", "{\"objects\":[1]}")
  assertEqual(first.attempts, "0", "attempts starts at zero")
  assertEqual(first.deliveredAt, "", "not delivered")
  assertEqual(first.url, url, "url stored")
  assertEqual(first.nextAttemptAt, first.createdAt, "a new row is due at once")
  val again = enqueue(sc, "s1", "{\"objects\":[1]}")
  assertEqual(again.id, first.id, "the same session and body return the existing row")
  val other = enqueue(sc, "s1", "{\"objects\":[2]}")
  assertTrue(other.id != first.id, "a different body is a new row")
}

test "a drain claims due rows in every tenant with the owner's scope, under a lease" {
  if not live() {
    return
  }
  migrate()
  val a = fresh()
  val b = fresh()
  val ra = enqueue(a, "sa", "{\"a\":1}")
  val rb = enqueue(b, "sb", "{\"b\":1}")
  val claims = claimDue()
  match claimFor(claims, ra.id) {
    case Some(c) -> {
      assertEqual(c.tenantScope.tenantId, a.tenantId, "tenant A's row carries tenant A")
      assertEqual(c.tenantScope.userId, a.userId, "and its owner")
      assertEqual(c.row.body, "{\"a\":1}", "the row is read back")
    }
    case None -> assertTrue(false, "tenant A's due row is claimed")
  }
  match claimFor(claims, rb.id) {
    case Some(c) -> assertEqual(c.tenantScope.tenantId, b.tenantId, "tenant B's row carries tenant B")
    case None -> assertTrue(false, "tenant B's due row is claimed")
  }
  val again = claimDue()
  assertTrue(absent(claimFor(again, ra.id)), "a leased row is not claimed by an overlapping drain")
  assertTrue(not claim(a, ra.id), "nor by an immediate attempt")
}

test "an immediate attempt's claim keeps drains off the row" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val r = enqueue(sc, "s", "{}")
  assertTrue(claim(sc, r.id), "a due, unclaimed row is claimed")
  assertTrue(not claim(sc, r.id), "a second claim fails while the first holds")
  assertTrue(absent(claimFor(claimDue(), r.id)), "a drain skips it")
}

test "a failed attempt schedules the retry and releases the lease" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val r = enqueue(sc, "s", "{}")
  assertTrue(claim(sc, r.id), "claimed")
  assertEqualInt(
    int(Outbox.markGraphIngestAttempt(r.id, "1", "connection refused", CloudAgents.Repository.nowMillis(), 60000, sc)),
    1,
    "attempt recorded"
  )
  val after = mustGet(sc, r.id)
  assertEqual(after.attempts, "1", "attempts bumped")
  assertEqual(after.lastError, "connection refused", "error stored")
  assertTrue(
    not CloudAgents.GraphIngestOutbox.isDueNow(after.nextAttemptAt, msAhead(50000)),
    "next attempt is a minute out"
  )
  assertTrue(not claim(sc, r.id), "not claimable before the retry is due")
  // Reschedule into the past: the row is claimable again, so the attempt
  // cleared the lease rather than leaving it to run out.
  assertEqualInt(int(Outbox.markGraphIngestAttempt(r.id, "2", "again", msAgo(120000), 0, sc)), 1, "rescheduled")
  assertTrue(claim(sc, r.id), "a due row whose lease was released is claimed")
}

test "a row given up on is never claimed and reads with the terminal sentinel" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val r = enqueue(sc, "s", "{}")
  assertEqualInt(int(Outbox.markGraphIngestTerminal(r.id, "50", "gave up", sc)), 1, "marked terminal")
  val after = mustGet(sc, r.id)
  assertEqual(after.nextAttemptAt, CloudAgents.GraphIngestOutbox.terminalSentinelMillis, "sentinel next attempt")
  assertEqual(after.attempts, "50", "attempts stored")
  assertTrue(not claim(sc, r.id), "never claimed again")
  assertTrue(absent(claimFor(claimDue(), r.id)), "not by a drain either")
}

test "delivery is recorded once and a delivered row is never claimed" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val r = enqueue(sc, "s", "{\"d\":1}")
  assertTrue(claim(sc, r.id), "claimed")
  val at = CloudAgents.Repository.nowMillis()
  assertEqualInt(int(Outbox.markGraphIngestDelivered(r.id, at, sc)), 1, "delivered")
  assertEqualInt(int(Outbox.markGraphIngestDelivered(r.id, at, sc)), 0, "a second delivery is a no-op")
  assertEqual(mustGet(sc, r.id).deliveredAt, at, "delivered_at round-trips")
  assertTrue(not claim(sc, r.id), "a delivered row is not claimed")
  assertEqual(enqueue(sc, "s", "{\"d\":1}").deliveredAt, at, "a re-enqueue returns the delivered row")
}

test "another tenant can neither read nor change a row" {
  if not live() {
    return
  }
  migrate()
  val owner = fresh()
  val other = fresh()
  val r = enqueue(owner, "s", "{}")
  assertTrue(absent(get(other, r.id)), "invisible to another tenant")
  assertTrue(not claim(other, r.id), "another tenant cannot claim it")
  assertEqualInt(
    int(Outbox.markGraphIngestDelivered(r.id, CloudAgents.Repository.nowMillis(), other)),
    0,
    "another tenant cannot mark it delivered"
  )
  assertEqual(mustGet(owner, r.id).deliveredAt, "", "still pending for its owner")
}

test "pruning deletes old delivered rows in every tenant and nothing else" {
  if not live() {
    return
  }
  migrate()
  val a = fresh()
  val b = fresh()
  val threeDays = 3 * 86400000
  val oldA = enqueue(a, "s", "{\"old\":\"a\"}")
  val oldB = enqueue(b, "s", "{\"old\":\"b\"}")
  val recent = enqueue(a, "s", "{\"recent\":1}")
  val pending = enqueue(b, "s", "{\"pending\":1}")
  assertEqualInt(int(Outbox.markGraphIngestDelivered(oldA.id, msAgo(threeDays), a)), 1, "old A delivered")
  assertEqualInt(int(Outbox.markGraphIngestDelivered(oldB.id, msAgo(threeDays), b)), 1, "old B delivered")
  assertEqualInt(
    int(Outbox.markGraphIngestDelivered(recent.id, CloudAgents.Repository.nowMillis(), a)),
    1,
    "recent delivered"
  )
  val n = int(Outbox.pruneDeliveredGraphIngest(1))
  assertTrue(n >= 2, "both tenants' old delivered rows are pruned")
  assertTrue(absent(get(a, oldA.id)), "old delivered row in A is gone")
  assertTrue(absent(get(b, oldB.id)), "old delivered row in B is gone")
  assertTrue(not absent(get(a, recent.id)), "a recently delivered row is kept")
  assertTrue(not absent(get(b, pending.id)), "a pending row is kept")
}
