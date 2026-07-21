//! GitHub OAuth (ADR-005, docs/phase3-multi-tenancy.md): the web-application
//! flow's server side, plus per-request bearer-token authentication.
//!
//! Flow: the frontend sends the user to github.com/login/oauth/authorize
//! (client id from GET /api/auth/github/config), GitHub redirects back with a
//! one-time code, and POST /api/auth/github/exchange swaps it — using the
//! client secret, which never leaves this server — for the user's OAuth
//! token. The frontend then presents that token as its Authorization bearer
//! on every API call; authenticateRequest() below validates it against
//! api.github.com/user (cached in SQLite, hashed), applies the
//! CLOUD_AGENTS_WHITELIST, and resolves the per-tenant user id (gh-<id>)
//! that scopes every query.
//!
//! The static CLOUD_AGENTS_API_TOKEN scheme keeps working unchanged as the
//! single-operator fallback; a bearer that matches it authenticates as the
//! operator identity exactly as before.
//!
//! Pure pieces (URL/body builders, response parsing, decision logic) are
//! separated from the two network calls so they stay unit-testable; the
//! network itself lives in CloudAgents.GitHubApi (sync, also import-safe for
//! tests, though tests never invoke the calls).
package CloudAgents.OAuth

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Crypto
import CloudAgents.GitHubApi
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env
import extern System.String as DotNetString

@generate(Json)
pub record ExchangeRequest {
  pub code: String
}

/// What a successful exchange returns to the frontend: the GitHub OAuth token
/// (the client's bearer credential from here on), the login for display, and
/// the resolved per-tenant user id.
@generate(Json)
pub record TokenGrant {
  pub token: String
  pub login: String
  pub userId: String
}

/// User-Agent for calls to GitHub — api.github.com rejects requests without one.
pub func userAgent(): String {
  return "cloud-agents"
}

/// Distinct failed validations tolerated per negative-cache window (1 min)
/// before the flood backstop stops validating unrecognised bearers (#425).
val maxRecentValidationFailures = 30

func envOr(name: in String): String {
  var v = Env.GetEnvironmentVariable(name)
  if DotNetString.IsNullOrEmpty(v) {
    return ""
  }
  return v
}

config Github {
  clientId: String = ""
  @sensitive clientSecret: String = ""
  whitelist: String = ""
}

pub func oauthClientId(): String {
  return Github.clientId
}

func oauthClientSecret(): String {
  return Github.clientSecret
}

func whitelistCsv(): String {
  return Github.whitelist
}

/// OAuth is usable only when both halves of the app registration are set.
pub func oauthConfigured(): Bool {
  return oauthClientId().length > 0 and oauthClientSecret().length > 0
}

/// `{"configured":"true|false","clientId":"..."}` for the login button. The
/// client id is public by design (it appears in the authorize URL); the
/// secret never leaves this process. Hand-built JSON, same as listSessions.
pub func configJson(): String {
  val configured = if oauthConfigured() { "true" } else { "false" }
  return "{\"configured\":\"" + configured + "\",\"clientId\":\"" +
    CloudAgents.SessionStore.jsonEscapeField(oauthClientId()) +
    "\"}"
}

// ─── Exchange: one-time code → OAuth token ───────────────────────────────────

pub func exchangeUrl(): String {
  return "https://github.com/login/oauth/access_token"
}

pub func githubUserUrl(): String {
  return "https://api.github.com/user"
}

/// Form body for the code exchange. Values are not URL-encoded: GitHub codes,
/// client ids, and app secrets are URL-safe by construction, and
/// isSafeOAuthCode rejects anything that could smuggle a delimiter.
pub func exchangeFormBody(clientId: in String, clientSecret: in String, code: in String): String {
  return "client_id=" + clientId + "&client_secret=" + clientSecret + "&code=" + code
}

/// A GitHub one-time authorization code: short, URL-safe charset. Rejecting
/// anything else keeps the form body unambiguous.
pub func isSafeOAuthCode(code: in String): Bool {
  if code.length == 0 or code.length > 128 {
    return false
  }
  var i = 0
  while i < code.length {
    val c = code.substring(i, 1)
    val isUpper = c >= "A" and c <= "Z"
    val isLower = c >= "a" and c <= "z"
    val isDigit = c >= "0" and c <= "9"
    if not (isUpper or isLower or isDigit or c == "_" or c == "-") {
      return false
    }
    i = i + 1
  }
  return true
}

/// The access_token from an exchange response ("" when GitHub returned an
/// error payload instead — expired code, mismatched secret, replay).
pub func accessTokenFromExchangeJson(json: in String): String {
  return CloudAgents.Auth.parseJsonString(json, "access_token")
}

