@test_module
package CloudAgents.Shim.V2ClientTests

import Std.Core
import Std.Testing
import Std.Collections
import Std.File
import CloudAgents.Shim.V2Transport
import CloudAgents.Shim.Callbacks
import CloudAgents.Shim.V2Client
import CloudAgents.Shim.V2TestFakes

// request_secret writes to /run/cloud-agents-secrets when /run exists, else
// /tmp/cloud-agents-secrets (CloudAgents.Shim.V2Client.secretsBaseDir). CI
// containers always have /run, so assert against whichever this environment
// actually resolves by probing the same way the production code does.
// Point the secret writer at a writable throwaway dir so the test never
// depends on /run being writable by the (non-root) test runner — the CI
// failure that surfaced the writable-vs-present fallback bug. Call at the
// top of a secret-writing test BEFORE requestSecret runs (it sets the
// override the writer reads), and use the returned dir in assertions.
func useTempSecretsDir(): String {
  val dir = Std.Environment.currentDirectory() + "/.lyric-test-secrets"
  Std.Environment.setVar("CLOUD_AGENTS_SECRETS_DIR", dir)
  return dir
}

func readBackOrPanic(path: in String): String {
  return match Std.File.readText(path) {
    case Ok(t) -> t
    case Err(e) -> panic("expected the secret file to exist at " + path)
  }
}

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

// ── request_secret ──────────────────────────────────────────────────────────
test "requestSecret approve: writes the value to a local file and returns ONLY the path" {
  val secretsDir = useTempSecretsDir()
  val fake = newFakeV2Transport()
  fake.createSecretOk = true
  fake.createSecretBody = "{\"id\":\"sr1\",\"status\":\"pending\"}"
  fake.pollSecretBodies = ["{\"status\":\"approved\",\"value\":\"ghp_super_secret_value\"}"]

  val outcome = requestSecret(fake, "GITHUB_TOKEN", "push a branch", 1, 5000)
  match outcome {
    case Approved(path) -> {
      assertTrue(path.startsWith(secretsDir), "the file lives under the secrets base dir: " + path)
      assertTrue(path.contains("GITHUB_TOKEN"), "the file name reflects the credential name: " + path)
      assertEqual(readBackOrPanic(path), "ghp_super_secret_value", "the value was actually written to disk")
      // The defining property this feature exists for: the value itself
      // must never appear anywhere in the tool-visible outcome — only the
      // path does.
      assertTrue(not path.contains("ghp_super_secret_value"), "the secret value never appears in the returned path")
    }
    case Refused(message) -> assertTrue(false, "expected Approved, got Refused: " + message)
  }
  assertEqual(fake.lastSecretName, "GITHUB_TOKEN", "the requested name was sent to the host")
  assertEqual(fake.lastSecretReason, "push a branch", "the reason was sent to the host")
}

test "requestSecret deny: refuses with a message, no file is written" {
  val fake = newFakeV2Transport()
  fake.createSecretOk = true
  fake.createSecretBody = "{\"id\":\"sr2\",\"status\":\"pending\"}"
  fake.pollSecretBodies = ["{\"status\":\"denied\",\"value\":\"\"}"]

  val outcome = requestSecret(fake, "AWS_KEY", "deploy", 1, 5000)
  match outcome {
    case Approved(path) -> assertTrue(false, "expected Refused, got Approved(" + path + ")")
    case Refused(message) -> assertTrue(message.contains("denied"), "refusal message explains the denial: " + message)
  }
}

test "requestSecret timeout: refuses with a client-side timeout message when the host never resolves" {
  val fake = newFakeV2Transport()
  fake.createSecretOk = true
  fake.createSecretBody = "{\"id\":\"sr3\",\"status\":\"pending\"}"
  // A single "pending" entry repeats forever (nextScripted clamps).
  fake.pollSecretBodies = ["{\"status\":\"pending\",\"value\":\"\"}"]

  val outcome = requestSecret(fake, "TOKEN", "x", 1, 3)
  match outcome {
    case Approved(path) -> assertTrue(false, "expected a fail-closed Refused on timeout, got Approved(" + path + ")")
    case Refused(message) -> {
      assertTrue(message.contains("timed out"), "timeout refusal explains why: " + message)
      assertTrue(fake.pollSecretCallCount >= 2, "the loop actually polled more than once before timing out")
    }
  }
}

