//! Message search tests: `searchMessagesHandler` over the Postgres store
//! (`messages.search_vector` full-text search, docs/phase9-message-search.md §8).
@test_module
package CloudAgents.SearchTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.Search
import CloudAgents.SessionStore
import CloudAgents.Db

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
  println("SKIP: message search tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Db.dbErrorMessage(e))
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

func uniq(prefix: in String): String {
  return prefix + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func mkSession(id: in String): Unit {
  val s = makeAgentSession(
    sessionId = id,
    repoUrl = "https://github.com/t/search",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = id
  )
  match addSession(s, CloudAgents.Auth.requestScope()) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func mkMessage(sessionId: in String, content: in String): Unit {
  match CloudAgents.Repository.addMessage(sessionId, CloudAgents.Auth.requestScope(), "user", content) {
    case Ok(_) -> ()
    case Err(e) -> panic("addMessage failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

// Same as mkMessage, but returns the freshly minted id so a test can target
// that exact row with a raw UPDATE/DELETE (used by the #918 sync-trigger
// tests below).
func mkMessageReturningId(sessionId: in String, content: in String): String {
  val m = match CloudAgents.Repository.addMessage(sessionId, CloudAgents.Auth.requestScope(), "user", content) {
    case Ok(msg) -> msg
    case Err(e) -> panic("addMessage failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  return m.id
}

// ── searchMessagesHandler: input validation ───────────────────────────────────
test "searchMessagesHandler rejects an empty or whitespace-only q" {
  if not live() {
    return
  }
  val me = freshUser("search-validate-empty")
  match CloudAgents.Search.searchMessagesHandler("") {
    case Ok(_) -> assertTrue(false, "an empty q must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty q -> 400")
  }
  match CloudAgents.Search.searchMessagesHandler("   ") {
    case Ok(_) -> assertTrue(false, "a whitespace-only q must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "whitespace-only q -> 400")
  }
}

test "searchMessagesHandler rejects a q longer than the max length" {
  if not live() {
    return
  }
  val me = freshUser("search-validate-toolong")
  var longTerm = ""
  var i = 0
  while i < 201 {
    longTerm = longTerm + "a"
    i = i + 1
  }
  match CloudAgents.Search.searchMessagesHandler(longTerm) {
    case Ok(_) -> assertTrue(false, "a q over 200 characters must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "too-long q -> 400")
  }
}

// ── searchMessagesHandler: DB-backed matching behavior ────────────────────────
test "searchMessagesHandler returns an empty, non-truncated result (not an error) when nothing matches" {
  if not live() {
    return
  }
  val me = freshUser("search-no-match")
  val sid = uniq("sess-search-1")
  mkSession(sid)
  mkMessage(sid, "let's talk about pancakes")

  match CloudAgents.Search.searchMessagesHandler("zzzznomatch") {
    case Ok(result) -> {
      assertEqualInt(result.messages.length.toInt(), 0, "no matching messages -> empty list, not an error")
      assertTrue(not result.truncated, "an empty result is never truncated")
    }
    case Err(e) -> assertTrue(false, "expected Ok with an empty list: " + toString(e.status))
  }
}

test "searchMessagesHandler finds a real match and returns it newest first" {
  if not live() {
    return
  }
  val me = freshUser("search-match")
  val sid = uniq("sess-search-2")
  mkSession(sid)
  mkMessage(sid, "first: let's schedule the migration")
  // "first" and "third" (asserted for relative order below) could otherwise
  // land in the same nowMillis() millisecond and tie on created_at — spin
  // past that same-ms window so the assertion tests ordering, not scheduler
  // luck (mirrors tests/interactions_tests.l's #803 same-ms spin idiom).
  val afterFirst = CloudAgents.Repository.nowMillis()
  var spin = 0
  while CloudAgents.Repository.nowMillis() <= afterFirst {
    spin = spin + 1
  }
  mkMessage(sid, "second: totally unrelated content")
  mkMessage(sid, "third: don't forget to schedule the follow-up")

  match CloudAgents.Search.searchMessagesHandler("schedule") {
    case Ok(result) -> {
      assertEqualInt(result.messages.length.toInt(), 2, "both messages containing 'schedule' are returned")
      assertEqual(result.messages[0].content, "third: don't forget to schedule the follow-up", "newest match comes first")
      assertEqual(result.messages[1].content, "first: let's schedule the migration", "older match comes second")
      assertTrue(not result.truncated, "well under the cap -> not truncated")
    }
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }
}

// ── searchMessagesHandler: truncation signal (#908) ───────────────────────────
test "searchMessagesHandler caps results at 50 and reports truncated when there are more" {
  if not live() {
    return
  }
  val me = freshUser("search-truncated")
  val sid = uniq("sess-search-truncated")
  mkSession(sid)
  var i = 0
  while i < 51 {
    mkMessage(sid, "truncationprobe message number " + toString(i))
    i = i + 1
  }

  match CloudAgents.Search.searchMessagesHandler("truncationprobe") {
    case Ok(result) -> {
      assertEqualInt(result.messages.length.toInt(), 50, "results are capped at maxSearchResults even though 51 messages match")
      assertTrue(result.truncated, "the true match count (51) exceeds the cap, so truncated must be reported")
    }
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }
}

test "searchMessagesHandler does not report truncated when the match count exactly equals the cap" {
  if not live() {
    return
  }
  val me = freshUser("search-exact-cap")
  val sid = uniq("sess-search-exact-cap")
  mkSession(sid)
  var i = 0
  while i < 50 {
    mkMessage(sid, "exactcapprobe message number " + toString(i))
    i = i + 1
  }

  match CloudAgents.Search.searchMessagesHandler("exactcapprobe") {
    case Ok(result) -> {
      assertEqualInt(result.messages.length.toInt(), 50, "all 50 matches are returned")
      assertTrue(not result.truncated, "exactly hitting the cap is not truncation")
    }
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }
}

test "searchMessagesHandler supports prefix matching" {
  if not live() {
    return
  }
  val me = freshUser("search-prefix")
  val sid = uniq("sess-search-3")
  mkSession(sid)
  mkMessage(sid, "the job is scheduled to run nightly")

  match CloudAgents.Search.searchMessagesHandler("sched") {
    case Ok(result) -> assertEqualInt(result.messages.length.toInt(), 1, "a word prefix matches via the quoted-prefix tsquery rewrite")
    case Err(e) -> assertTrue(false, "expected a successful prefix search: " + toString(e.status))
  }
}

test "searchMessagesHandler only ever returns the calling user's own messages" {
  if not live() {
    return
  }
  val me = freshUser("search-ownership")
  val alice = newUser("alice")
  val bob = newUser("bob")
  CloudAgents.Auth.setCurrentUserId(alice)
  val aliceSession = uniq("sess-search-alice")
  mkSession(aliceSession)
  mkMessage(aliceSession, "alice's secret roadmap notes")

  CloudAgents.Auth.setCurrentUserId(bob)
  val bobSession = uniq("sess-search-bob")
  mkSession(bobSession)
  mkMessage(bobSession, "bob's secret roadmap notes")

  CloudAgents.Auth.setCurrentUserId(alice)
  match CloudAgents.Search.searchMessagesHandler("roadmap") {
    case Ok(result) -> {
      assertEqualInt(result.messages.length.toInt(), 1, "alice sees only her own matching message")
      assertEqual(result.messages[0].content, "alice's secret roadmap notes", "it's alice's own content")
    }
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }

  CloudAgents.Auth.setCurrentUserId(bob)
  match CloudAgents.Search.searchMessagesHandler("roadmap") {
    case Ok(result) -> {
      assertEqualInt(result.messages.length.toInt(), 1, "bob sees only his own matching message")
      assertEqual(result.messages[0].content, "bob's secret roadmap notes", "it's bob's own content")
    }
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }
}

// Raw writes straight at `messages` (bypassing the INSERT-only repository API
// on purpose), through a tenant-scoped unit so RLS applies.
func pokeMessage(owner: in String, sql: in String, params: in slice[String]): Unit {
  val u = match CloudAgents.PgStore.open(CloudAgents.Pg.personalScope(owner)) {
    case Ok(x) -> x
    case Err(e) -> panic("open failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.ex(u, sql, params) {
    case Ok(_) -> ()
    case Err(e) -> {
      CloudAgents.PgStore.release(u)
      panic("poke failed: " + CloudAgents.Db.dbErrorMessage(e))
    }
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> panic("commit failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  CloudAgents.PgStore.release(u)
}

// ── messages.search_vector sync (#918) ─────────────────────────────────────────
// `messages` is still INSERT-only in application code, but the index itself
// must not silently desync if that ever changes. These drive raw UPDATE/
// DELETE statements straight at `messages` (bypassing the app's own
// INSERT-only repository API on purpose) to prove the
// content / AFTER DELETE behaviour keeps the search index correct (on Postgres
// `search_vector` is a generated column, so it follows the row by construction).
test "messages.search_vector stays in sync when a message's content is updated" {
  if not live() {
    return
  }
  val me = freshUser("search-sync-update")
  val sid = uniq("sess-search-sync-update")
  mkSession(sid)
  val id = mkMessageReturningId(sid, "the original stew recipe")

  pokeMessage(me, "UPDATE messages SET content = @p0 WHERE id = @p1", ["a brand new casserole recipe", id])

  match CloudAgents.Search.searchMessagesHandler("stew") {
    case Ok(result) -> assertEqualInt(result.messages.length.toInt(), 0, "the old content must no longer match")
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }
  match CloudAgents.Search.searchMessagesHandler("casserole") {
    case Ok(result) -> {
      assertEqualInt(result.messages.length.toInt(), 1, "the new content must match")
      assertEqual(result.messages[0].content, "a brand new casserole recipe", "the updated content is what's returned")
    }
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }
}

test "messages.search_vector stays in sync when a message is deleted" {
  if not live() {
    return
  }
  val me = freshUser("search-sync-delete")
  val sid = uniq("sess-search-sync-delete")
  mkSession(sid)
  val id = mkMessageReturningId(sid, "a message about deletionprobe topics")

  match CloudAgents.Search.searchMessagesHandler("deletionprobe") {
    case Ok(result) -> assertEqualInt(result.messages.length.toInt(), 1, "the message is findable before deletion")
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }

  pokeMessage(me, "DELETE FROM messages WHERE id = @p0", [id])

  match CloudAgents.Search.searchMessagesHandler("deletionprobe") {
    case Ok(result) -> assertEqualInt(result.messages.length.toInt(), 0, "a deleted message must never surface in search")
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }
}
