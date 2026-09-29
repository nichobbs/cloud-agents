//! Live-Postgres tests for CloudAgents.PgStore.Prompts
//! (docs/phase11-postgres-tenancy.md §9 slices B/C): the Postgres prompt
//! store behaves like the SQLite one (tests/prompt_tests.l) and is isolated
//! by tenant and user. Runs iff the Postgres DSNs are set (see
//! tests/pg_live_tests.l); otherwise records a visible skip. Per-run unique
//! user ids keep it re-runnable against the same database.
@test_module
package CloudAgents.PgStorePromptsTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Prompts
import CloudAgents.Repository
import CloudAgents.Sqlite

func live(): Bool {
  val ok = CloudAgents.Pg.serviceConfigured() and
    Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "").length.toInt() > 0
  if ok {
    return true
  }
  // CI sets CLOUD_AGENTS_REQUIRE_LIVE_PG=1 so a missing DSN fails the suite
  // instead of letting it pass on skips alone.
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: PgStore prompt tests needs LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

func freshUser(): String {
  return "gh-pgp-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func mustPrompt(r: in Result[Prompt, DbError]): Prompt {
  return match r { case Ok(p) -> p; case Err(e) -> panic("prompt op failed: " + dbErrorMessage(e)) }
}

func mustPrompts(r: in Result[slice[Prompt], DbError]): slice[Prompt] {
  return match r { case Ok(ps) -> ps; case Err(e) -> panic("prompt list failed: " + dbErrorMessage(e)) }
}

func mustInt(r: in Result[Int, DbError]): Int {
  return match r { case Ok(n) -> n; case Err(e) -> panic("prompt write failed: " + dbErrorMessage(e)) }
}

func mustGet(r: in Result[Option[Prompt], DbError]): Option[Prompt] {
  return match r { case Ok(o) -> o; case Err(e) -> panic("getPrompt failed: " + dbErrorMessage(e)) }
}

func names(ps: in slice[Prompt]): String {
  var acc = ""
  for p in ps {
    acc = acc + p.name + ","
  }
  return acc
}

func joined(xs: in slice[String]): String {
  var acc = ""
  for x in xs {
    acc = acc + x + ","
  }
  return acc
}

test "add returns the stored record and list reads it back exactly, with tags" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val sc = personalScope(freshUser())
  val tags: slice[String] = ["ops", "daily"]
  val created = mustPrompt(CloudAgents.PgStore.Prompts.addPromptWithTags(sc, "greeting", "Say hello", tags))
  val listed = mustPrompts(CloudAgents.PgStore.Prompts.listPrompts(sc))
  assertEqualInt(listed.length.toInt(), 1, "one prompt listed")
  assertEqual(listed[0].id, created.id, "same id")
  assertEqual(listed[0].body, "Say hello", "body")
  assertEqual(listed[0].useCount, "0", "use count starts at 0")
  assertEqual(listed[0].createdAt, created.createdAt, "created_at round-trips to the millisecond")
  assertEqual(listed[0].updatedAt, created.updatedAt, "updated_at round-trips")
  assertEqual(joined(listed[0].tags), "daily,ops,", "tags come back alphabetical")
}

test "names sort in byte order, as SQLite's BINARY collation did" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val sc = personalScope(freshUser())
  mustPrompt(CloudAgents.PgStore.Prompts.addPrompt(sc, "beta", "b"))
  mustPrompt(CloudAgents.PgStore.Prompts.addPrompt(sc, "Zeta", "z"))
  mustPrompt(CloudAgents.PgStore.Prompts.addPrompt(sc, "alpha", "a"))
  assertEqual(
    names(mustPrompts(CloudAgents.PgStore.Prompts.listPrompts(sc))),
    "Zeta,alpha,beta,",
    "uppercase sorts before lowercase"
  )
}

test "usage ordering follows markPromptUsed, ties by name" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val sc = personalScope(freshUser())
  val a = mustPrompt(CloudAgents.PgStore.Prompts.addPrompt(sc, "alpha", "a"))
  val b = mustPrompt(CloudAgents.PgStore.Prompts.addPrompt(sc, "beta", "b"))
  mustPrompt(CloudAgents.PgStore.Prompts.addPrompt(sc, "gamma", "g"))
  assertEqualInt(mustInt(CloudAgents.PgStore.Prompts.markPromptUsed(b.id, sc)), 1, "use recorded")
  assertEqualInt(mustInt(CloudAgents.PgStore.Prompts.markPromptUsed(b.id, sc)), 1, "second use recorded")
  assertEqualInt(mustInt(CloudAgents.PgStore.Prompts.markPromptUsed(a.id, sc)), 1, "use recorded")
  val popular = mustPrompts(CloudAgents.PgStore.Prompts.listPromptsByUsage(sc))
  assertEqual(names(popular), "beta,alpha,gamma,", "most used first, ties by name")
  assertEqual(popular[0].useCount, "2", "use count is numeric text")
}

