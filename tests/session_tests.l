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
    containerId = ""
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
    }
    case None -> assertTrue(false, "session should exist in store")
  }

  // 3. Update container ID
  updateSessionContainer(sessionId, "container-abc")
  match getSession(sessionId) {
    case Some(s) -> {
      assertEqual(s.containerId, "container-abc", "container ID was updated successfully")
    }
    case None -> assertTrue(false, "session should still exist in store")
  }

  // 4. Remove session
  match removeSession(sessionId) {
    case Some(s) -> {
      assertEqual(s.sessionId, sessionId, "removed session ID matches")
    }
    case None -> assertTrue(false, "should successfully remove session")
  }

  // 5. Verify removed
  match getSession(sessionId) {
    case Some(_) -> assertTrue(false, "session should no longer exist")
    case None -> ()
  }

  println("✓ Session Store tests passed!")
}

test "Test Handler createSession validation" {
  println("Testing Handler createSession validation...")

  // Test empty repoUrl validation
  val req1 = CreateSessionRequest(repoUrl = "", branch = "main")
  match createSession(req1) {
    case Ok(_) -> assertTrue(false, "should fail on empty repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "returns 400 bad request")
  }

  // Test empty branch validation
  val req2 = CreateSessionRequest(repoUrl = "https://github.com/nic/repos/cloud-agents", branch = "")
  match createSession(req2) {
    case Ok(_) -> assertTrue(false, "should fail on empty branch")
    case Err(err) -> assertEqualInt(err.status, 400, "returns 400 bad request")
  }

  // Test successful session creation
  val req3 = CreateSessionRequest(repoUrl = "https://github.com/nic/repos/cloud-agents", branch = "main")
  match createSession(req3) {
    case Ok(resp) -> {
      assertTrue(resp.sessionId.length > 0, "generates a non-empty sessionId")
      // Clean up the created session
      val _ = removeSession(resp.sessionId)
    }
    case Err(_) -> assertTrue(false, "should successfully create session")
  }

  println("✓ Handler validation tests passed!")
}
