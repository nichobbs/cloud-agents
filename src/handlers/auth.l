package CloudAgents.Auth

import Std.Core
import CloudAgents.Text
import extern System.String as DotNetString

/// Phase 3 groundwork: GitHub-OAuth-based authentication helpers.
///
/// The full middleware (docs/phase3-multi-tenancy.md) validates the bearer
/// token by calling `https://api.github.com/user` and caches the result for
/// the token lifetime. That network call belongs in the HTTP boundary layer;
/// the pure pieces — extracting the token, parsing the identity, and access
/// control — live here so they can be unit-tested without a network.
/// Authenticated GitHub identity, the stable per-tenant key.
@generate(Json)
pub record GitHubUser {

  pub id: Long
  pub login: String
}

/// Reasons authentication can fail. Shared by the static-token flow
/// (authorize/authorizeSecret) and the future GitHub-OAuth flow, so the
/// messages avoid naming a specific scheme except where one genuinely applies
/// (NotWhitelisted is OAuth-only).
pub enum AuthError {
  case MissingToken
  case InvalidToken
  case AuthNotConfigured
  case NotWhitelisted
}

pub func authErrorMessage(e: in AuthError): String {
  return match e {
    case MissingToken -> "missing Authorization bearer token"
    case InvalidToken -> "invalid or expired token"
    case AuthNotConfigured -> "authentication is not configured; access is disabled"
    case NotWhitelisted -> "user is not on the access whitelist"
  }
}

/// Message for the GitHub-token validation failure (used by the OAuth path).
pub func githubTokenInvalidMessage(): String {
  return "invalid or expired GitHub token"
}

/// Extract the raw token from an `Authorization: Bearer <token>` header value.
/// Returns `None` when the header is absent or not a well-formed bearer header.
pub func extractBearerToken(headerValue: in String): Option[String] {
  val prefix = "Bearer "
  if headerValue.length <= prefix.length {
    return None
  }
  val head = headerValue.substring(0, prefix.length)
  if head != prefix {
    return None
  }
  val token = headerValue.substring(prefix.length, headerValue.length - prefix.length)
  if token.length == 0 {
    return None
  }
  return Some(value = token)
}

extern type Type = "System.Type"

extern type StringArray = "System.String[]"

@externInstance
@externTarget("System.Object.GetType")
func getStringType(obj: in String): Type = ()

@externTarget("System.Array.CreateInstance")
func createStringArray(elementType: in Type, length: in Int): StringArray = ()

@externTarget("System.Array.Copy")
func copyStringArray(
  sourceArray: in StringArray,
  sourceIndex: in Int,
  destinationArray: in StringArray,
  destinationIndex: in Int,
  length: in Int,
): Unit = ()

@externInstance
@externTarget("System.Array.get_Length")
func getStringArrayLength(arr: in StringArray): Int = ()

@externInstance
@externTarget("System.Array.SetValue")
func setStringArrayValue(arr: in StringArray, value: in String, index: in Int): Unit = ()

@externInstance
@externTarget("System.Array.GetValue")
func getStringArrayValue(arr: in StringArray, index: in Int): String = ()

pub func appendString(arr: in StringArray, item: in String): StringArray {
  val oldLen = getStringArrayLength(arr)
  val stringType = getStringType("")
  val newArr = createStringArray(stringType, oldLen + 1)
  if oldLen > 0 {
    copyStringArray(arr, 0, newArr, 0, oldLen)
  }
  setStringArrayValue(newArr, item, oldLen)
  return newArr
}

pub func createEmptyStringArray(): StringArray {
  val stringType = getStringType("")
  return createStringArray(stringType, 0)
}

/// Split a comma-separated whitelist into trimmed, non-empty entries.
/// A whitelist is configured via an environment variable (e.g.
/// `CLOUD_AGENTS_WHITELIST=12345,67890`).
pub func parseWhitelist(csv: in String): StringArray {
  var entries = createEmptyStringArray()
  var current = ""
  var i = 0
  while i < csv.length {
    val c = csv.substring(i, 1)
    if c == "," {
      val trimmed = current.trim()
      if trimmed.length > 0 {
        entries = appendString(entries, trimmed)
      }
      current = ""
    } else {
      current = current + c
    }
    i = i + 1
  }
  val lastTrimmed = current.trim()
  if lastTrimmed.length > 0 {
    entries = appendString(entries, lastTrimmed)
  }
  return entries
}

