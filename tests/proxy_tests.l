//! Proxy handler tests: pure validators plus the no-credential paths against
//! the Postgres store (a fresh user's vault is empty).
@test_module
package CloudAgents.ProxyTests

import Std.Core
import Std.Environment
import CloudAgents.Scope
import Std.Testing
import Std.Uuid
import CloudAgents.Proxy
import CloudAgents.Repository
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Sqlite
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
  println("SKIP: proxy tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

// ── Notes ─────────────────────────────────────────────────────────────────────
//
// NB: no network path is ever exercised here — the no-credential tests fail
// closed at the vault lookup (404) before any outbound request could happen,
// and everything else is a pure validator. ENCRYPTION_KEY is deliberately NOT
// set: decryptedCredentialValue answers Ok(None) for an absent row before any
// decryption, so an empty vault needs no crypto configuration.

// ── Pure validators ───────────────────────────────────────────────────────────

test "isValidProxyPage accepts 1..10 and nothing else" {
  assertTrue(isValidProxyPage("1"), "1 ok")
  assertTrue(isValidProxyPage("5"), "5 ok")
  assertTrue(isValidProxyPage("9"), "9 ok")
  assertTrue(isValidProxyPage("10"), "10 ok")
  assertTrue(not isValidProxyPage(""), "empty rejected")
  assertTrue(not isValidProxyPage("0"), "0 rejected")
  assertTrue(not isValidProxyPage("11"), "11 rejected")
  assertTrue(not isValidProxyPage("100"), "3 digits rejected")
  assertTrue(not isValidProxyPage("-1"), "sign rejected")
  assertTrue(not isValidProxyPage("1a"), "trailing letter rejected")
  assertTrue(not isValidProxyPage("a"), "letter rejected")
  assertTrue(not isValidProxyPage(" 1"), "space rejected")
  // A leading zero is harmless: "01" parses to 1, stays in range, and GitHub
  // treats page=01 as page 1 — accepted by the value rule.
  assertTrue(isValidProxyPage("01"), "leading-zero form of an in-range page accepted")
}

test "isValidOwnerOrRepo enforces the GitHub-name charset" {
  assertTrue(isValidOwnerOrRepo("nichobbs"), "plain owner ok")
  assertTrue(isValidOwnerOrRepo("cloud-agents"), "hyphenated ok")
  assertTrue(isValidOwnerOrRepo("repo.name"), "dotted ok")
  assertTrue(isValidOwnerOrRepo("under_score"), "underscore ok")
  assertTrue(isValidOwnerOrRepo("A1"), "alnum ok")
  assertTrue(not isValidOwnerOrRepo(""), "empty rejected")
  assertTrue(not isValidOwnerOrRepo("-leading"), "leading hyphen rejected")
  assertTrue(not isValidOwnerOrRepo(".leading"), "leading dot rejected")
  assertTrue(not isValidOwnerOrRepo("a/b"), "slash rejected")
  assertTrue(not isValidOwnerOrRepo("a b"), "space rejected")
  assertTrue(not isValidOwnerOrRepo("a\"b"), "quote rejected")
  assertTrue(not isValidOwnerOrRepo("a\\b"), "backslash rejected")
  assertTrue(not isValidOwnerOrRepo("a?b"), "question mark rejected")
  assertTrue(not isValidOwnerOrRepo("a#b"), "hash rejected")
  assertTrue(not isValidOwnerOrRepo("a%b"), "percent rejected")
  var oversized = ""
  var i = 0
  while i < 101 {
    oversized = oversized + "a"
    i = i + 1
  }
  assertTrue(not isValidOwnerOrRepo(oversized), "101 chars rejected")
  assertTrue(isValidOwnerOrRepo(oversized.substring(0, 100)), "100 chars ok")
}

test "isValidProxyBranch allows slashes but stays URL-safe" {
  assertTrue(isValidProxyBranch("main"), "main ok")
  assertTrue(isValidProxyBranch("feature/one"), "one slash ok")
  assertTrue(isValidProxyBranch("a/b/c"), "nested ok")
  assertTrue(isValidProxyBranch("v1.2.3"), "dots ok")
  assertTrue(isValidProxyBranch("fix-42_x"), "hyphen underscore ok")
  assertTrue(not isValidProxyBranch(""), "empty rejected")
  assertTrue(not isValidProxyBranch("-flag"), "leading hyphen rejected")
  assertTrue(not isValidProxyBranch(".hidden"), "leading dot rejected")
  assertTrue(not isValidProxyBranch("a..b"), "double dot rejected")
  assertTrue(not isValidProxyBranch("a b"), "space rejected")
  assertTrue(not isValidProxyBranch("a\"b"), "quote rejected")
  assertTrue(not isValidProxyBranch("a\\b"), "backslash rejected")
  assertTrue(not isValidProxyBranch("a#b"), "hash rejected")
  assertTrue(not isValidProxyBranch("a?b"), "question mark rejected")
  assertTrue(not isValidProxyBranch("a%b"), "percent rejected")
  assertTrue(not isValidProxyBranch("a:b"), "colon rejected")
  assertTrue(not isValidProxyBranch("a~b"), "tilde rejected")
  assertTrue(not isValidProxyBranch("a^b"), "caret rejected")
  var oversized = ""
  var i = 0
  while i < 256 {
    oversized = oversized + "b"
    i = i + 1
  }
  assertTrue(not isValidProxyBranch(oversized), "256 chars rejected")
  assertTrue(isValidProxyBranch(oversized.substring(0, 255)), "255 chars ok")
}

test "isKnownProxyHarness knows exactly the five harnesses" {
  assertTrue(isKnownProxyHarness("claude"), "claude ok")
  assertTrue(isKnownProxyHarness("codex"), "codex ok")
  assertTrue(isKnownProxyHarness("opencode"), "opencode ok")
  assertTrue(isKnownProxyHarness("gemini"), "gemini ok")
  assertTrue(isKnownProxyHarness("antigravity"), "antigravity ok")
  assertTrue(not isKnownProxyHarness(""), "empty rejected")
  assertTrue(not isKnownProxyHarness("vim"), "unknown rejected")
  assertTrue(not isKnownProxyHarness("Claude"), "case-sensitive")
}

// ── Harness availability (#523) ────────────────────────────────────────────
//
// Env.SetEnvironmentVariable("CLOUD_AGENTS_ENABLED_HARNESSES", "") unsets it
// (.NET treats an empty value as removal) — used to reset the process-global
// var back to its default "unset" state so these tests can't leak into
// whichever test runs next.

test "isHarnessEnabled reports every harness enabled when unset (fail open)" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ENABLED_HARNESSES", "")
  assertTrue(isHarnessEnabled("claude"), "claude enabled by default")
  assertTrue(isHarnessEnabled("codex"), "codex enabled by default")
  assertTrue(isHarnessEnabled("opencode"), "opencode enabled by default")
  assertTrue(isHarnessEnabled("gemini"), "gemini enabled by default")
  assertTrue(isHarnessEnabled("antigravity"), "antigravity enabled by default")
}

