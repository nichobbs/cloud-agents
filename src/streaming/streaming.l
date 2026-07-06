package CloudAgents.Streaming

import Std.Core

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
    } else {
      acc = acc + c
    }
    i = i + 1
  }
  return acc
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