test "requestSecret create failure (e.g. an unconfigured/missing credential) refuses without ever polling" {
  val fake = newFakeV2Transport()
  fake.createSecretOk = false
  fake.createSecretError = "POST .../callbacks/secret failed: (400) Bad Request: no credential named 'NOPE' is configured for this session"

  val outcome = requestSecret(fake, "NOPE", "x", 1, 5000)
  match outcome {
    case Approved(path) -> assertTrue(false, "expected Refused, got Approved(" + path + ")")
    case Refused(message) -> assertTrue(message.contains("NOPE"), "refusal message surfaces the host's error: " + message)
  }
  assertEqualInt(fake.pollSecretCallCount, 0, "a create failure never reaches the poll loop")
}

test "requestSecret refuses when approved but the value was already delivered (once-only)" {
  val fake = newFakeV2Transport()
  fake.createSecretOk = true
  fake.createSecretBody = "{\"id\":\"sr4\",\"status\":\"pending\"}"
  fake.pollSecretBodies = ["{\"status\":\"approved\",\"value\":\"\"}"]

  val outcome = requestSecret(fake, "TOKEN", "x", 1, 5000)
  match outcome {
    case Approved(path) -> assertTrue(false, "an approved-but-empty-value decision must not fabricate a file, got " + path)
    case Refused(message) -> assertTrue(message.contains("unavailable"), "refusal explains the value is unavailable: " + message)
  }
}