test "isHarnessEnabled restricts to the configured comma-separated list" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ENABLED_HARNESSES", "claude, codex")
  assertTrue(isHarnessEnabled("claude"), "claude listed")
  assertTrue(isHarnessEnabled("codex"), "codex listed (surrounding whitespace trimmed)")
  assertTrue(not isHarnessEnabled("opencode"), "opencode not listed")
  assertTrue(not isHarnessEnabled("gemini"), "gemini not listed")
  assertTrue(not isHarnessEnabled("antigravity"), "antigravity not listed")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ENABLED_HARNESSES", "")
}

test "harnessesHandler reports the JSON enabled list, restricted or not" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ENABLED_HARNESSES", "")
  val allEnabled = harnessesHandler()
  assertTrue(allEnabled.contains("\"claude\""), "claude present when unset")
  assertTrue(allEnabled.contains("\"codex\""), "codex present when unset")
  assertTrue(allEnabled.contains("\"opencode\""), "opencode present when unset")
  assertTrue(allEnabled.contains("\"gemini\""), "gemini present when unset")
  assertTrue(allEnabled.contains("\"antigravity\""), "antigravity present when unset")

  Env.SetEnvironmentVariable("CLOUD_AGENTS_ENABLED_HARNESSES", "claude,gemini")
  val restricted = harnessesHandler()
  assertTrue(restricted.contains("\"claude\""), "claude present")
  assertTrue(restricted.contains("\"gemini\""), "gemini present")
  assertTrue(not restricted.contains("\"codex\""), "codex absent")
  assertTrue(not restricted.contains("\"opencode\""), "opencode absent")
  assertTrue(not restricted.contains("\"antigravity\""), "antigravity absent")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ENABLED_HARNESSES", "")
}

// ── Handler validation (no DB, no network) ────────────────────────────────────

test "proxy handlers reject invalid inputs with 400 before any lookup" {
  match githubReposHandler("0") {
    case Ok(_) -> assertTrue(false, "page 0 must fail")
    case Err(e) -> assertEqualInt(e.status, 400, "page 0 -> 400")
  }
  match githubReposHandler("abc") {
    case Ok(_) -> assertTrue(false, "non-numeric page must fail")
    case Err(e) -> assertEqualInt(e.status, 400, "non-numeric page -> 400")
  }
  match githubRepoHandler("-bad", "repo") {
    case Ok(_) -> assertTrue(false, "bad owner must fail")
    case Err(e) -> assertEqualInt(e.status, 400, "bad owner -> 400")
  }
  match githubRepoHandler("owner", "re po") {
    case Ok(_) -> assertTrue(false, "bad repo must fail")
    case Err(e) -> assertEqualInt(e.status, 400, "bad repo -> 400")
  }
  match githubPullsHandler("owner", "repo", "a..b") {
    case Ok(_) -> assertTrue(false, "bad branch must fail")
    case Err(e) -> assertEqualInt(e.status, 400, "bad branch -> 400")
  }
  match githubChecksHandler("owner", "repo", "a#b") {
    case Ok(_) -> assertTrue(false, "unsafe ref must fail")
    case Err(e) -> assertEqualInt(e.status, 400, "unsafe ref -> 400")
  }
  match modelsHandler("vim") {
    case Ok(_) -> assertTrue(false, "unknown harness must fail")
    case Err(e) -> assertEqualInt(e.status, 400, "unknown harness -> 400")
  }
}