test "tag filter returns matching prompts with their full tag sets" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val sc = personalScope(freshUser())
  val t1: slice[String] = ["ops", "daily"]
  val t2: slice[String] = ["dev"]
  mustPrompt(CloudAgents.PgStore.Prompts.addPromptWithTags(sc, "one", "1", t1))
  mustPrompt(CloudAgents.PgStore.Prompts.addPromptWithTags(sc, "two", "2", t2))
  val ops = mustPrompts(CloudAgents.PgStore.Prompts.listPromptsByTag(sc, "ops"))
  assertEqual(names(ops), "one,", "only the tagged prompt")
  assertEqual(joined(ops[0].tags), "daily,ops,", "carries its full tag set, not just the filter tag")
}

test "update replaces name, body and tags; another user's prompt is untouched" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val owner = freshUser()
  val sc = personalScope(owner)
  val tags: slice[String] = ["old"]
  val p = mustPrompt(CloudAgents.PgStore.Prompts.addPromptWithTags(sc, "name", "body", tags))
  val newTags: slice[String] = ["new", "fresh"]
  assertEqualInt(
    mustInt(CloudAgents.PgStore.Prompts.updatePromptWithTags(p.id, sc, "renamed", "body2", newTags)),
    1,
    "owner updates"
  )
  match mustGet(CloudAgents.PgStore.Prompts.getPrompt(p.id, sc)) {
    case Some(got) -> {
      assertEqual(got.name, "renamed", "name updated")
      assertEqual(got.body, "body2", "body updated")
      assertEqual(joined(got.tags), "fresh,new,", "tag set replaced")
    }
    case None -> assertTrue(false, "prompt must exist")
  }
  // A different user in the same tenant cannot see or change it.
  val intruder = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = freshUser())
  val hijack: slice[String] = ["hijack"]
  assertEqualInt(
    mustInt(CloudAgents.PgStore.Prompts.updatePromptWithTags(p.id, intruder, "x", "y", hijack)),
    0,
    "other user updates nothing"
  )
  assertTrue(isNone(mustGet(CloudAgents.PgStore.Prompts.getPrompt(p.id, intruder))), "other user cannot read it")
  assertEqualInt(mustInt(CloudAgents.PgStore.Prompts.deletePrompt(p.id, intruder)), 0, "other user deletes nothing")
  match mustGet(CloudAgents.PgStore.Prompts.getPrompt(p.id, sc)) {
    case Some(got) -> assertEqual(joined(got.tags), "fresh,new,", "no tags added by the failed update")
    case None -> assertTrue(false, "prompt must survive the other user's delete")
  }
}

test "delete removes the prompt and its tags" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val sc = personalScope(freshUser())
  val tags: slice[String] = ["ops"]
  val p = mustPrompt(CloudAgents.PgStore.Prompts.addPromptWithTags(sc, "gone", "soon", tags))
  assertEqualInt(mustInt(CloudAgents.PgStore.Prompts.deletePrompt(p.id, sc)), 1, "deleted")
  assertTrue(isNone(mustGet(CloudAgents.PgStore.Prompts.getPrompt(p.id, sc))), "gone")
  assertEqualInt(
    mustPrompts(CloudAgents.PgStore.Prompts.listPromptsByTag(sc, "ops")).length.toInt(),
    0,
    "its tags are gone too"
  )
  assertEqualInt(mustInt(CloudAgents.PgStore.Prompts.deletePrompt(p.id, sc)), 0, "deleting again reports not found")
}

test "the same user in another tenant sees none of these prompts" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val user = freshUser()
  val sc = personalScope(user)
  mustPrompt(CloudAgents.PgStore.Prompts.addPrompt(sc, "mine", "m"))
  val otherTenant = CloudAgents.Pg.TenantScope(tenantId = "org-" + user, userId = user)
  assertEqualInt(
    mustPrompts(CloudAgents.PgStore.Prompts.listPrompts(otherTenant)).length.toInt(),
    0,
    "tenant isolation holds for the same user"
  )
}

test "an empty scope is rejected without touching the database" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  match CloudAgents.PgStore.Prompts.listPrompts(CloudAgents.Pg.TenantScope(tenantId = "", userId = "u")) {
    case Ok(_) -> assertTrue(false, "must be rejected")
    case Err(e) -> assertEqual(dbErrorMessage(e), "invalid scope: empty tenant id", "rejected with a clear message")
  }
}
