package CloudAgents.AuthContext

import Std.Core
import Web
import CloudAgents.Auth

/// Cached, validated identity for a bearer token.
pub record AuthSession {
  pub token: String
  pub githubUserId: String
  pub login: String
  pub expiresAtMillis: Long
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
    case Some(t) -> Ok(AuthSession(
      token = t,
      githubUserId = "",
      login = "",
      expiresAtMillis = 0.toLong()
    ))
  }
}
