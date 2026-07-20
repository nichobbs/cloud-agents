@test_module
package CloudAgents.Shim.ToolsTests

import Std.Core
import Std.Testing
import Std.Collections
import JsonRpc.Json
import Mcp
import CloudAgents.Shim.Transport
import CloudAgents.Shim.Tools
import CloudAgents.Shim.TestFakes

func onlyText(r: in McpToolResult): String {
  match r.content[0] {
    case TextContent(t) -> t
    case _ -> ""
  }
}

// ── request_permission: the exact --permission-prompt-tool payload shape ────
test "request_permission tool returns the exact Claude Code allow payload shape" {
  val fake = newFakeTransport()
  fake.createPermissionOk = true
  fake.createPermissionBody = "{\"id\":\"r1\",\"status\":\"pending\"}"
  fake.pollPermissionBodies = ["{\"status\":\"allowed\",\"updatedInputJson\":\"\",\"note\":\"\"}"]
  val tool = RequestPermissionTool(transport = fake, pollIntervalMs = 1, timeoutMs = 5000)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "tool_use_id", value = JString(value = "tu_1")),
        JsonField(name = "tool_name", value = JString(value = "Bash")),
        JsonField(
          name = "input",
          value = JObject(
            fields = [JsonField(name = "command", value = JString(value = "ls"))]
          )
        )
      ]
    )
  )

  val result = match tool.call(args) {
    case Ok(r) -> r
    case Err(e) -> panic("call() must not fail for request_permission: " + e)
  }
  assertTrue(not result.isError, "an allow decision is not a tool-execution error")
  assertEqualInt(result.content.count, 1, "exactly one text content block")
  assertEqual(
    onlyText(result),
    "{\"behavior\":\"allow\",\"updatedInput\":{\"command\":\"ls\"}}",
    "exact allow payload shape Claude Code expects"
  )
}

test "request_permission tool returns the exact Claude Code deny payload shape" {
  val fake = newFakeTransport()
  fake.createPermissionOk = true
  fake.createPermissionBody = "{\"id\":\"r2\",\"status\":\"pending\"}"
  fake.pollPermissionBodies = ["{\"status\":\"denied\",\"updatedInputJson\":\"\",\"note\":\"too risky\"}"]
  val tool = RequestPermissionTool(transport = fake, pollIntervalMs = 1, timeoutMs = 5000)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "tool_name", value = JString(value = "Bash")),
        JsonField(
          name = "input",
          value = JObject(
            fields = [
              JsonField(
                name = "command",
                value = JString(value = "rm -rf /")
              )
            ]
          )
        )
      ]
    )
  )

  val result = match tool.call(args) {
    case Ok(r) -> r
    case Err(e) -> panic("call() must not fail for request_permission: " + e)
  }
  assertTrue(
    not result.isError,
    "a deny decision is still not a tool-execution error — it's a well-formed protocol response"
  )
  assertEqual(
    onlyText(result),
    "{\"behavior\":\"deny\",\"message\":\"too risky\"}",
    "exact deny payload shape Claude Code expects"
  )
}

test "request_permission tool applies the host's updatedInput override" {
  val fake = newFakeTransport()
  fake.createPermissionOk = true
  fake.createPermissionBody = "{\"id\":\"r3\",\"status\":\"pending\"}"
  fake.pollPermissionBodies = [
    "{\"status\":\"allowed\",\"updatedInputJson\":\"{\\\"command\\\":\\\"ls -la\\\"}\",\"note\":\"\"}"
  ]
  val tool = RequestPermissionTool(transport = fake, pollIntervalMs = 1, timeoutMs = 5000)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "tool_name", value = JString(value = "Bash")),
        JsonField(
          name = "input",
          value = JObject(
            fields = [JsonField(name = "command", value = JString(value = "ls"))]
          )
        )
      ]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertEqual(
    onlyText(result),
    "{\"behavior\":\"allow\",\"updatedInput\":{\"command\":\"ls -la\"}}",
    "the human's edited input is echoed back, not the original"
  )
}

test "request_permission tool denies with a message when 'tool_name' is missing" {
  val fake = newFakeTransport()
  val tool = RequestPermissionTool(transport = fake, pollIntervalMs = 1, timeoutMs = 5000)

  val args = Some(value = JObject(fields = [JsonField(name = "input", value = JObject(fields = newList()))]))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a validation deny is still a well-formed protocol response, not an isError result")
  assertTrue(
    onlyText(result).contains("\"behavior\":\"deny\""),
    "missing tool_name still produces a well-formed deny payload"
  )
  assertTrue(onlyText(result).contains("tool_name"), "deny message names the missing field: " + onlyText(result))
}

