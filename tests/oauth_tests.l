@test_module
package CloudAgents.OAuthTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Crypto
import CloudAgents.OAuth
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/session_tests.l) ─────────────────

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

// Setting an env var to "" removes it on .NET, so tests can restore the
// unconfigured state they started from.
func clearOAuthEnv(): Unit {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_ID", "")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_SECRET", "")
}

// ── Pure builders and parsers ─────────────────────────────────────────────────

test "exchange form body carries all three OAuth params" {
  val body = exchangeFormBody("cid123", "secret456", "code789")
  assertEqual(body, "client_id=cid123&client_secret=secret456&code=code789", "form body shape")
}

test "isSafeOAuthCode accepts GitHub-shaped codes and rejects smuggling" {
  assertTrue(isSafeOAuthCode("a1b2c3d4e5"), "hex code ok")
  assertTrue(isSafeOAuthCode("code_with-both"), "underscore and hyphen ok")
  assertTrue(not isSafeOAuthCode(""), "empty rejected")
  assertTrue(not isSafeOAuthCode("a&client_id=evil"), "ampersand rejected")
  assertTrue(not isSafeOAuthCode("a=b"), "equals rejected")
  assertTrue(not isSafeOAuthCode("a b"), "space rejected")
}

test "access token and error parse from GitHub's exchange response" {
  val ok = "{\"access_token\":\"gho_abc123\",\"scope\":\"repo\",\"token_type\":\"bearer\"}"
  assertEqual(accessTokenFromExchangeJson(ok), "gho_abc123", "token extracted")

  val err = "{\"error\":\"bad_verification_code\",\"error_description\":\"The code passed is incorrect or expired.\"}"
  assertEqual(accessTokenFromExchangeJson(err), "", "no token in an error payload")
  assertEqual(exchangeErrorFromJson(err), "The code passed is incorrect or expired.", "description preferred")

  val bare = "{\"error\":\"bad_verification_code\"}"
  assertEqual(exchangeErrorFromJson(bare), "bad_verification_code", "falls back to the error code")
}

// ── Configuration ─────────────────────────────────────────────────────────────

test "oauthConfigured requires both halves of the app registration" {
  clearOAuthEnv()
  assertTrue(not oauthConfigured(), "unset -> unconfigured")
  assertTrue(configJson().contains("\"configured\":\"false\""), "config json says false")

  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_ID", "cid-only")
  assertTrue(not oauthConfigured(), "id without secret -> unconfigured")

  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_SECRET", "sec")
  assertTrue(oauthConfigured(), "both set -> configured")
  val json = configJson()
  assertTrue(json.contains("\"configured\":\"true\""), "config json says true")
  assertTrue(json.contains("\"clientId\":\"cid-only\""), "config json carries the public client id")
  clearOAuthEnv()
}

test "exchangeCode refuses when unconfigured and validates the code first" {
  clearOAuthEnv()
  match exchangeCode(ExchangeRequest(code = "abc123")) {
    case Ok(_) -> assertTrue(false, "unconfigured exchange must fail")
    case Err(e) -> assertEqualInt(e.status, 400, "unconfigured -> 400")
  }

  // Configured but a malformed code: rejected before any network call.
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_ID", "cid")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_SECRET", "sec")
  match exchangeCode(ExchangeRequest(code = "bad&code")) {
    case Ok(_) -> assertTrue(false, "malformed code must fail")
    case Err(e) -> assertEqualInt(e.status, 400, "malformed code -> 400")
  }
  clearOAuthEnv()
}

// ── Request authentication (no-network paths) ─────────────────────────────────

