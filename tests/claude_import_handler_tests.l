//! Tests for the Claude session import endpoints
//! (docs/claude-session-import.md §6, §7): the pure guards, and the findings
//! handler's cursor rules against live Postgres (new chunk, replay, gap,
//! restart and its cooldown, realign, body cap, tombstone). The handler is
//! called directly with the identity the auth middleware would stamp.
@test_module
package CloudAgents.ClaudeImportHandlerTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.PgStore.Imports
import CloudAgents.PgStore.Sessions as Sessions
import CloudAgents.Auth
import CloudAgents.Db
import CloudAgents.ImportHandlers
import extern System.Environment as Env

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
  println("SKIP: Claude import handler tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

/// A fresh user with a token, stamped as the current importer.
func importer(): CloudAgents.Pg.TenantScope {
  val userId = "t-imph-" + uid()
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(userId) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning failed: " + dbErrorMessage(e))
  }
  val sc = CloudAgents.Pg.personalScope(userId)
  val created = match createImportToken(sc.userId, sc.tenantId, "test") {
    case Ok(Some(c)) -> c
    case Ok(None) -> panic("no token")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  CloudAgents.Auth.setCurrentUserId(sc.userId)
  CloudAgents.Auth.setCurrentTenantId(sc.tenantId)
  CloudAgents.Auth.setCurrentImportTokenId(created.info.id)
  return sc
}

func chunk(from: in Int, through: in Int, eventId: in String, extra: in String, summary: in String): String {
  return "{\"session\":{\"title\":\"T\",\"repoUrl\":\"https://github.com/acme/shop\"},\"fromOrdinal\":" + toString(from) +
    ",\"throughOrdinal\":" +
    toString(through) +
    ",\"throughEventId\":\"" +
    eventId +
    "\",\"backfill\":true" +
    extra +
    ",\"candidates\":[{\"kind\":\"shortcut\",\"summary\":\"" +
    summary +
    "\",\"seqStart\":\"" +
    toString(from) +
    "\",\"seqEnd\":\"" +
    toString(from) +
    "\",\"confidence\":\"0.9\",\"evidence\":\"event e: quote\"}]}"
}

// ── Pure guards ──────────────────────────────────────────────────────────────
test "only run-changing routes of a session are guarded" {
  assertEqual(readOnlyGuardedSessionId("POST", "/api/sessions/abc/messages"), "abc", "sending a message")
  assertEqual(readOnlyGuardedSessionId("POST", "/api/sessions/abc/ledger/observe"), "abc", "an observer pass")
  assertEqual(readOnlyGuardedSessionId("POST", "/api/sessions/abc/model"), "abc", "changing the model")
  assertEqual(readOnlyGuardedSessionId("POST", "/api/sessions/abc/archive"), "", "archiving is allowed")
  assertEqual(readOnlyGuardedSessionId("POST", "/api/sessions/abc/ledger/entries/e1/review"), "", "reviewing is allowed")
  assertEqual(readOnlyGuardedSessionId("GET", "/api/sessions/abc/messages"), "", "reading is allowed")
  assertEqual(readOnlyGuardedSessionId("DELETE", "/api/sessions/abc"), "", "deleting is allowed")
  assertEqual(readOnlyGuardedSessionId("POST", "/api/sessions"), "", "creating a session is not about one")
}

test "CCR session ids are checked and import routes are the only ones a token may call" {
  assertTrue(isValidCcrSessionId("session_01MzoMEQogKcLSCfXbwQpzew"), "session_")
  assertTrue(isValidCcrSessionId("cse_abc123"), "cse_")
  assertTrue(not isValidCcrSessionId("../etc"), "path characters")
  assertTrue(not isValidCcrSessionId("abc"), "no prefix")
  assertTrue(CloudAgents.Auth.isImportRoute("/api/imports/claude/state"), "importer route")
  assertTrue(not CloudAgents.Auth.isImportRoute("/api/imports/tokens"), "token management is the owner's")
  assertTrue(not CloudAgents.Auth.isImportRoute("/api/sessions"), "sessions")
}

test "a restart cooldown runs from the last restart" {
  val hour = 3600000.toLong()
  assertTrue(not inRestartCooldown("", 100.toLong() * hour, 24), "never restarted")
  assertTrue(inRestartCooldown(toString(90.toLong() * hour), 100.toLong() * hour, 24), "ten hours ago")
  assertTrue(not inRestartCooldown(toString(70.toLong() * hour), 100.toLong() * hour, 24), "thirty hours ago")
}

// ── Findings ─────────────────────────────────────────────────────────────────
test "chunks advance the cursor; replays, gaps and restarts follow the rules" {
  if not live() {
    return ()
  }
  migrate()
  Env.SetEnvironmentVariable("CLOUDAGENTS_IMPORTS_ENABLED", "1")
  val sc = importer()
  val ccr = "session_t" + uid().replace("-", "")
  val first = importFindingsHandler(ccr, chunk(0, 9, "e9", "", "Skipped the flaky refund test"))
  assertEqualInt(first.status, 200, "first chunk: " + first.body)
  assertTrue(first.body.contains("\"undeclared\":1"), "stored")
  val replay = importFindingsHandler(ccr, chunk(0, 9, "e9", "", "Skipped the flaky refund test"))
  assertEqualInt(replay.status, 200, "a replay is accepted")
  assertEqual(replay.body, first.body, "and changes nothing")
  val gap = importFindingsHandler(ccr, chunk(12, 15, "e15", "", "Another"))
  assertEqualInt(gap.status, 409, "a gap")
  assertTrue(gap.body.contains("\"throughOrdinal\":9"), "the 409 carries the stored cursor")
  val realign = importFindingsHandler(ccr, chunk(40, 45, "e45", ",\"resync\":\"realign\",\"afterEventId\":\"e9\"", "Changed the cache key"))
  assertEqualInt(realign.status, 200, "realign after the stored event: " + realign.body)
  val restart = importFindingsHandler(ccr, chunk(0, 9, "r9", ",\"resync\":\"restart\"", "Disabled the flaky refund test"))
  assertEqualInt(restart.status, 200, "restart: " + restart.body)
  assertTrue(restart.body.contains("\"duplicates\":1"), "a reworded finding is a duplicate while restarting")
  val again = importFindingsHandler(ccr, chunk(0, 9, "r9b", ",\"resync\":\"restart\"", "x"))
  assertEqualInt(again.status, 429, "a second restart inside the cooldown")
  val c = match getImportCursor(sc, ccr) { case Ok(Some(v)) -> v; case _ -> panic("no cursor") }
  assertTrue(c.restartUntilOrdinal == 45.toLong(), "restarting until the old cursor")
}

test "the body cap, a bad chunk and a deleted session are refused" {
  if not live() {
    return ()
  }
  migrate()
  Env.SetEnvironmentVariable("CLOUDAGENTS_IMPORTS_ENABLED", "1")
  Env.SetEnvironmentVariable("CLOUDAGENTS_IMPORT_MAX_BODY_BYTES", "200")
  val sc = importer()
  val ccr = "session_t" + uid().replace("-", "")
  val big = importFindingsHandler(ccr, chunk(0, 9, "e9", "", "Skipped the flaky refund test, and a long summary to pass the cap"))
  assertEqualInt(big.status, 413, "over the cap")
  Env.SetEnvironmentVariable("CLOUDAGENTS_IMPORT_MAX_BODY_BYTES", "")
  val outside = importFindingsHandler(ccr, chunk(0, 9, "e9", "", "x").replace("\"seqEnd\":\"0\"", "\"seqEnd\":\"10\""))
  assertEqualInt(outside.status, 422, "a candidate outside its chunk")
  val ok = importFindingsHandler(ccr, chunk(0, 9, "e9", "", "Skipped the flaky refund test"))
  assertEqualInt(ok.status, 200, "accepted")
  val sid = match getImportCursor(sc, ccr) { case Ok(Some(v)) -> v.sessionId; case _ -> panic("no cursor") }
  match Sessions.deleteSessionRecord(sid, sc) { case Ok(_) -> (); case Err(e) -> panic(dbErrorMessage(e)) }
  val gone = importFindingsHandler(ccr, chunk(10, 12, "e12", "", "y"))
  assertEqualInt(gone.status, 410, "a deleted session is skipped")
}

test "without an import token, or with imports off, the importer routes refuse" {
  Env.SetEnvironmentVariable("CLOUDAGENTS_IMPORTS_ENABLED", "1")
  CloudAgents.Auth.setCurrentUserId("someone")
  val noToken = importFindingsHandler("session_x", "{}")
  assertEqualInt(noToken.status, 403, "a signed-in user is not an importer")
  Env.SetEnvironmentVariable("CLOUDAGENTS_IMPORTS_ENABLED", "")
  CloudAgents.Auth.setCurrentImportTokenId("t")
  val off = importFindingsHandler("session_x", "{}")
  assertEqualInt(off.status, 404, "imports are off")
}
