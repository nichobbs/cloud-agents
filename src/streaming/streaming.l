package CloudAgents.Streaming

import Std.Core
import CloudAgents.Text

/// Server-Sent Events helpers for Phase 1 streaming.
///
/// Each line of container stdout is wrapped as an SSE `data:` frame carrying a
/// small JSON object: `data: {"chunk":"<line>"}\n\n`.
///
/// ANSI escape codes are intentionally *not* stripped here. The Phase 1 design
/// (docs/phase1-core-loop.md) allows ANSI handling to happen on the frontend
/// via `ansi_up`, which keeps the backend free of the ESC-byte handling that
/// Lyric string literals do not express cleanly. The frontend renders colour;
/// the backend only frames and JSON-escapes.
/// Escape a string so it is safe to embed inside a JSON string literal.
pub func jsonEscape(

  s: in String,
): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    if c == "\"" {
      acc = acc + "\\\""
    } else if c == "\\" {
      acc = acc + "\\\\"
    } else if c == "\n" {
      acc = acc + "\\n"
    } else if c == "\r" {
      acc = acc + "\\r"
    } else if c == "\t" {
      acc = acc + "\\t"
    } else if CloudAgents.Text.isControlChar(c) {
      acc = acc + controlEscape(c)
    } else {
      acc = acc + c
    }
    i = i + 1
  }
  return acc
}

// ── Control characters ────────────────────────────────────────────────────────
//
// JSON forbids raw control characters (U+0000–U+001F) inside string literals;
// browsers' JSON.parse rejects frames containing them, and the frontend then
// silently drops the "malformed" chunk. ESC (0x1B) is exactly such a byte, so
// without this every ANSI-coloured log line vanished from the stream. Lyric
// string literals cannot express these bytes, so the helpers go through the
// BCL. The single-char control-character test lives in CloudAgents.Text
// (isControlChar); the char<->code-point externs below are streaming-specific.
/// The single-character string for a Unicode code point. Exposed so tests can
/// construct control characters that Lyric literals cannot express.
@externTarget("System.Char.ConvertFromUtf32")
pub func charFromCode(code: in Int): String = ()

/// The Unicode code point of the character at `index` in `s`. The inverse of
/// charFromCode, used to escape a control char in O(1) rather than scanning all
/// 32 control codes (#171).
@externTarget("System.Char.ConvertToUtf32")
func codeFromChar(s: in String, index: in Int): Int = ()

func hexDigit(n: in Int): String {
  if n == 10 {
    return "a"
  }
  if n == 11 {
    return "b"
  }
  if n == 12 {
    return "c"
  }
  if n == 13 {
    return "d"
  }
  if n == 14 {
    return "e"
  }
  if n == 15 {
    return "f"
  }
  return toString(n)
}

/// The `\u00XX` escape for a control character (code point below 0x20).
func controlEscape(c: in String): String {
  // Read the code point directly (O(1)) instead of scanning charFromCode for
  // all 32 control codes to find the one that matches `c` (#171).
  val code = codeFromChar(c, 0)
  if code < 16 {
    return "\\u000" + hexDigit(code)
  }
  return "\\u001" + hexDigit(code - 16)
}

/// Wrap a single output line as one SSE data frame.
pub func toSseChunk(line: in String): String {
  return "data: {\"chunk\":\"" + jsonEscape(line) + "\"}\n\n"
}

/// The portion of `logs` past `offset` — the newly-produced output the
/// streaming run loop should write. Empty when the caller is caught up
/// (`offset >= length`). Pure and unit-tested so the loop's delta/offset math
/// (the part most prone to an off-by-one) has coverage without Docker (#486).
///
/// Surrogate-pair safety (#493): the caller only ever passes an `offset` equal
/// to a PRIOR full length of the (append-only-growing) log, and the delta runs
/// to the current full length. A UTF-16 surrogate pair is contiguous inside the
/// string, so it lies wholly on one side of any such full-length boundary — the
/// cut can't split an emoji across two frames unless the log itself contained a
/// lone surrogate, which UTF-8-decoded container output does not produce
/// (invalid sequences decode to U+FFFD, not a bare surrogate).
pub func outputDelta(logs: in String, offset: in Int): String {
  val total = logs.length.toInt()
  if offset >= total {
    return ""
  }
  return logs.substring(offset, total - offset)
}

/// An SSE comment frame ("`: ...`") used as a keepalive during quiet stretches
/// of a run (#499). It carries no `data:`/`event:` line, so the frontend's frame
/// parser skips it (`if (!dataStr) continue`) — it never reaches the transcript.
/// Its purpose is the WRITE, not the payload: the run loop only discovers a
/// vanished client on an attempted `writeChunk`, and writes otherwise happen
/// only when there is new output. Emitting a keepalive on each quiet tick means a
/// client that disconnects mid-silence is detected within a poll interval instead
/// of lingering until the next output chunk or the 30-minute hard cap.
pub func sseKeepalive(): String {
  return ": keepalive\n\n"
}

/// Terminal SSE frame signalling the stream is complete.
pub func sseDone(): String {
  return "event: done\ndata: {}\n\n"
}

