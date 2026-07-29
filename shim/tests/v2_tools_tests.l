@test_module
package CloudAgents.Shim.V2ToolsTests

import Std.Core
import Std.Testing
import Std.Collections
import Std.Environment
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
  Std.Environment.setVar("CLOUD_AGENTS_SECRETS_DIR", Std.Environment.currentDirectory() + "/.lyric-test-secrets")
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

test "report_artifact tool forwards an optional 'scope' argument, defaulting to '' when omitted (docs/phase7 §6)" {
  val fake = newFakeV2Transport()
  fake.uploadArtifactOk = true
  fake.uploadArtifactBody = "{\"id\":\"art-repo-1\"}"
  val tool = ReportArtifactTool(transport = fake)
  val path = writeTempFile("repo-scoped.txt", "durable across sessions")

  val argsWithScope = Some(
    value = JObject(
      fields = [
        JsonField(name = "path", value = JString(value = path)),
        JsonField(name = "mimeType", value = JString(value = "text/plain")),
        JsonField(name = "scope", value = JString(value = "repo"))
      ]
    )
  )
  val result = match tool.call(argsWithScope) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful repo-scoped upload is not a tool-execution error")
  assertEqual(fake.lastUploadArtifactScope, "repo", "the 'scope' argument is forwarded to the transport")

  val argsWithoutScope = Some(
    value = JObject(
      fields = [
        JsonField(name = "path", value = JString(value = path)),
        JsonField(name = "mimeType", value = JString(value = "text/plain"))
      ]
    )
  )
  match tool.call(argsWithoutScope) {
    case Ok(r) -> assertTrue(not r.isError, "omitting 'scope' still succeeds")
    case Err(e) -> panic("unexpected Err: " + e)
  }
  assertEqual(fake.lastUploadArtifactScope, "", "omitting 'scope' defaults to '' (today's exact behavior)")
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

// ── remember / recall (phase 7 §4) ────────────────────────────────────────────
test "remember tool forwards key+value and returns a confirmation" {
  val fake = newFakeV2Transport()
  fake.rememberOk = true
  fake.rememberBody = "{\"key\":\"build\"}"
  val tool = RememberTool(transport = fake)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "key", value = JString(value = "build")),
        JsonField(name = "value", value = JString(value = "make lyric"))
      ]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful remember is not a tool error")
  assertTrue(onlyText(result).contains("build"), "confirmation names the key: " + onlyText(result))
  assertEqual(fake.lastRememberKey, "build", "the key was forwarded")
  assertEqual(fake.lastRememberValue, "make lyric", "the value was forwarded")
}

test "remember tool denies for a missing value without contacting the host" {
  val fake = newFakeV2Transport()
  val tool = RememberTool(transport = fake)

  val missingValue = Some(value = JObject(fields = [JsonField(name = "key", value = JString(value = "k"))]))
  val result = match tool.call(missingValue) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result.isError, "missing 'value' is a tool error")
  assertTrue(onlyText(result).contains("value"), "error names the missing field: " + onlyText(result))
  assertEqual(fake.lastRememberKey, "", "the host is never contacted for a malformed call")
}

test "recall tool with no key returns all entries" {
  val fake = newFakeV2Transport()
  fake.recallOk = true
  fake.recallBody = "{\"entries\":[{\"key\":\"build\",\"value\":\"make lyric\"}]}"
  val tool = RecallTool(transport = fake)

  val args = Some(value = JObject(fields = newList()))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful recall is not a tool error")
  assertTrue(onlyText(result).contains("build: make lyric"), "renders the entry: " + onlyText(result))
}

test "recall tool with a key returns only that value" {
  val fake = newFakeV2Transport()
  fake.recallByKeyOk = true
  fake.recallByKeyBody = "{\"entries\":[{\"key\":\"tests\",\"value\":\"lyric test\"}]}"
  val tool = RecallTool(transport = fake)

  val args = Some(value = JObject(fields = [JsonField(name = "key", value = JString(value = "tests"))]))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertEqual(onlyText(result), "lyric test", "returns only the requested key's value")
  assertEqual(fake.lastRecallKey, "tests", "the key was sent to the host via the single-key lookup (#590)")
}

