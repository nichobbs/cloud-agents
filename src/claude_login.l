//! CloudAgents.ClaudeLogin: the pure rules for the refreshable Claude
//! subscription login kept in the vault as `CLAUDE_CREDENTIALS_JSON`
//! (docs/credentials.md "Refreshable Claude login").
//!
//! The vault copy is a seed; the CLI refreshes the login in place on the home
//! volume. Writing a refreshed login back is only safe if a stale copy can
//! never replace a newer one, so the "which is newer" rule lives here, pure and
//! unit-tested, and the store applies it under optimistic concurrency.
//! No Long arithmetic: expiry is only ever compared, never subtracted.
package CloudAgents.ClaudeLogin

import Std.Core

/// The `claudeAiOauth` object of ~/.claude/.credentials.json. Only the fields
/// the comparison needs; any others in the JSON are ignored on parse.
@generate(Json)
pub record ClaudeOauth {
  pub accessToken: String
  pub refreshToken: String
  pub expiresAt: Long
}

@generate(Json)
pub record ClaudeLogin {
  pub claudeAiOauth: ClaudeOauth
}

/// The login in `json`, or None when it is malformed or has no access token.
pub func parseLogin(json: in String): Option[ClaudeLogin] {
  match ClaudeLogin.fromJson(json) {
    case Ok(l) -> {
      if l.claudeAiOauth.accessToken.length > 0 {
        return Some(value = l)
      }
      return None
    }
    case Err(_) -> return None
  }
}

/// Whether `candidate` should replace `current`: it is a usable login and
/// either `current` is not, or it expires strictly later. Equal expiry keeps
/// `current`, so re-reading an unchanged volume never rewrites the vault.
pub func isNewerLogin(candidate: in String, current: in String): Bool {
  val c = match parseLogin(candidate) {
    case Some(l) -> l
    case None -> return false
  }
  val cur = match parseLogin(current) {
    case Some(l) -> l
    case None -> return true
  }
  return c.claudeAiOauth.expiresAt > cur.claudeAiOauth.expiresAt
}
