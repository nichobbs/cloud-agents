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

test "sseKeepalive is a data-less SSE comment frame (#499)" {
  // A comment frame the frontend parser skips (no data:/event: line). Its value
  // is the write itself, letting a quiet-stretch disconnect be detected promptly.
  assertEqual(sseKeepalive(), ": keepalive\n\n", "keepalive is a bare SSE comment frame")
  assertTrue(not sseKeepalive().contains("data:"), "keepalive carries no data line")
}

test "nextPollMs doubles the interval, capped at the max (#498)" {
  assertEqualInt(nextPollMs(1000, 5000), 2000, "1s doubles to 2s below the cap")
  assertEqualInt(nextPollMs(2000, 5000), 4000, "2s doubles to 4s below the cap")
  assertEqualInt(nextPollMs(4000, 5000), 5000, "4s would double to 8s but is capped at 5s")
  assertEqualInt(nextPollMs(5000, 5000), 5000, "already at the cap stays at the cap")
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

// ── Phase 6: MCP-callback SSE event framing (docs/phase6-mcp-callbacks.md §5) ─
test "ssePermissionRequest frames a permission_request SSE event" {
  val frame = ssePermissionRequest("req-1", "Bash", "{\"command\":\"ls\"}")
  assertEqual(
    frame,
    "event: permission_request\ndata: {\"id\":\"req-1\",\"toolName\":\"Bash\",\"inputJson\":\"{\\\"command\\\":\\\"ls\\\"}\"}\n\n",
    "permission_request frame is well formed and JSON-escapes the input"
  )
  assertTrue(frame.startsWith("event: permission_request\n"), "distinct event type, not a plain data chunk")
}

test "sseUserQuestion frames a user_question SSE event" {
  val frame = sseUserQuestion("q-1", "Which package?", "[\"A\",\"B\"]")
  assertEqual(
    frame,
    "event: user_question\ndata: {\"id\":\"q-1\",\"question\":\"Which package?\",\"optionsJson\":\"[\\\"A\\\",\\\"B\\\"]\"}\n\n",
    "user_question frame is well formed and JSON-escapes the options"
  )
}

test "sseProgressUpdate frames a progress_update SSE event" {
  val frame = sseProgressUpdate("cloning repo", "10")
  assertEqual(
    frame,
    "event: progress_update\ndata: {\"summary\":\"cloning repo\",\"percentComplete\":\"10\"}\n\n",
    "progress_update frame is well formed"
  )
  assertTrue(sseProgressUpdate("say \"hi\"", "").contains("\\\"hi\\\""), "summary is JSON-escaped")
}
