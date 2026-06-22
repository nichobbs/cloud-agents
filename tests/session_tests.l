@test_module
package CloudAgents.SessionTests

import Std.Core
import Std.Testing
import CloudAgents.SessionStore
import CloudAgents.Handlers

test "Test Session Store CRUD Operations" {
  println("Testing Session Store operations...")

  val sessionId = "test-session-123"
  val session = makeAgentSession(
    sessionId = sessionId,
    repoUrl = "https://github.com/nic/repos/cloud-agents",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = sessionId
  )

  // 1. Add session
  addSession(session)


  // 2. Get and verify session
  match getSession(sessionId) {
    case Some(s) -> {
      assertEqual(s.sessionId, sessionId, "session ID matches")
      assertEqual(s.repoUrl, "https://github.com/nic/repos/cloud-agents", "repoUrl matches")
      assertEqual(s.branch, "main", "branch matches")
      assertEqual(s.containerId, "", "container ID is initially empty")
      assertEqual(s.harness, "claude", "harness matches")
      assertEqual(s.model, "claude-opus-4-8", "model matches")
      assertEqual(s.nativeSessionId, sessionId, "nativeSessionId matches")
    }
    case None -> assertTrue(false, "session should exist in store")
  }

  // 3. Update container ID
  updateSessionContainer(sessionId, "container-abc")
  match getSession(sessionId) {
    case Some(s) -> {
      assertEqual(s.containerId, "container-abc", "container ID was updated successfully")
      assertEqual(s.model, "claude-opus-4-8", "model preserved across container update")
    }
    case None -> assertTrue(false, "session should still exist in store")
  }

  // 4. Switch model (same harness)
  updateSessionModel(sessionId, "claude-sonnet-4-6")
  match getSession(sessionId) {
    case Some(s) -> {
      assertEqual(s.model, "claude-sonnet-4-6", "model was switched")
      assertEqual(s.nativeSessionId, sessionId, "nativeSessionId preserved across model switch")
    }
    case None -> assertTrue(false, "session should still exist in store")
  }

  // 5. Remove session
  match removeSession(sessionId) {
    case Some(s) -> {
      assertEqual(s.sessionId, sessionId, "removed session ID matches")
    }
    case None -> assertTrue(false, "should successfully remove session")
  }

  // 6. Verify removed
  match getSession(sessionId) {
    case Some(_) -> assertTrue(false, "session should no longer exist")
    case None -> ()
  }

  println("✓ Session Store tests passed!")
}

test "Test default model per harness" {
  assertEqual(defaultModelForHarness("claude"), "claude-opus-4-8", "claude default model")
  assertEqual(defaultModelForHarness("codex"), "o4-mini", "codex default model")
  assertEqual(defaultModelForHarness("opencode"), "claude-sonnet-4-6", "opencode default model")
  assertEqual(defaultModelForHarness("unknown"), "claude-opus-4-8", "unknown harness falls back to claude default")
}

test "Test legacy session deserialisation defaults" {
  // A session JSON predating the harness/model/nativeSessionId fields must
  // deserialise with safe defaults rather than empty strings.
  val legacyJson = "{\"sessions\":[{\"sessionId\":\"legacy-1\",\"repoUrl\":\"https://github.com/nic/repo\",\"branch\":\"main\",\"containerId\":\"\"}]}"
  val parsed = parseSessionsJson(legacyJson)
  val sessions = parsed.toArray()
  assertEqualInt(sessions.length, 1, "one legacy session parsed")
  val s = sessions[0]
  assertEqual(s.harness, "claude", "legacy harness defaults to claude")
  assertEqual(s.model, "claude-opus-4-8", "legacy model defaults to harness default, not empty")
  assertEqual(s.nativeSessionId, "legacy-1", "legacy nativeSessionId defaults to sessionId")
}

test "Test Handler createSession validation" {
  println("Testing Handler createSession validation...")

  // Test empty repoUrl validation
  val req1 = CreateSessionRequest(repoUrl = "", branch = "main", harness = "claude", model = "claude-opus-4-8")
  match createSession(req1) {
    case Ok(_) -> assertTrue(false, "should fail on empty repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "returns 400 bad request")
  }

  // Test empty branch validation
  val req2 = CreateSessionRequest(repoUrl = "https://github.com/nic/repos/cloud-agents", branch = "", harness = "claude", model = "claude-opus-4-8")
  match createSession(req2) {
    case Ok(_) -> assertTrue(false, "should fail on empty branch")
    case Err(err) -> assertEqualInt(err.status, 400, "returns 400 bad request")
  }

  // Test successful session creation
  val req3 = CreateSessionRequest(repoUrl = "https://github.com/nic/repos/cloud-agents", branch = "main", harness = "claude", model = "claude-opus-4-8")
  match createSession(req3) {
    case Ok(resp) -> {
      assertTrue(resp.sessionId.length > 0, "generates a non-empty sessionId")
      // Clean up the created session
      val _ = removeSession(resp.sessionId)
    }
    case Err(_) -> assertTrue(false, "should successfully create session")
  }

  // An empty model must be backfilled with the harness default, not stored empty.
  val req4 = CreateSessionRequest(repoUrl = "https://github.com/nic/repos/cloud-agents", branch = "main", harness = "codex", model = "")
  match createSession(req4) {
    case Ok(resp) -> {
      match getSession(resp.sessionId) {
        case Some(s) -> assertEqual(s.model, "o4-mini", "empty model backfilled with codex default")
        case None -> assertTrue(false, "created session should exist")
      }
      val _ = removeSession(resp.sessionId)
    }
    case Err(_) -> assertTrue(false, "should create session with empty model")
  }

  println("✓ Handler validation tests passed!")
}
