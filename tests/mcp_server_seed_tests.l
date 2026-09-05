@test_module
package CloudAgents.McpServerSeedTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.McpServerSeed
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/library_seed_tests.l) ──────────
@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

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
}

test "seedMcpServersDir defaults to seed/mcp-servers and honors CLOUD_AGENTS_SEED_MCP_SERVERS_DIR" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_MCP_SERVERS_DIR", "")
  assertEqual(seedMcpServersDir(), "seed/mcp-servers", "default directory")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_MCP_SERVERS_DIR", "/tmp/custom-mcp-seed-dir")
  assertEqual(seedMcpServersDir(), "/tmp/custom-mcp-seed-dir", "override honored")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_MCP_SERVERS_DIR", "")
}

test "defaultMcpServerNames is the fixed curated set of four" {
  val names = defaultMcpServerNames()
  assertEqualInt(names.length.toInt(), 4, "four curated MCP servers")
  var foundGithub = false
  var foundPlaywright = false
  var foundFetch = false
  var foundContext7 = false
  var i = 0
  while i < names.length.toInt() {
    if names[i] == "github" { foundGithub = true }
    if names[i] == "playwright" { foundPlaywright = true }
    if names[i] == "fetch" { foundFetch = true }
    if names[i] == "context7" { foundContext7 = true }
    i = i + 1
  }
  assertTrue(foundGithub, "github is curated")
  assertTrue(foundPlaywright, "playwright is curated")
  assertTrue(foundFetch, "fetch is curated")
  assertTrue(foundContext7, "context7 is curated")
}

