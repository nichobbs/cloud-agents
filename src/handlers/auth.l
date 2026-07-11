package CloudAgents.Auth

import Std.Core

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

/// The identity that owns per-user data (prompts, credentials, sessions) for
/// the current request. Static-token phase: one operator identity for the
/// whole deployment. The GitHub-OAuth follow-up replaces this body with the
/// id of the validated bearer token's user — every schema and query is
/// already scoped by this value, so that change stays contained here.
pub func currentUserId(): String {
  return "default"
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
// NB: enforcement at the HTTP boundary depends on Lyric.Web exposing the
// request's Authorization header to handlers, which the pinned version does
// not yet do (docs/BUILD.md "Dependencies"). The pure decision logic below is
// fully unit-tested now so that wiring it in is a one-line change once the
// framework supports it.
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
pub func constantTimeEquals(candidate: in String, expected: in String): Bool {
  val candLen = candidate.length.toInt()
  val expectedLen = expected.length.toInt()
  var diff = if candLen == expectedLen then 0 else 1
  var i = 0
  while i < expectedLen {
    val ce = expected.substring(i, 1)
    // Past the candidate's end, compare `ce` against itself so the step is a
    // no-op: the length mismatch is already recorded in `diff`, and this keeps
    // per-iteration work uniform without introducing a content-dependent branch.
    val cc = if i < candLen then candidate.substring(i, 1) else ce
    if cc != ce {
      diff = 1
    }
    i = i + 1
  }
  return diff == 0
}

/// Outcome of authenticating a request.
pub union AuthOutcome {
  case Allowed(userId: String)
  case Denied(error: AuthError)
}

/// Decide whether a request bearing `authHeaderValue` may proceed, given the
/// configured `apiToken`.
///
/// - An empty `apiToken` means auth is not configured. Callers decide per
/////   route whether that is acceptable: general endpoints stay open (matching
///   today's behaviour), but credential endpoints must refuse rather than
///   expose secrets unauthenticated — see `authorizeSecret`.
/// - A configured token requires a well-formed bearer header whose token
///   matches in constant time.
pub func authorize(authHeaderValue: in String, apiToken: in String): AuthOutcome {
  if apiToken.length == 0 {
    return Allowed(userId = currentUserId())
  }
  match extractBearerToken(authHeaderValue) {
    case None -> return Denied(error = MissingToken)
    case Some(token) -> {
      if constantTimeEquals(token, apiToken) {
        return Allowed(userId = currentUserId())
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
/// First index of `needle` in `hay` at or after `from`, or -1 if not present.
/// A manual scan — the compiler's `String.indexOf`/`Option` path is unreliable
/// at runtime in the current toolchain, and this keeps the parsers on the
/// String/Int operations that are known-good.
pub func indexOfFrom(hay: in String, needle: in String, from: in Int): Int {
  val hayLen = hay.length.toInt()
  val needleLen = needle.length.toInt()
  if needleLen == 0 {
    return from
  }
  var i = from
  val last = hayLen - needleLen
  while i <= last {
    var j = 0
    var matched = true
    while j < needleLen {
      if hay.substring(i + j, 1) != needle.substring(j, 1) {
        matched = false
        j = needleLen
      } else {
        j = j + 1
      }
    }
    if matched {
      return i
    }
    i = i + 1
  }
  return -1
}

/// Extract a string field's value, or "" if the field is absent. Handles the
/// `"field"` token, the following colon, and a double-quoted value.
pub func parseJsonString(json: in String, field: in String): String {
  val target = "\"" + field + "\""
  val pos = indexOfFrom(json, target, 0)
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
  val pos = indexOfFrom(json, target, 0)
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

// ─── Per-request enforcement (behind the Lyric.Web gate) ────────────────────────
//
// Once Lyric.Web exposes the request's Authorization header, main() wires
// `enforce()` as a pre-handler guard. Secret routes (credential storage) use
// authorizeSecret so they refuse when no token is configured; all others use
// authorize (open when unconfigured, matching today's behaviour). Both the
// classification and the decision are pure and tested here, so wiring is a
// one-line change when the framework supports it.
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