/// GitHub's error detail from a failed exchange, best field first.
pub func exchangeErrorFromJson(json: in String): String {
  val detail = CloudAgents.Auth.parseJsonString(json, "error_description")
  if detail.length > 0 {
    return detail
  }
  return CloudAgents.Auth.parseJsonString(json, "error")
}

/// A validated GitHub identity: the raw numeric id (digit string) and login.
pub record GitHubIdentity {
  pub githubId: String
  pub login: String
}

/// Whether a github_api.l error string reflects GitHub actually refusing the
/// credential (HTTP 401/403 in the WebException text) rather than a
/// transport failure. Textual matching is inherently approximate, but the
/// runner images and deploy containers run under the invariant culture, so
/// .NET's "(401) Unauthorized"-style message text is stable there; a missed
/// match merely skips the negative-cache write (fail-safe) (#435).
pub func isConfirmedAuthRejection(errorText: in String): Bool {
  return errorText.contains("(401)") or errorText.contains("(403)")
}

/// Whether the tenant already has a GITHUB_TOKEN in the credential vault
/// (name check only — no decryption). Fails closed to "present" on a DB
/// error so a transient read failure can't cause an overwrite (#441).
func hasGitHubTokenCredential(userId: in String): Bool {
  match CloudAgents.Repository.listCredentialNames(userId) {
    case Ok(names) -> {
      var i = 0
      while i < names.length {
        if names[i].name == "GITHUB_TOKEN" {
          return true
        }
        i = i + 1
      }
      return false
    }
    case Err(_) -> return true
  }
}

/// Validate a token against api.github.com/user and parse the identity.
func fetchIdentity(token: in String): Result[GitHubIdentity, String] {
  val json = CloudAgents.GitHubApi.httpGetWithBearer(githubUserUrl(), token, userAgent())?
  val githubId = CloudAgents.Auth.githubUserIdFromJson(json)
  if githubId.length == 0 {
    return Err(error = "GitHub /user response carried no user id")
  }
  return Ok(value = GitHubIdentity(githubId = githubId, login = CloudAgents.Auth.githubLoginFromJson(json)))
}

/// POST /api/auth/github/exchange: swap the one-time code for the user's
/// OAuth token, validate the token's identity, apply the whitelist, and prime
/// the validation cache so the client's first real API call is fast.
pub func exchangeCode(req: in ExchangeRequest): Result[TokenGrant, Web.ApiError] {
  if not oauthConfigured() {
    return Err(Web.badRequest("GitHub OAuth is not configured on this server (set CLOUD_AGENTS_GITHUB_CLIENT_ID and CLOUD_AGENTS_GITHUB_CLIENT_SECRET)"))
  }
  if not isSafeOAuthCode(req.code) {
    return Err(Web.badRequest("code is missing or not a valid GitHub authorization code"))
  }
  // Exchange flood protection (#434), mirroring the bearer path's backstop
  // but on its OWN counter (rejected-code rows carry the 'oauth-code'
  // marker), so a garbage-bearer flood can never lock out sign-ins and a
  // garbage-code flood only throttles the exchange endpoint itself. A code
  // GitHub already rejected is refused outright while its negative row
  // lives; past the threshold of distinct rejected codes, stop spending
  // outbound exchanges until the window drains.
  val codeHash = CloudAgents.Crypto.sha256Base64("oauth-code:" + req.code)
  match CloudAgents.Repository.cachedGitHubToken(codeHash) {
    case Ok(Some(_)) -> return Err(Web.badRequest("this authorization code was recently rejected — restart the sign-in flow"))
    case Ok(None) -> ()
    case Err(_) -> ()
  }
  val recentRejections = match CloudAgents.Repository.activeRejectedOAuthCodes() {
    case Ok(n) -> n
    case Err(_) -> 0
  }
  if recentRejections >= maxRecentValidationFailures {
    return Err(Web.badRequest("too many recent failed sign-in attempts on this server — try again in a minute"))
  }
  // The exchange endpoint is reachable unauthenticated by design, so raw
  // transport errors (which can carry internal host/proxy detail) are logged
  // server-side and callers get a generic message — same rule as
  // checkHealth's DB probe (#55, review #422).
  val body = match CloudAgents.GitHubApi.httpPostForm(
    exchangeUrl(),
    exchangeFormBody(oauthClientId(), oauthClientSecret(), req.code),
    userAgent()
  ) {
    case Ok(b) -> b
    case Err(e) -> {
      println("WARNING: GitHub token exchange failed: " + e)
      return Err(Web.internalError("token exchange with GitHub failed"))
    }
  }
  val token = accessTokenFromExchangeJson(body)
  if token.length == 0 {
    // GitHub answered and said no — an unambiguous rejection, safe to count
    // toward the exchange backstop (#434). Best-effort write.
    match CloudAgents.Repository.cacheOAuthCodeRejected(codeHash) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
    val detail = exchangeErrorFromJson(body)
    val reason = if detail.length > 0 { detail } else { "no access token in GitHub's response" }
    return Err(Web.badRequest("GitHub rejected the authorization code: " + reason))
  }
  val identity = match fetchIdentity(token) {
    case Ok(idn) -> idn
    case Err(e) -> {
      println("WARNING: validating a freshly exchanged GitHub token failed: " + e)
      return Err(Web.internalError("validating the new token with GitHub failed"))
    }
  }
  match CloudAgents.Auth.authorizeGitHub(identity.githubId, whitelistCsv()) {
    case Allowed(userId) -> {
      // Prime the bearer-validation cache (best-effort — a cache write
      // failure must not fail a successful login).
      match CloudAgents.Repository.cacheGitHubToken(CloudAgents.Crypto.sha256Base64(token), userId, identity.login) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }
      // Vault the token as the tenant's GITHUB_TOKEN credential (encrypted
      // at rest via putCredential), so runner containers' GITHUB_TOKEN and
      // server-side GitHub features work right after sign-in with no
      // separate Integrations step. GITHUB_TOKEN is deliberately NOT a
      // reserved credential name (see credentials.l). ONLY when the tenant
      // has no GITHUB_TOKEN yet (#441): an existing credential may be a
      // deliberately-scoped fine-grained PAT the user configured by hand —
      // sign-in must never silently replace it. (Consequence: a stale
      // auto-vaulted token is refreshed by deleting the credential and
      // signing in again — documented in docs/credentials.md.) BEST-EFFORT:
      // a vault miss (e.g. ENCRYPTION_KEY unconfigured) must never fail a
      // successful login — log a NOTE and continue.
      if not hasGitHubTokenCredential(userId) {
        match CloudAgents.Repository.putCredential(userId, "GITHUB_TOKEN", token) {
          case Ok(_) -> ()
          case Err(e) -> println("NOTE: could not store GITHUB_TOKEN in the credential vault: " + CloudAgents.Repository.credentialErrorMessage(e))
        }
      }
      return Ok(TokenGrant(token = token, login = identity.login, userId = userId))
    }
    // Web.unauthorized is the closest proven response helper (this codebase
    // has no Web.forbidden call site to pattern-match against).
    case Denied(e) -> return Err(Web.unauthorized(CloudAgents.Auth.authErrorMessage(e)))
  }
}