// ── add_followup_task ───────────────────────────────────────────────────────
test "addFollowupTask returns the created id on success" {
  val fake = newFakeV2Transport()
  fake.createTodoOk = true
  fake.createTodoBody = "{\"id\":\"todo-1\"}"

  match addFollowupTask(fake, "double-check the migration") {
    case Ok(id) -> assertEqual(id, "todo-1", "the created id round-trips")
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
  assertEqual(fake.lastTodoDescription, "double-check the migration", "the description was sent to the host")
}

test "addFollowupTask surfaces a transport failure" {
  val fake = newFakeV2Transport()
  fake.createTodoOk = false
  fake.createTodoError = "connection refused"

  match addFollowupTask(fake, "x") {
    case Ok(id) -> assertTrue(false, "expected Err, got Ok(" + id + ")")
    case Err(message) -> assertTrue(message.contains("connection refused"), "error carries the transport failure: " + message)
  }
}

// ── remember / recall (phase 7 §4) ────────────────────────────────────────────
test "remember returns a confirmation and sends key+value to the host" {
  val fake = newFakeV2Transport()
  fake.rememberOk = true
  fake.rememberBody = "{\"key\":\"build\"}"

  match remember(fake, "build", "make lyric") {
    case Ok(msg) -> assertTrue(msg.contains("build"), "confirmation names the key: " + msg)
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
  assertEqual(fake.lastRememberKey, "build", "the key was sent to the host")
  assertEqual(fake.lastRememberValue, "make lyric", "the value was sent to the host")
}

test "remember surfaces a transport failure" {
  val fake = newFakeV2Transport()
  fake.rememberOk = false
  fake.rememberError = "connection refused"

  match remember(fake, "k", "v") {
    case Ok(msg) -> assertTrue(false, "expected Err, got Ok(" + msg + ")")
    case Err(message) -> assertTrue(message.contains("connection refused"), "error carries the transport failure: " + message)
  }
}

test "recall with no key returns every entry as key: value lines" {
  val fake = newFakeV2Transport()
  fake.recallOk = true
  fake.recallBody = "{\"entries\":[{\"key\":\"build\",\"value\":\"make lyric\"},{\"key\":\"tests\",\"value\":\"lyric test\"}]}"

  match recall(fake, "") {
    case Ok(text) -> {
      assertTrue(text.contains("build: make lyric"), "first entry rendered: " + text)
      assertTrue(text.contains("tests: lyric test"), "second entry rendered: " + text)
    }
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
}

test "recall with a key returns just that entry's value" {
  val fake = newFakeV2Transport()
  fake.recallOk = true
  fake.recallBody = "{\"entries\":[{\"key\":\"build\",\"value\":\"make lyric\"},{\"key\":\"tests\",\"value\":\"lyric test\"}]}"

  match recall(fake, "tests") {
    case Ok(text) -> assertEqual(text, "lyric test", "returns only the requested key's value")
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
}

test "recall with an unknown key reports nothing stored under it" {
  val fake = newFakeV2Transport()
  fake.recallOk = true
  fake.recallBody = "{\"entries\":[{\"key\":\"build\",\"value\":\"make lyric\"}]}"

  match recall(fake, "nope") {
    case Ok(text) -> assertTrue(text.contains("no memory"), "explains the key is unknown: " + text)
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
}

test "recall with an empty store reports nothing remembered yet" {
  val fake = newFakeV2Transport()
  fake.recallOk = true
  fake.recallBody = "{\"entries\":[]}"

  match recall(fake, "") {
    case Ok(text) -> assertTrue(text.contains("no memory"), "explains the store is empty: " + text)
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
}

test "recall surfaces a transport failure" {
  val fake = newFakeV2Transport()
  fake.recallOk = false
  fake.recallError = "connection refused"

  match recall(fake, "") {
    case Ok(text) -> assertTrue(false, "expected Err, got Ok(" + text + ")")
    case Err(message) -> assertTrue(message.contains("connection refused"), "error carries the transport failure: " + message)
  }
}

test "forget reports a deleted key and sends it to the host" {
  val fake = newFakeV2Transport()
  fake.forgetOk = true
  fake.forgetBody = "{\"key\":\"build\",\"status\":\"deleted\"}"

  match forget(fake, "build") {
    case Ok(msg) -> assertTrue(msg.contains("forgot") and msg.contains("build"), "confirms deletion: " + msg)
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
  assertEqual(fake.lastForgetKey, "build", "the key was sent to the host")
}

test "forget of an absent key is a success, not an error" {
  val fake = newFakeV2Transport()
  fake.forgetOk = true
  fake.forgetBody = "{\"key\":\"nope\",\"status\":\"absent\"}"

  match forget(fake, "nope") {
    case Ok(msg) -> assertTrue(msg.contains("no memory"), "reports the key was absent: " + msg)
    case Err(message) -> assertTrue(false, "an absent key must not be an error: " + message)
  }
}

test "forget surfaces a transport failure" {
  val fake = newFakeV2Transport()
  fake.forgetOk = false
  fake.forgetError = "connection refused"

  match forget(fake, "k") {
    case Ok(msg) -> assertTrue(false, "expected Err, got Ok(" + msg + ")")
    case Err(message) -> assertTrue(message.contains("connection refused"), "error carries the transport failure: " + message)
  }
}

// ── notify (phase 7 §5) ───────────────────────────────────────────────────────
test "notify returns the created id and sends summary+level to the host" {
  val fake = newFakeV2Transport()
  fake.notifyOk = true
  fake.notifyBody = "{\"id\":\"note-1\"}"

  match notify(fake, "migration finished", "done") {
    case Ok(id) -> assertEqual(id, "note-1", "the created id round-trips")
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
  assertEqual(fake.lastNotifySummary, "migration finished", "the summary was sent to the host")
  assertEqual(fake.lastNotifyLevel, "done", "the level was sent to the host")
}

test "notify surfaces a transport failure" {
  val fake = newFakeV2Transport()
  fake.notifyOk = false
  fake.notifyError = "connection refused"

  match notify(fake, "x", "") {
    case Ok(id) -> assertTrue(false, "expected Err, got Ok(" + id + ")")
    case Err(message) -> assertTrue(message.contains("connection refused"), "error carries the transport failure: " + message)
  }
}

// ── add_task / list_tasks / complete_task (phase 7 §8) ────────────────────────
test "addTask returns the created id on success and sends the description" {
  val fake = newFakeV2Transport()
  fake.createTaskOk = true
  fake.createTaskBody = "{\"id\":\"task-1\"}"

  match addTask(fake, "migrate the auth module") {
    case Ok(id) -> assertEqual(id, "task-1", "the created id round-trips")
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
  assertEqual(fake.lastTaskDescription, "migrate the auth module", "the description was sent to the host")
}

test "addTask surfaces a transport failure" {
  val fake = newFakeV2Transport()
  fake.createTaskOk = false
  fake.createTaskError = "connection refused"

  match addTask(fake, "x") {
    case Ok(id) -> assertTrue(false, "expected Err, got Ok(" + id + ")")
    case Err(message) -> assertTrue(message.contains("connection refused"), "error carries the transport failure: " + message)
  }
}

test "listTasks with no filter renders every task as id [status]: description lines" {
  val fake = newFakeV2Transport()
  fake.listTasksOk = true
  fake.listTasksBody = "{\"tasks\":[{\"id\":\"t1\",\"description\":\"migrate auth\",\"status\":\"open\",\"createdAt\":\"1\",\"updatedAt\":\"1\"},{\"id\":\"t2\",\"description\":\"write docs\",\"status\":\"done\",\"createdAt\":\"2\",\"updatedAt\":\"2\"}]}"

  match listTasks(fake, "") {
    case Ok(text) -> {
      assertTrue(text.contains("t1 [open]: migrate auth"), "first task rendered: " + text)
      assertTrue(text.contains("t2 [done]: write docs"), "second task rendered: " + text)
    }
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
  assertEqual(fake.lastTaskStatusFilter, "", "an empty filter was sent to the host")
}

test "listTasks forwards a status filter to the host" {
  val fake = newFakeV2Transport()
  fake.listTasksOk = true
  fake.listTasksBody = "{\"tasks\":[]}"

  match listTasks(fake, "open") {
    case Ok(_) -> ()
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
  assertEqual(fake.lastTaskStatusFilter, "open", "the status filter was sent to the host")
}

test "listTasks with an empty store reports nothing stored" {
  val fake = newFakeV2Transport()
  fake.listTasksOk = true
  fake.listTasksBody = "{\"tasks\":[]}"

  match listTasks(fake, "") {
    case Ok(text) -> assertTrue(text.contains("no tasks"), "explains the backlog is empty: " + text)
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
}

test "listTasks surfaces a transport failure" {
  val fake = newFakeV2Transport()
  fake.listTasksOk = false
  fake.listTasksError = "connection refused"

  match listTasks(fake, "") {
    case Ok(text) -> assertTrue(false, "expected Err, got Ok(" + text + ")")
    case Err(message) -> assertTrue(message.contains("connection refused"), "error carries the transport failure: " + message)
  }
}

test "completeTask reports success and sends the task id" {
  val fake = newFakeV2Transport()
  fake.completeTaskOk = true
  fake.completeTaskBody = "{\"id\":\"task-1\",\"status\":\"done\"}"

  match completeTask(fake, "task-1") {
    case Ok(msg) -> assertTrue(msg.contains("task-1"), "confirmation names the task: " + msg)
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
  assertEqual(fake.lastCompleteTaskId, "task-1", "the task id was sent to the host")
}

test "completeTask surfaces a transport failure (e.g. an unknown/cross-scope task id)" {
  val fake = newFakeV2Transport()
  fake.completeTaskOk = false
  fake.completeTaskError = "POST .../callbacks/tasks/nope/complete failed: (404) Not Found: task not found"

  match completeTask(fake, "nope") {
    case Ok(msg) -> assertTrue(false, "expected Err, got Ok(" + msg + ")")
    case Err(message) -> assertTrue(message.contains("task not found"), "error surfaces the host's error: " + message)
  }
}

// ── report_artifact ─────────────────────────────────────────────────────────
func writeTempFile(name: in String, content: in String): String {
  val path = "/tmp/cloud-agents-shim-test-" + name
  match Std.File.writeText(path, content) {
    case Ok(_) -> ()
    case Err(e) -> panic("failed to set up temp file " + path)
  }
  return path
}

test "reportArtifact reads, base64-encodes, uploads, and returns the artifact id" {
  val fake = newFakeV2Transport()
  fake.uploadArtifactOk = true
  fake.uploadArtifactBody = "{\"id\":\"art-1\"}"
  val path = writeTempFile("small.txt", "hello artifact")

  match reportArtifact(fake, path, "text/plain", "a report", "") {
    case Ok(id) -> assertEqual(id, "art-1", "the created id round-trips")
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
  assertEqual(fake.lastUploadMimeType, "text/plain", "mimeType was sent")
  assertEqual(fake.lastUploadDescription, "a report", "description was sent")
  assertEqual(fake.lastUploadFileName, "cloud-agents-shim-test-small.txt", "fileName is the basename of the local path")
  assertTrue(fake.lastUploadContentBase64.length > 0, "content was base64-encoded and sent")
  assertEqual(fake.lastUploadArtifactScope, "", "an empty scope (today's exact behavior) is sent as-is")
}

test "reportArtifact passes a 'repo' scope through to the transport unchanged (docs/phase7 §6)" {
  val fake = newFakeV2Transport()
  fake.uploadArtifactOk = true
  fake.uploadArtifactBody = "{\"id\":\"art-repo-1\"}"
  val path = writeTempFile("repo-scoped.txt", "durable across sessions")

  match reportArtifact(fake, path, "text/plain", "", "repo") {
    case Ok(id) -> assertEqual(id, "art-repo-1", "the created id round-trips")
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
  assertEqual(fake.lastUploadArtifactScope, "repo", "the 'repo' scope is forwarded to the transport")
}

test "reportArtifact rejects a file over the 8 MiB cap without uploading anything" {
  val fake = newFakeV2Transport()
  fake.uploadArtifactOk = true
  fake.uploadArtifactBody = "{\"id\":\"should-not-be-used\"}"

  // Build a file just over 8 MiB (8388608 bytes) without an enormous
  // in-source literal. Doubling (s = s + s) rather than Std.String.repeat's
  // single-character-at-a-time loop: repeat's O(n^2) behavior made a
  // ~100 KB call take unworkably long at this size.
  val path = writeTempFile("big.bin", atLeast(8388609))

  match reportArtifact(fake, path, "application/octet-stream", "", "") {
    case Ok(id) -> assertTrue(false, "an oversize artifact must be rejected, got id " + id)
    case Err(message) -> assertTrue(message.contains("8 MiB"), "error explains the size cap: " + message)
  }
  assertEqualInt(fake.uploadArtifactCallCount, 0, "an oversize file is rejected before the host is ever contacted")
}

test "reportArtifact surfaces a missing file as a clear error" {
  val fake = newFakeV2Transport()
  match reportArtifact(fake, "/tmp/cloud-agents-shim-test-does-not-exist.bin", "text/plain", "", "") {
    case Ok(id) -> assertTrue(false, "a missing file must not succeed, got id " + id)
    case Err(message) -> assertTrue(message.length > 0, "a clear error is returned")
  }
}

// ── wall-clock deadline (#540) for request_secret ────────────────────────────
// Mirrors the v1 ClockJumpingTransport test: pollSecret always reports
// "pending" but jumps a shared ManualClock past the deadline as a side
// effect, proving requestSecretWithClock stops after exactly one poll on a
// wall-clock timeout regardless of pollIntervalMs.
record ClockJumpingV2Transport {
  var clock: ManualClock
  var jumpToMillis: Long
  var pollSecretCallCount: Int
}

impl V2CallbackTransport for ClockJumpingV2Transport {
  func createSecret(name: in String, reason: in String): Result[String, String] {
    Ok(value = "{\"id\":\"cj-secret\",\"status\":\"pending\"}")
  }

  func pollSecret(requestId: in String): Result[String, String] {
    self.pollSecretCallCount = self.pollSecretCallCount + 1
    self.clock.millis = self.jumpToMillis
    Ok(value = "{\"status\":\"pending\",\"value\":\"\"}")
  }

  func createTodo(description: in String): Result[String, String] {
    Ok(value = "{\"id\":\"cj-todo\"}")
  }

  func uploadArtifact(
    fileName: in String,
    mimeType: in String,
    description: in String,
    contentBase64: in String,
    artifactScope: in String,
  ): Result[String, String] {
    Ok(value = "{\"id\":\"cj-artifact\"}")
  }

  func remember(key: in String, value: in String): Result[String, String] {
    Ok(value = "{\"key\":\"cj\"}")
  }

  func recallAll(): Result[String, String] {
    Ok(value = "{\"entries\":[]}")
  }

  func forget(key: in String): Result[String, String] {
    Ok(value = "{\"key\":\"cj\",\"status\":\"absent\"}")
  }

  func createTask(description: in String): Result[String, String] {
    Ok(value = "{\"id\":\"cj-task\"}")
  }

  func listTasks(statusFilter: in String): Result[String, String] {
    Ok(value = "{\"tasks\":[]}")
  }

  func completeTask(taskId: in String): Result[String, String] {
    Ok(value = "{\"id\":\"cj-task\",\"status\":\"done\"}")
  }

  func notify(summary: in String, level: in String): Result[String, String] {
    Ok(value = "{\"id\":\"cj-notify\"}")
  }
}

test "requestSecretWithClock refuses via a wall-clock deadline, not an iteration count" {
  val clock = manualClock(0i64)
  val transport = ClockJumpingV2Transport(clock = clock, jumpToMillis = 999999i64, pollSecretCallCount = 0)

  val outcome = requestSecretWithClock(transport, "GITHUB_TOKEN", "push", 25000, 1000, clock)
  match outcome {
    case Approved(path) -> assertTrue(false, "expected a fail-closed Refused on a wall-clock timeout, got Approved(" + path + ")")
    case Refused(message) -> {
      assertTrue(message.contains("timed out"), "timeout refusal explains why: " + message)
      assertEqualInt(
        transport.pollSecretCallCount,
        1,
        "the wall-clock deadline fired after exactly one poll, despite pollIntervalMs=25000"
      )
    }
  }
}
