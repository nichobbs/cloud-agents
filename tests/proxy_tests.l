@test_module
package CloudAgents.ProxyTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Proxy
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/oauth_tests.l) ────────────────────
//
// NB: no network path is ever exercised here — the no-credential tests fail
// closed at the vault lookup (404) before any outbound request could happen,
// and everything else is a pure validator. ENCRYPTION_KEY is deliberately NOT
// set: decryptedCredentialValue answers Ok(None) for an absent row before any
// decryption, so an empty vault needs no crypto configuration.

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
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

test "isKnownProxyHarness knows exactly the four harnesses" {
  assertTrue(isKnownProxyHarness("claude"), "claude ok")
  assertTrue(isKnownProxyHarness("codex"), "codex ok")
  assertTrue(isKnownProxyHarness("opencode"), "opencode ok")
  assertTrue(isKnownProxyHarness("gemini"), "gemini ok")
  assertTrue(not isKnownProxyHarness(""), "empty rejected")
  assertTrue(not isKnownProxyHarness("vim"), "unknown rejected")
  assertTrue(not isKnownProxyHarness("Claude"), "case-sensitive")
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

// ── No-credential paths (live temp DB, empty vault, no network) ───────────────

test "GitHub proxy answers 404 when the vault has no GITHUB_TOKEN" {
  val dbPath = useFreshTestDb("proxy-no-github-token")
  defer {
    cleanupTestDb(dbPath)
  }
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
  val dbPath = useFreshTestDb("proxy-no-model-keys")
  defer {
    cleanupTestDb(dbPath)
  }
  match modelsHandler("claude") {
    case Ok(_) -> assertTrue(false, "empty vault must not reach any provider")
    case Err(e) -> assertEqualInt(e.status, 404, "no provider keys -> 404")
  }
  // opencode maps to all three providers; still 404 with an empty vault.
  match modelsHandler("opencode") {
    case Ok(_) -> assertTrue(false, "empty vault must not reach any provider")
    case Err(e) -> assertEqualInt(e.status, 404, "no provider keys -> 404")
  }
}

test "decryptedCredentialValue is Ok(None) on an empty vault without crypto" {
  val dbPath = useFreshTestDb("proxy-cred-lookup")
  defer {
    cleanupTestDb(dbPath)
  }
  // ENCRYPTION_KEY is not set in this suite: absence must be decided before
  // any decryption, so this returns Ok(None) rather than a crypto error.
  match CloudAgents.Repository.decryptedCredentialValue("default", "GITHUB_TOKEN") {
    case Ok(None) -> ()
    case Ok(Some(_)) -> assertTrue(false, "empty vault must have no value")
    case Err(e) -> assertTrue(false, "lookup failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
}