/// Decide whether a GitHub user id is allowed.
/// An empty whitelist means "open access" (any authenticated user).
pub func isWhitelisted(githubUserId: in String, csv: in String): Bool {
  val entries = parseWhitelist(csv)
  val len = getStringArrayLength(entries)
  if len == 0 {
    return true
  }
  var i = 0
  while i < len {
    if getStringArrayValue(entries, i) == githubUserId {
      return true
    }
    i = i + 1
  }
  return false
}

/// Cache key for a validated token. Tokens are opaque secrets, so the cache
/// is keyed by the token itself; callers should treat this as sensitive.
pub func tokenCacheKey(token: in String): String {
  return "ghtoken:" + token
}

// ─── Validation cache ─────────────────────────────────────────────────────────
//
// Validating a token means a round-trip to api.github.com/user (~100-200ms),
// so results are cached for the token lifetime (docs/phase3 §1). These helpers
// own the pure expiry arithmetic; the cache store itself lives in the HTTP
// layer.
/// A cached, previously-validated identity.
pub record CachedToken {
  pub userId: String
  pub login: String
  pub expiresAtMillis: Long
}

/// Absolute expiry instant for a freshly validated token.
pub func cacheExpiry(nowMillis: in Long, ttlSeconds: in Long): Long {
  return nowMillis + ttlSeconds * 1000.toLong()
}

/// Whether a cache entry is still valid at `nowMillis`.
pub func isCacheValid(entry: in CachedToken, nowMillis: in Long): Bool {
  return nowMillis < entry.expiresAtMillis
}

// ─── Ownership ────────────────────────────────────────────────────────────────
/// Whether the authenticated user owns the resource. A mismatch is a 403
/// (docs/phase3 §4).
pub func ownsResource(authedUserId: in String, ownerUserId: in String): Bool {
  return authedUserId == ownerUserId
}

// ─── Per-request identity ─────────────────────────────────────────────────────
//
// The middleware authenticates each request and stamps the resolved user id
// into a named thread-data slot before dispatching the handler; everything
// downstream reads it back via currentUserId(). Thread data (not a plain
// package-level var) because Lyric.Web dispatches requests concurrently — a
// shared var would let one request's identity bleed into another's queries.
//
// The whole request pipeline (middleware + handler + repository calls) runs
// synchronously on one thread, so thread data is sound there. It does NOT
// flow onto the worker threads Docker's async runs execute on — which is why
// the container path takes an explicit userId parameter, captured on the
// request thread (see CloudAgents.Docker.streamSessionMessage), instead of
// reading this ambient value.
extern type DataSlot = "System.LocalDataStoreSlot"

@externTarget("System.Threading.Thread.GetNamedDataSlot")
func getNamedDataSlot(name: in String): DataSlot = ()

// Thread.SetData's parameter is object; passing String binds fine — the same
// assignability sqlite_driver.l relies on for Array.SetValue.
@externTarget("System.Threading.Thread.SetData")
func threadSetData(slot: in DataSlot, data: in String): Unit = ()

// Returns null when nothing was stored on this thread; declared String and
// null-checked via DotNetString, the same pattern main.l uses for
// GetEnvironmentVariable.
@externTarget("System.Threading.Thread.GetData")
func threadGetData(slot: in DataSlot): String = ""

/// The single-operator identity: static-token auth and unauthenticated-open
/// deployments resolve to this, exactly as before OAuth existed.
pub func operatorUserId(): String {
  return "default"
}

/// Stamp the authenticated user id for the current request's thread. Called
/// by the middleware on every allowed request (so a pooled thread can never
/// leak the previous request's identity into this one).
pub func setCurrentUserId(userId: in String): Unit {
  threadSetData(getNamedDataSlot("cloud-agents-current-user"), userId)
}

