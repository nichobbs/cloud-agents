@test_module
package CloudAgents.LibraryTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Db
import CloudAgents.Library
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

// ── SQL builder tests (no database needed) ────────────────────────────────────
test "library SQL builders are owner-scoped and escaped" {
  val ins = insertSkillSql("s1", "u1", "it's a name", "desc", "body", "1000")
  assertTrue(ins.startsWith("INSERT INTO skills"), "insert target")
  assertTrue(ins.contains("'it''s a name'"), "name is escaped")
  assertTrue(selectSkillsSql("u1").contains("WHERE user_id = 'u1'"), "list scoped by owner")
  assertTrue(selectSkillByIdSql("s1", "u1").contains("AND user_id = 'u1'"), "get scoped by owner")
  assertTrue(deleteSkillSql("s1", "u1").endsWith("AND user_id = 'u1'"), "delete scoped by owner")
  assertTrue(skillsSchemaSql().contains("UNIQUE(user_id, name)"), "skill names unique per user")

  assertTrue(subagentsSchemaSql().contains("UNIQUE(user_id, name)"), "subagent names unique per user")
  assertTrue(selectSubagentsSql("u1").contains("ORDER BY name ASC"), "subagents alphabetical")

  assertTrue(mcpServersSchemaSql().contains("UNIQUE(user_id, name)"), "mcp server names unique per user")
  val argIns = insertMcpServerArgSql("a1", "m1", "u1", "0", "--flag")
  assertTrue(argIns.contains("VALUES ('a1', 'm1', 'u1', '0', '--flag')"), "arg row shape")
  assertTrue(
    selectMcpServerArgsSql("m1", "u1").contains("ORDER BY CAST(position AS INTEGER) ASC"),
    "args ordered numerically"
  )

  val grant = insertProfileSkillSql("g1", "p1", "u1", "s1")
  assertTrue(grant.contains("ON CONFLICT(profile_id, skill_id) DO NOTHING"), "skill grant insert is idempotent")
  assertTrue(selectProfileSkillIdsSql("p1", "u1").contains("WHERE profile_id = 'p1'"), "skill grants scoped to profile")
}

test "handler validation rejects bad names, enums, and content" {
  assertTrue(isValidLibraryName("my-skill_1"), "valid slug accepted")
  assertTrue(not isValidLibraryName(""), "empty name rejected")
  assertTrue(not isValidLibraryName("has spaces"), "spaces rejected")
  assertTrue(not isValidLibraryName("has/slash"), "slash rejected (path traversal guard)")
  assertTrue(not isValidLibraryName("../etc"), "dot-dot rejected")

  assertTrue(isValidMcpTransport("stdio") and isValidMcpTransport("url"), "known transports accepted")
  assertTrue(not isValidMcpTransport("sse"), "unknown transport rejected")
}