test "recall tool works with no arguments at all (key is optional)" {
  val fake = newFakeV2Transport()
  fake.recallOk = true
  fake.recallBody = "{\"entries\":[]}"
  val tool = RecallTool(transport = fake)

  val noArgs: Option[JsonValue] = None
  val result = match tool.call(noArgs) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "recall with no args is valid (loads everything)")
  assertTrue(onlyText(result).contains("no memory"), "empty-store message: " + onlyText(result))
}

test "recallSchema declares no required field" {
  val schema = recallSchema()
  val schemaJson = writeValue(schema)
  assertTrue(schemaJson.contains("\"key\""), "schema mentions the optional 'key'")
  assertTrue(not schemaJson.contains("\"required\""), "recall has no required fields")
}

test "forget tool deletes a key and reports it" {
  val fake = newFakeV2Transport()
  fake.forgetOk = true
  fake.forgetBody = "{\"key\":\"build\",\"status\":\"deleted\"}"
  val tool = ForgetTool(transport = fake)

  val args = Some(value = JObject(fields = [JsonField(name = "key", value = JString(value = "build"))]))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful forget is not a tool error")
  assertTrue(onlyText(result).contains("build"), "result names the forgotten key: " + onlyText(result))
  assertEqual(fake.lastForgetKey, "build", "the key was forwarded")
}

test "forget tool denies for a missing key without contacting the host" {
  val fake = newFakeV2Transport()
  val tool = ForgetTool(transport = fake)

  val args = Some(value = JObject(fields = newList()))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result.isError, "a missing key is a tool error")
  assertTrue(onlyText(result).contains("key"), "error names the missing field: " + onlyText(result))
  assertEqual(fake.lastForgetKey, "", "the host is never contacted for a malformed call")
}

// ── add_task / list_tasks / complete_task (phase 7 §8) ────────────────────────
test "add_task tool forwards the description and returns the created task id" {
  val fake = newFakeV2Transport()
  fake.createTaskOk = true
  fake.createTaskBody = "{\"id\":\"task-1\"}"
  val tool = AddTaskTool(transport = fake)

  val args = Some(
    value = JObject(
      fields = [JsonField(name = "description", value = JString(value = "migrate the auth module"))]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful add_task is not a tool error")
  assertTrue(onlyText(result).contains("task-1"), "result names the created id: " + onlyText(result))
  assertEqual(fake.lastTaskDescription, "migrate the auth module", "the description was forwarded")
}

test "add_task tool denies for a missing description without contacting the host" {
  val fake = newFakeV2Transport()
  val tool = AddTaskTool(transport = fake)

  val args = Some(value = JObject(fields = newList()))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result.isError, "a missing description is a tool error")
  assertTrue(onlyText(result).contains("description"), "error names the missing field: " + onlyText(result))
  assertEqual(fake.lastTaskDescription, "", "the host is never contacted for a malformed call")
}

test "addTaskSchema declares description as required" {
  val schema = addTaskSchema()
  val schemaJson = writeValue(schema)
  assertTrue(schemaJson.contains("\"description\""), "schema mentions 'description'")
  assertTrue(schemaJson.contains("\"required\""), "schema declares required fields")
}

test "list_tasks tool with no arguments lists every task (status is optional)" {
  val fake = newFakeV2Transport()
  fake.listTasksOk = true
  fake.listTasksBody = "{\"tasks\":[{\"id\":\"t1\",\"description\":\"migrate auth\",\"status\":\"open\",\"createdAt\":\"1\",\"updatedAt\":\"1\"}]}"
  val tool = ListTasksTool(transport = fake)

  val noArgs: Option[JsonValue] = None
  val result = match tool.call(noArgs) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "list_tasks with no args is valid (lists everything)")
  assertTrue(onlyText(result).contains("t1 [open]: migrate auth"), "renders the task: " + onlyText(result))
  assertEqual(fake.lastTaskStatusFilter, "", "no filter was sent when status is omitted")
}

test "list_tasks tool forwards the status filter" {
  val fake = newFakeV2Transport()
  fake.listTasksOk = true
  fake.listTasksBody = "{\"tasks\":[]}"
  val tool = ListTasksTool(transport = fake)

  val args = Some(value = JObject(fields = [JsonField(name = "status", value = JString(value = "done"))]))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful filtered list is not a tool error")
  assertEqual(fake.lastTaskStatusFilter, "done", "the status filter was forwarded")
}