test "request_permission denies when 'input' is missing" {
  val fake = newFakeTransport()
  val tool = RequestPermissionTool(transport = fake, pollIntervalMs = 1, timeoutMs = 1000)

  val args = Some(value = JObject(fields = [JsonField(name = "tool_name", value = JString(value = "Bash"))]))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a deny payload is a successful tool result, not a protocol error")
  assertTrue(onlyText(result).contains("\"behavior\":\"deny\""), "missing 'input' fails closed to deny (#538)")
  assertTrue(onlyText(result).contains("input"), "deny message names the missing field: " + onlyText(result))
  assertEqualInt(fake.pollPermissionCallCount, 0, "the host is never contacted for a malformed call")
}

test "request_permission tool denies for safety when the host's updatedInput is malformed" {
  val fake = newFakeTransport()
  fake.createPermissionOk = true
  fake.createPermissionBody = "{\"id\":\"r4\",\"status\":\"pending\"}"
  fake.pollPermissionBodies = ["{\"status\":\"allowed\",\"updatedInputJson\":\"not json\",\"note\":\"\"}"]
  val tool = RequestPermissionTool(transport = fake, pollIntervalMs = 1, timeoutMs = 5000)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "tool_name", value = JString(value = "Bash")),
        JsonField(name = "input", value = JObject(fields = newList()))
      ]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(onlyText(result).contains("\"behavior\":\"deny\""), "a malformed updatedInput fails closed to deny")
  assertTrue(onlyText(result).contains("malformed"), "deny message explains why: " + onlyText(result))
}

// ── ask_user ─────────────────────────────────────────────────────────────────
test "ask_user tool returns plain answer text, not a JSON envelope" {
  val fake = newFakeTransport()
  fake.createQuestionOk = true
  fake.createQuestionBody = "{\"id\":\"q1\"}"
  fake.pollQuestionBodies = ["{\"status\":\"answered\",\"answer\":\"Postgres\"}"]
  val tool = AskUserTool(transport = fake, pollIntervalMs = 1, timeoutMs = 5000)

  val args = Some(value = JObject(fields = [JsonField(name = "question", value = JString(value = "Which database?"))]))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful answer is not a tool-execution error")
  assertEqual(onlyText(result), "Postgres", "the raw answer text, no JSON wrapping")
}

test "ask_user tool surfaces a timeout as an isError result" {
  val fake = newFakeTransport()
  fake.createQuestionOk = true
  fake.createQuestionBody = "{\"id\":\"q2\"}"
  fake.pollQuestionBodies = ["{\"status\":\"pending\",\"answer\":\"\"}"]
  val tool = AskUserTool(transport = fake, pollIntervalMs = 1, timeoutMs = 3)

  val args = Some(value = JObject(fields = [JsonField(name = "question", value = JString(value = "Proceed?"))]))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(
    result.isError,
    "a timed-out question is reported as a tool-execution failure per the MCP isError convention"
  )
  assertTrue(onlyText(result).contains("timed out"), "error text explains the timeout: " + onlyText(result))
}

// ── report_progress ──────────────────────────────────────────────────────────
test "report_progress tool always reports success, even when the transport fails" {
  val fake = newFakeTransport()
  fake.reportProgressOk = false
  fake.reportProgressError = "network down"
  val tool = ReportProgressTool(transport = fake)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "summary", value = JString(value = "cloning repo")),
        JsonField(name = "percentComplete", value = JInt(value = 10))
      ]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "fire-and-forget: a transport failure never surfaces as a tool error")
  assertEqualInt(fake.reportProgressCallCount, 1, "the transport was still called")
}

test "report_progress truncates a fractional percentComplete instead of dropping it" {
  val fake = newFakeTransport()
  val tool = ReportProgressTool(transport = fake)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "summary", value = JString(value = "building")),
        JsonField(name = "percentComplete", value = JFloat(value = 62.5))
      ]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "fractional progress is accepted")
  assertEqual(fake.lastProgressPercent, "62", "62.5 truncates to a whole percent (#537), not the empty string")
}
