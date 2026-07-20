@test_module
package CloudAgents.Shim.V2ToolsTests

import Std.Core
import Std.Testing
import Std.Collections
import Std.File
import JsonRpc.Json
import Mcp
import CloudAgents.Shim.V2Transport
import CloudAgents.Shim.V2Tools
import CloudAgents.Shim.V2TestFakes

/// A string at least `minLen` characters long, built by doubling
/// (`s = s + s`, O(n)) rather than Std.String.repeat's single-character
/// loop (O(n^2), unworkably slow at this size — timed out in practice).
func atLeast(minLen: in Int): String {
  var s = "A"
  while s.length < minLen {
    s = s + s
  }
  return s
}

func onlyText(r: in McpToolResult): String {
  match r.content[0] {
    case TextContent(t) -> t
    case _ -> ""
  }
}

// ── request_secret ──────────────────────────────────────────────────────────
test "request_secret tool returns the file path on approval, never the value" {
  val fake = newFakeV2Transport()
  fake.createSecretOk = true
  fake.createSecretBody = "{\"id\":\"sr1\",\"status\":\"pending\"}"
  fake.pollSecretBodies = ["{\"status\":\"approved\",\"value\":\"top-secret-value-xyz\"}"]
  val tool = RequestSecretTool(transport = fake, pollIntervalMs = 1, timeoutMs = 5000)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "name", value = JString(value = "GITHUB_TOKEN")),
        JsonField(name = "reason", value = JString(value = "push a branch"))
      ]
    )
  )
  val result = match tool.call(args) {
    case Ok(r) -> r
    case Err(e) -> panic("call() must not fail for request_secret: " + e)
  }
  assertTrue(not result.isError, "an approved request is not a tool-execution error")
  val text = onlyText(result)
  assertTrue(text.length > 0, "a non-empty path is returned")
  assertTrue(not text.contains("top-secret-value-xyz"), "the tool result text never contains the secret value")

  // Assert the ENTIRE tool result content, not just the text field, never
  // carries the value — guards against a future field addition leaking it.
  var wholeResultContainsValue = false
  for c in result.content {
    match c {
      case TextContent(t) -> {
        if t.contains("top-secret-value-xyz") {
          wholeResultContainsValue = true
        }
      }
      case _ -> ()
    }
  }
  assertTrue(not wholeResultContainsValue, "no content block in the tool result carries the secret value")
}

test "request_secret tool reports a denial as a tool error, not a fabricated path" {
  val fake = newFakeV2Transport()
  fake.createSecretOk = true
  fake.createSecretBody = "{\"id\":\"sr2\",\"status\":\"pending\"}"
  fake.pollSecretBodies = ["{\"status\":\"denied\",\"value\":\"\"}"]
  val tool = RequestSecretTool(transport = fake, pollIntervalMs = 1, timeoutMs = 5000)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "name", value = JString(value = "AWS_KEY")),
        JsonField(name = "reason", value = JString(value = "deploy"))
      ]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result.isError, "a denied request is a tool-execution error")
  assertTrue(onlyText(result).contains("denied"), "error explains the denial: " + onlyText(result))
}

test "request_secret tool reports a timeout as a tool error" {
  val fake = newFakeV2Transport()
  fake.createSecretOk = true
  fake.createSecretBody = "{\"id\":\"sr3\",\"status\":\"pending\"}"
  fake.pollSecretBodies = ["{\"status\":\"pending\",\"value\":\"\"}"]
  val tool = RequestSecretTool(transport = fake, pollIntervalMs = 1, timeoutMs = 3)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "name", value = JString(value = "TOKEN")),
        JsonField(name = "reason", value = JString(value = "x"))
      ]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result.isError, "a timed-out request is reported as a tool-execution failure")
  assertTrue(onlyText(result).contains("timed out"), "error text explains the timeout: " + onlyText(result))
}

test "request_secret tool denies for missing arguments without contacting the host" {
  val fake = newFakeV2Transport()
  val tool = RequestSecretTool(transport = fake, pollIntervalMs = 1, timeoutMs = 5000)

  val missingReason = Some(value = JObject(fields = [JsonField(name = "name", value = JString(value = "X"))]))
  val result1 = match tool.call(missingReason) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result1.isError, "missing 'reason' is a tool error")
  assertTrue(onlyText(result1).contains("reason"), "error names the missing field: " + onlyText(result1))

  val missingName = Some(value = JObject(fields = [JsonField(name = "reason", value = JString(value = "x"))]))
  val result2 = match tool.call(missingName) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result2.isError, "missing 'name' is a tool error")
  assertTrue(onlyText(result2).contains("name"), "error names the missing field: " + onlyText(result2))

  assertEqualInt(fake.pollSecretCallCount, 0, "the host is never contacted for a malformed call")
}

