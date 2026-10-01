//! src/handlers/search.l — CloudAgents.Search: full-text search across a
//! user's own message transcripts (docs/phase9-message-search.md), backed by
//! the Postgres full-text index on `messages.search_vector`
//! (`CloudAgents.PgStore.Messages.searchMessages`).
package CloudAgents.Search

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Db

val maxSearchTermLen = 200

/// Capped and never client-supplied (CloudAgents.Db.searchMessagesSql's own
/// doc comment explains why: an attacker-controlled LIMIT would be a
/// resource-exhaustion vector) — every call from this file passes this fixed
/// constant.
val maxSearchResults = 50

func dbError(e: in CloudAgents.Db.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Db.dbErrorMessage(e))
}

/// GET /api/search/messages?q=... response: the (possibly capped) matches,
/// newest first, plus whether the true match count exceeded maxSearchResults
/// — #908, so the frontend can tell the user results were cut off instead of
/// silently rendering a partial list as if it were complete.
pub record SearchMessagesResult {
  pub messages: slice[CloudAgents.Repository.Message]
  pub truncated: Bool
}

/// GET /api/search/messages?q=... — full-text search across every message
/// in the caller's own sessions, newest first, capped at maxSearchResults.
pub func searchMessagesHandler(term: in String): Result[SearchMessagesResult, Web.ApiError] {
  val trimmed = term.trim()
  if trimmed.length == 0 {
    return Err(Web.badRequest("q is required"))
  }
  if trimmed.length > maxSearchTermLen {
    return Err(Web.badRequest("q is too long (max " + toString(maxSearchTermLen) + " characters)"))
  }
  // Fetch one extra row beyond the cap: its mere presence (not its content)
  // is the truncation signal, so it's dropped below rather than ever
  // reaching the response.
  match CloudAgents.Repository.searchMessages(CloudAgents.Auth.requestScope(), trimmed, maxSearchResults + 1) {
    case Ok(rows) -> {
      val truncated = rows.length.toInt() > maxSearchResults
      var messages: slice[CloudAgents.Repository.Message] = []
      var i = 0
      while i < rows.length.toInt() and i < maxSearchResults {
        messages = messages.append(rows[i])
        i = i + 1
      }
      return Ok(value = SearchMessagesResult(messages = messages, truncated = truncated))
    }
    case Err(e) -> return Err(dbError(e))
  }
}
