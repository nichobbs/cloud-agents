//! Prompt library tests: the repository's prompt store (Postgres since the
//! phase 11 cut-over), template rendering, and the prompt handlers.
@test_module
package CloudAgents.PromptTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Prompts
import CloudAgents.Repository
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
  println("SKIP: prompt store tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

// Result convenience methods (.unwrapResult(), .isOk(), ...) compile as
// dot-calls but fail at runtime with "unsupported method" in the current
// toolchain (see docs/lyric/gotchas.md) — unwrap via match+panic instead.
func mustPrompt(r: in Result[Prompt, CloudAgents.Sqlite.DbError]): Prompt {
  return match r { case Ok(p) -> p; case Err(e) -> panic("prompt op failed: " + CloudAgents.Sqlite.dbErrorMessage(e)) }
}

func mustPrompts(r: in Result[slice[Prompt], CloudAgents.Sqlite.DbError]): slice[Prompt] {
  return match r {
    case Ok(ps) -> ps
    case Err(e) -> panic("prompt list failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustOptPrompt(r: in Result[Option[Prompt], CloudAgents.Sqlite.DbError]): Option[Prompt] {
  return match r { case Ok(o) -> o; case Err(e) -> panic("prompt get failed: " + CloudAgents.Sqlite.dbErrorMessage(e)) }
}

func mustRows(r: in Result[Int, CloudAgents.Sqlite.DbError]): Int {
  return match r {
    case Ok(n) -> n
    case Err(e) -> panic("prompt write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// Async wrapper so deletePrompt can be raced under real concurrent
// contention (#577), mirroring tests/session_tests.l's claimAsync (#206 —
// a @test_module declaring its own async func and driving it with
// spawn/scope, confirmed safe by real CI in PR #553, see #559). Needed
// because the existing "cannot delete another user's prompt" cross-user
// test below only ever exercises deletePrompt's ownership PRE-CHECK
// (getPrompt returning None), which early-exits to Ok(0) identically
// whether the fix or the old hardcoded `return Ok(value = 1)` is in place —
// it never reaches the line that actually differs. A genuine race, where
// both calls pass the pre-check before either's DELETE commits, is the only
// way to force the transaction's real rows-affected count to matter.
async func deletePromptAsync(id: in String, userId: in String): Int {
  return mustRows(CloudAgents.Repository.deletePrompt(id, personalScope(userId)))
}

test "renderTemplate substitutes bound placeholders and leaves others" {
  assertEqual(renderTemplate("Hello {{name}}!", ["name"], ["world"]), "Hello world!", "single var")
  assertEqual(renderTemplate("{{a}}-{{b}}-{{a}}", ["a", "b"], ["1", "2"]), "1-2-1", "repeated + multiple vars")
  assertEqual(renderTemplate("no vars here", [], []), "no vars here", "no vars")
  assertEqual(renderTemplate("keep {{unbound}}", ["x"], ["y"]), "keep {{unbound}}", "unbound placeholder left intact")
  // #274: placeholders with internal whitespace ("{{ name }}") match the
  // trimmed key, so the value isn't silently dropped.
  assertEqual(renderTemplate("Hi {{ name }}!", ["name"], ["Nic"]), "Hi Nic!", "whitespace in placeholder is tolerated")
  // #265: a substituted value that itself contains "{{...}}" must NOT be
  // re-expanded — one variable can't inject a reference to another.
  assertEqual(
    renderTemplate("{{a}}", ["a", "b"], ["{{b}}", "secret"]),
    "{{b}}",
    "value is not re-scanned for placeholders"
  )
  assertEqual(renderTemplate("no close {{a", ["a"], ["x"]), "no close {{a", "unclosed placeholder left intact")
}

test "Popular prompts are ordered by use count" {
  if not live() {
    return
  }
  val me = freshUser("prompt-popular")
  val userId = me
  val a = mustPrompt(addPrompt(personalScope(userId), "alpha", "a"))
  val b = mustPrompt(addPrompt(personalScope(userId), "beta", "b"))
  // Use beta twice, alpha once -> beta is more popular.
  mustRows(markPromptUsed(b.id, personalScope(userId)))
  mustRows(markPromptUsed(b.id, personalScope(userId)))
  mustRows(markPromptUsed(a.id, personalScope(userId)))
  val popular = mustPrompts(listPromptsByUsage(personalScope(userId)))
  assertEqualInt(popular.length.toInt(), 2, "two prompts listed")
  assertEqual(popular[0].name, "beta", "most-used first")
  assertEqual(popular[1].name, "alpha", "less-used second")
}

test "renderPromptHandler renders a template and counts a use" {
  if not live() {
    return
  }
  val me = freshUser("prompt-render")
  val created = mustPrompt(addPrompt(personalScope(me), "greet", "Hi {{who}} on {{repo}}"))
  match renderPromptHandler(created.id, RenderPromptRequest(keys = ["who", "repo"], values = ["Nic", "cloud-agents"])) {
    case Ok(r) -> assertEqual(r.rendered, "Hi Nic on cloud-agents", "template rendered with bindings")
    case Err(_) -> assertTrue(false, "render should succeed")
  }
  match renderPromptHandler("nope", RenderPromptRequest(keys = [], values = [])) {
    case Ok(_) -> assertTrue(false, "unknown id should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "unknown prompt -> 404")
  }
  match getPrompt(created.id, personalScope(me)) {
    case Ok(Some(p)) -> assertEqual(p.useCount, "1", "render counted as a use")
    case Ok(None) -> assertTrue(false, "prompt should exist")
    case Err(e) -> assertTrue(false, "getPrompt failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "Prompt CRUD round-trips through the store" {
  if not live() {
    return
  }
  val me = freshUser("prompt-crud")
  val userId = me

  val created = mustPrompt(addPrompt(personalScope(userId), "greeting", "Say hello to the repo"))
  assertTrue(created.id.length > 0, "created prompt has an id")
  assertEqual(created.useCount, "0", "new prompt starts unused")

  val listed = mustPrompts(listPrompts(personalScope(userId)))
  assertEqualInt(listed.length.toInt(), 1, "one prompt listed")
  assertEqual(listed[0].name, "greeting", "listed prompt name matches")

  val updated = mustRows(updatePrompt(created.id, personalScope(userId), "greeting v2", "Say hello twice"))
  assertEqualInt(updated, 1, "update touches one row")
  match mustOptPrompt(getPrompt(created.id, personalScope(userId))) {
    case Some(p) -> assertEqual(p.name, "greeting v2", "update persisted")
    case None -> assertTrue(false, "updated prompt should exist")
  }

  val used = mustRows(markPromptUsed(created.id, personalScope(userId)))
  assertEqualInt(used, 1, "use touches one row")
  match mustOptPrompt(getPrompt(created.id, personalScope(userId))) {
    case Some(p) -> assertEqual(p.useCount, "1", "use count bumped")
    case None -> assertTrue(false, "used prompt should exist")
  }

  val deleted = mustRows(deletePrompt(created.id, personalScope(userId)))
  assertEqualInt(deleted, 1, "delete touches one row")
  val after = mustPrompts(listPrompts(personalScope(userId)))
  assertEqualInt(after.length.toInt(), 0, "library empty after delete")
}

test "Prompt ownership scoping hides other users' prompts" {
  if not live() {
    return
  }
  val me = freshUser("prompt-scope")
  val mine = mustPrompt(addPrompt(personalScope(me), "mine", "my body"))
  val theirs = mustPrompt(addPrompt(personalScope(newUser("someone-else")), "theirs", "their body"))

  val myList = mustPrompts(listPrompts(personalScope(me)))
  assertEqualInt(myList.length.toInt(), 1, "only my prompt listed")
  assertEqual(myList[0].id, mine.id, "listed prompt is mine")

  // Cross-user read/use/update/delete must all no-op against another user's row.
  match mustOptPrompt(getPrompt(theirs.id, personalScope(me))) {
    case Some(_) -> assertTrue(false, "cannot read another user's prompt")
    case None -> ()
  }
  assertEqualInt(
    mustRows(markPromptUsed(theirs.id, personalScope(me))),
    0,
    "cannot mark another user's prompt used"
  )
  assertEqualInt(
    mustRows(updatePrompt(theirs.id, personalScope(me), "x", "y")),
    0,
    "cannot update another user's prompt"
  )
  assertEqualInt(mustRows(deletePrompt(theirs.id, personalScope(me))), 0, "cannot delete another user's prompt")
}

test "Concurrent deletePrompt calls on the same row: exactly one reports the real affected count (#577/#238)" {
  // The cross-user test above proves deletePrompt returns 0 for a row it was
  // never going to touch — but that path early-exits on the ownership
  // pre-check before ever reaching executeTransaction's rows-affected
  // return, so it can't tell today's real-count fix apart from the old,
  // always-succeeds `return Ok(value = 1)`. Racing two deletes against the
  // SAME existing, owned row forces the distinguishing case: both calls pass
  // the pre-check before either's DELETE commits, so only the one whose
  // DELETE actually removes the row can legitimately report 1 — the other's
  // DELETE affects 0 rows because the row is already gone by the time its
  // transaction runs. Under the old hardcoded return, both would report 1
  // (sum 2) regardless of what the database actually did.
  if not live() {
    return
  }
  val me = freshUser("prompt-delete-race")
  val userId = me
  val p = mustPrompt(addPrompt(personalScope(userId), "race-me", "body"))

  scope {
    val t1 = spawn deletePromptAsync(p.id, userId)
    val t2 = spawn deletePromptAsync(p.id, userId)
    val r1 = await t1
    val r2 = await t2
    assertEqualInt(r1 + r2, 1, "exactly one concurrent delete reports the real affected row; the other reports 0")
  }

  match getPrompt(p.id, personalScope(userId)) {
    case Ok(Some(_)) -> assertTrue(false, "prompt should be gone after either concurrent delete wins")
    case Ok(None) -> ()
    case Err(e) -> assertTrue(false, "getPrompt failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "updatePromptWithTags round-trips name/body/tags and 0-affects a foreign prompt (#577)" {
  // updatePromptWithTags (unlike the simpler updatePrompt exercised in "Prompt
  // CRUD round-trips through SQLite" above) had no direct test coverage at
  // all prior to this — it's the transactional function #238's fix actually
  // touched (its own doc comment cites #238 directly), so it should be
  // covered the same way updateProfile/updatePrompt already are.
  if not live() {
    return
  }
  val me = freshUser("prompt-update-with-tags")
  val userId = me
  val p = mustPrompt(addPrompt(personalScope(userId), "orig", "orig body"))
  match setPromptTags(p.id, personalScope(userId), ["red"]) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setPromptTags failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  val updated = mustRows(updatePromptWithTags(p.id, personalScope(userId), "renamed", "new body", ["blue", "green"]))
  assertEqualInt(updated, 1, "update touches one row")
  match getPrompt(p.id, personalScope(userId)) {
    case Ok(Some(gp)) -> {
      assertEqual(gp.name, "renamed", "name updated")
      assertEqual(gp.body, "new body", "body updated")
      assertEqualInt(gp.tags.length.toInt(), 2, "tag set replaced")
      assertEqual(gp.tags[0], "blue", "tags alphabetical: blue first")
      assertEqual(gp.tags[1], "green", "tags alphabetical: green second")
    }
    case Ok(None) -> assertTrue(false, "updated prompt should exist")
    case Err(e) -> assertTrue(false, "getPrompt failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Another user's prompt: the pre-check itself already 0s this (owner-scoped
  // getPrompt), the same shape as the existing cross-user tests above — kept
  // here so updatePromptWithTags has its own explicit 0-path assertion rather
  // than relying on updatePrompt's coverage to stand in for it.
  val theirs = mustPrompt(addPrompt(personalScope(newUser("someone-else")), "theirs", "their body"))
  assertEqualInt(
    mustRows(updatePromptWithTags(theirs.id, personalScope(me), "x", "y", [])),
    0,
    "cannot update another user's prompt via updatePromptWithTags"
  )
}

// ── Handler-level coverage (review #177) ──────────────────────────────────────
func verifyCreatedPromptHandler(p: in Prompt): Unit {
  assertEqual(p.name, "handler prompt", "handler returns stored name")
  assertTrue(p.id.length > 0, "handler returns stored id")
}

test "Prompt tags round-trip, replace, and filter" {
  if not live() {
    return
  }
  val me = freshUser("prompt-tags")
  val userId = me
  val p = mustPrompt(addPrompt(personalScope(userId), "tagged", "body"))
  match setPromptTags(p.id, personalScope(userId), ["red", "blue"]) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setPromptTags failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match getPrompt(p.id, personalScope(userId)) {
    case Ok(Some(gp)) -> assertEqualInt(gp.tags.length.toInt(), 2, "two tags attached to the prompt")
    case Ok(None) -> assertTrue(false, "prompt should exist")
    case Err(e) -> assertTrue(false, "getPrompt failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // setPromptTags is a full replace, not an append.
  match setPromptTags(p.id, personalScope(userId), ["green"]) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  assertEqualInt(
    mustPrompts(listPromptsByTag(personalScope(userId), "green")).length.toInt(),
    1,
    "found under the new tag"
  )
  assertEqualInt(
    mustPrompts(listPromptsByTag(personalScope(userId), "red")).length.toInt(),
    0,
    "old tag no longer matches"
  )
}

test "listPromptsByTag returns each matching prompt with its full tag set (#339)" {
  if not live() {
    return
  }
  val me = freshUser("prompt-by-tag-tags")
  val userId = me
  val a = mustPrompt(addPrompt(personalScope(userId), "alpha", "a"))
  val b = mustPrompt(addPrompt(personalScope(userId), "beta", "b"))
  match setPromptTags(a.id, personalScope(userId), ["red", "green"]) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setPromptTags a failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match setPromptTags(b.id, personalScope(userId), ["blue"]) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setPromptTags b failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Filtering by one of alpha's tags returns only alpha — but with its whole
  // tag set attached (green, red), not just the filter tag, and never beta's.
  val byRed = mustPrompts(listPromptsByTag(personalScope(userId), "red"))
  assertEqualInt(byRed.length.toInt(), 1, "only alpha carries 'red'")
  assertEqual(byRed[0].name, "alpha", "the match is alpha")
  assertEqualInt(byRed[0].tags.length.toInt(), 2, "alpha's full tag set is attached")
  assertEqual(byRed[0].tags[0], "green", "full tags alphabetical: green first")
  assertEqual(byRed[0].tags[1], "red", "full tags alphabetical: red second")

  // The other tag returns only beta with its own single tag.
  val byBlue = mustPrompts(listPromptsByTag(personalScope(userId), "blue"))
  assertEqualInt(byBlue.length.toInt(), 1, "only beta carries 'blue'")
  assertEqual(byBlue[0].name, "beta", "the match is beta")
  assertEqualInt(byBlue[0].tags.length.toInt(), 1, "beta has only its own tag")
  assertEqual(byBlue[0].tags[0], "blue", "beta tag")
}

test "listPrompts attaches each prompt's own tags from one batched read (#246)" {
  if not live() {
    return
  }
  val me = freshUser("prompt-list-tags")
  val userId = me
  val a = mustPrompt(addPrompt(personalScope(userId), "alpha", "body-a"))
  val b = mustPrompt(addPrompt(personalScope(userId), "beta", "body-b"))
  match setPromptTags(a.id, personalScope(userId), ["red", "green"]) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setPromptTags a failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match setPromptTags(b.id, personalScope(userId), ["blue"]) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setPromptTags b failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // listPrompts now fetches all tags in one query and attaches each prompt's
  // own set — the batched path must still give every prompt exactly its tags,
  // alphabetically, and never another prompt's.
  val listed = mustPrompts(listPrompts(personalScope(userId)))
  assertEqualInt(listed.length.toInt(), 2, "both prompts listed")
  // selectPromptsSql is name-ordered: alpha then beta.
  assertEqual(listed[0].name, "alpha", "first prompt is alpha")
  assertEqualInt(listed[0].tags.length.toInt(), 2, "alpha keeps its two tags")
  assertEqual(listed[0].tags[0], "green", "alpha tags alphabetical: green first")
  assertEqual(listed[0].tags[1], "red", "alpha tags alphabetical: red second")
  assertEqual(listed[1].name, "beta", "second prompt is beta")
  assertEqualInt(listed[1].tags.length.toInt(), 1, "beta keeps its one tag")
  assertEqual(listed[1].tags[0], "blue", "beta has only its own tag, not alpha's")
}

test "listPromptsByUsage attaches each prompt's own tags from the batched read (#338)" {
  if not live() {
    return
  }
  val me = freshUser("prompt-usage-tags")
  val userId = me
  val a = mustPrompt(addPrompt(personalScope(userId), "alpha", "a"))
  val b = mustPrompt(addPrompt(personalScope(userId), "beta", "b"))
  match setPromptTags(a.id, personalScope(userId), ["red", "green"]) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setPromptTags a failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match setPromptTags(b.id, personalScope(userId), ["blue"]) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setPromptTags b failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // Use beta once so the usage ordering is deterministic (beta first).
  mustRows(markPromptUsed(b.id, personalScope(userId)))

  val popular = mustPrompts(listPromptsByUsage(personalScope(userId)))
  assertEqualInt(popular.length.toInt(), 2, "two prompts listed")
  assertEqual(popular[0].name, "beta", "most-used first")
  assertEqualInt(popular[0].tags.length.toInt(), 1, "beta keeps its one tag")
  assertEqual(popular[0].tags[0], "blue", "beta tag under the usage ordering")
  assertEqual(popular[1].name, "alpha", "less-used second")
  assertEqualInt(popular[1].tags.length.toInt(), 2, "alpha keeps its two tags")
  assertEqual(popular[1].tags[0], "green", "alpha tags alphabetical: green first")
  assertEqual(popular[1].tags[1], "red", "alpha second tag")
}

test "Prompt handlers validate, store and 404 correctly" {
  if not live() {
    return
  }
  val me = freshUser("prompt-handlers")

  // Validation: empty name / empty body are 400s.
  match addPromptHandler(SavePromptRequest(name = "", body = "b", tags = [])) {
    case Ok(_) -> assertTrue(false, "empty name should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty name -> 400")
  }
  match addPromptHandler(SavePromptRequest(name = "n", body = "", tags = [])) {
    case Ok(_) -> assertTrue(false, "empty body should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty body -> 400")
  }
  // Invalid tag -> 400.
  match addPromptHandler(SavePromptRequest(name = "n", body = "b", tags = ["bad tag"])) {
    case Ok(_) -> assertTrue(false, "invalid tag should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "invalid tag -> 400")
  }

  // Happy path with tags: create, then see it in the list + tag handlers.
  match addPromptHandler(SavePromptRequest(name = "handler prompt", body = "hello", tags = ["ci", "deploy"])) {
    case Ok(p) -> verifyCreatedPromptHandler(p)
    case Err(_) -> assertTrue(false, "valid prompt should be created")
  }
  match listPromptsHandler() {
    case Ok(pl) -> assertEqualInt(pl.prompts.length.toInt(), 1, "list handler returns the stored prompt")
    case Err(_) -> assertTrue(false, "list handler should succeed")
  }
  // Tag filter finds it under 'ci' and not under a foreign tag.
  match listPromptsByTagHandler("ci") {
    case Ok(pl) -> assertEqualInt(pl.prompts.length.toInt(), 1, "tag filter finds the tagged prompt")
    case Err(_) -> assertTrue(false, "tag filter should succeed")
  }
  match listPromptsByTagHandler("nonexistent") {
    case Ok(pl) -> assertEqualInt(pl.prompts.length.toInt(), 0, "unknown tag returns nothing")
    case Err(_) -> assertTrue(false, "tag filter should succeed")
  }

  // Unknown ids are 404s.
  match updatePromptHandler("nope", SavePromptRequest(name = "n", body = "b", tags = [])) {
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