/// Terminal SSE frame signalling the run FAILED after the response was already
/// committed (200 + headers sent, so an HTTP error status is no longer
/// possible). Emitted as a distinct `event: error` frame — not a plain data
/// chunk — so the frontend's stream reader can recognise it and mark the send
/// failed (#485), rather than folding a failed run into the transcript as if it
/// succeeded.
pub func sseError(message: in String): String {
  return "event: error\ndata: {\"error\":\"" + jsonEscape(message) + "\"}\n\n"
}

/// Terminal SSE frame carrying the id of the persisted agent message, so the
/// client can anchor comments and todos to this response.
pub func sseDoneWithMessage(messageId: in String): String {
  return "event: done\ndata: {\"messageId\":\"" + jsonEscape(messageId) + "\"}\n\n"
}

/// Next poll interval after a QUIET streaming tick: double the current interval,
/// capped at `maxMs`. The run loop resets to its floor itself the moment output
/// arrives, so this only ever grows the interval — pure and unit-tested so the
/// backoff math has coverage without Docker (#495/#498).
pub func nextPollMs(current: in Int, maxMs: in Int): Int {
  val next = current * 2
  if next > maxMs {
    return maxMs
  }
  return next
}

// ─── Phase 6: MCP-callback SSE events ────────────────────────────────────────
//
// docs/phase6-mcp-callbacks.md §5: three new event types pushed on the same
// session output stream as the existing `data:`/`done`/`error` frames above —
// `permission_request` / `user_question` when the container creates one
// (CloudAgents.Callbacks), and `progress_update` on a report_progress call.
// Emission itself happens from CloudAgents.Docker's existing per-run poll
// loop (the only place holding an open ResponseWriter for a session's active
// stream); these are the pure framing functions, unit-tested exactly like
// toSseChunk/sseDone/sseError above.
/// A newly created permission request, for the human to answer in the UI.
/// `inputJson` is the tool's pending input, passed through opaque and
/// JSON-escaped like every other string field on this stream.
pub func ssePermissionRequest(id: in String, toolName: in String, inputJson: in String): String {
  return "event: permission_request\ndata: {\"id\":\"" + jsonEscape(id) + "\",\"toolName\":\"" + jsonEscape(toolName) +
    "\",\"inputJson\":\"" +
    jsonEscape(inputJson) +
    "\"}\n\n"
}

/// A newly created user question (ask_user MCP tool). `optionsJson` is "" for
/// a free-text question or a JSON array of choices for multiple-choice.
pub func sseUserQuestion(id: in String, question: in String, optionsJson: in String): String {
  return "event: user_question\ndata: {\"id\":\"" + jsonEscape(id) + "\",\"question\":\"" + jsonEscape(question) +
    "\",\"optionsJson\":\"" +
    jsonEscape(optionsJson) +
    "\"}\n\n"
}

/// A fire-and-forget progress report (report_progress MCP tool).
/// `percentComplete` is "" when the tool call omitted it.
pub func sseProgressUpdate(summary: in String, percentComplete: in String): String {
  return "event: progress_update\ndata: {\"summary\":\"" + jsonEscape(summary) + "\",\"percentComplete\":\"" +
    jsonEscape(percentComplete) +
    "\"}\n\n"
}

// ─── Phase 6 §7: v2 MCP-callback SSE events ──────────────────────────────────
//
// docs/phase6-mcp-callbacks.md §7. `secret_request` deliberately carries only
// `name` and `reason` — the SAME two fields CloudAgents.Callbacks accepts
// from the container's create call — never a value, so it is safe to stream
// unconditionally even before a human has decided anything.
/// A newly created secret request, for the human to approve or deny in the
/// UI. Never carries the credential value.
pub func sseSecretRequest(id: in String, name: in String, reason: in String): String {
  return "event: secret_request\ndata: {\"id\":\"" + jsonEscape(id) + "\",\"name\":\"" + jsonEscape(name) +
    "\",\"reason\":\"" +
    jsonEscape(reason) +
    "\"}\n\n"
}

/// A newly uploaded artifact (report_artifact MCP tool). Carries only the
/// metadata the artifact list already exposes — never the file's bytes.
pub func sseArtifactReported(id: in String, fileName: in String, mimeType: in String): String {
  return "event: artifact_reported\ndata: {\"id\":\"" + jsonEscape(id) + "\",\"fileName\":\"" + jsonEscape(fileName) +
    "\",\"mimeType\":\"" +
    jsonEscape(mimeType) +
    "\"}\n\n"
}

// ─── Phase 7 §5: notify SSE event ─────────────────────────────────────────────
//
// docs/phase7-autonomy.md §5. A fire-and-forget push from the notify MCP
// tool, forwarded the same way artifact_reported/secret_request are — by
// CloudAgents.Docker's per-run poll loop.
/// A newly created notification (notify MCP tool). `level` is one of
/// info/done/blocked.
pub func sseNotification(id: in String, level: in String, summary: in String): String {
  return "event: notification\ndata: {\"id\":\"" + jsonEscape(id) + "\",\"level\":\"" + jsonEscape(level) +
    "\",\"summary\":\"" +
    jsonEscape(summary) +
    "\"}\n\n"
}

// (The whole-log framing helpers logsToFrames/formatLogsAsSse/
// formatLogsAsSseWithId were removed as dead code (#492): they buffered a
// completed run's captured log into one SSE body, which the streaming handler
// (streamSessionMessage writing per-delta toSseChunk frames + a terminal
// sseDone/sseDoneWithMessage) replaced. Nothing in src/ called them once
// sendMessage was migrated.)