// ── No-credential paths (live Postgres, fresh user with an empty vault, no network) ───────────────

test "GitHub proxy answers 404 when the vault has no GITHUB_TOKEN" {
  if not live() {
    return
  }
  val me = freshUser("proxy-no-github-token")
  match githubReposHandler("1") {
    case Ok(_) -> assertTrue(false, "empty vault must not reach GitHub")
    case Err(e) -> assertEqualInt(e.status, 404, "no vault token -> 404")
  }
  match githubRepoHandler("owner", "repo") {
    case Ok(_) -> assertTrue(false, "empty vault must not reach GitHub")
    case Err(e) -> assertEqualInt(e.status, 404, "no vault token -> 404")
  }
  match githubPullsHandler("owner", "repo", "main") {
    case Ok(_) -> assertTrue(false, "empty vault must not reach GitHub")
    case Err(e) -> assertEqualInt(e.status, 404, "no vault token -> 404")
  }
  match githubChecksHandler("owner", "repo", "main") {
    case Ok(_) -> assertTrue(false, "empty vault must not reach GitHub")
    case Err(e) -> assertEqualInt(e.status, 404, "no vault token -> 404")
  }
}

test "models proxy answers 404 when the vault has no provider keys" {
  if not live() {
    return
  }
  val me = freshUser("proxy-no-model-keys")
  match modelsHandler("claude") {
    case Ok(_) -> assertTrue(false, "empty vault must not reach any provider")
    case Err(e) -> assertEqualInt(e.status, 404, "no provider keys -> 404")
  }
  // opencode maps to four providers; still 404 with an empty vault.
  match modelsHandler("opencode") {
    case Ok(_) -> assertTrue(false, "empty vault must not reach any provider")
    case Err(e) -> assertEqualInt(e.status, 404, "no provider keys -> 404")
  }
}

test "decryptedCredentialValue is Ok(None) on an empty vault without crypto" {
  if not live() {
    return
  }
  val me = freshUser("proxy-cred-lookup")
  // ENCRYPTION_KEY is not set in this suite: absence must be decided before
  // any decryption, so this returns Ok(None) rather than a crypto error.
  match CloudAgents.Repository.decryptedCredentialValue(CloudAgents.Scope.userScope(me), "GITHUB_TOKEN") {
    case Ok(None) -> ()
    case Ok(Some(_)) -> assertTrue(false, "empty vault must have no value")
    case Err(e) -> assertTrue(false, "lookup failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
}

test "providersForHarness returns correct provider mappings" {
  val claude = providersForHarness("claude")
  assertEqualInt(claude.length.toInt(), 1, "claude length")
  assertEqual(claude[0], "anthropic", "claude content")

  val gemini = providersForHarness("gemini")
  assertEqualInt(gemini.length.toInt(), 1, "gemini length")
  assertEqual(gemini[0], "google", "gemini content")

  val antigravity = providersForHarness("antigravity")
  assertEqualInt(antigravity.length.toInt(), 1, "antigravity length")
  assertEqual(antigravity[0], "google", "antigravity content")

  val opencode = providersForHarness("opencode")
  assertEqualInt(opencode.length.toInt(), 4, "opencode length")
  assertEqual(opencode[0], "anthropic", "opencode[0]")
  assertEqual(opencode[1], "openai", "opencode[1]")
  assertEqual(opencode[2], "google", "opencode[2]")
  assertEqual(opencode[3], "opencode", "opencode[3]")
}

test "keyForProvider returns None for absent keys when vault is empty" {
  if not live() {
    return
  }
  val me = freshUser("proxy-key-lookup-empty")
  match keyForProvider("opencode") {
    case Some(_) -> assertTrue(false, "empty vault must return None")
    case None -> ()
  }
  match keyForProvider("google") {
    case Some(_) -> assertTrue(false, "empty vault must return None for google")
    case None -> ()
  }
}

test "validateKeyHandler rejects unknown providers with 400" {
  match validateKeyHandler("vim", "key") {
    case Ok(_) -> assertTrue(false, "unknown provider must fail")
    case Err(e) -> assertEqualInt(e.status, 400, "unknown provider -> 400")
  }
}

