//! Highlights tests: pure helpers plus the owner-scoped handlers over the
//! Postgres store.
@test_module
package CloudAgents.HighlightsTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Highlights
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Db
import extern System.Environment as Env

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
  println("SKIP: highlights tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
  match addSession(s, CloudAgents.Auth.requestScope()) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

// ── buildChatRequestJson ─────────────────────────────────────────────────────
test "buildChatRequestJson embeds the model and escapes the agent output" {
  val body = buildChatRequestJson("big-pickle", "line one\nwith \"quotes\"")
  assertTrue(body.startsWith("{\"model\":\"big-pickle\""), "model field first: " + body.substring(0, 30))
  assertTrue(body.contains("\\n"), "newlines are JSON-escaped")
  assertTrue(body.contains("\\\"quotes\\\""), "quotes are JSON-escaped")
  assertTrue(body.contains("\"role\":\"user\""), "single user message")
}

// ── jsonStringValueOf ────────────────────────────────────────────────────────
test "jsonStringValueOf extracts and unescapes a chat completion's content" {
  val resp = "{\"id\":\"c1\",\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"discovery | found it | a \\\"quoted\\\" note\\nnone\"}}]}"
  val content = jsonStringValueOf(resp, "content")
  assertTrue(content.contains("a \"quoted\" note"), "escaped quotes resolve: " + content)
  assertTrue(content.contains("\n"), "\\n resolves to a real newline")
}

test "jsonStringValueOf handles \\u escapes and lone surrogates safely" {
  assertEqual(jsonStringValueOf("{\"content\":\"caf\\u00e9\"}", "content"), "café", "\\u00e9 decodes")
  val lone = jsonStringValueOf("{\"content\":\"x\\ud800y\"}", "content")
  assertTrue(lone.contains("x") and lone.contains("y"), "lone surrogate does not destroy the rest: " + lone)
}

test "jsonStringValueOf returns empty for a missing or non-string field" {
  assertEqual(jsonStringValueOf("{\"other\":\"x\"}", "content"), "", "missing key -> empty")
  assertEqual(jsonStringValueOf("{\"content\":{\"nested\":1}}", "content"), "", "non-string value -> empty")
  assertEqual(jsonStringValueOf("{\"content\":\"unterminated", "content"), "", "unterminated string -> empty")
}

// ── parseHighlightLines ──────────────────────────────────────────────────────
test "parseHighlightLines parses kind | title | detail lines and drops junk" {
  val items = parseHighlightLines(
    "discovery | flaky test found | retry masks a race in auth_tests\n" +
      "ISSUE | opened lyric-lang#123 | filed upstream for the codegen crash\n" +
      "- workaround | pinned v0.4.19 | avoids the append bug\n" +
      "not-a-kind | nope | dropped\n" +
      "just some prose the model added\n" +
      "incomplete | skipped e2e test\n" +
      "none"
  )
  assertEqualInt(items.length.toInt(), 4, "four valid items survive")
  assertEqual(items[0].kind, "discovery", "first kind")
  assertEqual(items[1].kind, "issue", "kind is case-normalized")
  assertTrue(items[1].title.contains("lyric-lang#123"), "issue title carries the reference")
  assertEqual(items[2].kind, "workaround", "leading bullet is stripped")
  assertEqual(items[3].kind, "incomplete", "two-field line parses with empty detail")
  assertEqual(items[3].detail, "", "missing detail is empty, not garbage")
}

test "parseHighlightLines returns nothing for 'none' or empty content" {
  assertEqualInt(parseHighlightLines("none").length.toInt(), 0, "'none' -> no items")
  assertEqualInt(parseHighlightLines("").length.toInt(), 0, "empty -> no items")
  assertEqualInt(parseHighlightLines("| no kind | x").length.toInt(), 0, "empty kind -> dropped")
}

test "parseHighlightLines caps runaway output at 20 items" {
  var content = ""
  var i = 0
  while i < 50 {
    content = content + "followup | item " + toString(i) + " | detail\n"
    i = i + 1
  }
  assertEqualInt(parseHighlightLines(content).length.toInt(), 20, "capped at maxItemsPerMessage")
}

// ── contentTail ──────────────────────────────────────────────────────────────
test "contentTail keeps short content whole and truncates long content from the front" {
  assertEqual(contentTail("short"), "short", "short content unchanged")
  var long = "x"
  while long.length < 20000 {
    long = long + long
  }
  val tail = contentTail(long)
  assertEqualInt(tail.length.toInt(), 16000, "long content truncated to the cap")
}

// ── kind allowlist ───────────────────────────────────────────────────────────
test "isValidHighlightKind accepts exactly the six kinds" {
  assertTrue(isValidHighlightKind("discovery"), "discovery")
  assertTrue(isValidHighlightKind("issue"), "issue")
  assertTrue(isValidHighlightKind("workaround"), "workaround")
  assertTrue(isValidHighlightKind("revert"), "revert")
  assertTrue(isValidHighlightKind("incomplete"), "incomplete")
  assertTrue(isValidHighlightKind("followup"), "followup")
  assertTrue(not isValidHighlightKind("progress"), "no extra kinds")
  assertTrue(not isValidHighlightKind(""), "empty is invalid")
}

// ── Handler-level ownership + config gating (#762) ───────────────────────────
test "listHighlightsHandler is owner-scoped: owner lists, another user 404s" {
  if not live() {
    return
  }
  val me = freshUser("hl-own")
  val intruder = newUser("hl-intruder")
  val sid = "sess-highlights-1-" + me
  mkSession(sid)

  match listHighlightsHandler(sid) {
    case Ok(l) -> assertEqualInt(l.highlights.length.toInt(), 0, "owner sees an (empty) list")
    case Err(e) -> assertTrue(false, "owner list failed: " + toString(e.status))
  }

  CloudAgents.Auth.setCurrentUserId(intruder)
  match listHighlightsHandler(sid) {
    case Ok(_) -> assertTrue(false, "another user must not list this session's highlights")
    case Err(e) -> assertEqualInt(e.status, 404, "another user's list -> 404, indistinguishable from absent")
  }
}

test "refreshHighlightsHandler is owner-scoped and reports 'disabled' with no summarizer configured" {
  if not live() {
    return
  }
  val me = freshUser("hl-refresh")
  val intruder = newUser("hl-intruder")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SUMMARIZER_URL", "")
  val sid = "sess-highlights-2-" + me
  mkSession(sid)

  CloudAgents.Auth.setCurrentUserId(intruder)
  match refreshHighlightsHandler(sid) {
    case Ok(_) -> assertTrue(false, "another user must not trigger a refresh for this session")
    case Err(e) -> assertEqualInt(e.status, 404, "another user's refresh -> 404")
  }

  CloudAgents.Auth.setCurrentUserId(me)
  match refreshHighlightsHandler(sid) {
    case Ok(r) -> {
      assertEqual(r.status, "disabled", "no summarizer URL -> feature reports disabled")
      assertEqual(r.scanned, "0", "nothing scanned when disabled")
    }
    case Err(e) -> assertTrue(false, "owner refresh failed: " + toString(e.status))
  }
}
