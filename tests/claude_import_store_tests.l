//! Live-Postgres tests for CloudAgents.PgStore.Imports
//! (docs/claude-session-import.md §5, §7, §9): import tokens, imported
//! sessions and their cursors, tombstones, and the guards that keep an
//! imported session out of runs and GitHub sync. Runs iff the Postgres DSNs
//! are set (see tests/pg_live_tests.l). Per-run unique ids keep it re-runnable.
@test_module
package CloudAgents.ClaudeImportStoreTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore
import CloudAgents.PgStore.Tenancy
import CloudAgents.PgStore.Imports
import CloudAgents.PgStore.Sessions as Sessions
import CloudAgents.PgStore.Ledger as Store
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
  println("SKIP: Claude import store tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

/// A provisioned personal tenant for a fresh user.
func fresh(): CloudAgents.Pg.TenantScope {
  val userId = "t-imp-" + uid()
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(userId) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning failed: " + dbErrorMessage(e))
  }
  return CloudAgents.Pg.personalScope(userId)
}

func info(title: in String): ImportedSessionInfo {
  return ImportedSessionInfo(
    title = title,
    repoUrl = "https://github.com/acme/shop",
    branch = "claude/x",
    createdAt = "2026-10-30T08:24:43Z",
    updatedAt = "2026-10-30T09:19:23Z"
  )
}

func ensure(sc: in CloudAgents.Pg.TenantScope, ccr: in String): String {
  return match ensureImportedSession(sc, ccr, info("Issues: JVM backend gaps")) {
    case Ok(v) -> v
    case Err(e) -> panic("ensureImportedSession failed: " + dbErrorMessage(e))
  }
}

func cursor(sc: in CloudAgents.Pg.TenantScope, ccr: in String): ImportCursor {
  return match getImportCursor(sc, ccr) {
    case Ok(Some(c)) -> c
    case Ok(None) -> panic("no cursor for " + ccr)
    case Err(e) -> panic(dbErrorMessage(e))
  }
}

