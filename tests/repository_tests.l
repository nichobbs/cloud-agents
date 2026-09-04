@test_module
package CloudAgents.RepositoryTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.Db
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/session_tests.l) ──────────────────
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
  match CloudAgents.Sqlite.execute(CloudAgents.Db.insertSessionSql(id, userId, "https://github.com/x/y", "main", "", "claude", "opus", id, "1000")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "insertTestSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustAddMessage(sessionId: in String, role: in String, content: in String): CloudAgents.Repository.Message {
  return match CloudAgents.Repository.addMessage(sessionId, role, content) {
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
  val dbPath = useFreshTestDb("model-cache")
  defer {
    cleanupTestDb(dbPath)
  }

  // Absent before any write.
  match mustOptStr(CloudAgents.Repository.cachedModelListing("gh-1", "anthropic")) {
    case Some(_) -> assertTrue(false, "no cached listing before a write")
    case None -> ()
  }

  // Write, then read back the exact body.
  mustCacheWrite(CloudAgents.Repository.cacheModelListing("gh-1", "anthropic", "{\"data\":[1]}"))
  match mustOptStr(CloudAgents.Repository.cachedModelListing("gh-1", "anthropic")) {
    case Some(body) -> assertEqual(body, "{\"data\":[1]}", "freshly-cached body reads back")
    case None -> assertTrue(false, "freshly-cached listing should be present")
  }

  // Scoped by provider: a different provider for the same user is independent.
  match mustOptStr(CloudAgents.Repository.cachedModelListing("gh-1", "openai")) {
    case Some(_) -> assertTrue(false, "a different provider is a separate cache entry")
    case None -> ()
  }
  // Scoped by user: another user never sees gh-1's entry.
  match mustOptStr(CloudAgents.Repository.cachedModelListing("gh-2", "anthropic")) {
    case Some(_) -> assertTrue(false, "a different user is a separate cache entry")
    case None -> ()
  }

  // Upsert replaces the body for the same (user, provider) key.
  mustCacheWrite(CloudAgents.Repository.cacheModelListing("gh-1", "anthropic", "{\"data\":[2]}"))
  match mustOptStr(CloudAgents.Repository.cachedModelListing("gh-1", "anthropic")) {
    case Some(body) -> assertEqual(body, "{\"data\":[2]}", "upsert replaces the cached body")
    case None -> assertTrue(false, "upserted listing should be present")
  }
}

// ── branchSession precondition failures (#1033) ───────────────────────────────
// Each of branchSession's three ValidationFailed precondition sites, asserting the
// rendered message via CloudAgents.Sqlite.dbErrorMessage.
test "branchSession rejects a parent session not found or not owned by user" {
  val dbPath = useFreshTestDb("branch-no-parent")
  defer {
    cleanupTestDb(dbPath)
  }

  // No parent session inserted at all → the id resolves to zero owned rows.
  expectBranchValidationFailed(
    CloudAgents.Repository.branchSession("missing-parent", "", "new-1", "gh-1", ""),
    "parent session not found or not owned by user",
    "unknown parent id is rejected"
  )

  // A session that exists but belongs to another user is equally invisible to gh-1
  // (selectSessionByIdSql is scoped by (id, user_id)).
  insertTestSession("owned-by-other", "gh-other")
  expectBranchValidationFailed(
    CloudAgents.Repository.branchSession("owned-by-other", "", "new-2", "gh-1", ""),
    "parent session not found or not owned by user",
    "parent owned by a different user is rejected"
  )
}

test "branchSession rejects a forked message that does not exist" {
  val dbPath = useFreshTestDb("branch-no-message")
  defer {
    cleanupTestDb(dbPath)
  }

  insertTestSession("parent-1", "gh-1")
  // Valid, owned parent — but the forked message id points at nothing.
  expectBranchValidationFailed(
    CloudAgents.Repository.branchSession("parent-1", "no-such-message", "new-3", "gh-1", ""),
    "forked message not found",
    "unknown forked message id is rejected"
  )
}

test "branchSession rejects a forked message from a different session" {
  val dbPath = useFreshTestDb("branch-cross-session")
  defer {
    cleanupTestDb(dbPath)
  }

  insertTestSession("parent-2", "gh-1")
  insertTestSession("other-session", "gh-1")
  // A real message, but it belongs to other-session, not parent-2.
  val strayMsg = mustAddMessage("other-session", "user", "hello from the other session")
  expectBranchValidationFailed(
    CloudAgents.Repository.branchSession("parent-2", strayMsg.id, "new-4", "gh-1", ""),
    "forked message does not belong to parent session",
    "a message from another session is rejected"
  )
}
