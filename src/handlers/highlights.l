//! Session highlights: after a run, an operator-configured summarizer model
//! reads the new agent responses and extracts the things a long transcript
//! tends to bury — discoveries, issues opened/actioned/closed, workarounds,
//! reverts, and incomplete/shortcut implementations — so the session UI can
//! surface them in a panel instead of the human re-reading everything.
//!
//! Configuration (all env vars, feature off unless the URL is set):
//!   CLOUD_AGENTS_SUMMARIZER_URL    an OpenAI-compatible chat-completions
//!                                  endpoint (e.g. OpenCode Zen's
//!                                  https://opencode.ai/zen/v1/chat/completions)
//!   CLOUD_AGENTS_SUMMARIZER_MODEL  model id (default "big-pickle" — OpenCode
//!                                  Zen's free tier; any free/cheap model works)
//!   CLOUD_AGENTS_SUMMARIZER_KEY    bearer token; falls back to
//!                                  OPENCODE_ZEN_API_KEY, then to none
//!
//! Extraction is deliberately NOT JSON: the model is asked for one item per
//! line as `kind | title | detail`, which a small line parser handles far
//! more robustly than parsing arbitrary model-emitted JSON in Lyric. Both the
//! request-building and the parsing are pure functions so tests cover them
//! without any network.
//!
//! The refresh is user-originated (a POST the frontend fires when a run
//! finishes) rather than a hook inside CloudAgents.Docker's async run loop:
//! the summarizer call can take tens of seconds, and the run loop is exactly
//! the code path with the known local-val-across-two-awaits hazard
//! (lyric-lang#6249) — keeping this module fully synchronous sidesteps both.
//!
//! DATA SENSITIVITY (#759): enabling the summarizer sends raw agent
//! transcript content — which can include repository code, file paths, and
//! error output — to whatever third-party endpoint the URL points at. Only
//! configure an endpoint you trust with your sessions' repository content,
//! and remember free-tier model providers may retain or train on inputs.
//! docs/session-visibility.md carries the same warning operator-side.
package CloudAgents.Highlights

import Std.Core
import Web
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Streaming
import CloudAgents.Text
import CloudAgents.GitHubApi
import extern System.Environment as Env
import extern System.String as DotNetString

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

