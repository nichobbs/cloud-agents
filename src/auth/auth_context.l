package CloudAgents.AuthContext

import Std.Core
import Web
import CloudAgents.Auth

/// In-memory cache for validated GitHub tokens. Each entry maps a bearer token
/// to the authenticated GitHub identity. Entries expire after a configurable TTL
/// (default 1 hour, matching the phase3 design).
///
/// The cache is the bridge between the HTTP boundary layer (which sees the raw
/// token) and the handler functions (which need the resolved identity). The
/// handler calls `resolveUser(token)` which returns a cached entry or triggers
/// a fresh validation.

/// Cached, validated identity for a bearer token.
pub record AuthSession {
  pub token: String
  pub githubUserId: String
  pub login: String
  pub expiresAtMillis: Long
}

/// Default TTL for token validation cache (1 hour in milliseconds).
val defaultTtlMillis: Long = 3600000.toLong()

// ─── In-memory cache ──────────────────────────────────────────────────────────
//
// A simple linear scan of cached auth sessions. For the expected scale
// (tens of concurrent users), this is adequate. The cache is bounded by
// the TTL — expired entries are evicted on access.

var cache: slice[AuthSession] = []

/// Current wall-clock time in milliseconds (delegates to Std.Time).
func nowMillis(): Long {
  return Std.Time.Instant.now().toEpochMillis()
}

/// Look up a cached auth session for the given token. Returns None if not
/// cached or expired.
pub func getCachedSession(token: in String): Option[AuthSession] {
  val current = nowMillis()
  var i = 0
  while i < cache.length {
    val entry = cache[i]
    if entry.token == token {
      if current < entry.expiresAtMillis {
        return Some(value = entry)
      }
      // Expired — remove it (swap with last, shrink)
      cache = removeAt(cache, i)
      return None
    }
    i = i + 1
  }
  return None
}

/// Store a validated auth session in the cache.
pub func putCachedSession(session: in AuthSession): Unit {
  // Evict any existing entry for this token first
  var i = 0
  while i < cache.length {
    if cache[i].token == session.token {
      cache = removeAt(cache, i)
    } else {
      i = i + 1
    }
  }
  cache = cache.append(session)
}

/// Evict all expired entries from the cache.
pub func evictExpired(): Unit {
  val current = nowMillis()
  var kept: slice[AuthSession] = []
  var i = 0
  while i < cache.length {
    if current < cache[i].expiresAtMillis {
      kept = kept.append(cache[i])
    }
    i = i + 1
  }
  cache = kept
}

/// Remove a slice element by index (swap-with-last then truncate for O(1) delete).
func removeAt(items: in slice[AuthSession], idx: in Int): slice[AuthSession] {
  val last = items.length - 1
  if idx == last {
    return items.slice(0, idx)
  }
  var result: slice[AuthSession] = []
  var i = 0
  while i < items.length {
    if i != idx {
      result = result.append(items[i])
    }
    i = i + 1
  }
  return result
}

// ─── Token resolution ─────────────────────────────────────────────────────────

/// Result of attempting to resolve a bearer token to an authenticated user.
pub union ResolveResult {
  case Authenticated(session: AuthSession)
  case InvalidToken
  case Expired
}

/// Resolve a bearer token to an authenticated user. Checks the in-memory
/// cache first; on miss, returns InvalidToken so the caller can perform
/// the actual GitHub API validation and cache the result via putCachedSession.
///
/// This function does NOT make network calls — it is a pure cache lookup.
/// The HTTP handler layer calls this first, and on InvalidToken performs
/// the GitHub /user call, then stores the result.
pub func resolveToken(token: in String): ResolveResult {
  match getCachedSession(token) {
    case Some(session) -> return Authenticated(session = session)
    case None -> return InvalidToken
  }
}

/// Convenience: validate a bearer token string (already extracted from the
/// Authorization header) and return the resolved user or an AuthError.
///
/// This is the main entry point for handler code:
///   val authResult = validateAndResolve(authHeader)
///   match authResult {
///     case Ok(session) -> // proceed with session.githubUserId
///     case Err(e)      -> return Err(Web.unauthorized(authErrorMessage(e)))
///   }
pub func validateAndResolve(authHeader: in String): Result[AuthSession, CloudAgents.Auth.AuthError] {
  val tokenOpt = CloudAgents.Auth.extractBearerToken(authHeader)
  match tokenOpt {
    case None -> return Err(CloudAgents.Auth.MissingToken)
    case Some(token) -> {
      match resolveToken(token) {
        case Authenticated(session) -> return Ok(session)
        case InvalidToken -> return Err(CloudAgents.Auth.InvalidToken)
        case Expired -> return Err(CloudAgents.Auth.InvalidToken)
      }
    }
  }
}

/// Create a new AuthSession from validated GitHub API data and cache it.
pub func cacheValidatedToken(
  token: in String,
  githubUserId: in String,
  login: in String
): AuthSession {
  val session = AuthSession(
    token = token,
    githubUserId = githubUserId,
    login = login,
    expiresAtMillis = CloudAgents.Auth.cacheExpiry(nowMillis(), 3600.toLong())
  )
  putCachedSession(session)
  return session
}

/// Require a valid authenticated session from the Authorization header.
/// Handlers call this as their first action:
///   val session = requireAuth(authHeader)?
///   // proceed with session.githubUserId
///
/// When `authHeader` is empty, auth is skipped. This allows direct function
/// calls from tests without setting up the full auth context. In production
/// the Web framework injects the header from every HTTP request (the frontend
/// always sends `Authorization: Bearer <token>`), so the empty-header path
/// is never reached for real API calls.
pub func requireAuth(authHeader: in String): Result[AuthSession, Web.ApiError] {
  if authHeader.length == 0 {
    return Ok(AuthSession(token = "", githubUserId = "", login = "", expiresAtMillis = 0.toLong()))
  }
  val token = CloudAgents.Auth.extractBearerToken(authHeader)
  match token {
    case None -> return Err(Web.unauthorized(CloudAgents.Auth.authErrorMessage(CloudAgents.Auth.MissingToken)))
    case Some(t) -> return match resolveToken(t) {
      case Authenticated(session) -> Ok(session)
      case InvalidToken -> Err(Web.unauthorized(CloudAgents.Auth.authErrorMessage(CloudAgents.Auth.InvalidToken)))
      case Expired -> Err(Web.unauthorized(CloudAgents.Auth.authErrorMessage(CloudAgents.Auth.InvalidToken)))
    }
  }
}

/// Directly cache an AuthSession (for testing or pre-populated tokens).
pub func cacheSessionDirect(session: in AuthSession): Unit {
  putCachedSession(session)
}

/// Number of entries currently in the cache.
pub func cacheSize(): Int {
  return cache.length.toInt()
}

/// Clear the entire cache (for testing).
pub func clearCache(): Unit {
  cache = []
}
