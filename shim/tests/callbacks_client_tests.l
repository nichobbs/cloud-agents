@test_module
package CloudAgents.Shim.CallbacksClientTests

import Std.Core
import Std.Testing
import Std.Collections
import CloudAgents.Shim.Transport
import CloudAgents.Shim.Callbacks
import CloudAgents.Shim.TestFakes

// ── request_permission / requestPermission ──────────────────────────────────
test "requestPermission returns Allow when the host approves immediately" {
  val fake = newFakeTransport()
  fake.createPermissionOk = true
  fake.createPermissionBody = "{\"id\":\"r1\",\"status\":\"pending\"}"
  fake.pollPermissionBodies = ["{\"status\":\"allowed\",\"updatedInputJson\":\"\",\"note\":\"looks fine\"}"]

  val outcome = requestPermission(fake, "Bash", "{\"command\":\"ls\"}", 1, 5000)
  match outcome {
    case Allow(updatedInputJson) -> assertEqual(updatedInputJson, "", "no override from the host means unchanged input")
    case Deny(message) -> assertTrue(false, "expected Allow, got Deny: " + message)
  }
}

test "requestPermission returns Deny with the host's note when the host denies" {
  val fake = newFakeTransport()
  fake.createPermissionOk = true
  fake.createPermissionBody = "{\"id\":\"r2\",\"status\":\"pending\"}"
  fake.pollPermissionBodies = ["{\"status\":\"denied\",\"updatedInputJson\":\"\",\"note\":\"looks dangerous\"}"]

  val outcome = requestPermission(fake, "Bash", "{\"command\":\"rm -rf /\"}", 1, 5000)
  match outcome {
    case Allow(_) -> assertTrue(false, "expected Deny, got Allow")
    case Deny(message) -> assertEqual(message, "looks dangerous", "deny message carries the host's note")
  }
}

test "requestPermission denies with a client-side timeout when the host never resolves" {
  val fake = newFakeTransport()
  fake.createPermissionOk = true
  fake.createPermissionBody = "{\"id\":\"r3\",\"status\":\"pending\"}"
  // A single "pending" entry repeats forever (nextScripted clamps).
  fake.pollPermissionBodies = ["{\"status\":\"pending\",\"updatedInputJson\":\"\",\"note\":\"\"}"]

  val outcome = requestPermission(fake, "Bash", "{}", 1, 3)
  match outcome {
    case Allow(_) -> assertTrue(false, "expected a fail-closed Deny on timeout, got Allow")
    case Deny(message) -> {
      assertTrue(message.contains("timed out"), "timeout deny message explains why: " + message)
      assertTrue(fake.pollPermissionCallCount >= 2, "the loop actually polled more than once before timing out")
    }
  }
}

test "requestPermission denies with a message when creating the request fails" {
  val fake = newFakeTransport()
  fake.createPermissionOk = true
  fake.createPermissionBody = "not json at all"

  val outcome = requestPermission(fake, "Bash", "{}", 1, 5000)
  match outcome {
    case Allow(_) -> assertTrue(false, "expected Deny on a malformed create response, got Allow")
    case Deny(message) -> assertTrue(message.contains("malformed"), "deny message names the malformed response: " + message)
  }
}

test "requestPermission denies with a message when polling returns a malformed body" {
  val fake = newFakeTransport()
  fake.createPermissionOk = true
  fake.createPermissionBody = "{\"id\":\"r4\",\"status\":\"pending\"}"
  fake.pollPermissionBodies = ["<html>not json</html>"]

  val outcome = requestPermission(fake, "Bash", "{}", 1, 5000)
  match outcome {
    case Allow(_) -> assertTrue(false, "expected Deny on a malformed poll response, got Allow")
    case Deny(message) -> assertTrue(message.contains("malformed"), "deny message names the malformed response: " + message)
  }
}

test "requestPermission denies with a message when the transport itself fails" {
  val fake = newFakeTransport()
  fake.createPermissionOk = false
  fake.createPermissionError = "connection refused"

  val outcome = requestPermission(fake, "Bash", "{}", 1, 5000)
  match outcome {
    case Allow(_) -> assertTrue(false, "expected Deny on a transport failure, got Allow")
    case Deny(message) -> assertTrue(message.contains("connection refused"), "deny message carries the transport error: " + message)
  }
}

// ── ask_user / askUser ──────────────────────────────────────────────────────
test "askUser returns the answer text on a round trip" {
  val fake = newFakeTransport()
  fake.createQuestionOk = true
  fake.createQuestionBody = "{\"id\":\"q1\"}"
  fake.pollQuestionBodies = ["{\"status\":\"answered\",\"answer\":\"A\"}"]

  match askUser(fake, "Which package?", "[\"A\",\"B\"]", 1, 5000) {
    case Ok(answer) -> assertEqual(answer, "A", "answer round-trips")
    case Err(message) -> assertTrue(false, "expected Ok, got Err: " + message)
  }
}

test "askUser fails with a distinct message on a host-reported timeout" {
  val fake = newFakeTransport()
  fake.createQuestionOk = true
  fake.createQuestionBody = "{\"id\":\"q2\"}"
  fake.pollQuestionBodies = ["{\"status\":\"timed_out\",\"answer\":\"\"}"]

  match askUser(fake, "Proceed?", "", 1, 5000) {
    case Ok(answer) -> assertTrue(false, "expected Err on a host-reported timeout, got Ok(" + answer + ")")
    case Err(message) -> assertTrue(message.contains("timed out"), "error message explains the timeout: " + message)
  }
}

test "askUser fails with a client-side timeout when the host never resolves" {
  val fake = newFakeTransport()
  fake.createQuestionOk = true
  fake.createQuestionBody = "{\"id\":\"q3\"}"
  fake.pollQuestionBodies = ["{\"status\":\"pending\",\"answer\":\"\"}"]

  match askUser(fake, "Proceed?", "", 1, 3) {
    case Ok(answer) -> assertTrue(false, "expected Err on client-side timeout, got Ok(" + answer + ")")
    case Err(message) -> assertTrue(message.contains("timed out"), "error message explains the timeout: " + message)
  }
}

// ── report_progress / reportProgress ────────────────────────────────────────
test "reportProgress is fire-and-forget and never raises even when the transport fails" {
  val fake = newFakeTransport()
  fake.reportProgressOk = false
  fake.reportProgressError = "network down"

  // Must not throw/panic — a progress report failure is swallowed, logged
  // to stderr, and never surfaces to the caller.
  reportProgress(fake, "cloning repo", "10")
  assertEqualInt(fake.reportProgressCallCount, 1, "the transport was still called exactly once")
}

test "reportProgress calls through to the transport on success" {
  val fake = newFakeTransport()
  fake.reportProgressOk = true

  reportProgress(fake, "running tests", "80")
  assertEqualInt(fake.reportProgressCallCount, 1, "the transport was called with the report")
}
