@test_module
package CloudAgents.SessionTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Handlers
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Streaming
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/prompt_tests.l) ───────────────────

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return path
}

func cleanupTestDb(path: in String): Unit {
  try {
    fileDelete(path)
  } catch Bug as b {
    // locked or already gone — fine for a temp file
  }
}

// Result convenience methods fail at runtime (docs/lyric/gotchas.md) —
// unwrap via match+panic.
func mustUnit(r: in Result[Unit, CloudAgents.Sqlite.DbError]): Unit {
  return match r {
    case Ok(_) -> ()
    case Err(e) -> panic("session store op failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustOptSession(r: in Result[Option[AgentSession], CloudAgents.Sqlite.DbError]): Option[AgentSession] {
  return match r {
    case Ok(o) -> o
    case Err(e) -> panic("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustClaim(r: in Result[Bool, CloudAgents.Sqlite.DbError]): Bool {
  return match r {
    case Ok(b) -> b
    case Err(e) -> panic("run claim failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

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
  val _ = mustOptSession(removeSession(resp.sessionId))
}

func verifyModelBackfill(resp: in CreateSessionResponse): Unit {
  match mustOptSession(getSession(resp.sessionId)) {
    case Some(s) -> assertEqual(s.model, "o4-mini", "empty model backfilled with codex default")
    case None -> assertTrue(false, "created session should exist")
  }
  val _ = mustOptSession(removeSession(resp.sessionId))
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
  // The list is a public projection: infrastructure handles must not leak.
  assertFalse(body.contains("containerId"), "containerId excluded from list")
  assertFalse(body.contains("nativeSessionId"), "nativeSessionId excluded from list")
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Test Session Store CRUD Operations" {
  val dbPath = useFreshTestDb("session-crud")
  defer {
    cleanupTestDb(dbPath)
  }
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
  mustUnit(addSession(session))

  // 2. Get and verify session
  match mustOptSession(getSession(sessionId)) {
    case Some(s) -> verifyNewSession(s, sessionId)
    case None -> assertTrue(false, "session should exist in store")
  }

  // 3. Update container ID
  mustUnit(updateSessionContainer(sessionId, "container-abc"))
  match mustOptSession(getSession(sessionId)) {
    case Some(s) -> verifyContainerUpdate(s)
    case None -> assertTrue(false, "session should still exist in store")
  }

  // 4. Switch model (same harness). Fully qualified: both SessionStore and
  // Handlers export an `updateSessionModel`, and the compiler resolves the
  // ambiguity silently by import order rather than erroring — an unqualified
  // call here bound to the Handlers overload (wrong argument type, runtime
  // cast crash) when the imports were reordered.
  mustUnit(CloudAgents.SessionStore.updateSessionModel(sessionId, "claude-sonnet-4-6"))
  match mustOptSession(getSession(sessionId)) {
    case Some(s) -> verifyModelSwitch(s, sessionId)
    case None -> assertTrue(false, "session should still exist in store")
  }

  // 5. Remove session
  match mustOptSession(removeSession(sessionId)) {
    case Some(s) -> assertEqual(s.sessionId, sessionId, "removed session ID matches")
    case None -> assertTrue(false, "should successfully remove session")
  }

  // 6. Verify removed
  match mustOptSession(getSession(sessionId)) {
    case Some(_) -> assertTrue(false, "session should no longer exist")
    case None -> ()
  }

  println("✓ Session Store tests passed!")
}

test "Run claim is exclusive per session" {
  val dbPath = useFreshTestDb("session-claim")
  defer {
    cleanupTestDb(dbPath)
  }
  mustUnit(addSession(makeAgentSession(
    sessionId = "claim-1",
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = "claim-1"
  )))

  assertTrue(mustClaim(CloudAgents.SessionStore.tryBeginRun("claim-1")), "first claim wins")
  assertFalse(mustClaim(CloudAgents.SessionStore.tryBeginRun("claim-1")), "second claim refused while running")
  mustUnit(CloudAgents.SessionStore.endRun("claim-1"))
  assertTrue(mustClaim(CloudAgents.SessionStore.tryBeginRun("claim-1")), "claim available again after endRun")
  assertFalse(mustClaim(CloudAgents.SessionStore.tryBeginRun("missing")), "claiming a nonexistent session fails")
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

test "Session store round-trips control characters in fields" {
  // The handler boundary rejects control chars today, but the store must not
  // depend on every future writer validating (review #170). charFromCode
  // comes from CloudAgents.Streaming since Lyric literals can't express ESC.
  val esc = charFromCode(27)
  val s = makeAgentSession(
    sessionId = "ctl-1",
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    containerId = "id" + esc + "tail",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = "ctl-1"
  )
  val json = "{\"sessions\":[" + agentSessionToJson(s) + "]}"
  assertTrue(json.contains("\\u001b"), "control char stored as unicode escape")
  val parsed = parseSessionsJson(json)
  assertEqualInt(getSessionArrayLength(parsed), 1, "one session parsed")
  assertEqual(getSessionArrayValue(parsed, 0).containerId, "id" + esc + "tail", "control char round-trips")
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
  val dbPath = useFreshTestDb("session-create")
  defer {
    cleanupTestDb(dbPath)
  }
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

  // git check-ref-format edge cases: reserved '@' and dot-leading components
  val r6 = CreateSessionRequest(repoUrl = "https://github.com/nic/repo", branch = "@", harness = "claude", model = "")
  match createSession(r6) {
    case Ok(_) -> assertTrue(false, "should reject reserved '@' branch")
    case Err(err) -> assertEqualInt(err.status, 400, "'@' branch -> 400")
  }

  val r7 = CreateSessionRequest(repoUrl = "https://github.com/nic/repo", branch = "feat/.wip", harness = "claude", model = "")
  match createSession(r7) {
    case Ok(_) -> assertTrue(false, "should reject dot-leading component")
    case Err(err) -> assertEqualInt(err.status, 400, "dot-leading component -> 400")
  }
}

test "Handler listSessions returns stored sessions" {
  val dbPath = useFreshTestDb("session-list")
  defer {
    cleanupTestDb(dbPath)
  }
  mustUnit(addSession(makeAgentSession(
    sessionId = "ls-1",
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = "ls-1"
  )))
  mustUnit(addSession(makeAgentSession(
    sessionId = "ls-2",
    repoUrl = "https://github.com/nic/other",
    branch = "main",
    containerId = "",
    harness = "codex",
    model = "o4-mini",
    nativeSessionId = "ls-2"
  )))
  match listSessions() {
    case Ok(body) -> verifyListSessionsBody(body)
    case Err(_) -> assertTrue(false, "listSessions should succeed")
  }
}

