//! Library tests (skills, subagents, MCP servers and profile grants): the
//! repository's library store (Postgres since the phase 11 cut-over) and the
//! library handlers.
@test_module
package CloudAgents.LibraryTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Library
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.Sqlite

test "handler validation rejects bad names, enums, and content" {
  assertTrue(isValidLibraryName("my-skill_1"), "valid slug accepted")
  assertTrue(not isValidLibraryName(""), "empty name rejected")
  assertTrue(not isValidLibraryName("has spaces"), "spaces rejected")
  assertTrue(not isValidLibraryName("has/slash"), "slash rejected (path traversal guard)")
  assertTrue(not isValidLibraryName("../etc"), "dot-dot rejected")

  assertTrue(isValidMcpTransport("stdio") and isValidMcpTransport("url"), "known transports accepted")
  assertTrue(not isValidMcpTransport("sse"), "unknown transport rejected")
}

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
  println("SKIP: library store tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

func mustSkill(r: in Result[Skill, CloudAgents.Sqlite.DbError]): Skill {
  return match r { case Ok(s) -> s; case Err(e) -> panic("skill op failed: " + CloudAgents.Sqlite.dbErrorMessage(e)) }
}

func mustMcpServer(r: in Result[McpServer, CloudAgents.Sqlite.DbError]): McpServer {
  return match r {
    case Ok(m) -> m
    case Err(e) -> panic("mcp server op failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustProfile(r: in Result[Profile, CloudAgents.Sqlite.DbError]): Profile {
  return match r { case Ok(p) -> p; case Err(e) -> panic("profile op failed: " + CloudAgents.Sqlite.dbErrorMessage(e)) }
}

test "Skill handlers validate names and reject duplicates" {
  if not live() {
    return
  }
  val me = freshUser("lib-skill-handlers")
  match addSkillHandler(SaveSkillRequest(name = "bad name", description = "d", body = "b")) {
    case Ok(_) -> assertTrue(false, "bad name should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "bad name -> 400")
  }
  match addSkillHandler(SaveSkillRequest(name = "good-name", description = "", body = "b")) {
    case Ok(_) -> assertTrue(false, "empty description should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty description -> 400")
  }
  match addSkillHandler(SaveSkillRequest(name = "greet", description = "says hi", body = "# Steps\n1. Say hi")) {
    case Ok(s) -> assertEqual(s.name, "greet", "skill created")
    case Err(_) -> assertTrue(false, "valid skill should create")
  }
  match addSkillHandler(SaveSkillRequest(name = "greet", description = "again", body = "b")) {
    case Ok(_) -> assertTrue(false, "duplicate name should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "duplicate name -> 400")
  }
  match updateSkillHandler("nope", SaveSkillRequest(name = "x", description = "d", body = "b")) {
    case Ok(_) -> assertTrue(false, "unknown update should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "unknown update -> 404")
  }
  match deleteSkillHandler("nope") {
    case Ok(_) -> assertTrue(false, "unknown delete should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "unknown delete -> 404")
  }
}

test "MCP server handlers validate transport-specific fields" {
  if not live() {
    return
  }
  val me = freshUser("lib-mcp-handlers")
  val noArgs: slice[String] = []
  match addMcpServerHandler(SaveMcpServerRequest(name = "gh", transport = "stdio", command = "", args = noArgs, url = "", env = noArgs)) {
    case Ok(_) -> assertTrue(false, "stdio without command should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "missing command -> 400")
  }
  match addMcpServerHandler(SaveMcpServerRequest(name = "gh", transport = "url", command = "", args = noArgs, url = "", env = noArgs)) {
    case Ok(_) -> assertTrue(false, "url transport without url should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "missing url -> 400")
  }
  match addMcpServerHandler(SaveMcpServerRequest(name = "gh", transport = "stdio", command = "npx", args = noArgs, url = "", env = ["NOEQUALS"])) {
    case Ok(_) -> assertTrue(false, "malformed env entry should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "malformed env -> 400")
  }
  // #782: a control char (e.g. an embedded newline, or a JSON-escaped NUL)
  // in an env value must be rejected up front — docker/inject-library.sh's
  // NUL-delimited env-pairs read can't tell such a byte apart from its own
  // delimiter, so the value can never reach the container in the first
  // place.
  match addMcpServerHandler(SaveMcpServerRequest(name = "gh", transport = "stdio", command = "npx", args = noArgs, url = "", env = ["KEY=line1\nline2"])) {
    case Ok(_) -> assertTrue(false, "env value with an embedded newline should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "control char in env value -> 400")
  }
  match addMcpServerHandler(SaveMcpServerRequest(name = "gh", transport = "stdio", command = "npx", args = ["-y", "gh-mcp"], url = "", env = ["DEBUG=1"])) {
    case Ok(m) -> {
      assertEqual(m.command, "npx", "command stored")
      assertEqualInt(m.args.length.toInt(), 2, "args stored in order")
      assertEqual(m.args[0], "-y", "first arg order preserved")
      assertEqual(m.enabled, "1", "enabled defaults to '1' when the request omits it")
    }
    case Err(_) -> assertTrue(false, "valid stdio server should create")
  }
  // #768: header entries reuse env's "NAME=VALUE" + control-char validation.
  match addMcpServerHandler(SaveMcpServerRequest(name = "gh2", transport = "url", command = "", args = noArgs, url = "https://example.com/mcp", env = noArgs, headers = ["NOEQUALS"])) {
    case Ok(_) -> assertTrue(false, "malformed header entry should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "malformed header -> 400")
  }
  match addMcpServerHandler(SaveMcpServerRequest(name = "gh2", transport = "url", command = "", args = noArgs, url = "https://example.com/mcp", env = noArgs, headers = ["Authorization=Bearer line1\nline2"])) {
    case Ok(_) -> assertTrue(false, "header value with an embedded newline should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "control char in header value -> 400")
  }
  match addMcpServerHandler(SaveMcpServerRequest(name = "gh2", transport = "url", command = "", args = noArgs, url = "https://example.com/mcp", env = noArgs, headers = [r"Authorization=Bearer ${GITHUB_TOKEN}"])) {
    case Ok(m) -> {
      assertEqualInt(m.headers.length.toInt(), 1, "header stored")
      assertEqual(m.headers[0], r"Authorization=Bearer ${GITHUB_TOKEN}", "header value preserved verbatim (expansion happens at injection time, not storage)")
    }
    case Err(_) -> assertTrue(false, "valid url server with a header should create")
  }
}

test "MCP server 'enabled' flag: rejected if not '0'/'1', persisted through add/update, gates container injection" {
  if not live() {
    return
  }
  val me = freshUser("lib-mcp-enabled")
  val noArgs: slice[String] = []
  match addMcpServerHandler(SaveMcpServerRequest(name = "gh", transport = "stdio", command = "npx", args = noArgs, url = "", env = noArgs, enabled = "yes")) {
    case Ok(_) -> assertTrue(false, "non-'0'/'1' enabled should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "invalid enabled -> 400")
  }

  val created = match addMcpServerHandler(SaveMcpServerRequest(name = "gh", transport = "stdio", command = "npx", args = noArgs, url = "", env = noArgs, enabled = "0")) {
    case Ok(m) -> m
    case Err(_) -> {
      assertTrue(false, "valid disabled server should create")
      panic("unreachable")
    }
  }
  assertEqual(created.enabled, "0", "enabled='0' persisted on create")

  val userId = me
  val profile = mustProfile(addProfile(CloudAgents.Pg.personalScope(userId), "p", "claude", "none", "all", noArgs, noArgs, noArgs, [created.id], "all", noArgs))
  match mcpServersForProfile(CloudAgents.Pg.personalScope(userId), profile.id) {
    case Ok(granted) -> assertEqualInt(granted.length.toInt(), 0, "a disabled server is withheld from container injection even when granted")
    case Err(e) -> assertTrue(false, "mcpServersForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match updateMcpServerHandler(created.id, SaveMcpServerRequest(name = "gh", transport = "stdio", command = "npx", args = noArgs, url = "", env = noArgs, enabled = "1")) {
    case Ok(m) -> assertEqual(m.enabled, "1", "enabled='1' persisted on update")
    case Err(_) -> assertTrue(false, "update to enabled='1' should succeed")
  }
  match mcpServersForProfile(CloudAgents.Pg.personalScope(userId), profile.id) {
    case Ok(granted) -> assertEqualInt(granted.length.toInt(), 1, "now-enabled server is injected once flipped on")
    case Err(e) -> assertTrue(false, "mcpServersForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "patchMissingMcpServerEnabled defaults a missing 'enabled' key to '1' and leaves a present one untouched" {
  // headers is supplied explicitly here so this test stays scoped to the
  // 'enabled' patch alone — see the dedicated patchMissingMcpServerHeaders
  // tests below for that field's own missing-key behavior.
  val withoutField = "{\"name\":\"gh\",\"transport\":\"stdio\",\"command\":\"npx\",\"args\":[],\"url\":\"\",\"env\":[],\"headers\":[]}"
  val patched = patchMissingMcpServerEnabled(withoutField)
  match SaveMcpServerRequest.fromJson(patched) {
    case Ok(req) -> assertEqual(req.enabled, "1", "missing enabled defaults to '1' so an old caller doesn't 400")
    case Err(_) -> assertTrue(false, "patched body should decode")
  }

  val withField = "{\"name\":\"gh\",\"transport\":\"stdio\",\"command\":\"npx\",\"args\":[],\"url\":\"\",\"env\":[],\"enabled\":\"0\"}"
  assertEqual(patchMissingMcpServerEnabled(withField), withField, "a body that already sends enabled is passed through unchanged")
}

test "patchMissingMcpServerEnabledForUpdate defaults a missing 'enabled' key to the server's current stored value, not '1'" {
  if not live() {
    return
  }
  val me = freshUser("lib-mcp-enabled-update-patch")
  val noArgs: slice[String] = []
  val disabled = match addMcpServerHandler(SaveMcpServerRequest(name = "gh", transport = "stdio", command = "npx", args = noArgs, url = "", env = noArgs, enabled = "0")) {
    case Ok(m) -> m
    case Err(_) -> {
      assertTrue(false, "valid disabled server should create")
      panic("unreachable")
    }
  }

  val withoutField = "{\"name\":\"gh\",\"transport\":\"stdio\",\"command\":\"npx\",\"args\":[],\"url\":\"\",\"env\":[],\"headers\":[]}"
  val patched = patchMissingMcpServerEnabledForUpdate(withoutField, disabled.id)
  match SaveMcpServerRequest.fromJson(patched) {
    case Ok(req) -> assertEqual(req.enabled, "0", "a stale update omitting enabled must preserve the server's current '0', not silently re-enable it")
    case Err(_) -> assertTrue(false, "patched body should decode")
  }

  val withField = "{\"name\":\"gh\",\"transport\":\"stdio\",\"command\":\"npx\",\"args\":[],\"url\":\"\",\"env\":[],\"enabled\":\"1\"}"
  assertEqual(patchMissingMcpServerEnabledForUpdate(withField, disabled.id), withField, "a body that already sends enabled is passed through unchanged")

  val patchedUnknownId = patchMissingMcpServerEnabledForUpdate(withoutField, "no-such-id")
  match SaveMcpServerRequest.fromJson(patchedUnknownId) {
    case Ok(req) -> assertEqual(req.enabled, "1", "an unknown id falls back to '1' — updateMcpServerHandler itself reports the real not-found error")
    case Err(_) -> assertTrue(false, "patched body should decode")
  }
}

test "patchMissingMcpServerHeaders defaults a missing 'headers' key to an empty list and leaves a present one untouched" {
  // add path only — there is no prior server to preserve headers from, so
  // [] is the correct default here. See patchMissingMcpServerHeadersForUpdate
  // below for the update path, which must preserve stored headers instead
  // of wiping them (#1043).
  val withoutField = "{\"name\":\"gh\",\"transport\":\"url\",\"command\":\"\",\"args\":[],\"url\":\"https://example.com/mcp\",\"env\":[],\"enabled\":\"1\"}"
  val patched = patchMissingMcpServerHeaders(withoutField)
  match SaveMcpServerRequest.fromJson(patched) {
    case Ok(req) -> assertEqualInt(req.headers.length.toInt(), 0, "missing headers defaults to [] so a pre-#768 caller doesn't 400")
    case Err(_) -> assertTrue(false, "patched body should decode")
  }

  val withField = "{\"name\":\"gh\",\"transport\":\"url\",\"command\":\"\",\"args\":[],\"url\":\"https://example.com/mcp\",\"env\":[],\"enabled\":\"1\",\"headers\":[\"Authorization=Bearer x\"]}"
  assertEqual(patchMissingMcpServerHeaders(withField), withField, "a body that already sends headers is passed through unchanged")
}

test "addMcpServerHandler with headers omitted from the decoded request stores no headers" {
  if not live() {
    return
  }
  val me = freshUser("lib-mcp-add-headers-omitted")
  // Mirrors what RouteAddMcpServer does: patch the raw body (as if a
  // pre-#768 caller sent one without 'headers') before decoding, then hand
  // the decoded request to the handler exactly as the route does.
  val rawBody = "{\"name\":\"gh\",\"transport\":\"url\",\"command\":\"\",\"args\":[],\"url\":\"https://example.com/mcp\",\"env\":[],\"enabled\":\"1\"}"
  val decoded = match SaveMcpServerRequest.fromJson(patchMissingMcpServerHeaders(rawBody)) {
    case Ok(req) -> req
    case Err(_) -> {
      assertTrue(false, "patched add body should decode")
      panic("unreachable")
    }
  }
  match addMcpServerHandler(decoded) {
    case Ok(m) -> assertEqualInt(m.headers.length.toInt(), 0, "a pre-#768 add request stores no headers, not an error")
    case Err(_) -> assertTrue(false, "add without headers should succeed")
  }
}

test "patchMissingMcpServerHeadersForUpdate defaults a missing 'headers' key to the server's current stored headers, not []" {
  if not live() {
    return
  }
  val me = freshUser("lib-mcp-headers-update-patch")
  val noArgs: slice[String] = []
  val withHeader = match addMcpServerHandler(SaveMcpServerRequest(name = "gh", transport = "url", command = "", args = noArgs, url = "https://example.com/mcp", env = noArgs, headers = [r"Authorization=Bearer ${GITHUB_TOKEN}"])) {
    case Ok(m) -> m
    case Err(_) -> {
      assertTrue(false, "valid server with a header should create")
      panic("unreachable")
    }
  }
  assertEqualInt(withHeader.headers.length.toInt(), 1, "header stored on create")

  // A stale client that predates #768 sends an update body with no
  // 'headers' key at all — must preserve the stored header, not wipe it.
  val withoutField = "{\"name\":\"gh\",\"transport\":\"url\",\"command\":\"\",\"args\":[],\"url\":\"https://example.com/mcp\",\"env\":[],\"enabled\":\"1\"}"
  val patched = patchMissingMcpServerHeadersForUpdate(withoutField, withHeader.id)
  val decoded = match SaveMcpServerRequest.fromJson(patched) {
    case Ok(req) -> req
    case Err(_) -> {
      assertTrue(false, "patched body should decode")
      panic("unreachable")
    }
  }
  assertEqualInt(decoded.headers.length.toInt(), 1, "a stale update omitting headers must preserve the server's currently-stored header, not silently wipe it (#1043)")
  assertEqual(decoded.headers[0], r"Authorization=Bearer ${GITHUB_TOKEN}", "preserved header value matches what was stored")
  match updateMcpServerHandler(withHeader.id, decoded) {
    case Ok(m) -> assertEqualInt(m.headers.length.toInt(), 1, "header survives a real update that omitted 'headers' from the body")
    case Err(_) -> assertTrue(false, "update should succeed")
  }

  // A caller that explicitly sends headers:[] means it, and must clear them.
  val withEmptyField = "{\"name\":\"gh\",\"transport\":\"url\",\"command\":\"\",\"args\":[],\"url\":\"https://example.com/mcp\",\"env\":[],\"enabled\":\"1\",\"headers\":[]}"
  assertEqual(patchMissingMcpServerHeadersForUpdate(withEmptyField, withHeader.id), withEmptyField, "a body that explicitly sends headers:[] is passed through unchanged, clearing them")
  match SaveMcpServerRequest.fromJson(withEmptyField) {
    case Ok(req) -> {
      match updateMcpServerHandler(withHeader.id, req) {
        case Ok(m) -> assertEqualInt(m.headers.length.toInt(), 0, "an explicit headers:[] on update clears the stored header")
        case Err(_) -> assertTrue(false, "update should succeed")
      }
    }
    case Err(_) -> assertTrue(false, "body should decode")
  }

  // A body that already sends a non-empty 'headers' passes through unchanged.
  val withField = "{\"name\":\"gh\",\"transport\":\"url\",\"command\":\"\",\"args\":[],\"url\":\"https://example.com/mcp\",\"env\":[],\"enabled\":\"1\",\"headers\":[\"X-Other=1\"]}"
  assertEqual(patchMissingMcpServerHeadersForUpdate(withField, withHeader.id), withField, "a body that already sends headers is passed through unchanged")

  val patchedUnknownId = patchMissingMcpServerHeadersForUpdate(withoutField, "no-such-id")
  match SaveMcpServerRequest.fromJson(patchedUnknownId) {
    case Ok(req) -> assertEqualInt(req.headers.length.toInt(), 0, "an unknown id falls back to [] — updateMcpServerHandler itself reports the real not-found error")
    case Err(_) -> assertTrue(false, "patched body should decode")
  }
}

test "Skill CRUD round-trips" {
  if not live() {
    return
  }
  val me = freshUser("lib-skill-crud")
  val userId = me
  val created = mustSkill(addSkill(CloudAgents.Pg.personalScope(userId), "greet", "says hi", "# Steps\n1. Say hi"))
  assertTrue(created.id.length > 0, "created skill has an id")

  val listed = mustSkills(listSkills(CloudAgents.Pg.personalScope(userId)))
  assertEqualInt(listed.length.toInt(), 1, "one skill listed")

  val updated = mustRows(updateSkill(created.id, CloudAgents.Pg.personalScope(userId), "greet", "says hi warmly", created.body))
  assertEqualInt(updated, 1, "update touches one row")
  match getSkill(created.id, CloudAgents.Pg.personalScope(userId)) {
    case Ok(Some(s)) -> assertEqual(s.description, "says hi warmly", "description updated")
    case Ok(None) -> assertTrue(false, "updated skill should exist")
    case Err(e) -> assertTrue(false, "getSkill failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  val deleted = mustRows(deleteSkill(created.id, CloudAgents.Pg.personalScope(userId)))
  assertEqualInt(deleted, 1, "delete touches one row")
  assertEqualInt(mustSkills(listSkills(CloudAgents.Pg.personalScope(userId))).length.toInt(), 0, "empty after delete")
}

func mustSkills(r: in Result[slice[Skill], CloudAgents.Sqlite.DbError]): slice[Skill] {
  return match r {
    case Ok(ss) -> ss
    case Err(e) -> panic("skill list failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustRows(r: in Result[Int, CloudAgents.Sqlite.DbError]): Int {
  return match r { case Ok(n) -> n; case Err(e) -> panic("write failed: " + CloudAgents.Sqlite.dbErrorMessage(e)) }
}

test "MCP server CRUD round-trips its ordered args and env" {
  if not live() {
    return
  }
  val me = freshUser("lib-mcp-crud")
  val userId = me
  val created = mustMcpServer(
    addMcpServer(CloudAgents.Pg.personalScope(userId), "gh", "stdio", "npx", ["-y", "gh-mcp", "--verbose"], "", ["DEBUG=1"])
  )
  assertEqualInt(created.args.length.toInt(), 3, "three args stored")
  assertEqual(created.args[0], "-y", "arg 0 order")
  assertEqual(created.args[1], "gh-mcp", "arg 1 order")
  assertEqual(created.args[2], "--verbose", "arg 2 order")

  match getMcpServer(created.id, CloudAgents.Pg.personalScope(userId)) {
    case Ok(Some(m)) -> {
      assertEqualInt(m.args.length.toInt(), 3, "args survive round-trip")
      assertEqual(m.env[0], "DEBUG=1", "env survives round-trip")
    }
    case Ok(None) -> assertTrue(false, "created server should exist")
    case Err(e) -> assertTrue(false, "getMcpServer failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Update replaces the args wholesale (shorter list) — old rows must not linger.
  val noEnv: slice[String] = []
  val updated = mustRows(updateMcpServer(created.id, CloudAgents.Pg.personalScope(userId), "gh", "stdio", "npx", ["-y"], "", noEnv))
  assertEqualInt(updated, 1, "update touches one row")
  match getMcpServer(created.id, CloudAgents.Pg.personalScope(userId)) {
    case Ok(Some(m)) -> {
      assertEqualInt(m.args.length.toInt(), 1, "arg list shrunk on update")
      assertEqualInt(m.env.length.toInt(), 0, "env cleared on update")
    }
    case Ok(None) -> assertTrue(false, "updated server should exist")
    case Err(e) -> assertTrue(false, "getMcpServer failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "MCP server CRUD round-trips its ordered headers, independently of args/env (#768)" {
  if not live() {
    return
  }
  val me = freshUser("lib-mcp-crud-headers")
  val userId = me
  val noArgs: slice[String] = []
  val noEnv: slice[String] = []
  val created = mustMcpServer(
    addMcpServer(
      CloudAgents.Pg.personalScope(userId), "github", "url", "", noArgs, "https://api.githubcopilot.com/mcp/", noEnv, "0",
      [r"Authorization=Bearer ${GITHUB_TOKEN}", "X-Extra=1"]
    )
  )
  assertEqualInt(created.headers.length.toInt(), 2, "two headers stored")
  assertEqual(created.headers[0], r"Authorization=Bearer ${GITHUB_TOKEN}", "header 0 order")
  assertEqual(created.headers[1], "X-Extra=1", "header 1 order")

  match getMcpServer(created.id, CloudAgents.Pg.personalScope(userId)) {
    case Ok(Some(m)) -> assertEqualInt(m.headers.length.toInt(), 2, "headers survive round-trip")
    case Ok(None) -> assertTrue(false, "created server should exist")
    case Err(e) -> assertTrue(false, "getMcpServer failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Update replaces headers wholesale, same clear-then-reinsert shape as args/env.
  val oneHeader = ["Authorization=Bearer new-token"]
  val updated = mustRows(updateMcpServer(created.id, CloudAgents.Pg.personalScope(userId), "github", "url", "", noArgs, "https://api.githubcopilot.com/mcp/", noEnv, "0", oneHeader))
  assertEqualInt(updated, 1, "update touches one row")
  match getMcpServer(created.id, CloudAgents.Pg.personalScope(userId)) {
    case Ok(Some(m)) -> {
      assertEqualInt(m.headers.length.toInt(), 1, "header list shrunk on update")
      assertEqual(m.headers[0], "Authorization=Bearer new-token", "new header value stored")
    }
    case Ok(None) -> assertTrue(false, "updated server should exist")
    case Err(e) -> assertTrue(false, "getMcpServer failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Deleting the server must not leave orphaned mcp_server_headers rows (#1039):
  // check the headers table directly, and confirm a second delete finds nothing.
  val deleted = mustRows(deleteMcpServer(created.id, CloudAgents.Pg.personalScope(userId)))
  assertEqualInt(deleted, 1, "delete touches one row")
  val u = match CloudAgents.PgStore.open(CloudAgents.Pg.personalScope(userId)) {
    case Ok(x) -> x
    case Err(e) -> panic("open failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.q(u, "SELECT id FROM mcp_server_headers WHERE mcp_server_id = @p0", [created.id]) {
    case Ok(rows) -> assertEqualInt(rows.length.toInt(), 0, "no orphaned mcp_server_headers rows after delete")
    case Err(e) -> assertTrue(false, "header query failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val deletedAgain = mustRows(deleteMcpServer(created.id, CloudAgents.Pg.personalScope(userId)))
  assertEqualInt(deletedAgain, 0, "second delete finds nothing")
}

test "Library ownership scoping hides other users' items" {
  if not live() {
    return
  }
  val me = freshUser("lib-library-scope")
  val other = newUser("lib-scope-other")
  val mine = mustSkill(addSkill(CloudAgents.Pg.personalScope(me), "mine", "d", "b"))
  val theirs = mustSkill(addSkill(CloudAgents.Pg.personalScope(other), "theirs", "d", "b"))

  assertEqualInt(mustSkills(listSkills(CloudAgents.Pg.personalScope(me))).length.toInt(), 1, "only my skill listed")
  match getSkill(theirs.id, CloudAgents.Pg.personalScope(me)) {
    case Ok(Some(_)) -> assertTrue(false, "cannot read another user's skill")
    case Ok(None) -> ()
    case Err(e) -> assertTrue(false, "getSkill failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertEqualInt(mustRows(deleteSkill(theirs.id, CloudAgents.Pg.personalScope(me))), 0, "cannot delete another user's skill")
  // Silences unused-binding warnings on `mine` if the toolchain has one — also
  // documents that the owner's own row is unaffected by the scoping checks above.
  assertTrue(mine.id.length > 0, "my skill id is set")
}

test "Profile grants resolve skills, subagents, and MCP servers, skipping dangling ids" {
  if not live() {
    return
  }
  val me = freshUser("lib-library-profile-grants")
  val userId = me
  val skill = mustSkill(addSkill(CloudAgents.Pg.personalScope(userId), "greet", "d", "b"))
  val noArgs: slice[String] = []
  val server = mustMcpServer(addMcpServer(CloudAgents.Pg.personalScope(userId), "gh", "stdio", "npx", noArgs, "", noArgs))

  val profile = mustProfile(
    addProfile(
      CloudAgents.Pg.personalScope(userId),
      "with-library",
      "claude",
      "full",
      "all",
      noArgs,
      [skill.id],
      [],
      [server.id, "dangling-id"],
      "all",
      noArgs
    )
  )
  assertEqualInt(profile.skillIds.length.toInt(), 1, "skill grant stored on the profile")
  assertEqualInt(profile.mcpServerIds.length.toInt(), 2, "both mcp server ids stored, including the dangling one")

  match skillsForProfile(CloudAgents.Pg.personalScope(userId), profile.id) {
    case Ok(resolvedSkills) -> {
      assertEqualInt(resolvedSkills.length.toInt(), 1, "one skill resolves")
      assertEqual(resolvedSkills[0].name, "greet", "resolved skill matches the grant")
    }
    case Err(e) -> assertTrue(false, "skillsForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match mcpServersForProfile(CloudAgents.Pg.personalScope(userId), profile.id) {
    case Ok(servers) -> assertEqualInt(servers.length.toInt(), 1, "dangling mcp server id is silently skipped")
    case Err(e) -> assertTrue(false, "mcpServersForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match subagentsForProfile(CloudAgents.Pg.personalScope(userId), profile.id) {
    case Ok(subagents) -> assertEqualInt(subagents.length.toInt(), 0, "no subagents granted")
    case Err(e) -> assertTrue(false, "subagentsForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // A sessionless/profileless run gets no library grants (unlike credentials,
  // there is no "fall open to everything" default).
  match skillsForProfile(CloudAgents.Pg.personalScope(userId), "") {
    case Ok(skills) -> assertEqualInt(skills.length.toInt(), 0, "empty profile id -> no skill grants")
    case Err(e) -> assertTrue(false, "skillsForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}
