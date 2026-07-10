@test_module
package CloudAgents.SessionTests

import Std.Core
import Std.Testing
import CloudAgents.SessionStore
import CloudAgents.Handlers

// ── Helpers ──────────────────────────────────────────────────────────────────
// Lyric match arms are `case Pattern -> expression` (no block form), so
// multi-assertion checks are extracted into named functions.

func verifyNewSession(s: in AgentSession, sessionId: in String): Unit {
  assertEqual(s.sessionId, sessionId, "session ID matches")
  assertEqual(s.repoUrl, "https://github.com/nic/repos/cloud-agents", "repoUrl matches")
  assertEqual(s.branch, "main", "branch matches")
  assertEqual(s.containerId, "", "container ID is initially empty")
  assertEqual(s.harness, "claude", "harness matches")
  assertEqual(s.model, "claude-opus-4-8", "model matches")
  assertEqual(s.nativeSessionId, sessionId, "nativeSessionId matches")
}

func verifyContainerUpdate(s: in AgentSession): Unit {
  assertEqual(s.containerId, "container-abc", "container ID was updated successfully")
  assertEqual(s.model, "claude-opus-4-8", "model preserved across container update")
}

func verifyModelSwitch(s: in AgentSession, sessionId: in String): Unit {
  assertEqual(s.model, "claude-sonnet-4-6", "model was switched")
  assertEqual(s.nativeSessionId, sessionId, "nativeSessionId preserved across model switch")
}

func verifyAndCleanCreateSession(resp: in CreateSessionResponse): Unit {
  assertTrue(resp.sessionId.length > 0, "generates a non-empty sessionId")
  val _ = removeSession(resp.sessionId)
}

func verifyModelBackfill(resp: in CreateSessionResponse): Unit {
  match getSession(resp.sessionId) {
    case Some(s) -> assertEqual(s.model, "o4-mini", "empty model backfilled with codex default")
    case None -> assertTrue(false, "created session should exist")
  }
  val _ = removeSession(resp.sessionId)
}

func verifyEscapedRoundTrip(p: in AgentSession): Unit {
  assertEqual(p.repoUrl, "https://github.com/nic/re\"po", "quote round-trips")
  assertEqual(p.branch, "feat\\wip", "backslash round-trips")
  assertEqual(p.containerId, "a\\", "trailing backslash round-trips")
  assertEqual(p.model, "claude-opus-4-8", "fields after escapes are intact")
  assertEqual(p.nativeSessionId, "esc-1", "last field intact")
}

func verifyListSessionsBody(body: in String): Unit {
  assertTrue(body.startsWith("{\"sessions\":["), "list body is a sessions object")
  assertTrue(body.contains("\"sessionId\":\"ls-1\""), "first session listed")
  assertTrue(body.contains("\"sessionId\":\"ls-2\""), "second session listed")
}

// ── Tests ─────────────────────────────────────────────────────────────────────

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
    case Some(s) -> verifyNewSession(s, sessionId)
    case None -> assertTrue(false, "session should exist in store")
  }

  // 3. Update container ID
  updateSessionContainer(sessionId, "container-abc")
  match getSession(sessionId) {
    case Some(s) -> verifyContainerUpdate(s)
    case None -> assertTrue(false, "session should still exist in store")
  }

  // 4. Switch model (same harness)
  updateSessionModel(sessionId, "claude-sonnet-4-6")
  match getSession(sessionId) {
    case Some(s) -> verifyModelSwitch(s, sessionId)
    case None -> assertTrue(false, "session should still exist in store")
  }

  // 5. Remove session
  match removeSession(sessionId) {
    case Some(s) -> assertEqual(s.sessionId, sessionId, "removed session ID matches")
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
  val sessions = parseSessionsJson(legacyJson)
  assertEqualInt(getSessionArrayLength(sessions), 1, "one legacy session parsed")
  val s = getSessionArrayValue(sessions, 0)
  assertEqual(s.harness, "claude", "legacy harness defaults to claude")
  assertEqual(s.model, "claude-opus-4-8", "legacy model defaults to harness default, not empty")
  assertEqual(s.nativeSessionId, "legacy-1", "legacy nativeSessionId defaults to sessionId")
}

test "Session store JSON escapes and round-trips special characters" {
  // Before jsonEscapeField, a quote or backslash in any user-supplied field
  // corrupted the entire store on the next save (and a value ending in a
  // backslash desynced the old look-behind quote scanner).
  val s = makeAgentSession(
    sessionId = "esc-1",
    repoUrl = "https://github.com/nic/re\"po",
    branch = "feat\\wip",
    containerId = "a\\",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = "esc-1"
  )
  val json = "{\"sessions\":[" + agentSessionToJson(s) + "]}"
  val parsed = parseSessionsJson(json)
  assertEqualInt(getSessionArrayLength(parsed), 1, "one session parsed")
  verifyEscapedRoundTrip(getSessionArrayValue(parsed, 0))
}