/// The identity that owns per-user data (prompts, credentials, sessions) for
/// the current request: whatever the middleware stamped for this thread, or
/// the operator identity when nothing was (tests, startup code, static-token
/// deployments). Every schema and query is scoped by this value.
pub func currentUserId(): String {
  val v = threadGetData(getNamedDataSlot("cloud-agents-current-user"))
  if DotNetString.IsNullOrEmpty(v) {
    return operatorUserId()
  }
  return v
}

// ─── Static-token authentication ──────────────────────────────────────────────
//
// Phase-1 auth: a single shared secret in CLOUD_AGENTS_API_TOKEN. Requests
// present it as `Authorization: Bearer <token>`; the middleware compares it to
// the configured value in constant time. This is the interim scheme the PR
// series wires in ahead of GitHub OAuth (docs/phase3 §1) — `authorize()` is
// the one function OAuth will replace, resolving a real user id instead of the
// fixed operator identity.
//
// NB: enforcement at the HTTP boundary is wired in as of the Lyric.Web 0.4.26
// pin, which exposes the request's Authorization header (docs/BUILD.md
// "Dependencies") — see AuthMiddleware in src/main.l, which calls enforce()
// below via Web.header(req, "Authorization"). The pure decision logic below
// was fully unit-tested before that wiring landed, which is why it was a
// one-line change once the framework supported it.
/// Constant-time string equality. Avoids leaking how many leading characters
/// of a candidate token matched via response timing.
///
/// The loop iterates over the trusted `expected` value's length only, never the
/// candidate's — so the number of comparisons (and thus the running time) does
/// not depend on the attacker-controlled candidate at all. The previous
/// implementation bounded the loop by max(candidate, expected), which produced
/// a timing "elbow" as the candidate grew past `expected` that leaked the
/// configured token's length (#212); now a candidate shorter, equal, or longer
/// than the secret all cost the same. A length mismatch is folded in up front
/// so a right-length-wrong-content and a wrong-length candidate both fail.
///
/// Pass the trusted secret as `expected` (as the sole caller `authorize` does:
/// `constantTimeEquals(token, apiToken)`).
///
/// Thin re-export of CloudAgents.Text.constantTimeEquals (#204) — kept as a
/// named function here (rather than inlining the qualified call at the one
/// caller) so this package's own public API and this file's existing tests
/// don't need to change.
pub func constantTimeEquals(candidate: in String, expected: in String): Bool {
  return CloudAgents.Text.constantTimeEquals(candidate, expected)
}

/// Outcome of authenticating a request.
pub union AuthOutcome {
  case Allowed(userId: String)
  case Denied(error: AuthError)
}

// Constructor helpers for other packages (CloudAgents.OAuth): union-case
// construction from outside the declaring package is in the same risk family
// as the package-qualified record-construction runtime failure documented in
// docs/lyric/gotchas.md, so cross-package callers go through these instead.
pub func allowedOutcome(userId: in String): AuthOutcome {
  return Allowed(userId = userId)
}

pub func deniedOutcome(error: in AuthError): AuthOutcome {
  return Denied(error = error)
}

pub func invalidTokenError(): AuthError {
  return InvalidToken
}

/// Decide whether a request bearing `authHeaderValue` may proceed, given the
/// configured `apiToken`.
///
/// - An empty `apiToken` means auth is not configured. Callers decide per
/// //   route whether that is acceptable: general endpoints stay open (matching
///   today's behaviour), but credential endpoints must refuse rather than
///   expose secrets unauthenticated — see `authorizeSecret`.
/// - A configured token requires a well-formed bearer header whose token
///   matches in constant time.
pub func authorize(authHeaderValue: in String, apiToken: in String): AuthOutcome {
  // Both Allowed arms resolve the OPERATOR identity explicitly — never
  // currentUserId(). currentUserId() reads the per-thread stamp left by the
  // *previous* request on a pooled thread, so reading it while deciding this
  // request's identity would let an unauthenticated (open-access) or
  // static-token request silently inherit an unrelated OAuth user's identity
  // (#420). The stamp is only ever written from an outcome, after this
  // decision.
  if apiToken.length == 0 {
    return Allowed(userId = operatorUserId())
  }
  match extractBearerToken(authHeaderValue) {
    case None -> return Denied(error = MissingToken)
    case Some(token) -> {
      if constantTimeEquals(token, apiToken) {
        return Allowed(userId = operatorUserId())
      }
      return Denied(error = InvalidToken)
    }
  }
}