test "requestSecretSchema declares name and reason as required" {
  val schema = requestSecretSchema()
  val schemaJson = writeValue(schema)
  assertTrue(schemaJson.contains("\"name\""), "schema mentions 'name'")
  assertTrue(schemaJson.contains("\"reason\""), "schema mentions 'reason'")
  assertTrue(schemaJson.contains("\"required\""), "schema declares required fields")
}

// ── add_followup_task ─────────────────────────────────────────────────────────
test "add_followup_task tool returns the created id" {
  val fake = newFakeV2Transport()
  fake.createTodoOk = true
  fake.createTodoBody = "{\"id\":\"todo-1\"}"
  val tool = AddFollowupTaskTool(transport = fake)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(
          name = "description",
          value = JString(value = "double-check the migration")
        )
      ]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful create is not a tool-execution error")
  assertTrue(onlyText(result).contains("todo-1"), "result names the created id: " + onlyText(result))
  assertEqual(fake.lastTodoDescription, "double-check the migration", "the description was forwarded")
}

test "add_followup_task tool denies for a missing description without contacting the host" {
  val fake = newFakeV2Transport()
  val tool = AddFollowupTaskTool(transport = fake)

  val args = Some(value = JObject(fields = newList()))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result.isError, "a missing description is a tool error")
  assertTrue(onlyText(result).contains("description"), "error names the missing field: " + onlyText(result))
}

// ── report_artifact ─────────────────────────────────────────────────────────
func writeTempFile(name: in String, content: in String): String {
  val path = "/tmp/cloud-agents-shim-tool-test-" + name
  match Std.File.writeText(path, content) {
    case Ok(_) -> ()
    case Err(e) -> panic("failed to set up temp file " + path)
  }
  return path
}

test "report_artifact tool uploads and returns the artifact id" {
  val fake = newFakeV2Transport()
  fake.uploadArtifactOk = true
  fake.uploadArtifactBody = "{\"id\":\"art-1\"}"
  val tool = ReportArtifactTool(transport = fake)
  val path = writeTempFile("report.txt", "hello artifact")

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "path", value = JString(value = path)),
        JsonField(name = "mimeType", value = JString(value = "text/plain")),
        JsonField(name = "description", value = JString(value = "a report"))
      ]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful upload is not a tool-execution error")
  assertTrue(onlyText(result).contains("art-1"), "result names the created artifact id: " + onlyText(result))
  assertEqual(
    fake.lastUploadFileName,
    "cloud-agents-shim-tool-test-report.txt",
    "fileName is the basename of the local path"
  )
}

test "report_artifact tool rejects an oversize file without contacting the host" {
  val fake = newFakeV2Transport()
  fake.uploadArtifactOk = true
  fake.uploadArtifactBody = "{\"id\":\"should-not-be-used\"}"
  val tool = ReportArtifactTool(transport = fake)

  // Doubling (s = s + s, O(n)) rather than Std.String.repeat's
  // single-character loop (O(n^2) — unworkably slow at this size).
  val path = writeTempFile("big.bin", atLeast(8388609))

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "path", value = JString(value = path)),
        JsonField(name = "mimeType", value = JString(value = "application/octet-stream"))
      ]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result.isError, "an oversize file is a tool error")
  assertTrue(onlyText(result).contains("8 MiB"), "error explains the size cap: " + onlyText(result))
  assertEqualInt(fake.uploadArtifactCallCount, 0, "the host is never contacted for an oversize file")
}

test "report_artifact tool denies for missing required arguments without contacting the host" {
  val fake = newFakeV2Transport()
  val tool = ReportArtifactTool(transport = fake)

  val missingMimeType = Some(value = JObject(fields = [JsonField(name = "path", value = JString(value = "/tmp/x"))]))
  val result1 = match tool.call(missingMimeType) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result1.isError, "missing 'mimeType' is a tool error")
  assertTrue(onlyText(result1).contains("mimeType"), "error names the missing field: " + onlyText(result1))

  val missingPath = Some(
    value = JObject(fields = [JsonField(name = "mimeType", value = JString(value = "text/plain"))])
  )
  val result2 = match tool.call(missingPath) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result2.isError, "missing 'path' is a tool error")
  assertTrue(onlyText(result2).contains("path"), "error names the missing field: " + onlyText(result2))

  assertEqualInt(fake.uploadArtifactCallCount, 0, "the host is never contacted for a malformed call")
}
