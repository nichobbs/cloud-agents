@test_module
package CloudAgents.StreamingTests

import Std.Core
import Std.Testing
import CloudAgents.Streaming

test "jsonEscape escapes quotes and backslashes" {
  assertEqual(jsonEscape("plain"), "plain", "plain text is unchanged")
  assertEqual(jsonEscape("say \"hi\""), "say \\\"hi\\\"", "double quotes are escaped")
  assertEqual(jsonEscape("a\\b"), "a\\\\b", "backslashes are escaped")
  assertEqual(jsonEscape("line\nbreak"), "line\\nbreak", "newlines are escaped")
}

test "toSseChunk wraps a line as an SSE data frame" {
  val chunk = toSseChunk("hello")
  assertEqual(chunk, "data: {\"chunk\":\"hello\"}\n\n", "frame is well formed")
}

test "outputDelta returns only the bytes past the offset (#486)" {
  assertEqual(outputDelta("hello world", 6), "world", "delta is the log past the offset")
  assertEqual(outputDelta("abc", 0), "abc", "offset 0 returns the whole log")
  assertEqual(outputDelta("abc", 3), "", "offset == length -> caught up, empty")
  assertEqual(outputDelta("abc", 5), "", "offset past the end -> empty, no overrun")
  assertEqual(outputDelta("", 0), "", "empty log -> empty delta")
}

test "sseError frames a committed-stream failure as an error event (#485)" {
  assertEqual(
    sseError("boom"),
    "event: error\ndata: {\"error\":\"boom\"}\n\n",
    "error frame is a distinct SSE event, not a data chunk"
  )
  assertTrue(sseError("a \"quote\"").contains("\\\"quote\\\""), "error message is JSON-escaped")
}

test "toSseChunk JSON-escapes the payload" {
  val chunk = toSseChunk("a\"b")
  assertEqual(chunk, "data: {\"chunk\":\"a\\\"b\"}\n\n", "quote inside chunk is escaped")
}

test "jsonEscape escapes raw control characters as unicode escapes" {
  // JSON forbids raw control chars in strings; browsers' JSON.parse rejects
  // them, and the frontend then drops the whole frame. ESC (0x1B) — the ANSI
  // colour introducer — is the case that used to eat every coloured line.
  assertEqual(jsonEscape(charFromCode(27)), "\\u001b", "ESC escapes to \\u001b")
  assertEqual(jsonEscape(charFromCode(1) + "x"), "\\u0001x", "SOH followed by text")
  assertEqual(jsonEscape("a" + charFromCode(8) + "b"), "a\\u0008b", "backspace mid-string")
  assertEqual(jsonEscape("line\nbreak"), "line\\nbreak", "newline still uses the short escape")
}

test "formatLogsAsSse emits one frame per line plus a done event" {
  val body = formatLogsAsSse("one\ntwo")
  val expected =
    "data: {\"chunk\":\"one\"}\n\n" +
    "data: {\"chunk\":\"two\"}\n\n" +
    "event: done\ndata: {}\n\n"
  assertEqual(body, expected, "two lines produce two data frames and a done frame")
}
