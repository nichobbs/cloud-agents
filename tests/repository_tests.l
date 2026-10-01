//! Repository tests: model-listing cache and branchSession preconditions over
//! the Postgres store.
@test_module
package CloudAgents.RepositoryTests

import Std.Core
import Std.Environment
import CloudAgents.Scope
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite

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
  println("SKIP: repository tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

func mustOptStr(r: in Result[Option[String], CloudAgents.Sqlite.DbError]): Option[String] {
  return match r {
    case Ok(o) -> o
    case Err(e) -> panic("model-listing cache read failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustCacheWrite(r: in Result[Unit, CloudAgents.Sqlite.DbError]): Unit {
  return match r {
    case Ok(_) -> ()
    case Err(e) -> panic("cacheModelListing failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── branchSession live-DB plumbing (#1033) ────────────────────────────────────
// Insert a plain (unbranched) parent session row directly, so branchSession has
// a real parent to fork from without going through the docker-spawning handler.
func insertTestSession(id: in String, userId: in String): Unit {
  val sess = CloudAgents.SessionStore.makeAgentSession(
    sessionId = id,
    repoUrl = "https://github.com/x/y",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "opus",
    nativeSessionId = id
  )
  match CloudAgents.SessionStore.addSession(sess, CloudAgents.Pg.personalScope(userId)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "insertTestSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustAddMessage(sessionId: in String, role: in String, content: in String): CloudAgents.Repository.Message {
  return match CloudAgents.Repository.addMessage(sessionId, CloudAgents.Auth.requestScope(), role, content) {
    case Ok(m) -> m
    case Err(e) -> panic("addMessage failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// Assert branchSession returned a ValidationFailed whose rendered message (via
// dbErrorMessage) equals the expected precondition message.
func expectBranchValidationFailed(
  r: in Result[Unit, CloudAgents.Sqlite.DbError], expected: in String, label: in String
): Unit {
  match r {
    case Ok(_) -> assertTrue(false, label + ": expected Err(ValidationFailed), got Ok")
    case Err(e) -> assertEqual(CloudAgents.Sqlite.dbErrorMessage(e), expected, label)
  }
}

// ── Model-listing cache (#446/#466) ───────────────────────────────────────────
test "model-listing cache round-trips and is scoped by (user, provider)" {
  if not live() {
    return
  }
  val u1 = freshUser("mc1")
  val u2 = newUser("mc2")

  // Absent before any write.
  match mustOptStr(CloudAgents.Repository.cachedModelListing(CloudAgents.Scope.userScope(u1), "anthropic")) {
    case Some(_) -> assertTrue(false, "no cached listing before a write")
    case None -> ()
  }

  // Write, then read back the exact body.
  mustCacheWrite(
    CloudAgents.Repository.cacheModelListing(CloudAgents.Scope.userScope(u1), "anthropic", "{\"data\":[1]}")
  )
  match mustOptStr(CloudAgents.Repository.cachedModelListing(CloudAgents.Scope.userScope(u1), "anthropic")) {
    case Some(body) -> assertEqual(body, "{\"data\":[1]}", "freshly-cached body reads back")
    case None -> assertTrue(false, "freshly-cached listing should be present")
  }

  // Scoped by provider: a different provider for the same user is independent.
  match mustOptStr(CloudAgents.Repository.cachedModelListing(CloudAgents.Scope.userScope(u1), "openai")) {
    case Some(_) -> assertTrue(false, "a different provider is a separate cache entry")
    case None -> ()
  }
  // Scoped by user: another user never sees the first user's entry.
  match mustOptStr(CloudAgents.Repository.cachedModelListing(CloudAgents.Scope.userScope(u2), "anthropic")) {
    case Some(_) -> assertTrue(false, "a different user is a separate cache entry")
    case None -> ()
  }

  // Upsert replaces the body for the same (user, provider) key.
  mustCacheWrite(
    CloudAgents.Repository.cacheModelListing(CloudAgents.Scope.userScope(u1), "anthropic", "{\"data\":[2]}")
  )
  match mustOptStr(CloudAgents.Repository.cachedModelListing(CloudAgents.Scope.userScope(u1), "anthropic")) {
    case Some(body) -> assertEqual(body, "{\"data\":[2]}", "upsert replaces the cached body")
    case None -> assertTrue(false, "upserted listing should be present")
  }
}

// ── branchSession precondition failures (#1033) ───────────────────────────────
// Each of branchSession's three ValidationFailed precondition sites, asserting the
// rendered message via CloudAgents.Sqlite.dbErrorMessage.
test "branchSession rejects a parent session not found or not owned by user" {
  if not live() {
    return
  }
  val u1 = freshUser("bnp")
  val other = newUser("bnp-other")
  val sfx = "-" + u1

  // No parent session inserted at all → the id resolves to zero owned rows.
  expectBranchValidationFailed(
    CloudAgents.Repository.branchSession("missing-parent" + sfx, "", "new-1" + sfx, CloudAgents.Pg.personalScope(u1), ""),
    "parent session not found or not owned by user",
    "unknown parent id is rejected"
  )

  // A session that exists but belongs to another user is equally invisible to the requesting user
  // (selectSessionByIdSql is scoped by (id, user_id)).
  insertTestSession("owned-by-other" + sfx, other)
  expectBranchValidationFailed(
    CloudAgents.Repository.branchSession("owned-by-other" + sfx, "", "new-2" + sfx, CloudAgents.Pg.personalScope(u1), ""),
    "parent session not found or not owned by user",
    "parent owned by a different user is rejected"
  )
}

test "branchSession rejects a forked message that does not exist" {
  if not live() {
    return
  }
  val u1 = freshUser("bnm")
  val sfx = "-" + u1

  insertTestSession("parent-1" + sfx, u1)
  // Valid, owned parent — but the forked message id points at nothing.
  expectBranchValidationFailed(
    CloudAgents.Repository.branchSession(
      "parent-1" + sfx,
      "no-such-message",
      "new-3" + sfx,
      CloudAgents.Pg.personalScope(u1),
      ""
    ),
    "forked message not found",
    "unknown forked message id is rejected"
  )
}

test "branchSession rejects a forked message from a different session" {
  if not live() {
    return
  }
  val u1 = freshUser("bcs")
  val sfx = "-" + u1

  insertTestSession("parent-2" + sfx, u1)
  insertTestSession("other-session" + sfx, u1)
  // A real message, but it belongs to other-session, not parent-2.
  val strayMsg = mustAddMessage("other-session" + sfx, "user", "hello from the other session")
  expectBranchValidationFailed(
    CloudAgents.Repository.branchSession("parent-2" + sfx, strayMsg.id, "new-4" + sfx, CloudAgents.Pg.personalScope(u1), ""),
    "forked message does not belong to parent session",
    "a message from another session is rejected"
  )
}
