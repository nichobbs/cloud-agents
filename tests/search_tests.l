@test_module
package CloudAgents.SearchTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Search
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/jobs_tests.l) ────────────────────
val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
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
  CloudAgents.Auth.setCurrentUserId("default")
}

func mkSession(id: in String): Unit {
  val s = makeAgentSession(
    sessionId = id,
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = id
  )
  match addSession(s) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mkMessage(sessionId: in String, content: in String): Unit {
  match CloudAgents.Repository.addMessage(sessionId, "user", content) {
    case Ok(_) -> ()
    case Err(e) -> panic("addMessage failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// Same as mkMessage, but returns the freshly minted id so a test can target
// that exact row with a raw UPDATE/DELETE (used by the #918 sync-trigger
// tests below).
func mkMessageReturningId(sessionId: in String, content: in String): String {
  val m = match CloudAgents.Repository.addMessage(sessionId, "user", content) {
    case Ok(msg) -> msg
    case Err(e) -> panic("addMessage failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return m.id
}

// ── buildFts5MatchExpr: pure tokenizer/escaper ────────────────────────────────
test "buildFts5MatchExpr wraps a single word as a quoted prefix token" {
  assertEqual(CloudAgents.Search.buildFts5MatchExpr("scheduled"), "\"scheduled\"*", "one word -> one quoted-prefix token")
}

test "buildFts5MatchExpr space-joins multiple words, collapsing extra whitespace" {
  assertEqual(
    CloudAgents.Search.buildFts5MatchExpr("hello   world"),
    "\"hello\"* \"world\"*",
    "runs of internal whitespace collapse to a single implicit-AND join"
  )
  assertEqual(
    CloudAgents.Search.buildFts5MatchExpr("  leading and trailing  "),
    "\"leading\"* \"and\"* \"trailing\"*",
    "leading/trailing whitespace is ignored, not turned into empty tokens"
  )
}

test "buildFts5MatchExpr doubles embedded double-quotes per word" {
  assertEqual(
    CloudAgents.Search.buildFts5MatchExpr("say \"hi\""),
    "\"say\"* \"\"\"hi\"\"\"*",
    "an embedded double-quote is doubled, mirroring sqlLiteral's doubling of '"
  )
}

test "buildFts5MatchExpr neutralizes FTS5 operator syntax as inert literal text" {
  assertEqual(CloudAgents.Search.buildFts5MatchExpr("AND"), "\"AND\"*", "a bare FTS5 keyword is just a literal word")
  // The tokenizer splits on whitespace BEFORE escaping (like every other
  // multi-word input), so this quote-injection attempt becomes five
  // separately-quoted-and-prefixed tokens, not one joined literal — CI's
  // real lyric test caught this test's expected value assuming the latter.
  // Still safe either way: each word (including "OR"/"MATCH") is its own
  // inert quoted-prefix token, never reinterpreted as FTS5 query syntax.
  assertEqual(
    CloudAgents.Search.buildFts5MatchExpr("a\" OR content MATCH \"x"),
    "\"a\"\"\"* \"OR\"* \"content\"* \"MATCH\"* \"\"\"x\"*",
    "a quote-injection attempt is split into per-word quoted-prefix tokens, each one inert literal text, never reopening FTS5 query syntax"
  )
  assertEqual(
    CloudAgents.Search.buildFts5MatchExpr("content:foo"),
    "\"content:foo\"*",
    "a column-filter-shaped word is inert literal text, not reinterpreted"
  )
}

test "buildFts5MatchExpr returns empty for input with no actual words" {
  assertEqual(CloudAgents.Search.buildFts5MatchExpr(""), "", "empty input has no words")
  assertEqual(CloudAgents.Search.buildFts5MatchExpr("   "), "", "whitespace-only input has no words")
}

// ── searchMessagesHandler: input validation ───────────────────────────────────
test "searchMessagesHandler rejects an empty or whitespace-only q" {
  val dbPath = useFreshTestDb("search-validate-empty")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
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
  val dbPath = useFreshTestDb("search-validate-toolong")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
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
  val dbPath = useFreshTestDb("search-no-match")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-search-1"
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
  val dbPath = useFreshTestDb("search-match")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-search-2"
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
  val dbPath = useFreshTestDb("search-truncated")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-search-truncated"
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
  val dbPath = useFreshTestDb("search-exact-cap")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-search-exact-cap"
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
  val dbPath = useFreshTestDb("search-prefix")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-search-3"
  mkSession(sid)
  mkMessage(sid, "the job is scheduled to run nightly")

  match CloudAgents.Search.searchMessagesHandler("sched") {
    case Ok(result) -> assertEqualInt(result.messages.length.toInt(), 1, "a word prefix matches via FTS5's quoted-prefix token")
    case Err(e) -> assertTrue(false, "expected a successful prefix search: " + toString(e.status))
  }
}

test "searchMessagesHandler only ever returns the calling user's own messages" {
  val dbPath = useFreshTestDb("search-ownership")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("alice")
  val aliceSession = "sess-search-alice"
  mkSession(aliceSession)
  mkMessage(aliceSession, "alice's secret roadmap notes")

  CloudAgents.Auth.setCurrentUserId("bob")
  val bobSession = "sess-search-bob"
  mkSession(bobSession)
  mkMessage(bobSession, "bob's secret roadmap notes")

  CloudAgents.Auth.setCurrentUserId("alice")
  match CloudAgents.Search.searchMessagesHandler("roadmap") {
    case Ok(result) -> {
      assertEqualInt(result.messages.length.toInt(), 1, "alice sees only her own matching message")
      assertEqual(result.messages[0].content, "alice's secret roadmap notes", "it's alice's own content")
    }
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }

  CloudAgents.Auth.setCurrentUserId("bob")
  match CloudAgents.Search.searchMessagesHandler("roadmap") {
    case Ok(result) -> {
      assertEqualInt(result.messages.length.toInt(), 1, "bob sees only his own matching message")
      assertEqual(result.messages[0].content, "bob's secret roadmap notes", "it's bob's own content")
    }
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }
}

// ── messages_fts sync triggers (#918) ─────────────────────────────────────────
// `messages` is still INSERT-only in application code, but the index itself
// must not silently desync if that ever changes. These drive raw UPDATE/
// DELETE statements straight at `messages` (bypassing the app's own
// INSERT-only repository API on purpose) to prove the AFTER UPDATE OF
// content / AFTER DELETE triggers added in migration 0033 keep
// `messages_fts` correct regardless of how the row changed.
test "messages_fts stays in sync when a message's content is updated" {
  val dbPath = useFreshTestDb("search-sync-update")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-search-sync-update"
  mkSession(sid)
  val id = mkMessageReturningId(sid, "the original stew recipe")

  match CloudAgents.Sqlite.execute(
    "UPDATE messages SET content = " + CloudAgents.Db.sqlLiteral("a brand new casserole recipe") + " WHERE id = " +
      CloudAgents.Db.sqlLiteral(id)
  ) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "UPDATE messages failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

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

test "messages_fts stays in sync when a message is deleted" {
  val dbPath = useFreshTestDb("search-sync-delete")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-search-sync-delete"
  mkSession(sid)
  val id = mkMessageReturningId(sid, "a message about deletionprobe topics")

  match CloudAgents.Search.searchMessagesHandler("deletionprobe") {
    case Ok(result) -> assertEqualInt(result.messages.length.toInt(), 1, "the message is findable before deletion")
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }

  match CloudAgents.Sqlite.execute("DELETE FROM messages WHERE id = " + CloudAgents.Db.sqlLiteral(id)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "DELETE FROM messages failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match CloudAgents.Search.searchMessagesHandler("deletionprobe") {
    case Ok(result) -> assertEqualInt(result.messages.length.toInt(), 0, "a deleted message must never surface in search")
    case Err(e) -> assertTrue(false, "expected a successful search: " + toString(e.status))
  }
}
