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

/// Terminal SSE frame signalling the stream is complete.
pub func sseDone(): String {
  return "event: done\ndata: {}\n\n"
}

/// Terminal SSE frame carrying the id of the persisted agent message, so the
/// client can anchor comments and todos to this response.
pub func sseDoneWithMessage(messageId: in String): String {
  return "event: done\ndata: {\"messageId\":\"" + jsonEscape(messageId) + "\"}\n\n"
}

/// Scan `logs` line-by-line and produce one SSE data frame per line.
/// CR is swallowed so CRLF output does not leave trailing carriage returns.
func logsToFrames(logs: in String): String {
  var acc = ""
  var line = ""
  var i = 0
  while i < logs.length {
    val c = logs.substring(i, 1)
    if c == "\n" {
      acc = acc + toSseChunk(line)
      line = ""
    } else if c == "\r" {
      // swallow
    } else {
      line = line + c
    }
    i = i + 1
  }
  if line.length > 0 {
    acc = acc + toSseChunk(line)
  }
  return acc
}

/// Convert a block of captured logs into an SSE stream body: one frame per
/// line, terminated by a `done` event.
pub func formatLogsAsSse(logs: in String): String {
  return logsToFrames(logs) + sseDone()
}

/// Like `formatLogsAsSse`, but the terminal `done` frame carries the persisted
/// agent message id (see CloudAgents.Repository.addMessage).
pub func formatLogsAsSseWithId(logs: in String, messageId: in String): String {
  return logsToFrames(logs) + sseDoneWithMessage(messageId)
}