// ─── Logout: server-side cache invalidation ──────────────────────────────────

/// POST /api/auth/github/logout: delete the presented bearer's
/// validation-cache row. Deleting the cache row forces the next presentation
/// of this token through live validation; the token itself stays valid at
/// GitHub until revoked there. Idempotent: a missing or malformed
/// Authorization header means there is nothing to invalidate, so it returns
/// Ok (as does deleting a row that was never cached).
pub func logout(authHeaderValue: in String): Result[Unit, Web.ApiError] {
  match CloudAgents.Auth.extractBearerToken(authHeaderValue) {
    case None -> return Ok(())
    case Some(token) -> {
      match CloudAgents.Repository.invalidateGitHubToken(CloudAgents.Crypto.sha256Base64(token)) {
        case Ok(_) -> return Ok(())
        case Err(e) -> {
          println("WARNING: logout could not invalidate the token-validation cache row: " + CloudAgents.Sqlite.dbErrorMessage(e))
          return Err(Web.internalError("logout failed"))
        }
      }
    }
  }
}

// ─── Per-request bearer authentication ───────────────────────────────────────

/// Authenticate a GitHub OAuth bearer: SQLite cache first (keyed by the
/// token's SHA-256, never the token itself), then a live /user validation
/// with whitelist enforcement, caching the outcome either way.
///
/// Cache-hit semantics:
///  - an empty cached userId is a short-lived NEGATIVE entry (#425) — the
///    same bad bearer is refused without another outbound round trip;
///  - a positive hit still re-applies the whitelist (a pure env check, no
///    network), so removing a user from CLOUD_AGENTS_WHITELIST takes effect
///    on their next request, not after the cache TTL (#424). Revocation of
///    the token *at GitHub* is still only noticed at revalidation — that
///    latency (≤10 min) is inherent to caching and documented in
///    docs/credentials.md.
pub func authenticateGitHubBearer(token: in String): AuthOutcome {
  val tokenHash = CloudAgents.Crypto.sha256Base64(token)
  match CloudAgents.Repository.cachedGitHubToken(tokenHash) {
    case Ok(Some(entry)) -> {
      if entry.userId.length == 0 {
        return CloudAgents.Auth.deniedOutcome(CloudAgents.Auth.invalidTokenError())
      }
      return match CloudAgents.Auth.authorizeGitHub(
        CloudAgents.Auth.githubIdFromUserId(entry.userId),
        whitelistCsv()
      ) {
        case Allowed(userId) -> CloudAgents.Auth.allowedOutcome(userId)
        case Denied(e) -> CloudAgents.Auth.deniedOutcome(e)
      }
    }
    case Ok(None) -> ()
    // A cache-read failure falls through to live validation — the cache is
    // an optimisation, not an authority.
    case Err(_) -> ()
  }
  // Flood backstop (#425): the negative cache only blunts REPEATS of the
  // same bad bearer — a flood of distinct garbage tokens would still cost
  // one outbound round trip each (blocking a request thread for up to the
  // HTTP timeout). Every distinct bad bearer leaves a 1-minute negative row,
  // so the count of active negative rows is a sliding-window rate of recent
  // failures; past a threshold no plausible number of legitimate new sign-ins
  // produces, stop validating unrecognised bearers outright until the window
  // drains. Fails open on a DB error: the cache is an optimisation, not the
  // authority.
  //
  // The counter is deliberately GLOBAL, not per-caller (#433): the only
  // per-caller signal available here is X-Forwarded-For, which an attacker
  // sets freely on direct-exposure deployments — partitioning by it would
  // let them escape their own bucket and reopen the unbounded-outbound hole
  // this exists to close. The blast radius of a tripped backstop is narrow
  // by construction: already-validated users ride on the positive cache, and
  // NEW sign-ins are unaffected because exchangeCode validates directly and
  // primes the positive cache — so the only callers refused during a flood
  // are bearers that never went through this server's exchange (e.g. the
  // same token pasted onto a second device), and re-running the sign-in flow
  // there self-heals. See docs/credentials.md.
  val recentFailures = match CloudAgents.Repository.activeNegativeGitHubTokens() {
    case Ok(n) -> n
    case Err(_) -> 0
  }
  if recentFailures >= maxRecentValidationFailures {
    return CloudAgents.Auth.deniedOutcome(CloudAgents.Auth.invalidTokenError())
  }

  val identity = match fetchIdentity(token) {
    case Ok(idn) -> idn
    case Err(e) -> {
      // Negatively cache only CONFIRMED rejections — GitHub answered with an
      // auth-failure status — never transport failures (DNS, outage,
      // timeout), which would otherwise lock a valid token out for the
      // negative TTL and pollute the flood counter during a GitHub blip
      // (#435). The request itself still fails closed either way.
      if isConfirmedAuthRejection(e) {
        match CloudAgents.Repository.cacheGitHubTokenDenied(tokenHash) {
          case Ok(_) -> ()
          case Err(_) -> ()
        }
      }
      return CloudAgents.Auth.deniedOutcome(CloudAgents.Auth.invalidTokenError())
    }
  }
  // The token is genuinely valid at this point — cache the IDENTITY
  // regardless of the whitelist verdict, and let the per-hit whitelist check
  // above enforce access. That makes whitelist changes symmetric and instant
  // in both directions (#424/#429): a removal locks the user out on their
  // next request, and an addition lets a previously-refused user straight in
  // — no negative row to wait out. (Negative rows are only for tokens GitHub
  // itself rejected, where there is no identity to re-check.) This also
  // means an unlisted-but-valid token stops costing outbound round trips,
  // exactly like a listed one.
  match CloudAgents.Repository.cacheGitHubToken(
    tokenHash,
    CloudAgents.Auth.userIdForGitHubId(identity.githubId),
    identity.login
  ) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  match CloudAgents.Auth.authorizeGitHub(identity.githubId, whitelistCsv()) {
    case Allowed(userId) -> return CloudAgents.Auth.allowedOutcome(userId)
    case Denied(e) -> return CloudAgents.Auth.deniedOutcome(e)
  }
}

/// The full per-request auth decision, replacing bare Auth.enforce in the
/// middleware:
///  1. a bearer matching the static CLOUD_AGENTS_API_TOKEN authenticates as
///     the operator identity (unchanged behaviour);
///  2. any other bearer, when OAuth is configured, is treated as a GitHub
///     OAuth token and validated (works for secret routes too — a validated
///     GitHub identity is real authentication);
///  3. everything else falls back to Auth.enforce, preserving the existing
///     static-token semantics (open when unconfigured, secret routes always
///     refusing to run unauthenticated).
pub func authenticateRequest(path: in String, authHeaderValue: in String, apiToken: in String): AuthOutcome {
  match CloudAgents.Auth.extractBearerToken(authHeaderValue) {
    case None -> return CloudAgents.Auth.enforce(path, authHeaderValue, apiToken)
    case Some(token) -> {
      if apiToken.length > 0 and CloudAgents.Auth.constantTimeEquals(token, apiToken) {
        return CloudAgents.Auth.allowedOutcome(CloudAgents.Auth.operatorUserId())
      }
      if oauthConfigured() {
        return authenticateGitHubBearer(token)
      }
      return CloudAgents.Auth.enforce(path, authHeaderValue, apiToken)
    }
  }
}
