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

test "refresh form body carries the grant_type and refresh token" {
  val body = refreshFormBody("cid123", "secret456", "rtok789")
  assertEqual(
    body,
    "client_id=cid123&client_secret=secret456&grant_type=refresh_token&refresh_token=rtok789",
    "form body shape"
  )
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

test "expiring-token exchange fields parse as unquoted JSON numbers, not strings (#665)" {
  // GitHub's real shape for an OAuth App enrolled in expiring user access
  // tokens: expires_in and refresh_token_expires_in are bare JSON numbers,
  // per GitHub's docs and RFC 6749 §5.1 — NOT quoted like access_token and
  // refresh_token. parseJsonString scanning for a closing quote on these
  // fields would walk past the number straight into the next field's key
  // quote and return garbage; parseJsonNumber is the correct extractor (the
  // same helper already used for GitHub's numeric user id).
  val body = "{\"access_token\":\"ghu_16C7e42F292c6912E7710c838347Ae178B4a\",\"expires_in\":28800,\"refresh_token\":\"ghr_1B4a2e77838347a7E420ce178F2E7c6912E169246c34E1ccbF66C46812d16D5B1a9Dc86A1498f4D69c47670475C5\",\"refresh_token_expires_in\":15811200,\"scope\":\"\",\"token_type\":\"bearer\"}"
  assertEqual(
    accessTokenFromExchangeJson(body),
    "ghu_16C7e42F292c6912E7710c838347Ae178B4a",
    "access token still extracts"
  )
  assertEqual(
    CloudAgents.Auth.parseJsonString(body, "refresh_token"),
    "ghr_1B4a2e77838347a7E420ce178F2E7c6912E169246c34E1ccbF66C46812d16D5B1a9Dc86A1498f4D69c47670475C5",
    "refresh token is quoted, parseJsonString is correct for it"
  )
  assertEqual(CloudAgents.Auth.parseJsonNumber(body, "expires_in"), "28800", "expires_in parses as a bare number")
  assertEqual(
    CloudAgents.Auth.parseJsonNumber(body, "refresh_token_expires_in"),
    "15811200",
    "refresh_token_expires_in parses as a bare number"
  )
}

// ── Configuration ─────────────────────────────────────────────────────────────
test "configOrEnv prefers a config-block value over the legacy env var, falling back when empty" {
  clearOAuthEnv()
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_ID", "env-value")
  assertEqual(
    configOrEnv("config-value", "CLOUD_AGENTS_GITHUB_CLIENT_ID"),
    "config-value",
    "a set config-block value wins over the env var"
  )
  assertEqual(
    configOrEnv("", "CLOUD_AGENTS_GITHUB_CLIENT_ID"),
    "env-value",
    "an unset (empty) config-block value falls back to the env var"
  )
  assertEqual(configOrEnv("", "CLOUD_AGENTS_GITHUB_CLIENT_ID_NONEXISTENT"), "", "both unset -> empty")
  clearOAuthEnv()
}

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

test "cache hits re-apply the whitelist so removals take effect immediately (#424)" {
  val dbPath = useFreshTestDb("oauth-cache-whitelist")
  defer {
    cleanupTestDb(dbPath)
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_ID", "cid")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_SECRET", "sec")
  val token = "gho_whitelisted"
  match CloudAgents.Repository.cacheGitHubToken(CloudAgents.Crypto.sha256Base64(token), "gh-42", "octocat") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "cache write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // Whitelist allows 42 -> cached identity resolves.
  Env.SetEnvironmentVariable("CLOUD_AGENTS_WHITELIST", "42")
  match authenticateRequest("/api/sessions", "Bearer " + token, "") {
    case Allowed(uid) -> assertEqual(uid, "gh-42", "whitelisted cache hit allowed")
    case Denied(_) -> assertTrue(false, "whitelisted cache hit must be allowed")
  }
  // Operator removes the user: the very next request is refused, cache TTL
  // notwithstanding.
  Env.SetEnvironmentVariable("CLOUD_AGENTS_WHITELIST", "999")
  match authenticateRequest("/api/sessions", "Bearer " + token, "") {
    case Allowed(_) -> assertTrue(false, "de-whitelisted user must be refused despite the cache")
    case Denied(_) -> ()
  }
  // ...and additions are just as immediate (#429): the identity row is
  // cached positively even while unlisted, so re-adding the user lets their
  // next request straight in — no negative entry to wait out.
  Env.SetEnvironmentVariable("CLOUD_AGENTS_WHITELIST", "999,42")
  match authenticateRequest("/api/sessions", "Bearer " + token, "") {
    case Allowed(uid) -> assertEqual(uid, "gh-42", "re-whitelisted user allowed immediately")
    case Denied(_) -> assertTrue(false, "whitelist addition must take effect on the next request")
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_WHITELIST", "")
  clearOAuthEnv()
}

test "negative cache entries refuse a bad bearer without a round trip (#425)" {
  val dbPath = useFreshTestDb("oauth-cache-negative")
  defer {
    cleanupTestDb(dbPath)
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_ID", "cid")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_SECRET", "sec")
  val token = "gho_knownbad"
  match CloudAgents.Repository.cacheGitHubTokenDenied(CloudAgents.Crypto.sha256Base64(token)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "negative cache write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // If this ever tried a live validation it would need the network — a
  // denial here proves the negative entry short-circuits.
  match authenticateRequest("/api/sessions", "Bearer " + token, "") {
    case Allowed(_) -> assertTrue(false, "negatively cached bearer must be refused")
    case Denied(_) -> ()
  }
  clearOAuthEnv()
}

test "a validated OAuth bearer satisfies secret routes without a static token (#428)" {
  val dbPath = useFreshTestDb("oauth-secret-route")
  defer {
    cleanupTestDb(dbPath)
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_ID", "cid")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_SECRET", "sec")
  val token = "gho_secretroute"
  match CloudAgents.Repository.cacheGitHubToken(CloudAgents.Crypto.sha256Base64(token), "gh-42", "octocat") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "cache write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // A validated GitHub identity is real authentication — credential routes
  // accept it even with no CLOUD_AGENTS_API_TOKEN configured.
  match authenticateRequest("/api/credentials", "Bearer " + token, "") {
    case Allowed(uid) -> assertEqual(uid, "gh-42", "OAuth identity allowed on secret route")
    case Denied(_) -> assertTrue(false, "validated OAuth bearer must satisfy secret routes")
  }
  // But an absent bearer on a secret route still refuses (unchanged).
  match authenticateRequest("/api/credentials", "", "") {
    case Allowed(_) -> assertTrue(false, "secret route must refuse without any credential")
    case Denied(_) -> ()
  }
  clearOAuthEnv()
}

test "the flood backstop stops validating unrecognised bearers (#425)" {
  val dbPath = useFreshTestDb("oauth-flood")
  defer {
    cleanupTestDb(dbPath)
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_ID", "cid")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_SECRET", "sec")
  // Simulate a flood: 30 distinct bad bearers negatively cached in-window.
  var i = 0
  while i < 30 {
    match CloudAgents.Repository.cacheGitHubTokenDenied(CloudAgents.Crypto.sha256Base64("gho_flood" + toString(i))) {
      case Ok(_) -> ()
      case Err(e) -> assertTrue(false, "negative cache write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
    }
    i = i + 1
  }
  match CloudAgents.Repository.activeNegativeGitHubTokens() {
    case Ok(n) -> assertEqualInt(n, 30, "all negative entries counted")
    case Err(e) -> assertTrue(false, "counter failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // A fresh, never-seen bearer is refused WITHOUT a network round trip (if
  // the backstop didn't fire, this test would need the network to proceed).
  match authenticateRequest("/api/sessions", "Bearer gho_fresh_during_flood", "") {
    case Allowed(_) -> assertTrue(false, "backstop must refuse during a flood")
    case Denied(_) -> ()
  }
  // Positively cached users are unaffected by the backstop.
  val good = "gho_stillgood"
  match CloudAgents.Repository.cacheGitHubToken(CloudAgents.Crypto.sha256Base64(good), "gh-42", "octocat") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "cache write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match authenticateRequest("/api/sessions", "Bearer " + good, "") {
    case Allowed(uid) -> assertEqual(uid, "gh-42", "validated users ride out the flood")
    case Denied(_) -> assertTrue(false, "positively cached user must not be blocked by the backstop")
  }
  clearOAuthEnv()
}

test "the exchange endpoint has its own flood backstop, independent of bearers (#434)" {
  val dbPath = useFreshTestDb("oauth-code-flood")
  defer {
    cleanupTestDb(dbPath)
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_ID", "cid")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_SECRET", "sec")

  // A code GitHub already rejected is refused while its negative row lives —
  // no second outbound exchange for the same code.
  match CloudAgents.Repository.cacheOAuthCodeRejected(CloudAgents.Crypto.sha256Base64("oauth-code:replayedcode")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "code-rejection write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match exchangeCode(ExchangeRequest(code = "replayedcode")) {
    case Ok(_) -> assertTrue(false, "recently rejected code must be refused")
    case Err(e) -> assertEqualInt(e.status, 400, "replayed code -> 400 without a round trip")
  }

  // 30 distinct rejected codes trip the exchange backstop for fresh codes...
  var i = 0
  while i < 30 {
    match CloudAgents.Repository.cacheOAuthCodeRejected(CloudAgents.Crypto.sha256Base64("oauth-code:bad" + toString(i))) {
      case Ok(_) -> ()
      case Err(e) -> assertTrue(false, "code-rejection write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
    }
    i = i + 1
  }
  match exchangeCode(ExchangeRequest(code = "freshcodeduringflood")) {
    case Ok(_) -> assertTrue(false, "exchange backstop must refuse during a code flood")
    case Err(e) -> assertEqualInt(e.status, 400, "code flood -> 400 without a round trip")
  }

  // ...but rejected codes never count toward the BEARER backstop (#433's
  // blast-radius argument stays intact).
  match CloudAgents.Repository.activeNegativeGitHubTokens() {
    case Ok(n) -> assertEqualInt(n, 0, "code rejections don't pollute the bearer counter")
    case Err(e) -> assertTrue(false, "counter failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  clearOAuthEnv()
}

test "only confirmed auth rejections are classified for negative caching (#435)" {
  assertTrue(
    isConfirmedAuthRejection(
      "GET https://api.github.com/user failed: The remote server returned an error: (401) Unauthorized."
    ),
    "401 is a confirmed rejection"
  )
  assertTrue(
    isConfirmedAuthRejection(
      "GET https://api.github.com/user failed: The remote server returned an error: (403) Forbidden."
    ),
    "403 is a confirmed rejection"
  )
  assertTrue(
    not isConfirmedAuthRejection("GET https://api.github.com/user failed: The remote name could not be resolved: 'api.github.com'"),
    "DNS failure is not a rejection"
  )
  assertTrue(
    not isConfirmedAuthRejection("GET https://api.github.com/user failed: The operation has timed out."),
    "timeout is not a rejection"
  )
}

// NB: exchangeCode's SUCCESS path (which, besides priming the cache, vaults
// the token as the tenant's GITHUB_TOKEN credential) needs a live GitHub
// round trip, so it cannot be exercised here — CI covers it via compilation
// only.
test "logout invalidates the token-validation cache row" {
  val dbPath = useFreshTestDb("oauth-logout")
  defer {
    cleanupTestDb(dbPath)
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_ID", "cid")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_GITHUB_CLIENT_SECRET", "sec")

  // Prime the cache exactly as a successful exchange would...
  val token = "gho_loggingout"
  val hash = CloudAgents.Crypto.sha256Base64(token)
  match CloudAgents.Repository.cacheGitHubToken(hash, "gh-42", "octocat") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "cache write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // ...confirm the bearer authenticates via the cache...
  match authenticateRequest("/api/sessions", "Bearer " + token, "") {
    case Allowed(uid) -> assertEqual(uid, "gh-42", "cached token authenticates before logout")
    case Denied(_) -> assertTrue(false, "cached token must authenticate before logout")
  }
  // ...log out, and the row is gone (the next presentation would revalidate
  // live — which this test must not do, so only assert the cache side).
  match logout("Bearer " + token) {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "logout with a cached bearer must succeed")
  }
  match CloudAgents.Repository.cachedGitHubToken(hash) {
    case Ok(Some(_)) -> assertTrue(false, "cache row must be gone after logout")
    case Ok(None) -> ()
    case Err(e) -> assertTrue(false, "cache read failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Idempotent: no header, or one that is not a well-formed bearer, means
  // nothing to invalidate — still Ok.
  match logout("") {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "logout with no header must be Ok")
  }
  match logout("garbage-not-a-bearer") {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "logout with a garbage header must be Ok")
  }
  clearOAuthEnv()
}

// ── GitHub OAuth token refresh ────────────────────────────────────────────────
test "github oauth refresh metadata round-trips through repository CRUD" {
  val dbPath = useFreshTestDb("oauth-refresh-crud")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "gh-500"

  // No metadata yet -> None (the common non-expiring-token case).
  match CloudAgents.Repository.githubOAuthRefreshStatus(userId) {
    case Ok(None) -> ()
    case Ok(Some(_)) -> assertTrue(false, "no row expected before any upsert")
    case Err(e) -> assertTrue(false, "status read failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }

  // Both tokens fresh.
  match CloudAgents.Repository.upsertGitHubOAuthRefresh(userId, "refresh-abc", "3600", "604800") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "upsert failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
  match CloudAgents.Repository.githubOAuthRefreshStatus(userId) {
    case Ok(Some(status)) -> {
      assertEqual(status.refreshToken, "refresh-abc", "refresh token decrypts back unchanged")
      assertTrue(not status.accessTokenExpired, "access token still fresh")
      assertTrue(not status.refreshTokenExpired, "refresh token still fresh")
    }
    case Ok(None) -> assertTrue(false, "row must exist after upsert")
    case Err(e) -> assertTrue(false, "status read failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }

  // Re-upsert (GitHub rotates the refresh token on every use): access token
  // now expired, refresh token still good — and the old value is replaced,
  // not duplicated.
  match CloudAgents.Repository.upsertGitHubOAuthRefresh(userId, "refresh-def", "-100", "604800") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "re-upsert failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
  match CloudAgents.Repository.githubOAuthRefreshStatus(userId) {
    case Ok(Some(status)) -> {
      assertEqual(status.refreshToken, "refresh-def", "upsert replaces the prior row")
      assertTrue(status.accessTokenExpired, "access token now expired")
      assertTrue(not status.refreshTokenExpired, "refresh token still fresh")
    }
    case Ok(None) -> assertTrue(false, "row must still exist")
    case Err(e) -> assertTrue(false, "status read failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }

  // Both expired — the unrecoverable case.
  match CloudAgents.Repository.upsertGitHubOAuthRefresh(userId, "refresh-ghi", "-100", "-100") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "re-upsert failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
  match CloudAgents.Repository.githubOAuthRefreshStatus(userId) {
    case Ok(Some(status)) -> {
      assertTrue(status.accessTokenExpired, "access token expired")
      assertTrue(status.refreshTokenExpired, "refresh token also expired")
    }
    case Ok(None) -> assertTrue(false, "row must still exist")
    case Err(e) -> assertTrue(false, "status read failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }

  // Delete drops the row entirely.
  match CloudAgents.Repository.deleteGitHubOAuthRefresh(userId) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "delete failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.githubOAuthRefreshStatus(userId) {
    case Ok(None) -> ()
    case Ok(Some(_)) -> assertTrue(false, "row must be gone after delete")
    case Err(e) -> assertTrue(false, "status read failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
}

test "ensureFreshGitHubToken falls back to a direct vault read with no refresh metadata" {
  val dbPath = useFreshTestDb("oauth-ensure-no-metadata")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "gh-501"

  // No vault entry and no metadata -> the same 404 a direct vault read gives.
  match ensureFreshGitHubToken(userId) {
    case Ok(_) -> assertTrue(false, "no token anywhere must fail")
    case Err(e) -> assertEqualInt(e.status, 404, "absent -> 404")
  }

  // Vaulted directly, as a non-expiring-token OAuth App's sign-in would leave
  // it (the common case) -> returned unchanged, no refresh attempted.
  match CloudAgents.Repository.putCredential(userId, "GITHUB_TOKEN", "gho_plain") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "putCredential failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
  match ensureFreshGitHubToken(userId) {
    case Ok(t) -> assertEqual(t, "gho_plain", "no metadata row -> vaulted token returned unchanged")
    case Err(_) -> assertTrue(false, "vaulted token must be returned")
  }
}

test "ensureFreshGitHubToken returns the vaulted token unchanged while still fresh" {
  val dbPath = useFreshTestDb("oauth-ensure-fresh")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "gh-502"
  match CloudAgents.Repository.upsertGitHubOAuthRefresh(userId, "refresh-xyz", "3600", "604800") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "upsert failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
  match CloudAgents.Repository.putCredential(userId, "GITHUB_TOKEN", "gho_stillfresh") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "putCredential failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
  // accessTokenExpired is false, so this must never attempt a network refresh.
  match ensureFreshGitHubToken(userId) {
    case Ok(t) -> assertEqual(t, "gho_stillfresh", "fresh access token returned without refreshing")
    case Err(_) -> assertTrue(false, "a still-fresh token must be returned")
  }
}

test "ensureFreshGitHubToken gives a clear reconnect message once the refresh token itself is dead" {
  val dbPath = useFreshTestDb("oauth-ensure-dead-refresh")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "gh-503"
  match CloudAgents.Repository.upsertGitHubOAuthRefresh(userId, "refresh-dead", "-100", "-100") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "upsert failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
  match CloudAgents.Repository.putCredential(userId, "GITHUB_TOKEN", "gho_stale") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "putCredential failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
  // Both expired -> refuse outright (no point attempting a doomed refresh),
  // with a message that tells the tenant exactly what to do.
  match ensureFreshGitHubToken(userId) {
    case Ok(_) -> assertTrue(false, "a dead refresh token must fail")
    case Err(e) -> {
      assertEqualInt(e.status, 401, "dead refresh token -> 401")
      assertEqual(e.message, reconnectGitHubMessage(), "actionable reconnect message, not a generic failure")
    }
  }
}

// NB: the branch where the access token IS expired but the refresh token is
// still valid (ensureFreshGitHubToken -> doRefresh) needs a live GitHub round
// trip, so — like exchangeCode's success path above — it cannot be exercised
// here; CI covers it via compilation only.
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
