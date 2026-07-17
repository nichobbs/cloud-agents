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

func envOr(name: in String): String {
  var v = Env.GetEnvironmentVariable(name)
  if DotNetString.IsNullOrEmpty(v) {
    return ""
  }
  return v
}

pub func oauthClientId(): String {
  return envOr("CLOUD_AGENTS_GITHUB_CLIENT_ID")
}

func oauthClientSecret(): String {
  return envOr("CLOUD_AGENTS_GITHUB_CLIENT_SECRET")
}

func whitelistCsv(): String {
  return envOr("CLOUD_AGENTS_WHITELIST")
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
  val body = match CloudAgents.GitHubApi.httpPostForm(
    exchangeUrl(),
    exchangeFormBody(oauthClientId(), oauthClientSecret(), req.code),
    userAgent()
  ) {
    case Ok(b) -> b
    case Err(e) -> return Err(Web.internalError("token exchange with GitHub failed: " + e))
  }
  val token = accessTokenFromExchangeJson(body)
  if token.length == 0 {
    val detail = exchangeErrorFromJson(body)
    val reason = if detail.length > 0 { detail } else { "no access token in GitHub's response" }
    return Err(Web.badRequest("GitHub rejected the authorization code: " + reason))
  }
  val identity = match fetchIdentity(token) {
    case Ok(idn) -> idn
    case Err(e) -> return Err(Web.internalError("validating the new token failed: " + e))
  }
  match CloudAgents.Auth.authorizeGitHub(identity.githubId, whitelistCsv()) {
    case Allowed(userId) -> {
      // Prime the bearer-validation cache (best-effort — a cache write
      // failure must not fail a successful login).
      match CloudAgents.Repository.cacheGitHubToken(CloudAgents.Crypto.sha256Base64(token), userId, identity.login) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }
      return Ok(TokenGrant(token = token, login = identity.login, userId = userId))
    }
    // Web.unauthorized is the closest proven response helper (this codebase
    // has no Web.forbidden call site to pattern-match against).
    case Denied(e) -> return Err(Web.unauthorized(CloudAgents.Auth.authErrorMessage(e)))
  }
}

// ─── Per-request bearer authentication ───────────────────────────────────────

/// Authenticate a GitHub OAuth bearer: SQLite cache first (keyed by the
/// token's SHA-256, never the token itself), then a live /user validation
/// with whitelist enforcement, caching the success.
pub func authenticateGitHubBearer(token: in String): AuthOutcome {
  val tokenHash = CloudAgents.Crypto.sha256Base64(token)
  match CloudAgents.Repository.cachedGitHubToken(tokenHash) {
    case Ok(Some(entry)) -> return CloudAgents.Auth.allowedOutcome(entry.userId)
    case Ok(None) -> ()
    // A cache-read failure falls through to live validation — the cache is
    // an optimisation, not an authority.
    case Err(_) -> ()
  }
  val identity = match fetchIdentity(token) {
    case Ok(idn) -> idn
    case Err(_) -> return CloudAgents.Auth.deniedOutcome(CloudAgents.Auth.invalidTokenError())
  }
  match CloudAgents.Auth.authorizeGitHub(identity.githubId, whitelistCsv()) {
    case Allowed(userId) -> {
      match CloudAgents.Repository.cacheGitHubToken(tokenHash, userId, identity.login) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }
      return CloudAgents.Auth.allowedOutcome(userId)
    }
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