func ok[T](r: in Result[T, DbError]): T {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

test "an import token resolves to its owner until revoked" {
  if not live() {
    return ()
  }
  migrate()
  val sc = fresh()
  val created = match ok(createImportToken(sc.userId, sc.tenantId, "claude importer")) {
    case Some(c) -> c
    case None -> panic("a member could not create a token")
  }
  assertTrue(created.token.startsWith("cai_"), "prefixed")
  assertTrue(not created.info.revoked, "fresh")
  val p = match ok(resolveImportToken(created.token)) {
    case Some(v) -> v
    case None -> panic("token did not resolve")
  }
  assertEqual(p.tenantId, sc.tenantId, "its tenant")
  assertEqual(p.userId, sc.userId, "its user")
  assertTrue(isNone(ok(resolveImportToken(created.token + "x"))), "a different token does not resolve")
  assertTrue(isNone(ok(resolveImportToken("not-a-token"))), "an unprefixed value does not resolve")
  val listed = ok(listImportTokens(sc.userId, sc.tenantId))
  assertEqualInt(listed.length.toInt(), 1, "listed")
  assertTrue(listed[0].lastUsedAt.length.toInt() > 0, "use recorded")
  val other = fresh()
  assertTrue(not ok(revokeImportToken(other.userId, other.tenantId, created.info.id)), "someone else's token cannot be revoked")
  assertTrue(ok(revokeImportToken(sc.userId, sc.tenantId, created.info.id)), "revoked")
  assertTrue(isNone(ok(resolveImportToken(created.token))), "a revoked token does not resolve")
  assertTrue(isNone(ok(createImportToken(other.userId, sc.tenantId, "x"))), "a non-member cannot create a token in a tenant")
}

test "the hourly chunk cap counts and refuses" {
  if not live() {
    return ()
  }
  migrate()
  val sc = fresh()
  val created = match ok(createImportToken(sc.userId, sc.tenantId, "cap")) { case Some(c) -> c; case None -> panic("no token") }
  assertTrue(ok(takeChunkSlot(created.info.id, 2)), "first")
  assertTrue(ok(takeChunkSlot(created.info.id, 2)), "second")
  assertTrue(not ok(takeChunkSlot(created.info.id, 2)), "third is over the cap")
}

test "an imported session is a read-only row with a cursor" {
  if not live() {
    return ()
  }
  migrate()
  val sc = fresh()
  val ccr = "session_" + uid()
  val sid = ensure(sc, ccr)
  assertEqual(ensure(sc, ccr), sid, "the same session on later chunks")
  assertTrue(ok(isImportedSession(sc, sid)), "marked imported")
  assertEqual(
    match ok(Sessions.sessionStatus(sid, sc)) { case Some(s) -> s; case None -> "missing" },
    "DESTROYED",
    "no container"
  )
  val c0 = cursor(sc, ccr)
  assertEqual(c0.sessionId, sid, "mapped")
  assertTrue(c0.throughOrdinal == -1.toLong(), "nothing imported yet")
  ok(advanceImportCursor(sc, ccr, "ev-199", 199.toLong(), "2026-10-30T09:19:23Z", "{\"undeclared\":1}", -2.toLong(), false))
  val c1 = cursor(sc, ccr)
  assertTrue(c1.throughOrdinal == 199.toLong(), "advanced")
  assertEqual(c1.throughEventId, "ev-199", "event id")
  assertEqual(c1.lastCounts, "{\"undeclared\":1}", "counts kept for replays")
  assertTrue(c1.restartUntilOrdinal == -1.toLong(), "not restarting")
  ok(advanceImportCursor(sc, ccr, "ev-9", 9.toLong(), "", "{}", 199.toLong(), true))
  val c2 = cursor(sc, ccr)
  assertTrue(c2.restartUntilOrdinal == 199.toLong(), "restarting until the old cursor")
  assertTrue(c2.lastRestartAt.length.toInt() > 0, "cooldown stamped")
  assertEqual(c2.lastEventAt, "2026-10-30T09:19:23Z", "an empty lastEventAt keeps the old one")
  assertTrue(isNone(ok(getImportCursor(fresh(), ccr))), "invisible to another tenant")
  val all = ok(listImportCursors(sc))
  assertEqualInt(all.length.toInt(), 1, "listed")
}

test "run-state writers leave an imported session alone" {
  if not live() {
    return ()
  }
  migrate()
  val sc = fresh()
  val sid = ensure(sc, "session_" + uid())
  assertTrue(not ok(Sessions.tryBeginRun(sid, sc)), "no run can start")
  ok(Sessions.resetSessionContainer(sid, sc))
  assertEqual(
    match ok(Sessions.sessionStatus(sid, sc)) { case Some(s) -> s; case None -> "missing" },
    "DESTROYED",
    "still DESTROYED"
  )
}

test "deleting an imported session leaves a tombstone" {
  if not live() {
    return ()
  }
  migrate()
  val sc = fresh()
  val ccr = "session_" + uid()
  val sid = ensure(sc, ccr)
  ok(Sessions.deleteSessionRecord(sid, sc))
  val c = cursor(sc, ccr)
  assertTrue(c.deleted, "tombstoned")
  assertEqual(c.sessionId, "", "no session any more")
  assertTrue(ok(clearImportTombstone(sc, ccr)), "cleared")
  assertTrue(isNone(ok(getImportCursor(sc, ccr))), "gone, so it may be imported again")
}

test "GitHub sync never lists an imported session" {
  if not live() {
    return ()
  }
  migrate()
  val sc = fresh()
  val sid = ensure(sc, "session_" + uid())
  ok(Store.registerItems(sid, sc, ["gh:acme/shop#77"], ["Seventy-seven"], [""]))
  val ids = ok(Store.sessionsToSync(100))
  var found = false
  for x in ids {
    if x == sid {
      found = true
    }
  }
  assertTrue(not found, "excluded even with a GitHub-backed item")
}
