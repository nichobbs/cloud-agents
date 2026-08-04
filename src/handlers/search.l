//! src/handlers/search.l — CloudAgents.Search: full-text search across a
//! user's own message transcripts (docs/phase9-message-search.md), backed by
//! the FTS5 index CloudAgents.Db/CloudAgents.Repository maintain
//! (`messages_fts`, migration 0028_message_search).
package CloudAgents.Search

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Sqlite

val maxSearchTermLen = 200

/// Capped and never client-supplied (CloudAgents.Db.searchMessagesSql's own
/// doc comment explains why: an attacker-controlled LIMIT would be a
/// resource-exhaustion vector) — every call from this file passes this fixed
/// constant.
val maxSearchResults = 50

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

/// The whitespace this hand-rolled tokenizer splits words on: space, tab,
/// newline, carriage return.
func isSpace(c: in String): Bool {
  return c == " " or c == "\t" or c == "\n" or c == "\r"
}

/// Escape one word for safe embedding as an FTS5 "quoted-prefix" token:
/// `"word"*`. Doubling any embedded `"` (FTS5's own quoting rule — mirrors
/// how sqlLiteral doubles `'` for SQL string literals) and wrapping the word
/// in double quotes disables every FTS5 query operator (AND/OR/NOT/`*`,
/// column filters like `content:`, etc.) for its contents, treating it as
/// pure literal text to match. The trailing `*` sits OUTSIDE the quotes —
/// FTS5 treats a quoted string immediately followed by `*` as a prefix query
/// on that literal token, which is what still gives useful prefix matching
/// ("sched" finds "scheduled") without reopening operator interpretation
/// inside the quotes. Confirmed against the real vaulted SQLite build (see
/// CloudAgents.Db.searchMessagesSql's module comment) with hostile inputs:
/// embedded quotes, bare AND/OR/NOT, colons, and a literal
/// quote-injection attempt (`a" OR content MATCH "x`) all come back as
/// inert literal text, never reinterpreted as query syntax.
func fts5EscapeWord(word: in String): String {
  var escaped = ""
  var i = 0
  while i < word.length {
    val c = word.substring(i, 1)
    if c == "\"" {
      escaped = escaped + "\"\""
    } else {
      escaped = escaped + c
    }
    i = i + 1
  }
  return "\"" + escaped + "\"*"
}

/// Build a safe FTS5 MATCH expression from raw user search text: split on
/// whitespace, escape+quote+prefix each word (fts5EscapeWord), space-join
/// them (FTS5's implicit AND between space-separated terms). Hand-rolled
/// character scan rather than `String.split()` — the latter has no proven
/// working precedent anywhere in this codebase (docs/lyric/gotchas.md
/// catalogs several documented-but-broken String methods), so this mirrors
/// the already-proven scan idiom in CloudAgents.Text.indexOfFrom instead.
///
/// Returns "" for a term with no actual words (empty or all whitespace) —
/// callers MUST reject that before it reaches the database: an empty FTS5
/// MATCH expression is itself a syntax error at the database, confirmed
/// directly (`fts5: syntax error near ''`), not just theoretically possible.
pub func buildFts5MatchExpr(term: in String): String {
  val termLen = term.length.toInt()
  var result = ""
  var wordStart = -1
  var i = 0
  while i < termLen {
    if isSpace(term.substring(i, 1)) {
      if wordStart >= 0 {
        val word = term.substring(wordStart, i - wordStart)
        result = if result.length == 0 { fts5EscapeWord(word) } else { result + " " + fts5EscapeWord(word) }
        wordStart = -1
      }
    } else {
      if wordStart < 0 {
        wordStart = i
      }
    }
    i = i + 1
  }
  if wordStart >= 0 {
    val word = term.substring(wordStart, termLen - wordStart)
    result = if result.length == 0 { fts5EscapeWord(word) } else { result + " " + fts5EscapeWord(word) }
  }
  return result
}

/// GET /api/search/messages?q=... — full-text search across every message
/// in the caller's own sessions, newest first, capped at maxSearchResults.
pub func searchMessagesHandler(term: in String): Result[CloudAgents.Repository.MessageList, Web.ApiError] {
  val trimmed = term.trim()
  if trimmed.length == 0 {
    return Err(Web.badRequest("q is required"))
  }
  if trimmed.length > maxSearchTermLen {
    return Err(Web.badRequest("q is too long (max " + toString(maxSearchTermLen) + " characters)"))
  }
  val matchExpr = buildFts5MatchExpr(trimmed)
  match CloudAgents.Repository.searchMessages(CloudAgents.Auth.currentUserId(), matchExpr, maxSearchResults) {
    case Ok(messages) -> return Ok(value = CloudAgents.Repository.MessageList(messages = messages))
    case Err(e) -> return Err(dbError(e))
  }
}
