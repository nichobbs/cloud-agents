@test_module
package CloudAgents.PromptTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Db
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── SQL builder tests (no database needed) ────────────────────────────────────

test "prompt SQL builders are owner-scoped and escaped" {
  val ins = insertPromptSql("p1", "u1", "it's a name", "body", "1000")
  assertTrue(ins.startsWith("INSERT INTO prompts"), "insert target")
  assertTrue(ins.contains("'it''s a name'"), "name is escaped")
  assertTrue(ins.contains("'0'"), "use_count starts at zero")
  assertTrue(selectPromptsSql("u1").contains("WHERE user_id = 'u1'"), "list scoped by owner")
  assertTrue(selectPromptsSql("u1").contains("ORDER BY name ASC"), "library is alphabetical")
  assertTrue(selectPromptByIdSql("p1", "u1").contains("AND user_id = 'u1'"), "get scoped by owner")
  assertTrue(updatePromptSql("p1", "u1", "n", "b", "2000").contains("AND user_id = 'u1'"), "update scoped by owner")
  assertTrue(touchPromptUsedSql("p1", "u1", "2000").contains("CAST(CAST(use_count AS INTEGER) + 1 AS TEXT)"), "use bumps count numerically")
  assertTrue(deletePromptSql("p1", "u1").endsWith("AND user_id = 'u1'"), "delete scoped by owner")
  assertTrue(promptsSchemaSql().contains("CREATE TABLE IF NOT EXISTS prompts"), "ddl idempotent")
}

// ── Live-database tests ───────────────────────────────────────────────────────
//
// First live-DB coverage in the repo: points CLOUD_AGENTS_DB_PATH at a unique
// temp file, creates the schema, and exercises the real Repository functions
// through Microsoft.Data.Sqlite. If these fail in CI with OpenFailed, the
// native e_sqlite3 library isn't reachable from the test runner — see
// docs/BUILD.md.

/// Point the driver at a fresh, unique database file and create the schema.
func useFreshTestDb(tag: in String): Unit {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "Prompt CRUD round-trips through SQLite" {
  useFreshTestDb("prompt-crud")
  val userId = "default"

  val created = unwrapResult(addPrompt(userId, "greeting", "Say hello to the repo"))
  assertTrue(created.id.length > 0, "created prompt has an id")
  assertEqual(created.useCount, "0", "new prompt starts unused")

  val listed = unwrapResult(listPrompts(userId))
  assertEqualInt(listed.length.toInt(), 1, "one prompt listed")
  assertEqual(listed[0].name, "greeting", "listed prompt name matches")

  val updated = unwrapResult(updatePrompt(created.id, userId, "greeting v2", "Say hello twice"))
  assertEqualInt(updated, 1, "update touches one row")
  match unwrapResult(getPrompt(created.id, userId)) {
    case Some(p) -> assertEqual(p.name, "greeting v2", "update persisted")
    case None -> assertTrue(false, "updated prompt should exist")
  }

  val used = unwrapResult(markPromptUsed(created.id, userId))
  assertEqualInt(used, 1, "use touches one row")
  match unwrapResult(getPrompt(created.id, userId)) {
    case Some(p) -> assertEqual(p.useCount, "1", "use count bumped")
    case None -> assertTrue(false, "used prompt should exist")
  }

  val deleted = unwrapResult(deletePrompt(created.id, userId))
  assertEqualInt(deleted, 1, "delete touches one row")
  val after = unwrapResult(listPrompts(userId))
  assertEqualInt(after.length.toInt(), 0, "library empty after delete")
}

test "Prompt ownership scoping hides other users' prompts" {
  useFreshTestDb("prompt-scope")
  val mine = unwrapResult(addPrompt("default", "mine", "my body"))
  val theirs = unwrapResult(addPrompt("someone-else", "theirs", "their body"))

  val myList = unwrapResult(listPrompts("default"))
  assertEqualInt(myList.length.toInt(), 1, "only my prompt listed")
  assertEqual(myList[0].id, mine.id, "listed prompt is mine")

  // Cross-user update/delete must not touch rows.
  assertEqualInt(unwrapResult(updatePrompt(theirs.id, "default", "x", "y")), 0, "cannot update another user's prompt")
  assertEqualInt(unwrapResult(deletePrompt(theirs.id, "default")), 0, "cannot delete another user's prompt")
}