test "authenticateRequest keeps static-token semantics" {
  clearOAuthEnv()

  // Static token matches -> the operator identity.
  match authenticateRequest("/api/sessions", "Bearer s3cret", "s3cret") {
    case Allowed(uid) -> assertEqual(uid, operatorUserId(), "static match -> operator")
    case Denied(_) -> assertTrue(false, "static match must be allowed")
  }

  // No bearer, nothing configured -> open access (unchanged behaviour).
  match authenticateRequest("/api/sessions", "", "") {
    case Allowed(uid) -> assertEqual(uid, operatorUserId(), "open when unconfigured")
    case Denied(_) -> assertTrue(false, "unconfigured non-secret route stays open")
  }

  // Secret route with no auth configured still refuses.
  match authenticateRequest("/api/credentials", "", "") {
    case Allowed(_) -> assertTrue(false, "secret route must refuse unauthenticated")
    case Denied(_) -> ()
  }

  // Wrong bearer with a static token and no OAuth -> denied.
  match authenticateRequest("/api/sessions", "Bearer wrong", "s3cret") {
    case Allowed(_) -> assertTrue(false, "wrong static token must be denied")
    case Denied(_) -> ()
  }
}

test "open-access decision never inherits a stale thread identity (#420)" {
  clearOAuthEnv()
  // Simulate a pooled thread that just served an OAuth user: the per-thread
  // stamp is still set when the next (unauthenticated) request's decision
  // runs. The decision must resolve the operator identity, not the stale one.
  setCurrentUserId("gh-99999")
  match authenticateRequest("/api/sessions", "", "") {
    case Allowed(uid) -> assertEqual(uid, operatorUserId(), "open access resolves the operator, never the stale stamp")
    case Denied(_) -> assertTrue(false, "open access should be allowed")
  }
  match authenticateRequest("/api/sessions", "Bearer s3cret", "s3cret") {
    case Allowed(uid) -> assertEqual(uid, operatorUserId(), "static match resolves the operator, never the stale stamp")
    case Denied(_) -> assertTrue(false, "static match should be allowed")
  }
  setCurrentUserId("")
}

// ── Token-validation cache (live DB, no network) ─────────────────────────────

test "cached bearer authenticates without a network round trip" {
  val dbPath = useFreshTestDb("oauth-cache")
  defer {
    cleanupTestDb(dbPath)
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_ID", "cid")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_SECRET", "sec")

  // Prime the cache exactly as a successful exchange would.
  val token = "gho_cachedtoken"
  val hash = CloudAgents.Crypto.sha256Base64(token)
  match CloudAgents.Repository.cacheGitHubToken(hash, "gh-42", "octocat") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "cache write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // The middleware path resolves it from the cache alone.
  match authenticateRequest("/api/sessions", "Bearer " + token, "") {
    case Allowed(uid) -> assertEqual(uid, "gh-42", "cached token -> cached identity")
    case Denied(_) -> assertTrue(false, "cached token must authenticate")
  }

  // Cache reads are keyed by hash: a different token misses (and would go to
  // the network, which this test must not do — so only assert the lookup side).
  match CloudAgents.Repository.cachedGitHubToken(CloudAgents.Crypto.sha256Base64("gho_other")) {
    case Ok(Some(_)) -> assertTrue(false, "different token must miss the cache")
    case Ok(None) -> ()
    case Err(e) -> assertTrue(false, "cache read failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  clearOAuthEnv()
}

test "expired cache entries never match" {
  val dbPath = useFreshTestDb("oauth-cache-expiry")
  defer {
    cleanupTestDb(dbPath)
  }
  val hash = CloudAgents.Crypto.sha256Base64("gho_expired")
  match CloudAgents.Repository.cacheGitHubToken(hash, "gh-7", "old") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "cache write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // Force the entry into the past.
  match CloudAgents.Sqlite.execute("UPDATE github_token_cache SET expires_at = '0' WHERE token_hash = '" + hash + "'") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setup update failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.cachedGitHubToken(hash) {
    case Ok(Some(_)) -> assertTrue(false, "expired entry must not match")
    case Ok(None) -> ()
    case Err(e) -> assertTrue(false, "cache read failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}
