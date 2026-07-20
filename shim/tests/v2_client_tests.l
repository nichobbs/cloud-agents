@test_module
package CloudAgents.Shim.V2ClientTests

import Std.Core
import Std.Testing
import Std.Collections
import Std.File
import CloudAgents.Shim.V2Transport
import CloudAgents.Shim.V2Client
import CloudAgents.Shim.V2TestFakes

// request_secret writes to /run/cloud-agents-secrets when /run exists, else
// /tmp/cloud-agents-secrets (CloudAgents.Shim.V2Client.secretsBaseDir). CI
// containers always have /run, so assert against whichever this environment
// actually resolves by probing the same way the production code does.
func expectedSecretsDir(): String {
  if Std.File.dirExists("/run") {
    return "/run/cloud-agents-secrets"
  }
  return "/tmp/cloud-agents-secrets"
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
  val fake = newFakeV2Transport()
  fake.createSecretOk = true
  fake.createSecretBody = "{\"id\":\"sr1\",\"status\":\"pending\"}"
  fake.pollSecretBodies = ["{\"status\":\"approved\",\"value\":\"ghp_super_secret_value\"}"]

  val outcome = requestSecret(fake, "GITHUB_TOKEN", "push a branch", 1, 5000)
  match outcome {
    case Approved(path) -> {
      assertTrue(path.startsWith(expectedSecretsDir()), "the file lives under the secrets base dir: " + path)
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

  match reportArtifact(fake, path, "text/plain", "a report") {
    case Ok(id) -> assertEqual(id, "art-1", "the created id round-trips")
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
  assertEqual(fake.lastUploadMimeType, "text/plain", "mimeType was sent")
  assertEqual(fake.lastUploadDescription, "a report", "description was sent")
  assertEqual(fake.lastUploadFileName, "cloud-agents-shim-test-small.txt", "fileName is the basename of the local path")
  assertTrue(fake.lastUploadContentBase64.length > 0, "content was base64-encoded and sent")
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

  match reportArtifact(fake, path, "application/octet-stream", "") {
    case Ok(id) -> assertTrue(false, "an oversize artifact must be rejected, got id " + id)
    case Err(message) -> assertTrue(message.contains("8 MiB"), "error explains the size cap: " + message)
  }
  assertEqualInt(fake.uploadArtifactCallCount, 0, "an oversize file is rejected before the host is ever contacted")
}

test "reportArtifact surfaces a missing file as a clear error" {
  val fake = newFakeV2Transport()
  match reportArtifact(fake, "/tmp/cloud-agents-shim-test-does-not-exist.bin", "text/plain", "") {
    case Ok(id) -> assertTrue(false, "a missing file must not succeed, got id " + id)
    case Err(message) -> assertTrue(message.length > 0, "a clear error is returned")
  }
}
