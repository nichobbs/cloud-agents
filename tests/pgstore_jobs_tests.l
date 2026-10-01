//! Live-Postgres tests for CloudAgents.PgStore.Jobs
//! (docs/phase11-postgres-tenancy.md §5.3a, §9 slices B/C): scheduled jobs
//! round-trip like the SQLite store and stay private to their owner and
//! tenant, and `claim_scheduled_jobs` claims due jobs across every tenant,
//! advancing each one's schedule so that no slot is fired twice, including
//! by concurrent callers. Runs iff the Postgres DSNs are set (see
//! tests/pg_live_tests.l). Per-run unique ids keep it re-runnable; the claim
//! is cross-tenant, so each test only looks at the jobs it created.
@test_module
package CloudAgents.PgStoreJobsTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import Db
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore
import CloudAgents.PgStore.Jobs as Store
import CloudAgents.Repository
import CloudAgents.Db

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
  println("SKIP: PgStore jobs tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
  return CloudAgents.Pg.personalScope("gh-pgj-" + uid())
}

func job(r: in Result[ScheduledJob, DbError]): ScheduledJob {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func get(id: in String, sc: in CloudAgents.Pg.TenantScope): ScheduledJob {
  return match Store.getScheduledJob(id, sc) {
    case Ok(Some(j)) -> j
    case Ok(None) -> panic("job " + id + " missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
}

func int(r: in Result[Int, DbError]): Int {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func unit(r: in Result[Unit, DbError]): Unit {
  match r {
    case Ok(_) -> ()
    case Err(e) -> panic("store call failed: " + dbErrorMessage(e))
  }
}

func claimMine(ids: in slice[String]): slice[ClaimedJob] {
  val all = match Store.claimDueScheduledJobs(100) {
    case Ok(cs) -> cs
    case Err(e) -> panic("claim failed: " + dbErrorMessage(e))
  }
  var acc: slice[ClaimedJob] = []
  for cl in all {
    for id in ids {
      if cl.job.id == id {
        acc = acc.append(cl)
      }
    }
  }
  return acc
}

func millisAgo(ms: in Int): String {
  return toString(CloudAgents.Repository.nowMillisLong() - ms.toLong())
}

func toLong(s: in String): Long {
  var n = 0.toLong()
  var i = 0
  while i < s.length.toInt() {
    n = n * 10.toLong() + CloudAgents.Repository.parseNatString(s.substring(i, 1)).toLong()
    i = i + 1
  }
  return n
}

test "jobs round-trip their text forms and stay private to their owner and tenant" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val recurring = job(
    Store.createScheduledJob(
      sc,
      "nightly",
      "digest",
      "prof-1",
      "https://github.com/acme/app",
      "main",
      "claude",
      "m",
      "",
      "3600"
    )
  )
  val oneShot = job(
    Store.createScheduledJob(
      sc,
      "once",
      "remind",
      "",
      "https://github.com/acme/app",
      "main",
      "claude",
      "m",
      "9999999999000",
      ""
    )
  )
  val r = get(recurring.id, sc)
  assertEqual(
    r.userId + "|" + r.name + "|" + r.prompt + "|" + r.profileId + "|" + r.repoUrl + "|" + r.branch + "|" + r.harness +
      "|" +
      r.model,
    sc.userId + "|nightly|digest|prof-1|https://github.com/acme/app|main|claude|m",
    "fields"
  )
  assertEqual(
    r.runAt + "|" + r.intervalSeconds + "|" + r.lastRunAt + "|" + r.sessionId + "|" + r.status,
    "|3600|||active",
    "unset fields read back as \"\""
  )
  assertEqual(r.nextRunAt, recurring.nextRunAt, "next_run_at defaults to the creation time")
  assertEqual(r.createdAt, recurring.createdAt, "created_at")
  val o = get(oneShot.id, sc)
  assertEqual(o.runAt + "|" + o.nextRunAt + "|" + o.intervalSeconds, "9999999999000|9999999999000|", "a one-shot job")
  match Store.listScheduledJobs(sc) {
    case Ok(js) -> assertEqualInt(js.length.toInt(), 2, "both listed")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  // Update: an edit that doesn't touch the schedule leaves next_run_at alone.
  assertEqualInt(
    int(Store.updateScheduledJob(recurring.id, sc, "nightly", "revised", "", "", "3600", "1", "paused", false)),
    1,
    "updated"
  )
  val u = get(recurring.id, sc)
  assertEqual(
    u.prompt + "|" + u.profileId + "|" + u.status + "|" + u.nextRunAt,
    "revised||paused|" + r.nextRunAt,
    "next_run_at untouched"
  )
  assertEqualInt(
    int(
      Store.updateScheduledJob(
        recurring.id,
        sc,
        "nightly",
        "revised",
        "",
        "1999999999000",
        "",
        "1999999999000",
        "active",
        true
      )
    ),
    1,
    "rescheduled"
  )
  val u2 = get(recurring.id, sc)
  assertEqual(
    u2.runAt + "|" + u2.intervalSeconds + "|" + u2.nextRunAt,
    "1999999999000||1999999999000",
    "flipped to one-shot"
  )
  // Attach once only.
  unit(Store.attachScheduledJobSession(oneShot.id, sc, "sess-1"))
  unit(Store.attachScheduledJobSession(oneShot.id, sc, "sess-2"))
  assertEqual(get(oneShot.id, sc).sessionId, "sess-1", "the first attach wins")
  val attached = job(Store.createScheduledJobWithSession(sc, "cb", "p", "", "60", "sess-3"))
  assertEqual(
    get(attached.id, sc).sessionId + "|" + get(attached.id, sc).profileId,
    "sess-3|",
    "created with its session"
  )
  // Isolation.
  val otherUser = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-pgj-other-" + uid())
  match Store.getScheduledJob(recurring.id, otherUser) {
    case Ok(None) -> ()
    case _ -> assertTrue(false, "another user in the tenant cannot read it")
  }
  assertEqualInt(int(Store.deleteScheduledJob(recurring.id, otherUser)), 0, "nor delete it")
  assertEqualInt(
    int(Store.updateScheduledJob(recurring.id, fresh(), "x", "x", "", "", "60", "", "active", false)),
    0,
    "another tenant cannot update it"
  )
  assertEqualInt(int(Store.deleteScheduledJob(recurring.id, sc)), 1, "the owner can delete it")
}

test "the claim works across tenants, advances each job and returns it as it was before" {
  if not live() {
    return
  }
  migrate()
  val a = fresh()
  val b = fresh()
  val slot = millisAgo(100000)
  val hourly = job(Store.createScheduledJob(a, "hourly", "p", "", "r", "main", "claude", "", slot, "3600"))
  val once = job(Store.createScheduledJob(b, "once", "p", "", "r", "main", "claude", "", millisAgo(1000), ""))
  val behindSlot = millisAgo(7200000)
  val behind = job(Store.createScheduledJob(a, "minutely", "p", "", "r", "main", "claude", "", behindSlot, "60"))
  val future = job(Store.createScheduledJob(a, "later", "p", "", "r", "main", "claude", "", "9999999999000", ""))
  val paused = job(Store.createScheduledJob(b, "paused", "p", "", "r", "main", "claude", "", millisAgo(1000), "60"))
  assertEqualInt(
    int(Store.updateScheduledJob(paused.id, b, "paused", "p", "", paused.runAt, "60", "", "paused", false)),
    1,
    "paused"
  )
  val ids: slice[String] = [hourly.id, once.id, behind.id, future.id, paused.id]
  val claims = claimMine(ids)
  assertEqualInt(claims.length.toInt(), 3, "the three due, active jobs, in both tenants")
  for cl in claims {
    val now = get(cl.job.id, cl.tenantScope)
    assertEqual(cl.claimedAt, now.lastRunAt, "claimedAt is the stored last_run_at")
    assertEqual(cl.claimedNextRunAt + "|" + cl.claimedStatus, now.nextRunAt + "|" + now.status, "and the stored schedule")
    assertEqual(cl.job.lastRunAt + "|" + cl.job.status, "|active", "the job as it was before the claim")
    if cl.job.id == hourly.id {
      assertEqual(
        cl.tenantScope.tenantId + "|" + cl.tenantScope.userId,
        a.tenantId + "|" + a.userId,
        "the owner's scope in tenant A"
      )
      assertEqual(cl.job.nextRunAt, slot, "the slot it was due at")
      assertEqual(now.nextRunAt, toString(toLong(slot) + 3600000.toLong()), "one interval on from the due slot")
    }
    if cl.job.id == once.id {
      assertEqual(cl.tenantScope.tenantId, b.tenantId, "tenant B's job in tenant B's scope")
      assertEqual(now.status + "|" + now.nextRunAt, "completed|", "a one-shot job completes on its claim")
    }
    if cl.job.id == behind.id {
      val next = toLong(now.nextRunAt)
      val fired = toLong(now.lastRunAt)
      assertTrue(next > fired and next - fired <= 60000.toLong(), "missed slots are skipped")
      assertTrue((next - toLong(behindSlot)) % 60000.toLong() == 0.toLong(), "on the job's own cadence")
    }
  }
  assertEqualInt(claimMine(ids).length.toInt(), 0, "no slot is claimed twice")
}

test "a released claim is due again, but never over an edit made in between" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val j1 = job(Store.createScheduledJob(sc, "j1", "p", "", "r", "main", "claude", "", millisAgo(5000), "3600"))
  val j2 = job(Store.createScheduledJob(sc, "j2", "p", "", "r", "main", "claude", "", millisAgo(5000), ""))
  val claims = claimMine([j1.id, j2.id])
  assertEqualInt(claims.length.toInt(), 2, "both claimed")
  for cl in claims {
    if cl.job.id == j1.id {
      unit(Store.releaseScheduledJobClaim(cl))
      val back = get(j1.id, sc)
      assertEqual(
        back.nextRunAt + "|" + back.lastRunAt + "|" + back.status,
        j1.nextRunAt + "||active",
        "the claim is undone"
      )
    } else {
      // A human cancels the one-shot while its (skipped) run is in flight.
      assertEqualInt(
        int(Store.updateScheduledJob(j2.id, sc, "j2", "p", "", j2.runAt, "", "", "cancelled", false)),
        1,
        "cancelled"
      )
      unit(Store.releaseScheduledJobClaim(cl))
      assertEqual(get(j2.id, sc).status, "cancelled", "the cancel stands")
    }
  }
  val again = claimMine([j1.id, j2.id])
  assertEqualInt(again.length.toInt(), 1, "only the released job is due again")
  assertEqual(again[0].job.id, j1.id, "it is j1")
}

test "concurrent claims never fire the same job" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val j = job(Store.createScheduledJob(sc, "race", "p", "", "r", "main", "claude", "", millisAgo(1000), "3600"))
  val c1 = match CloudAgents.Pg.connectService() {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    c1.close()
  }
  // c1 claims but does not commit yet, so it still holds the row lock.
  val t1 = match CloudAgents.Pg.beginUnscopedUnit(c1) {
    case Ok(t) -> t
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  val got1 = match t1.query("SELECT id FROM public.claim_scheduled_jobs(100)", []) {
    case Ok(rs) -> rs
    case Err(e) -> panic(e.message)
  }
  var firstHasIt = false
  for r in got1 {
    if CloudAgents.PgStore.col(r, "id") == j.id {
      firstHasIt = true
    }
  }
  val second = claimMine([j.id])
  match CloudAgents.Pg.commitUnit(t1) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  assertTrue(firstHasIt, "the first caller claims the job")
  assertEqualInt(second.length.toInt(), 0, "the concurrent caller skips it")
  assertEqualInt(claimMine([j.id]).length.toInt(), 0, "and it is not due again once the first claim commits")
}