// ── Live-database tests ───────────────────────────────────────────────────────
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
    // fine
  }
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
  val dbPath = useFreshTestDb("skill-handlers")
  defer {
    cleanupTestDb(dbPath)
  }
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
  val dbPath = useFreshTestDb("mcp-handlers")
  defer {
    cleanupTestDb(dbPath)
  }
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
  val dbPath = useFreshTestDb("mcp-enabled")
  defer {
    cleanupTestDb(dbPath)
  }
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

  val userId = "default"
  val profile = mustProfile(addProfile(userId, "p", "claude", "none", "all", noArgs, noArgs, noArgs, [created.id], "all", noArgs))
  match mcpServersForProfile(userId, profile.id) {
    case Ok(granted) -> assertEqualInt(granted.length.toInt(), 0, "a disabled server is withheld from container injection even when granted")
    case Err(e) -> assertTrue(false, "mcpServersForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match updateMcpServerHandler(created.id, SaveMcpServerRequest(name = "gh", transport = "stdio", command = "npx", args = noArgs, url = "", env = noArgs, enabled = "1")) {
    case Ok(m) -> assertEqual(m.enabled, "1", "enabled='1' persisted on update")
    case Err(_) -> assertTrue(false, "update to enabled='1' should succeed")
  }
  match mcpServersForProfile(userId, profile.id) {
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
  val dbPath = useFreshTestDb("mcp-enabled-update-patch")
  defer {
    cleanupTestDb(dbPath)
  }
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
  val withoutField = "{\"name\":\"gh\",\"transport\":\"url\",\"command\":\"\",\"args\":[],\"url\":\"https://example.com/mcp\",\"env\":[],\"enabled\":\"1\"}"
  val patched = patchMissingMcpServerHeaders(withoutField)
  match SaveMcpServerRequest.fromJson(patched) {
    case Ok(req) -> assertEqualInt(req.headers.length.toInt(), 0, "missing headers defaults to [] so a pre-#768 caller doesn't 400")
    case Err(_) -> assertTrue(false, "patched body should decode")
  }

  val withField = "{\"name\":\"gh\",\"transport\":\"url\",\"command\":\"\",\"args\":[],\"url\":\"https://example.com/mcp\",\"env\":[],\"enabled\":\"1\",\"headers\":[\"Authorization=Bearer x\"]}"
  assertEqual(patchMissingMcpServerHeaders(withField), withField, "a body that already sends headers is passed through unchanged")
}

test "Skill CRUD round-trips" {
  val dbPath = useFreshTestDb("skill-crud")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"
  val created = mustSkill(addSkill(userId, "greet", "says hi", "# Steps\n1. Say hi"))
  assertTrue(created.id.length > 0, "created skill has an id")

  val listed = mustSkills(listSkills(userId))
  assertEqualInt(listed.length.toInt(), 1, "one skill listed")

  val updated = mustRows(updateSkill(created.id, userId, "greet", "says hi warmly", created.body))
  assertEqualInt(updated, 1, "update touches one row")
  match getSkill(created.id, userId) {
    case Ok(Some(s)) -> assertEqual(s.description, "says hi warmly", "description updated")
    case Ok(None) -> assertTrue(false, "updated skill should exist")
    case Err(e) -> assertTrue(false, "getSkill failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  val deleted = mustRows(deleteSkill(created.id, userId))
  assertEqualInt(deleted, 1, "delete touches one row")
  assertEqualInt(mustSkills(listSkills(userId)).length.toInt(), 0, "empty after delete")
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
  val dbPath = useFreshTestDb("mcp-crud")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"
  val created = mustMcpServer(
    addMcpServer(userId, "gh", "stdio", "npx", ["-y", "gh-mcp", "--verbose"], "", ["DEBUG=1"])
  )
  assertEqualInt(created.args.length.toInt(), 3, "three args stored")
  assertEqual(created.args[0], "-y", "arg 0 order")
  assertEqual(created.args[1], "gh-mcp", "arg 1 order")
  assertEqual(created.args[2], "--verbose", "arg 2 order")

  match getMcpServer(created.id, userId) {
    case Ok(Some(m)) -> {
      assertEqualInt(m.args.length.toInt(), 3, "args survive round-trip")
      assertEqual(m.env[0], "DEBUG=1", "env survives round-trip")
    }
    case Ok(None) -> assertTrue(false, "created server should exist")
    case Err(e) -> assertTrue(false, "getMcpServer failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Update replaces the args wholesale (shorter list) — old rows must not linger.
  val noEnv: slice[String] = []
  val updated = mustRows(updateMcpServer(created.id, userId, "gh", "stdio", "npx", ["-y"], "", noEnv))
  assertEqualInt(updated, 1, "update touches one row")
  match getMcpServer(created.id, userId) {
    case Ok(Some(m)) -> {
      assertEqualInt(m.args.length.toInt(), 1, "arg list shrunk on update")
      assertEqualInt(m.env.length.toInt(), 0, "env cleared on update")
    }
    case Ok(None) -> assertTrue(false, "updated server should exist")
    case Err(e) -> assertTrue(false, "getMcpServer failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "MCP server CRUD round-trips its ordered headers, independently of args/env (#768)" {
  val dbPath = useFreshTestDb("mcp-crud-headers")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"
  val noArgs: slice[String] = []
  val noEnv: slice[String] = []
  val created = mustMcpServer(
    addMcpServer(
      userId, "github", "url", "", noArgs, "https://api.githubcopilot.com/mcp/", noEnv, "0",
      [r"Authorization=Bearer ${GITHUB_TOKEN}", "X-Extra=1"]
    )
  )
  assertEqualInt(created.headers.length.toInt(), 2, "two headers stored")
  assertEqual(created.headers[0], r"Authorization=Bearer ${GITHUB_TOKEN}", "header 0 order")
  assertEqual(created.headers[1], "X-Extra=1", "header 1 order")

  match getMcpServer(created.id, userId) {
    case Ok(Some(m)) -> assertEqualInt(m.headers.length.toInt(), 2, "headers survive round-trip")
    case Ok(None) -> assertTrue(false, "created server should exist")
    case Err(e) -> assertTrue(false, "getMcpServer failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Update replaces headers wholesale, same clear-then-reinsert shape as args/env.
  val oneHeader = ["Authorization=Bearer new-token"]
  val updated = mustRows(updateMcpServer(created.id, userId, "github", "url", "", noArgs, "https://api.githubcopilot.com/mcp/", noEnv, "0", oneHeader))
  assertEqualInt(updated, 1, "update touches one row")
  match getMcpServer(created.id, userId) {
    case Ok(Some(m)) -> {
      assertEqualInt(m.headers.length.toInt(), 1, "header list shrunk on update")
      assertEqual(m.headers[0], "Authorization=Bearer new-token", "new header value stored")
    }
    case Ok(None) -> assertTrue(false, "updated server should exist")
    case Err(e) -> assertTrue(false, "getMcpServer failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Deleting the server must not leave orphaned mcp_server_headers rows (#1039):
  // check the headers table directly, and confirm a second delete finds nothing.
  val deleted = mustRows(deleteMcpServer(created.id, userId))
  assertEqualInt(deleted, 1, "delete touches one row")
  match CloudAgents.Sqlite.query(CloudAgents.Db.selectMcpServerHeadersSql(created.id, userId)) {
    case Ok(rows) -> assertEqualInt(CloudAgents.Sqlite.getRowArrayLength(rows), 0, "no orphaned mcp_server_headers rows after delete")
    case Err(e) -> assertTrue(false, "header query failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val deletedAgain = mustRows(deleteMcpServer(created.id, userId))
  assertEqualInt(deletedAgain, 0, "second delete finds nothing")
}

test "Library ownership scoping hides other users' items" {
  val dbPath = useFreshTestDb("library-scope")
  defer {
    cleanupTestDb(dbPath)
  }
  val mine = mustSkill(addSkill("default", "mine", "d", "b"))
  val theirs = mustSkill(addSkill("someone-else", "theirs", "d", "b"))

  assertEqualInt(mustSkills(listSkills("default")).length.toInt(), 1, "only my skill listed")
  match getSkill(theirs.id, "default") {
    case Ok(Some(_)) -> assertTrue(false, "cannot read another user's skill")
    case Ok(None) -> ()
    case Err(e) -> assertTrue(false, "getSkill failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertEqualInt(mustRows(deleteSkill(theirs.id, "default")), 0, "cannot delete another user's skill")
  // Silences unused-binding warnings on `mine` if the toolchain has one — also
  // documents that the owner's own row is unaffected by the scoping checks above.
  assertTrue(mine.id.length > 0, "my skill id is set")
}

test "Profile grants resolve skills, subagents, and MCP servers, skipping dangling ids" {
  val dbPath = useFreshTestDb("library-profile-grants")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"
  val skill = mustSkill(addSkill(userId, "greet", "d", "b"))
  val noArgs: slice[String] = []
  val server = mustMcpServer(addMcpServer(userId, "gh", "stdio", "npx", noArgs, "", noArgs))

  val profile = mustProfile(
    addProfile(
      userId,
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

  match skillsForProfile(userId, profile.id) {
    case Ok(resolvedSkills) -> {
      assertEqualInt(resolvedSkills.length.toInt(), 1, "one skill resolves")
      assertEqual(resolvedSkills[0].name, "greet", "resolved skill matches the grant")
    }
    case Err(e) -> assertTrue(false, "skillsForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match mcpServersForProfile(userId, profile.id) {
    case Ok(servers) -> assertEqualInt(servers.length.toInt(), 1, "dangling mcp server id is silently skipped")
    case Err(e) -> assertTrue(false, "mcpServersForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match subagentsForProfile(userId, profile.id) {
    case Ok(subagents) -> assertEqualInt(subagents.length.toInt(), 0, "no subagents granted")
    case Err(e) -> assertTrue(false, "subagentsForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // A sessionless/profileless run gets no library grants (unlike credentials,
  // there is no "fall open to everything" default).
  match skillsForProfile(userId, "") {
    case Ok(skills) -> assertEqualInt(skills.length.toInt(), 0, "empty profile id -> no skill grants")
    case Err(e) -> assertTrue(false, "skillsForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}