/// Whether a route that must never run unauthenticated (credential storage)
/// may proceed. Distinct from `authorize`: here a missing/empty configured
/// token is itself a denial, so secrets can never be served on an
/// unauthenticated deployment.
pub func authorizeSecret(authHeaderValue: in String, apiToken: in String): AuthOutcome {
  if apiToken.length == 0 {
    return Denied(error = AuthNotConfigured)
  }
  return authorize(authHeaderValue, apiToken)
}

// ─── GitHub /user response parsing ────────────────────────────────────────────
//
// The validation call returns a JSON object containing at least `id` (number)
// and `login` (string). These extractors pull those two fields without a full
// JSON parser, so they are pure and runtime-testable. The handler layer turns
// the results into a `GitHubUser` and rejects responses missing either field.
/// Extract a string field's value, or "" if the field is absent. Handles the
/// `"field"` token, the following colon, and a double-quoted value.
pub func parseJsonString(json: in String, field: in String): String {
  val target = "\"" + field + "\""
  val pos = CloudAgents.Text.indexOfFrom(json, target, 0)
  if pos < 0 {
    return ""
  }
  val jsonLen = json.length.toInt()
  var i = pos + target.length.toInt()
  var inValue = false
  var start = 0
  while i < jsonLen {
    val c = json.substring(i, 1)
    if not inValue {
      if c == "\"" {
        inValue = true
        start = i + 1
      }
      i = i + 1
    } else {
      if c == "\"" {
        return json.substring(start, i - start)
      }
      i = i + 1
    }
  }
  return ""
}

/// Extract an unsigned integer field's value as a string of digits, or "" if
/// the field is absent. (GitHub user ids are JSON numbers, not quoted.)
pub func parseJsonNumber(json: in String, field: in String): String {
  val target = "\"" + field + "\""
  val pos = CloudAgents.Text.indexOfFrom(json, target, 0)
  if pos < 0 {
    return ""
  }
  val jsonLen = json.length.toInt()
  var i = pos + target.length.toInt()
  var seenColon = false
  var acc = ""
  while i < jsonLen {
    val c = json.substring(i, 1)
    if not seenColon {
      if c == ":" {
        seenColon = true
      }
      i = i + 1
    } else if c == "0" or c == "1" or c == "2" or c == "3" or c == "4" or c == "5" or c == "6" or c == "7" or c == "8" or c == "9" {
      acc = acc + c
      i = i + 1
    } else if acc.length > 0 {
      return acc
    } else if c == " " {
      i = i + 1
    } else {
      return ""
    }
  }
  return acc
}

// ─── GitHub OAuth authorization (behind the Lyric.Web gate) ─────────────────────
//
// The token->identity network call (GET api.github.com/user) is the
// HTTP-boundary piece Lyric.Web must host; the pure pieces — turning that
// response into a stable user id and applying the whitelist — live here and are
// unit-tested. Kept as strings (the id as its digit form) so no Long parse is
// needed and everything lines up with isWhitelisted's string interface.
/// The GitHub numeric id (digit string, "" if absent) from a /user response.
pub func githubUserIdFromJson(json: in String): String {
  return parseJsonNumber(json, "id")
}

/// The login ("" if absent) from a /user response.
pub func githubLoginFromJson(json: in String): String {
  return parseJsonString(json, "login")
}

/// The stable per-tenant user id for a GitHub numeric id. Prefixed so it can
/// never collide with the static-token "default" identity. This is the value
/// currentUserId() returns once OAuth is wired in — every schema/query is
/// already scoped by it, so the switch stays contained.
pub func userIdForGitHubId(githubId: in String): String {
  return "gh-" + githubId
}