test "Session store parsing survives braces inside field values" {
  val s1 = makeAgentSession(
    sessionId = "brace-1",
    repoUrl = "https://github.com/nic/repo{x}",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = "brace-1"
  )
  val s2 = makeAgentSession(
    sessionId = "brace-2",
    repoUrl = "https://github.com/nic/other",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = "brace-2"
  )
  val json = "{\"sessions\":[" + agentSessionToJson(s1) + "," + agentSessionToJson(s2) + "]}"
  val parsed = parseSessionsJson(json)
  assertEqualInt(getSessionArrayLength(parsed), 2, "brace in a value must not desync object splitting")
  assertEqual(getSessionArrayValue(parsed, 1).sessionId, "brace-2", "second session parsed intact")
}

test "Test Handler createSession validation" {
  println("Testing Handler createSession validation...")

  // Test empty repoUrl validation
  val req1 = CreateSessionRequest(repoUrl = "", branch = "main", harness = "claude", model = "claude-opus-4-8")
  match createSession(req1) {
    case Ok(_) -> assertTrue(false, "should fail on empty repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "returns 400 bad request")
  }

  // Test non-https repoUrl validation
  val req1b = CreateSessionRequest(repoUrl = "git@github.com:nic/repo.git", branch = "main", harness = "claude", model = "claude-opus-4-8")
  match createSession(req1b) {
    case Ok(_) -> assertTrue(false, "should reject non-https repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "non-https returns 400")
  }

  val req1c = CreateSessionRequest(repoUrl = "http://github.com/nic/repo", branch = "main", harness = "claude", model = "claude-opus-4-8")
  match createSession(req1c) {
    case Ok(_) -> assertTrue(false, "should reject http repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "http returns 400")
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
    case Ok(resp) -> verifyAndCleanCreateSession(resp)
    case Err(_) -> assertTrue(false, "should successfully create session")
  }

  // An empty model must be backfilled with the harness default, not stored empty.
  val req4 = CreateSessionRequest(repoUrl = "https://github.com/nic/repos/cloud-agents", branch = "main", harness = "codex", model = "")
  match createSession(req4) {
    case Ok(resp) -> verifyModelBackfill(resp)
    case Err(_) -> assertTrue(false, "should create session with empty model")
  }

  println("✓ Handler validation tests passed!")
}

test "Handler createSession rejects unsafe inputs" {
  // A branch starting with '-' could be misread as a git command-line option.
  val r1 = CreateSessionRequest(repoUrl = "https://github.com/nic/repo", branch = "-evil", harness = "claude", model = "")
  match createSession(r1) {
    case Ok(_) -> assertTrue(false, "should reject leading-dash branch")
    case Err(err) -> assertEqualInt(err.status, 400, "leading-dash branch -> 400")
  }

  val r2 = CreateSessionRequest(repoUrl = "https://github.com/nic/repo", branch = "a..b", harness = "claude", model = "")
  match createSession(r2) {
    case Ok(_) -> assertTrue(false, "should reject '..' in branch")
    case Err(err) -> assertEqualInt(err.status, 400, "'..' branch -> 400")
  }

  val r3 = CreateSessionRequest(repoUrl = "https://github.com/nic/repo", branch = "main", harness = "garbage", model = "")
  match createSession(r3) {
    case Ok(_) -> assertTrue(false, "should reject unknown harness")
    case Err(err) -> assertEqualInt(err.status, 400, "unknown harness -> 400")
  }

  // A quote in the repoUrl used to corrupt (or forge fields in) the session
  // store JSON; now rejected at the boundary as well as escaped in the store.
  val r4 = CreateSessionRequest(repoUrl = "https://github.com/nic/re\"po", branch = "main", harness = "claude", model = "")
  match createSession(r4) {
    case Ok(_) -> assertTrue(false, "should reject quote in repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "quoted repoUrl -> 400")
  }

  val r5 = CreateSessionRequest(repoUrl = "https://github.com/nic/repo", branch = "main", harness = "claude", model = "bad model")
  match createSession(r5) {
    case Ok(_) -> assertTrue(false, "should reject whitespace in model")
    case Err(err) -> assertEqualInt(err.status, 400, "whitespace model -> 400")
  }
}

test "Handler listSessions returns stored sessions" {
  addSession(makeAgentSession(
    sessionId = "ls-1",
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = "ls-1"
  ))
  addSession(makeAgentSession(
    sessionId = "ls-2",
    repoUrl = "https://github.com/nic/other",
    branch = "main",
    containerId = "",
    harness = "codex",
    model = "o4-mini",
    nativeSessionId = "ls-2"
  ))
  match listSessions() {
    case Ok(body) -> verifyListSessionsBody(body)
    case Err(_) -> assertTrue(false, "listSessions should succeed")
  }
  val removedFirst = removeSession("ls-1")
  val removedSecond = removeSession("ls-2")
  assertTrue(removedFirst.isSome(), "ls-1 cleaned up")
  assertTrue(removedSecond.isSome(), "ls-2 cleaned up")
}