// ── seedDefaultMcpServersIfEmpty against a live DB and the real repo-root seed files ──
test "seedDefaultMcpServersIfEmpty populates an empty library from the real seed/mcp-servers files, is idempotent, and never overwrites" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_MCP_SERVERS_DIR", "")
  val dbPath = useFreshTestDb("mcp-server-seed")
  val userId = "gh-mcp-seed-test-user"

  seedDefaultMcpServersIfEmpty(userId)

  val seeded = match CloudAgents.Repository.listMcpServers(userId) {
    case Ok(s) -> s
    case Err(e) -> {
      assertTrue(false, "listMcpServers failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      []
    }
  }
  val expectedNames = defaultMcpServerNames()
  assertEqualInt(seeded.length.toInt(), expectedNames.length.toInt(), "every curated MCP server seeded from the real files")

  // A second call is a no-op: the library is no longer empty, so nothing is
  // re-inserted (row count unchanged).
  seedDefaultMcpServersIfEmpty(userId)
  val afterSecondCall = match CloudAgents.Repository.listMcpServers(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  assertEqualInt(afterSecondCall.length.toInt(), seeded.length.toInt(), "re-seeding an already-populated library is a no-op")

  // Deleting every seeded server brings the user back to empty, and a later
  // sign-in should reseed rather than leave them stuck at zero.
  var i = 0
  while i < seeded.length.toInt() {
    match CloudAgents.Repository.deleteMcpServer(seeded[i].id, userId) {
      case Ok(_) -> ()
      case Err(e) -> assertTrue(false, "deleteMcpServer failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
    }
    i = i + 1
  }
  seedDefaultMcpServersIfEmpty(userId)
  val reseeded = match CloudAgents.Repository.listMcpServers(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  assertEqualInt(reseeded.length.toInt(), expectedNames.length.toInt(), "an emptied library is reseeded on the next call")

  cleanupTestDb(dbPath)
}

test "seedDefaultMcpServersIfEmpty never touches a library the user has already started customizing" {
  val dbPath = useFreshTestDb("mcp-server-seed-nonempty")
  val userId = "gh-mcp-seed-test-user-2"
  val noArgs: slice[String] = []
  match CloudAgents.Repository.addMcpServer(userId, "my-own-server", "stdio", "npx", ["-y", "my-mcp"], "", noArgs) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "addMcpServer failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  seedDefaultMcpServersIfEmpty(userId)

  val servers = match CloudAgents.Repository.listMcpServers(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  assertEqualInt(servers.length.toInt(), 1, "a non-empty library is left exactly as the user made it")
  assertEqual(servers[0].name, "my-own-server", "the user's own MCP server is untouched")

  cleanupTestDb(dbPath)
}

test "the curated catalog's enabled/disabled defaults match the design: credential-requiring or heavier servers ship disabled" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_MCP_SERVERS_DIR", "")
  val dbPath = useFreshTestDb("mcp-server-seed-enabled")
  val userId = "gh-mcp-seed-test-user-enabled"

  seedDefaultMcpServersIfEmpty(userId)

  val servers = match CloudAgents.Repository.listMcpServers(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  var i = 0
  while i < servers.length.toInt() {
    val s = servers[i]
    if s.name == "github" {
      assertEqual(s.enabled, "0", "github ships disabled until GITHUB_TOKEN is granted")
      assertEqual(s.transport, "url", "github is a url-transport (hosted) server, not the deprecated npm package (#768)")
      assertTrue(s.headers.length.toInt() > 0, "github references a credential via an Authorization header")
    }
    if s.name == "playwright" {
      assertEqual(s.enabled, "0", "playwright ships disabled (heavier footprint, opt-in)")
    }
    if s.name == "fetch" {
      assertEqual(s.enabled, "1", "fetch needs no credential and ships enabled")
    }
    if s.name == "context7" {
      assertEqual(s.enabled, "1", "context7 works unauthenticated and ships enabled")
    }
    i = i + 1
  }

  cleanupTestDb(dbPath)
}

test "the seeded github server points at the hosted GitHub MCP endpoint with a bearer-token Authorization header (#768)" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_MCP_SERVERS_DIR", "")
  val dbPath = useFreshTestDb("mcp-server-seed-github-url")
  val userId = "gh-mcp-seed-test-user-github-url"

  seedDefaultMcpServersIfEmpty(userId)

  val servers = match CloudAgents.Repository.listMcpServers(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  var found = false
  var i = 0
  while i < servers.length.toInt() {
    val s = servers[i]
    if s.name == "github" {
      found = true
      assertEqual(s.url, "https://api.githubcopilot.com/mcp/", "github points at the hosted GitHub MCP endpoint, not the deprecated npm package")
      assertEqualInt(s.headers.length.toInt(), 1, "exactly one header entry")
      assertEqual(s.headers[0], r"Authorization=Bearer ${GITHUB_TOKEN}", "header carries a bearer token referencing the GITHUB_TOKEN credential")
      assertEqualInt(s.env.length.toInt(), 0, "no env entries — the credential now flows through the header, not env")
    }
    i = i + 1
  }
  assertTrue(found, "github is present in the seeded catalog")

  cleanupTestDb(dbPath)
}

test "a disabled seeded MCP server granted to a profile is excluded from container injection" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SEED_MCP_SERVERS_DIR", "")
  val dbPath = useFreshTestDb("mcp-server-seed-injection")
  val userId = "gh-mcp-seed-test-user-injection"

  seedDefaultMcpServersIfEmpty(userId)
  val servers = match CloudAgents.Repository.listMcpServers(userId) {
    case Ok(s) -> s
    case Err(_) -> []
  }
  var ids: slice[String] = []
  var i = 0
  while i < servers.length.toInt() {
    ids = ids.append(servers[i].id)
    i = i + 1
  }
  val profile = match CloudAgents.Repository.addProfile(userId, "p", "claude", "none", "all", [], [], [], ids, "all", []) {
    case Ok(p) -> p
    case Err(e) -> {
      assertTrue(false, "addProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      CloudAgents.Repository.Profile(
        id = "", userId = "", name = "", harness = "", networkPolicy = "", credentialMode = "", credentials = [],
        skillIds = [], subagentIds = [], mcpServerIds = [], toolMode = "", tools = [], createdAt = "", updatedAt = ""
      )
    }
  }

  val granted = match CloudAgents.Repository.mcpServersForProfile(userId, profile.id) {
    case Ok(s) -> s
    case Err(e) -> {
      assertTrue(false, "mcpServersForProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      []
    }
  }
  var foundGithub = false
  var foundPlaywright = false
  var foundFetch = false
  var j = 0
  while j < granted.length.toInt() {
    if granted[j].name == "github" { foundGithub = true }
    if granted[j].name == "playwright" { foundPlaywright = true }
    if granted[j].name == "fetch" { foundFetch = true }
    j = j + 1
  }
  assertTrue(not foundGithub, "disabled github server is withheld from injection despite being granted")
  assertTrue(not foundPlaywright, "disabled playwright server is withheld from injection despite being granted")
  assertTrue(foundFetch, "enabled fetch server is still injected")
  assertEqualInt(granted.length.toInt(), 2, "only the two enabled servers (fetch, context7) make it through")

  cleanupTestDb(dbPath)
}