/// Inverse of userIdForGitHubId: the raw GitHub numeric id from a per-tenant
/// user id, or "" when the id is not a GitHub identity. Lets the cached-token
/// path re-apply the whitelist (a pure env check) on every hit, so removing a
/// user from CLOUD_AGENTS_WHITELIST takes effect on their next request
/// instead of after the cache TTL (#424).
pub func githubIdFromUserId(userId: in String): String {
  val prefix = "gh-"
  if userId.length <= prefix.length {
    return ""
  }
  val head = userId.substring(0, prefix.length)
  if head != prefix {
    return ""
  }
  return userId.substring(prefix.length, userId.length - prefix.length)
}

/// Access decision for a validated GitHub identity against the whitelist. A
/// missing id (unparseable /user response) is InvalidToken; an id absent from a
/// non-empty whitelist is NotWhitelisted; otherwise Allowed with the
/// GitHub-derived user id. The caller obtains `githubId` by validating the
/// bearer token at the HTTP boundary — the one gated piece.
pub func authorizeGitHub(githubId: in String, whitelistCsv: in String): AuthOutcome {
  if githubId.length == 0 {
    return Denied(error = InvalidToken)
  }
  if not isWhitelisted(githubId, whitelistCsv) {
    return Denied(error = NotWhitelisted)
  }
  return Allowed(userId = userIdForGitHubId(githubId))
}

// ─── Per-request enforcement ──────────────────────────────────────────────────
//
// main.l's AuthMiddleware wires this in as a pre-handler guard (Lyric.Web
// 0.4.26 exposes the request's Authorization header via Web.header). Secret
// routes (credential storage) use authorizeSecret so they refuse when no
// token is configured; all others use authorize (open when unconfigured,
// matching today's behaviour). Both the classification and the decision
// stayed pure and unit-tested throughout, so wiring them in was a one-line
// change once the framework supported it.
/// Whether a request path must never run unauthenticated — the credential
/// routes, which read/write secrets. Matches the /api/credentials prefix.
pub func routeRequiresSecret(path: in String): Bool {
  return path == "/api/credentials" or path.startsWith("/api/credentials/")
}

/// The auth decision for a request: authorizeSecret for secret routes,
/// authorize otherwise.
pub func enforce(path: in String, authHeaderValue: in String, apiToken: in String): AuthOutcome {
  if routeRequiresSecret(path) {
    return authorizeSecret(authHeaderValue, apiToken)
  }
  return authorize(authHeaderValue, apiToken)
}

// ─── Phase 6: MCP-callback authentication ────────────────────────────────────
//
// Container-originated calls (create/poll a permission request or question,
// report progress) authenticate with a per-session callback bearer token —
// never the user's OAuth/static token — so they bypass the normal
// AuthMiddleware bearer check entirely (see isContainerCallbackRoute below)
// and are checked directly against the session's stored token by
// CloudAgents.Callbacks. docs/phase6-mcp-callbacks.md §2/§5.
/// Whether `authHeaderValue` carries a bearer token matching `expectedToken`
/// (constant-time, same shape as the static-token check above). Pure so it is
/// unit-testable without a database; CloudAgents.Callbacks supplies the
/// session's stored token looked up via CloudAgents.SessionStore.
pub func authorizeCallback(authHeaderValue: in String, expectedToken: in String): Bool {
  match extractBearerToken(authHeaderValue) {
    case None -> false
    case Some(token) -> constantTimeEquals(token, expectedToken)
  }
}

/// Whether a request path is a container-originated MCP-callback endpoint —
/// the create/poll routes under `/api/sessions/{id}/callbacks/...`. These
/// authenticate themselves (authorizeCallback, above) against the session's
/// own bearer token, so AuthMiddleware must NOT run its normal user-auth
/// check against them (the container has no user token to present). The
/// `.../answer` sub-route is the opposite case — a human answering a pending
/// request/question from the UI — and is deliberately NOT exempt: it flows
/// through normal user auth plus an ownership check in the handler, exactly
/// like every other session sub-resource route.
pub func isContainerCallbackRoute(path: in String): Bool {
  return path.contains("/callbacks/") and not path.endsWith("/answer")
}