/// Small local copy of CloudAgents.Callbacks.requireOwnedSession (that one is
/// package-private): 404 both when the session doesn't exist and when it
/// belongs to someone else — getSession is already owner-scoped.
func requireOwnedSession(sessionId: in String): Result[Unit, Web.ApiError] {
  match getSession(sessionId) {
    case Ok(Some(_)) -> return Ok(())
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

func readEnv(name: in String): String {
  val raw = Env.GetEnvironmentVariable(name)
  if DotNetString.IsNullOrEmpty(raw) {
    return ""
  }
  return raw
}

/// The chat-completions endpoint, "" when the feature is disabled.
pub func summarizerUrl(): String {
  return readEnv("CLOUD_AGENTS_SUMMARIZER_URL")
}

pub func summarizerModel(): String {
  val m = readEnv("CLOUD_AGENTS_SUMMARIZER_MODEL")
  if m.length == 0 {
    return "big-pickle"
  }
  return m
}

func summarizerKey(): String {
  val k = readEnv("CLOUD_AGENTS_SUMMARIZER_KEY")
  if k.length > 0 {
    return k
  }
  return readEnv("OPENCODE_ZEN_API_KEY")
}

// ─── Pure request building / response parsing ─────────────────────────────────
/// Only the LAST maxContentChars of each agent message are summarized — the
/// tail is where an agent's own summary/notes live, and it bounds token cost.
val maxContentChars = 16000

/// At most this many not-yet-scanned agent messages are summarized per
/// refresh call, so one POST can't run the summarizer unboundedly long.
val maxMessagesPerRefresh = 3

/// Wall-clock budget for one refresh call (#760): even under the message
/// cap, three sequential slow summarizer calls could pin a request thread
/// for minutes — stop starting new calls once this much time has elapsed
/// and let the next refresh continue from the cursor.
val maxRefreshMillis = 90000

/// At most this many extracted items are stored per message — a runaway model
/// that emits hundreds of lines can't flood the table.
val maxItemsPerMessage = 20

val extractionInstruction = "You review the output of an AI coding agent's work session. Extract ONLY genuinely notable items a busy human reviewer must not miss: unexpected discoveries, bugs found, issues/tickets opened or closed (with their number/URL), workarounds applied, reverts, incomplete or skipped work, shortcuts taken, and follow-up work the agent suggested. Output ONE item per line, no other text, in exactly this format: kind | short title | one-sentence detail. kind must be one of: discovery, issue, workaround, revert, incomplete, followup. Do not invent items; do not restate routine progress. If nothing is notable, output exactly: none"

/// The OpenAI-compatible chat-completions request body. Pure so tests can
/// assert the exact JSON (jsonEscape is CloudAgents.Streaming's, already
/// battle-tested for control characters/ANSI in agent output).
pub func buildChatRequestJson(model: in String, agentOutput: in String): String {
  return "{\"model\":\"" + CloudAgents.Streaming.jsonEscape(model) +
    "\",\"messages\":[{\"role\":\"user\",\"content\":\"" +
    CloudAgents.Streaming.jsonEscape(
      extractionInstruction + "\n\nAgent session output follows:\n\n" + agentOutput
    ) +
    "\"}]}"
}

func hexVal(c: in String): Int {
  if c >= "0" and c <= "9" {
    return codeUnitDelta(c, "0")
  }
  if c >= "a" and c <= "f" {
    return 10 + codeUnitDelta(c, "a")
  }
  if c >= "A" and c <= "F" {
    return 10 + codeUnitDelta(c, "A")
  }
  return -1
}

@externTarget("System.Char.ConvertToUtf32")
func codeFromChar(s: in String, index: in Int): Int = ()

func codeUnitDelta(c: in String, base: in String): Int {
  return codeFromChar(c, 0) - codeFromChar(base, 0)
}

/// The first JSON string value for `"key"` in `json`, decoded (backslash
/// escapes resolved, including \uXXXX), or "" when absent/malformed. Unlike
/// CloudAgents.Auth.parseJsonString this handles escaped quotes, which LLM
/// message content is full of. Pure and unit-tested.
pub func jsonStringValueOf(json: in String, key: in String): String {
  val target = "\"" + key + "\""
  val pos = CloudAgents.Text.indexOfFrom(json, target, 0)
  if pos < 0 {
    return ""
  }
  val jsonLen = json.length.toInt()
  var i = pos + target.length.toInt()
  // Skip to the opening quote of the value (past ':' and whitespace). A
  // non-string value (object/number/null) means this key isn't a string —
  // give up rather than misparse.
  var opened = false
  while i < jsonLen and not opened {
    val c = json.substring(i, 1)
    if c == "\"" {
      opened = true
    } else if c == ":" or c == " " or c == "\n" or c == "\r" or c == "\t" {
      i = i + 1
    } else {
      return ""
    }
  }
  if not opened {
    return ""
  }
  i = i + 1
  var acc = ""
  while i < jsonLen {
    val c = json.substring(i, 1)
    if c == "\"" {
      return acc
    }
    if c == "\\" and i + 1 < jsonLen {
      val e = json.substring(i + 1, 1)
      if e == "n" {
        acc = acc + "\n"
      } else if e == "t" {
        acc = acc + "\t"
      } else if e == "r" {
        acc = acc + "\r"
      } else if e == "u" and i + 5 < jsonLen {
        val h1 = hexVal(json.substring(i + 2, 1))
        val h2 = hexVal(json.substring(i + 3, 1))
        val h3 = hexVal(json.substring(i + 4, 1))
        val h4 = hexVal(json.substring(i + 5, 1))
        if h1 >= 0 and h2 >= 0 and h3 >= 0 and h4 >= 0 {
          val code = ((h1 * 16 + h2) * 16 + h3) * 16 + h4
          // Lone surrogates can't be materialized as a char — substitute
          // U+FFFD, same policy as GitHubApi.readAllUtf8.
          if code >= 55296 and code <= 57343 {
            acc = acc + CloudAgents.Streaming.charFromCode(65533)
          } else {
            acc = acc + CloudAgents.Streaming.charFromCode(code)
          }
          i = i + 6
          continue
        }
        acc = acc + e
      } else {
        // \" \\ \/ and anything unknown: take the escaped char literally.
        acc = acc + e
      }
      i = i + 2
      continue
    }
    acc = acc + c
    i = i + 1
  }
  return ""
}

/// One extracted item, pre-storage.
pub record ParsedHighlight {
  pub kind: String
  pub title: String
  pub detail: String
}

pub func isValidHighlightKind(k: in String): Bool {
  return k == "discovery" or k == "issue" or k == "workaround" or k == "revert" or k == "incomplete" or k == "followup"
}

func isTrimmable(c: in String): Bool {
  return c == " " or c == "\t" or c == "\r"
}

func trimSpaces(s: in String): String {
  var start = 0
  var stop = s.length.toInt()
  while start < stop and isTrimmable(s.substring(start, 1)) {
    start = start + 1
  }
  while stop > start and isTrimmable(s.substring(stop - 1, 1)) {
    stop = stop - 1
  }
  return s.substring(start, stop - start)
}

@externInstance
@externTarget("System.String.ToLowerInvariant")
func strToLower(s: in String): String = ()

/// Strip a leading list bullet ("- ", "* ") or numbering the model might add
/// despite instructions.
func stripBullet(s: in String): String {
  if s.length >= 2 and (s.substring(0, 2) == "- " or s.substring(0, 2) == "* ") {
    return trimSpaces(s.substring(2, s.length.toInt() - 2))
  }
  return s
}

/// Parse the model's line-based output into validated items. Junk lines,
/// unknown kinds, and empty titles are dropped; "none" yields no items.
/// Capped at maxItemsPerMessage. Pure and unit-tested.
pub func parseHighlightLines(content: in String): slice[ParsedHighlight] {
  var acc: slice[ParsedHighlight] = []
  var lineStart = 0
  val n = content.length.toInt()
  var i = 0
  while i <= n {
    val atEnd = i == n
    if atEnd or content.substring(i, 1) == "\n" {
      val line = stripBullet(trimSpaces(content.substring(lineStart, i - lineStart)))
      lineStart = i + 1
      if line.length > 0 and acc.length < maxItemsPerMessage {
        val p1 = CloudAgents.Text.indexOfFrom(line, "|", 0)
        if p1 > 0 {
          val kind = strToLower(trimSpaces(line.substring(0, p1)))
          val rest = line.substring(p1 + 1, line.length.toInt() - p1 - 1)
          val p2 = CloudAgents.Text.indexOfFrom(rest, "|", 0)
          val title = if p2 >= 0 { trimSpaces(rest.substring(0, p2)) } else { trimSpaces(rest) }
          val detail = if p2 >= 0 { trimSpaces(rest.substring(p2 + 1, rest.length.toInt() - p2 - 1)) } else { "" }
          if isValidHighlightKind(kind) and title.length > 0 {
            acc = acc.append(ParsedHighlight(kind = kind, title = title, detail = detail))
          }
        }
      }
    }
    i = i + 1
  }
  return acc
}

/// The tail of `content`, at most maxContentChars characters.
pub func contentTail(content: in String): String {
  val n = content.length.toInt()
  if n <= maxContentChars {
    return content
  }
  return content.substring(n - maxContentChars, maxContentChars)
}

// ─── Handlers ─────────────────────────────────────────────────────────────────
@generate(Json)
pub record RefreshHighlightsResponse {
  /// "disabled" (no summarizer configured), "ok", or "error".
  pub status: String
  /// How many agent messages were scanned this call (digit text).
  pub scanned: String
  /// How many highlights were stored this call (digit text).
  pub added: String
  /// Human-readable failure detail when status is "error", else "".
  pub detail: String
}

/// GET /api/sessions/{id}/highlights — user-originated.
pub func listHighlightsHandler(id: in String): Result[CloudAgents.Repository.HighlightList, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  requireOwnedSession(id)?
  match CloudAgents.Repository.listHighlights(id) {
    // Constructed unqualified — package-qualified record construction
    // compiles but dies at runtime (docs/lyric/gotchas.md).
    case Ok(hs) -> return Ok(HighlightList(highlights = hs))
    case Err(e) -> return Err(dbError(e))
  }
}

/// POST /api/sessions/{id}/highlights/refresh — user-originated (the frontend
/// fires it after a run completes; there's also a manual refresh button).
/// Summarizes up to maxMessagesPerRefresh not-yet-scanned agent messages,
/// stores what was extracted, and advances the scan cursor. Synchronous by
/// design (see module doc); the caller treats it as best-effort.
pub func refreshHighlightsHandler(id: in String): Result[RefreshHighlightsResponse, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  requireOwnedSession(id)?
  val url = summarizerUrl()
  if url.length == 0 {
    return Ok(RefreshHighlightsResponse(status = "disabled", scanned = "0", added = "0", detail = ""))
  }
  val lastSeq = match CloudAgents.Repository.highlightScanSeq(id) {
    case Ok(s) -> s
    case Err(e) -> return Err(dbError(e))
  }
  val msgs = match CloudAgents.Repository.agentMessagesAfterSeq(id, lastSeq) {
    case Ok(ms) -> ms
    case Err(e) -> return Err(dbError(e))
  }
  var scanned = 0
  var added = 0
  var i = 0
  // Int `System.Environment.TickCount`, NOT a `Long` epoch-millisecond
  // value: a repeated `Long` (Int64) subtract-and-compare crashes the
  // process with a native AccessViolationException (docs/BUILD.md's ninth
  // compiler bug, docs/lyric/gotchas.md's "Long" entry) — this loop was
  // doing exactly that pattern (`nowMillisLong() - startedAt > ...`) once
  // per iteration. `TickCount` wraps to negative roughly every 24.9 days of
  // host uptime; irrelevant here since maxRefreshMillis is 90 seconds.
  val startedAt = Env.get_TickCount()
  while i < msgs.length and scanned < maxMessagesPerRefresh {
    // Wall-clock budget (#760): don't START another summarizer call once the
    // budget is spent — the cursor already reflects everything finished, so
    // the next refresh resumes exactly here.
    if Env.get_TickCount() - startedAt > maxRefreshMillis {
      return Ok(
        RefreshHighlightsResponse(
          status = "ok",
          scanned = toString(scanned),
          added = toString(added),
          detail = "time budget reached; more messages remain — refresh again to continue"
        )
      )
    }
    val m = msgs[i]
    val body = buildChatRequestJson(summarizerModel(), contentTail(m.content))
    val respBody = match CloudAgents.GitHubApi.httpPostJsonWithBearer(url, body, summarizerKey(), "cloud-agents") {
      case Ok(b) -> b
      // Transport/HTTP failure: stop WITHOUT advancing the cursor past this
      // message, so the next refresh retries it. Report what already worked.
      case Err(msg) -> {
        return Ok(
          RefreshHighlightsResponse(
            status = "error",
            scanned = toString(scanned),
            added = toString(added),
            detail = msg
          )
        )
      }
    }
    val content = jsonStringValueOf(respBody, "content")
    // A response with NO string `content` field is a malformed/error
    // envelope (#761) — stop WITHOUT advancing the cursor, exactly like a
    // transport failure, so the message is retried rather than permanently
    // skipped. A legitimate "nothing notable" answer is the non-empty
    // literal "none" (per the prompt), which parses to zero items below and
    // DOES advance the cursor.
    if content.length == 0 {
      return Ok(
        RefreshHighlightsResponse(
          status = "error",
          scanned = toString(scanned),
          added = toString(added),
          detail = "summarizer response carried no message content (malformed or error envelope)"
        )
      )
    }
    val items = parseHighlightLines(content)
    var j = 0
    while j < items.length {
      val it = items[j]
      match CloudAgents.Repository.addHighlight(id, m.id, it.kind, it.title, it.detail) {
        case Ok(_) -> {
          added = added + 1
        }
        case Err(e) -> return Err(dbError(e))
      }
      j = j + 1
    }
    // Advance the cursor past this message even when nothing was extracted —
    // an empty result is a scan outcome, not a retryable failure.
    match CloudAgents.Repository.setHighlightScanSeq(id, m.seq) {
      case Ok(_) -> ()
      case Err(e) -> return Err(dbError(e))
    }
    scanned = scanned + 1
    i = i + 1
  }
  return Ok(RefreshHighlightsResponse(status = "ok", scanned = toString(scanned), added = toString(added), detail = ""))
}