test "listTasksSchema declares no required field" {
  val schema = listTasksSchema()
  val schemaJson = writeValue(schema)
  assertTrue(schemaJson.contains("\"status\""), "schema mentions the optional 'status'")
  assertTrue(not schemaJson.contains("\"required\""), "list_tasks has no required fields")
}

test "complete_task tool marks a task done and reports success" {
  val fake = newFakeV2Transport()
  fake.completeTaskOk = true
  fake.completeTaskBody = "{\"id\":\"task-1\",\"status\":\"done\"}"
  val tool = CompleteTaskTool(transport = fake)

  val args = Some(value = JObject(fields = [JsonField(name = "id", value = JString(value = "task-1"))]))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful completion is not a tool error")
  assertTrue(onlyText(result).contains("task-1"), "result names the completed task: " + onlyText(result))
  assertEqual(fake.lastCompleteTaskId, "task-1", "the task id was forwarded")
}

test "complete_task tool denies for a missing id without contacting the host" {
  val fake = newFakeV2Transport()
  val tool = CompleteTaskTool(transport = fake)

  val args = Some(value = JObject(fields = newList()))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result.isError, "a missing id is a tool error")
  assertTrue(onlyText(result).contains("id"), "error names the missing field: " + onlyText(result))
  assertEqual(fake.lastCompleteTaskId, "", "the host is never contacted for a malformed call")
}

test "complete_task tool surfaces a not-found error for an unknown/cross-scope id" {
  val fake = newFakeV2Transport()
  fake.completeTaskOk = false
  fake.completeTaskError = "POST .../callbacks/tasks/nope/complete failed: (404) Not Found: task not found"
  val tool = CompleteTaskTool(transport = fake)

  val args = Some(value = JObject(fields = [JsonField(name = "id", value = JString(value = "nope"))]))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result.isError, "a not-found completion is a tool error")
  assertTrue(onlyText(result).contains("task not found"), "error surfaces the host's message: " + onlyText(result))
}

// ── notify (phase 7 §5) ───────────────────────────────────────────────────────
test "notify tool forwards summary+level and returns a confirmation" {
  val fake = newFakeV2Transport()
  fake.notifyOk = true
  fake.notifyBody = "{\"id\":\"note-1\"}"
  val tool = NotifyTool(transport = fake)

  val args = Some(
    value = JObject(
      fields = [
        JsonField(name = "summary", value = JString(value = "migration finished")),
        JsonField(name = "level", value = JString(value = "done"))
      ]
    )
  )
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful notify is not a tool error")
  assertTrue(onlyText(result).contains("note-1"), "result names the created id: " + onlyText(result))
  assertEqual(fake.lastNotifySummary, "migration finished", "the summary was forwarded")
  assertEqual(fake.lastNotifyLevel, "done", "the level was forwarded")
}

test "notify tool defaults level to empty when omitted" {
  val fake = newFakeV2Transport()
  fake.notifyOk = true
  fake.notifyBody = "{\"id\":\"note-2\"}"
  val tool = NotifyTool(transport = fake)

  val args = Some(value = JObject(fields = [JsonField(name = "summary", value = JString(value = "still working"))]))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(not result.isError, "a successful notify is not a tool error")
  assertEqual(fake.lastNotifySummary, "still working", "the summary was forwarded")
  assertEqual(fake.lastNotifyLevel, "", "an omitted level is forwarded as empty (the host defaults it to info)")
}

test "notify tool denies for a missing summary without contacting the host" {
  val fake = newFakeV2Transport()
  val tool = NotifyTool(transport = fake)

  val args = Some(value = JObject(fields = newList()))
  val result = match tool.call(args) { case Ok(r) -> r; case Err(e) -> panic("unexpected Err: " + e) }
  assertTrue(result.isError, "a missing summary is a tool error")
  assertTrue(onlyText(result).contains("summary"), "error names the missing field: " + onlyText(result))
  assertEqualInt(fake.notifyCallCount, 0, "the host is never contacted for a malformed call")
}

test "notifySchema declares summary as required and level as optional" {
  val schema = notifySchema()
  val schemaJson = writeValue(schema)
  assertTrue(schemaJson.contains("\"summary\""), "schema mentions 'summary'")
  assertTrue(schemaJson.contains("\"level\""), "schema mentions 'level'")
  assertTrue(schemaJson.contains("\"required\""), "schema declares required fields")
}
