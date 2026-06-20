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

/// Split a comma-separated whitelist into trimmed, non-empty entries.
/// A whitelist is configured via an environment variable (e.g.
/// `CLOUD_AGENTS_WHITELIST=12345,67890`).
pub func parseWhitelist(csv: in String): slice[String] {
  var entries: slice[String] = []
  var current = ""
  var i = 0
  while i < csv.length {
    val c = csv.substring(i, 1)
    if c == "," {
      val trimmed = current.trim()
      if trimmed.length > 0 {
        entries = entries.append(trimmed)
      }
      current = ""
    } else {
      current = current + c
    }
    i = i + 1
  }
  val lastTrimmed = current.trim()
  if lastTrimmed.length > 0 {
    entries = entries.append(lastTrimmed)
  }
  return entries
}

/// Decide whether a GitHub user id is allowed.
/// An empty whitelist means "open access" (any authenticated user).
pub func isWhitelisted(githubUserId: in String, csv: in String): Bool {
  val entries = parseWhitelist(csv)
  if entries.length == 0 {
    return true
  }
  var i = 0
  while i < entries.length {
    if entries[i] == githubUserId {
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
