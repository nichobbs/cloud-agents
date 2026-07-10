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
// through Microsoft.Data.Sqlite. If these fail with OpenFailed / a
// SqliteConnection type-initializer error, the native libe_sqlite3.so isn't
// reachable from the test runner — CI exports LD_LIBRARY_PATH pointing at
// bin/runtimes/linux-x64/native (populated by scripts/build-full.sh) before
// `lyric test` for exactly this reason; do the same locally.

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

/// Point the driver at a fresh, unique database file and create the schema.
/// Returns the file path so the test can clean it up (review #175).
func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return path
}

/// Best-effort removal of a test database file. A failed assertion earlier in
/// the test skips this — acceptable, the paths are unique per run.
func cleanupTestDb(path: in String): Unit {
  try {
    fileDelete(path)
  } catch Bug as b {
    // locked or already gone — fine for a temp file
  }
}

test "Prompt CRUD round-trips through SQLite" {
  val dbPath = useFreshTestDb("prompt-crud")
  val userId = "default"

  val created = addPrompt(userId, "greeting", "Say hello to the repo").unwrapResult()
  assertTrue(created.id.length > 0, "created prompt has an id")
  assertEqual(created.useCount, "0", "new prompt starts unused")

  val listed = listPrompts(userId).unwrapResult()
  assertEqualInt(listed.length.toInt(), 1, "one prompt listed")
  assertEqual(listed[0].name, "greeting", "listed prompt name matches")

  val updated = updatePrompt(created.id, userId, "greeting v2", "Say hello twice").unwrapResult()
  assertEqualInt(updated, 1, "update touches one row")
  match getPrompt(created.id, userId).unwrapResult() {
    case Some(p) -> assertEqual(p.name, "greeting v2", "update persisted")
    case None -> assertTrue(false, "updated prompt should exist")
  }

  val used = markPromptUsed(created.id, userId).unwrapResult()
  assertEqualInt(used, 1, "use touches one row")
  match getPrompt(created.id, userId).unwrapResult() {
    case Some(p) -> assertEqual(p.useCount, "1", "use count bumped")
    case None -> assertTrue(false, "used prompt should exist")
  }

  val deleted = deletePrompt(created.id, userId).unwrapResult()
  assertEqualInt(deleted, 1, "delete touches one row")
  val after = listPrompts(userId).unwrapResult()
  assertEqualInt(after.length.toInt(), 0, "library empty after delete")
  cleanupTestDb(dbPath)
}

test "Prompt ownership scoping hides other users' prompts" {
  val dbPath = useFreshTestDb("prompt-scope")
  val mine = addPrompt("default", "mine", "my body").unwrapResult()
  val theirs = addPrompt("someone-else", "theirs", "their body").unwrapResult()

  val myList = listPrompts("default").unwrapResult()
  assertEqualInt(myList.length.toInt(), 1, "only my prompt listed")
  assertEqual(myList[0].id, mine.id, "listed prompt is mine")

  // Cross-user update/delete must not touch rows.
  assertEqualInt(updatePrompt(theirs.id, "default", "x", "y").unwrapResult(), 0, "cannot update another user's prompt")
  assertEqualInt(deletePrompt(theirs.id, "default").unwrapResult(), 0, "cannot delete another user's prompt")
  cleanupTestDb(dbPath)
}
