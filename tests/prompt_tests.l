@test_module
package CloudAgents.PromptTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Db
import CloudAgents.Prompts
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
//
// Assumption (review #178): tests within one suite run sequentially in a
// single process, so re-pointing the CLOUD_AGENTS_DB_PATH env var at the top
// of each test cannot race another test in this suite. The driver re-reads
// the env var on every connection, so each test sees its own database. If
// the runner ever parallelises tests within a suite, these must switch to a
// per-test connection-string mechanism instead.

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


// Result convenience methods (.unwrapResult(), .isOk(), ...) compile as
// dot-calls but fail at runtime with "unsupported method" in the current
// toolchain (see docs/lyric/gotchas.md) — unwrap via match+panic instead.
func mustPrompt(r: in Result[Prompt, CloudAgents.Sqlite.DbError]): Prompt {
  return match r {
    case Ok(p) -> p
    case Err(e) -> panic("prompt op failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustPrompts(r: in Result[slice[Prompt], CloudAgents.Sqlite.DbError]): slice[Prompt] {
  return match r {
    case Ok(ps) -> ps
    case Err(e) -> panic("prompt list failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustOptPrompt(r: in Result[Option[Prompt], CloudAgents.Sqlite.DbError]): Option[Prompt] {
  return match r {
    case Ok(o) -> o
    case Err(e) -> panic("prompt get failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustRows(r: in Result[Int, CloudAgents.Sqlite.DbError]): Int {
  return match r {
    case Ok(n) -> n
    case Err(e) -> panic("prompt write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "Migrations are idempotent and back-fill the ledger" {
  val dbPath = useFreshTestDb("migrations")
  defer {
    cleanupTestDb(dbPath)
  }
  // useFreshTestDb already ran initSchema (-> runMigrations) once. Running it
  // again must be a clean no-op: the ledger already records 0001_init, so no
  // statement re-executes, and prompt CRUD still works afterwards.
  match CloudAgents.Repository.runMigrations() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "second runMigrations should no-op: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val created = mustPrompt(addPrompt("default", "post-migrate", "still works"))
  assertTrue(created.id.length > 0, "schema is usable after a repeat migration run")
}

test "executeTransaction rolls back the whole batch on failure" {
  val dbPath = useFreshTestDb("txn-rollback")
  defer {
    cleanupTestDb(dbPath)
  }
  // The atomicity the migration runner relies on (#229): a batch whose second
  // statement is invalid must leave no trace of the first.
  val goodInsert = insertPromptSql("txn-1", "default", "should-not-persist", "body", "1000")
  match CloudAgents.Sqlite.executeTransaction([goodInsert, "THIS IS NOT SQL"]) {
    case Ok(_) -> assertTrue(false, "a batch with an invalid statement must fail")
    case Err(_) -> ()
  }
  match getPrompt("txn-1", "default") {
    case Ok(Some(_)) -> assertTrue(false, "rolled-back insert must not persist")
    case Ok(None) -> ()
    case Err(e) -> assertTrue(false, "getPrompt failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "renderTemplate substitutes bound placeholders and leaves others" {
  assertEqual(renderTemplate("Hello {{name}}!", ["name"], ["world"]), "Hello world!", "single var")
  assertEqual(renderTemplate("{{a}}-{{b}}-{{a}}", ["a", "b"], ["1", "2"]), "1-2-1", "repeated + multiple vars")
  assertEqual(renderTemplate("no vars here", [], []), "no vars here", "no vars")
  assertEqual(renderTemplate("keep {{unbound}}", ["x"], ["y"]), "keep {{unbound}}", "unbound placeholder left intact")
}

test "Popular prompts are ordered by use count" {
  val dbPath = useFreshTestDb("prompt-popular")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"
  val a = mustPrompt(addPrompt(userId, "alpha", "a"))
  val b = mustPrompt(addPrompt(userId, "beta", "b"))
  // Use beta twice, alpha once -> beta is more popular.
  mustRows(markPromptUsed(b.id, userId))
  mustRows(markPromptUsed(b.id, userId))
  mustRows(markPromptUsed(a.id, userId))
  val popular = mustPrompts(listPromptsByUsage(userId))
  assertEqualInt(popular.length.toInt(), 2, "two prompts listed")
  assertEqual(popular[0].name, "beta", "most-used first")
  assertEqual(popular[1].name, "alpha", "less-used second")
}

test "renderPromptHandler renders a template and counts a use" {
  val dbPath = useFreshTestDb("prompt-render")
  defer {
    cleanupTestDb(dbPath)
  }
  val created = mustPrompt(addPrompt("default", "greet", "Hi {{who}} on {{repo}}"))
  match renderPromptHandler(created.id, RenderPromptRequest(keys = ["who", "repo"], values = ["Nic", "cloud-agents"])) {
    case Ok(r) -> assertEqual(r.rendered, "Hi Nic on cloud-agents", "template rendered with bindings")
    case Err(_) -> assertTrue(false, "render should succeed")
  }
  match renderPromptHandler("nope", RenderPromptRequest(keys = [], values = [])) {
    case Ok(_) -> assertTrue(false, "unknown id should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "unknown prompt -> 404")
  }
  match getPrompt(created.id, "default") {
    case Ok(Some(p)) -> assertEqual(p.useCount, "1", "render counted as a use")
    case Ok(None) -> assertTrue(false, "prompt should exist")
    case Err(e) -> assertTrue(false, "getPrompt failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "Prompt CRUD round-trips through SQLite" {
  val dbPath = useFreshTestDb("prompt-crud")
  defer {
    cleanupTestDb(dbPath) // defer: also runs when an assertion panics (#176)
  }
  val userId = "default"

  val created = mustPrompt(addPrompt(userId, "greeting", "Say hello to the repo"))
  assertTrue(created.id.length > 0, "created prompt has an id")
  assertEqual(created.useCount, "0", "new prompt starts unused")

  val listed = mustPrompts(listPrompts(userId))
  assertEqualInt(listed.length.toInt(), 1, "one prompt listed")
  assertEqual(listed[0].name, "greeting", "listed prompt name matches")

  val updated = mustRows(updatePrompt(created.id, userId, "greeting v2", "Say hello twice"))
  assertEqualInt(updated, 1, "update touches one row")
  match mustOptPrompt(getPrompt(created.id, userId)) {
    case Some(p) -> assertEqual(p.name, "greeting v2", "update persisted")
    case None -> assertTrue(false, "updated prompt should exist")
  }

  val used = mustRows(markPromptUsed(created.id, userId))
  assertEqualInt(used, 1, "use touches one row")
  match mustOptPrompt(getPrompt(created.id, userId)) {
    case Some(p) -> assertEqual(p.useCount, "1", "use count bumped")
    case None -> assertTrue(false, "used prompt should exist")
  }

  val deleted = mustRows(deletePrompt(created.id, userId))
  assertEqualInt(deleted, 1, "delete touches one row")
  val after = mustPrompts(listPrompts(userId))
  assertEqualInt(after.length.toInt(), 0, "library empty after delete")
}

test "Prompt ownership scoping hides other users' prompts" {
  val dbPath = useFreshTestDb("prompt-scope")
  defer {
    cleanupTestDb(dbPath)
  }
  val mine = mustPrompt(addPrompt("default", "mine", "my body"))
  val theirs = mustPrompt(addPrompt("someone-else", "theirs", "their body"))

  val myList = mustPrompts(listPrompts("default"))
  assertEqualInt(myList.length.toInt(), 1, "only my prompt listed")
  assertEqual(myList[0].id, mine.id, "listed prompt is mine")

  // Cross-user read/use/update/delete must all no-op against another user's row.
  match mustOptPrompt(getPrompt(theirs.id, "default")) {
    case Some(_) -> assertTrue(false, "cannot read another user's prompt")
    case None -> ()
  }
  assertEqualInt(mustRows(markPromptUsed(theirs.id, "default")), 0, "cannot mark another user's prompt used")
  assertEqualInt(mustRows(updatePrompt(theirs.id, "default", "x", "y")), 0, "cannot update another user's prompt")
  assertEqualInt(mustRows(deletePrompt(theirs.id, "default")), 0, "cannot delete another user's prompt")
}

// ── Handler-level coverage (review #177) ──────────────────────────────────────

func verifyCreatedPromptHandler(p: in Prompt): Unit {
  assertEqual(p.name, "handler prompt", "handler returns stored name")
  assertTrue(p.id.length > 0, "handler returns stored id")
}

test "Prompt handlers validate, store and 404 correctly" {
  val dbPath = useFreshTestDb("prompt-handlers")
  defer {
    cleanupTestDb(dbPath)
  }

  // Validation: empty name / empty body are 400s.
  match addPromptHandler(SavePromptRequest(name = "", body = "b")) {
    case Ok(_) -> assertTrue(false, "empty name should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty name -> 400")
  }
  match addPromptHandler(SavePromptRequest(name = "n", body = "")) {
    case Ok(_) -> assertTrue(false, "empty body should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty body -> 400")
  }

  // Happy path: create, then see it in the list handler.
  match addPromptHandler(SavePromptRequest(name = "handler prompt", body = "hello")) {
    case Ok(p) -> verifyCreatedPromptHandler(p)
    case Err(_) -> assertTrue(false, "valid prompt should be created")
  }
  match listPromptsHandler() {
    case Ok(pl) -> assertEqualInt(pl.prompts.length.toInt(), 1, "list handler returns the stored prompt")
    case Err(_) -> assertTrue(false, "list handler should succeed")
  }

  // Unknown ids are 404s.
  match updatePromptHandler("nope", SavePromptRequest(name = "n", body = "b")) {
    case Ok(_) -> assertTrue(false, "unknown id update should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "update unknown -> 404")
  }
  match usePromptHandler("nope") {
    case Ok(_) -> assertTrue(false, "unknown id use should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "use unknown -> 404")
  }
  match deletePromptHandler("nope") {
    case Ok(_) -> assertTrue(false, "unknown id delete should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "delete unknown -> 404")
  }
}
