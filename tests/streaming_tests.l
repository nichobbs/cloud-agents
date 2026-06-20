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

test "toSseChunk JSON-escapes the payload" {
  val chunk = toSseChunk("a\"b")
  assertEqual(chunk, "data: {\"chunk\":\"a\\\"b\"}\n\n", "quote inside chunk is escaped")
}

test "formatLogsAsSse emits one frame per line plus a done event" {
  val body = formatLogsAsSse("one\ntwo")
  val expected =
    "data: {\"chunk\":\"one\"}\n\n" +
    "data: {\"chunk\":\"two\"}\n\n" +
    "event: done\ndata: {}\n\n"
  assertEqual(body, expected, "two lines produce two data frames and a done frame")
}
