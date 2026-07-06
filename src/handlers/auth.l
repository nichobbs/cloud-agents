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

/// Reasons authentication can fail.
pub enum AuthError {
  case MissingToken
  case InvalidToken
  case NotAuthorized
}

pub func authErrorMessage(e: in AuthError): String {
  return match e {
    case MissingToken -> "missing Authorization bearer token"
    case InvalidToken -> "invalid or expired GitHub token"
    case NotAuthorized -> "user is not on the access whitelist"
  }
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
