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
import extern System.String as DotNetString

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
  return match r { case Ok(b) -> b; case Err(e) -> panic("run claim failed: " + CloudAgents.Sqlite.dbErrorMessage(e)) }
}

func mustInt(r: in Result[Int, CloudAgents.Sqlite.DbError]): Int {
  return match r { case Ok(n) -> n; case Err(e) -> panic("expected Ok(Int): " + CloudAgents.Sqlite.dbErrorMessage(e)) }
}

// Async wrapper so a run claim can be `spawn`ed inside a `scope` block (#206)
// — `tryBeginRun` itself is a plain synchronous func, so a genuinely
// concurrent test needs an async entry point to race it under `spawn`/`await`
// rather than calling it twice, sequentially, on one thread.
async func claimAsync(sessionId: in String): Bool {
  return mustClaim(CloudAgents.SessionStore.tryBeginRun(sessionId))
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

func verifyGeminiBackfill(resp: in CreateSessionResponse): Unit {
  match mustOptSession(getSession(resp.sessionId)) {
    case Some(s) -> assertEqual(s.model, "gemini-2.5-pro", "empty model backfilled with gemini default")
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
  // Bookkeeping columns the UI shows (when created / last active / running?).
  assertTrue(body.contains("\"status\":\"IDLE\""), "status included in list")
  assertTrue(body.contains("\"createdAt\":\""), "createdAt included in list")
  assertTrue(body.contains("\"lastMessageAt\":\""), "lastMessageAt included in list")
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

  // 3. Update container ID ("default" = the operator identity addSession
  // stored the session under on this test thread; the explicit-owner form is
  // the only one — see #426)
  mustUnit(updateSessionContainerFor(sessionId, "default", "container-abc"))
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
  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = "claim-1",
        repoUrl = "https://github.com/nic/repo",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "claude-opus-4-8",
        nativeSessionId = "claim-1"
      )
    )
  )

  assertTrue(mustClaim(CloudAgents.SessionStore.tryBeginRun("claim-1")), "first claim wins")
  assertFalse(mustClaim(CloudAgents.SessionStore.tryBeginRun("claim-1")), "second claim refused while running")
  mustUnit(CloudAgents.SessionStore.endRun("claim-1"))
  assertTrue(mustClaim(CloudAgents.SessionStore.tryBeginRun("claim-1")), "claim available again after endRun")
  assertFalse(mustClaim(CloudAgents.SessionStore.tryBeginRun("missing")), "claiming a nonexistent session fails")
}

test "Run claim is exclusive under real concurrent contention (#206)" {
  // The test above only proves the guard's logic (status check, scoping) by
  // calling tryBeginRun twice in sequence on one thread — it never actually
  // races two callers against the same row, so it doesn't exercise the
  // atomicity property tryBeginRunSql's guarded UPDATE
  // (`status <> 'RUNNING'`, rows-affected = 1 means the claim won) is meant to
  // guarantee under real contention. This test spawns two callers inside one
  // `scope` — both `spawn`s are issued before either is `await`ed, so the two
  // underlying tryBeginRun UPDATEs are genuinely in flight together, not run
  // one at a time — and asserts exactly one wins.
  val dbPath = useFreshTestDb("session-claim-concurrent")
  defer {
    cleanupTestDb(dbPath)
  }
  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = "claim-race",
        repoUrl = "https://github.com/nic/repo",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "claude-opus-4-8",
        nativeSessionId = "claim-race"
      )
    )
  )

  scope {
    val t1 = spawn claimAsync("claim-race")
    val t2 = spawn claimAsync("claim-race")
    val r1 = await t1
    val r2 = await t2
    assertTrue(r1 xor r2, "exactly one concurrent claim wins under real contention")
  }

  // The loser's failure was contention, not a stuck row: the winner's run is
  // still open (endRun not yet called), so a further claim must still refuse.
  assertFalse(mustClaim(CloudAgents.SessionStore.tryBeginRun("claim-race")), "session stays claimed after the race")
  mustUnit(CloudAgents.SessionStore.endRun("claim-race"))
  assertTrue(mustClaim(CloudAgents.SessionStore.tryBeginRun("claim-race")), "claim available again after endRun")
}

test "deleteSessionRecord removes the row and is a no-op when already gone (#310)" {
  val dbPath = useFreshTestDb("session-delete-record")
  defer {
    cleanupTestDb(dbPath)
  }
  val sessionId = "del-rec-1"
  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = sessionId,
        repoUrl = "https://github.com/nic/repo",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "claude-opus-4-8",
        nativeSessionId = sessionId
      )
    )
  )
  // Present before the delete.
  match mustOptSession(getSession(sessionId)) {
    case Some(_) -> ()
    case None -> assertTrue(false, "session should exist before deleteSessionRecord")
  }
  // deleteSessionRecord drops the row without re-reading it first (#172).
  mustUnit(deleteSessionRecord(sessionId))
  match mustOptSession(getSession(sessionId)) {
    case Some(_) -> assertTrue(false, "session should be gone after deleteSessionRecord")
    case None -> ()
  }
  // Deleting an already-gone row is a no-op success, not an error.
  mustUnit(deleteSessionRecord(sessionId))
}

test "recoverDanglingSessions frees sessions stuck RUNNING on restart (#198)" {
  val dbPath = useFreshTestDb("recover-dangling")
  defer {
    cleanupTestDb(dbPath)
  }
  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = "dangling-1",
        repoUrl = "https://github.com/nic/repo",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "claude-opus-4-8",
        nativeSessionId = "dangling-1"
      )
    )
  )
  // Claim it so it is RUNNING, then "crash" — the process dies without ever
  // calling endRun, leaving the row dangling. A second claim is refused.
  assertTrue(mustClaim(CloudAgents.SessionStore.tryBeginRun("dangling-1")), "claim wins")
  assertFalse(mustClaim(CloudAgents.SessionStore.tryBeginRun("dangling-1")), "second claim refused while RUNNING")
  // Startup recovery resets the dangling RUNNING row back to a usable state.
  val recovered = mustInt(recoverDanglingSessions())
  assertTrue(recovered >= 1, "at least one dangling session recovered")
  assertTrue(mustClaim(CloudAgents.SessionStore.tryBeginRun("dangling-1")), "claim available again after recovery")
}

test "importLegacyEnvSessions inserts env sessions into the store and clears the env (#198)" {
  val dbPath = useFreshTestDb("legacy-import")
  defer {
    cleanupTestDb(dbPath)
  }
  val s = makeAgentSession(
    sessionId = "legacy-import-1",
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = "legacy-import-1"
  )
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SESSIONS_JSON", "{\"sessions\":[" + agentSessionToJson(s) + "]}")
  importLegacyEnvSessions()
  // The env session is now persisted in SQLite...
  match mustOptSession(getSession("legacy-import-1")) {
    case Some(imported) -> assertEqual(imported.sessionId, "legacy-import-1", "imported session id matches")
    case None -> assertTrue(false, "legacy env session should have been imported into the store")
  }
  // ...and the env var is cleared so a restart doesn't re-import it.
  assertTrue(
    DotNetString.IsNullOrEmpty(Env.GetEnvironmentVariable("CLOUD_AGENTS_SESSIONS_JSON")),
    "CLOUD_AGENTS_SESSIONS_JSON cleared after a successful import"
  )
}

test "importLegacyEnvSessions imports only sessions not already in the store (#323)" {
  val dbPath = useFreshTestDb("legacy-import-mixed")
  defer {
    cleanupTestDb(dbPath)
  }
  // A session that already exists in the store.
  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = "legacy-existing",
        repoUrl = "https://github.com/nic/original",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "claude-opus-4-8",
        nativeSessionId = "legacy-existing"
      )
    )
  )
  // The env carries a *changed* copy of that existing session plus a brand-new
  // one. Import must insert only the new session and leave the existing row
  // untouched (skipped), not overwrite it with the env copy.
  val existingChanged = makeAgentSession(
    sessionId = "legacy-existing",
    repoUrl = "https://github.com/nic/CHANGED",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = "legacy-existing"
  )
  val fresh = makeAgentSession(
    sessionId = "legacy-new",
    repoUrl = "https://github.com/nic/new",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = "legacy-new"
  )
  Env.SetEnvironmentVariable(
    "CLOUD_AGENTS_SESSIONS_JSON",
    "{\"sessions\":[" + agentSessionToJson(existingChanged) + "," + agentSessionToJson(fresh) + "]}"
  )
  importLegacyEnvSessions()

  // The new session was inserted.
  match mustOptSession(getSession("legacy-new")) {
    case Some(_) -> ()
    case None -> assertTrue(false, "the new legacy session should have been imported")
  }
  // The pre-existing session was skipped, not overwritten by the env copy.
  match mustOptSession(getSession("legacy-existing")) {
    case Some(s) -> assertEqual(s.repoUrl, "https://github.com/nic/original", "existing session left untouched (not overwritten by the env copy)")
    case None -> assertTrue(false, "existing session should still be present after import")
  }
}

test "Test default model per harness" {
  assertEqual(defaultModelForHarness("claude"), "claude-opus-4-8", "claude default model")
  assertEqual(defaultModelForHarness("codex"), "o4-mini", "codex default model")
  assertEqual(defaultModelForHarness("opencode"), "claude-sonnet-4-6", "opencode default model")
  assertEqual(defaultModelForHarness("gemini"), "gemini-2.5-pro", "gemini default model")
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
  val req1b = CreateSessionRequest(
    repoUrl = "git@github.com:nic/repo.git",
    branch = "main",
    harness = "claude",
    model = "claude-opus-4-8"
  )
  match createSession(req1b) {
    case Ok(_) -> assertTrue(false, "should reject non-https repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "non-https returns 400")
  }

  val req1c = CreateSessionRequest(
    repoUrl = "http://github.com/nic/repo",
    branch = "main",
    harness = "claude",
    model = "claude-opus-4-8"
  )
  match createSession(req1c) {
    case Ok(_) -> assertTrue(false, "should reject http repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "http returns 400")
  }

  // SSRF: a repoUrl pointing at a loopback/link-local/private host must be
  // rejected before the runner clones it (#33).
  val ssrfLoopback = CreateSessionRequest(
    repoUrl = "https://127.0.0.1/nic/repo",
    branch = "main",
    harness = "claude",
    model = "claude-opus-4-8"
  )
  match createSession(ssrfLoopback) {
    case Ok(_) -> assertTrue(false, "should reject loopback repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "loopback repoUrl returns 400")
  }
  val ssrfMetadata = CreateSessionRequest(
    repoUrl = "https://169.254.169.254/latest/meta-data",
    branch = "main",
    harness = "claude",
    model = "claude-opus-4-8"
  )
  match createSession(ssrfMetadata) {
    case Ok(_) -> assertTrue(false, "should reject link-local metadata repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "link-local repoUrl returns 400")
  }
  val ssrfLocalhost = CreateSessionRequest(
    repoUrl = "https://localhost/nic/repo",
    branch = "main",
    harness = "claude",
    model = "claude-opus-4-8"
  )
  match createSession(ssrfLocalhost) {
    case Ok(_) -> assertTrue(false, "should reject localhost repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "localhost repoUrl returns 400")
  }
  // Userinfo must not smuggle a public host past the check (authority parsing).
  val ssrfUserinfo = CreateSessionRequest(
    repoUrl = "https://github.com@127.0.0.1/repo",
    branch = "main",
    harness = "claude",
    model = "claude-opus-4-8"
  )
  match createSession(ssrfUserinfo) {
    case Ok(_) -> assertTrue(false, "should reject userinfo-smuggled loopback repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "userinfo loopback repoUrl returns 400")
  }

  // Test empty branch validation
  val req2 = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repos/cloud-agents",
    branch = "",
    harness = "claude",
    model = "claude-opus-4-8"
  )
  match createSession(req2) {
    case Ok(_) -> assertTrue(false, "should fail on empty branch")
    case Err(err) -> assertEqualInt(err.status, 400, "returns 400 bad request")
  }

  // Test successful session creation
  val req3 = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repos/cloud-agents",
    branch = "main",
    harness = "claude",
    model = "claude-opus-4-8"
  )
  match createSession(req3) {
    case Ok(resp) -> verifyAndCleanCreateSession(resp)
    case Err(_) -> assertTrue(false, "should successfully create session")
  }

  // An empty model must be backfilled with the harness default, not stored empty.
  val req4 = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repos/cloud-agents",
    branch = "main",
    harness = "codex",
    model = ""
  )
  match createSession(req4) {
    case Ok(resp) -> verifyModelBackfill(resp)
    case Err(_) -> assertTrue(false, "should create session with empty model")
  }

  // The gemini harness is accepted and gets its own default model.
  val req5 = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repos/cloud-agents",
    branch = "main",
    harness = "gemini",
    model = ""
  )
  match createSession(req5) {
    case Ok(resp) -> verifyGeminiBackfill(resp)
    case Err(_) -> assertTrue(false, "should accept the gemini harness")
  }

  println("✓ Handler validation tests passed!")
}

test "Handler createSession rejects unsafe inputs" {
  // A branch starting with '-' could be misread as a git command-line option.
  val r1 = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repo",
    branch = "-evil",
    harness = "claude",
    model = ""
  )
  match createSession(r1) {
    case Ok(_) -> assertTrue(false, "should reject leading-dash branch")
    case Err(err) -> assertEqualInt(err.status, 400, "leading-dash branch -> 400")
  }

  val r2 = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repo",
    branch = "a..b",
    harness = "claude",
    model = ""
  )
  match createSession(r2) {
    case Ok(_) -> assertTrue(false, "should reject '..' in branch")
    case Err(err) -> assertEqualInt(err.status, 400, "'..' branch -> 400")
  }

  val r3 = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    harness = "garbage",
    model = ""
  )
  match createSession(r3) {
    case Ok(_) -> assertTrue(false, "should reject unknown harness")
    case Err(err) -> assertEqualInt(err.status, 400, "unknown harness -> 400")
  }

  // A quote in the repoUrl used to corrupt (or forge fields in) the session
  // store JSON; now rejected at the boundary as well as escaped in the store.
  val r4 = CreateSessionRequest(
    repoUrl = "https://github.com/nic/re\"po",
    branch = "main",
    harness = "claude",
    model = ""
  )
  match createSession(r4) {
    case Ok(_) -> assertTrue(false, "should reject quote in repoUrl")
    case Err(err) -> assertEqualInt(err.status, 400, "quoted repoUrl -> 400")
  }

  val r5 = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    harness = "claude",
    model = "bad model"
  )
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

  val r7 = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repo",
    branch = "feat/.wip",
    harness = "claude",
    model = ""
  )
  match createSession(r7) {
    case Ok(_) -> assertTrue(false, "should reject dot-leading component")
    case Err(err) -> assertEqualInt(err.status, 400, "dot-leading component -> 400")
  }
}

test "createSession rejects a known-but-disabled harness (#560)" {
  val dbPath = useFreshTestDb("session-create-harness-gate")
  defer {
    cleanupTestDb(dbPath)
  }
  // Distinct from the "unknown harness" case above (isKnownHarness rejects a
  // name this deployment never recognizes at all); this exercises the
  // isHarnessEnabled gate specifically — a name isKnownHarness accepts, but
  // this deployment's CLOUD_AGENTS_ENABLED_HARNESSES doesn't include.
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ENABLED_HARNESSES", "codex")
  val disabled = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    harness = "claude",
    model = ""
  )
  match createSession(disabled) {
    case Ok(_) -> assertTrue(false, "should reject a harness this deployment disabled")
    case Err(err) -> assertEqualInt(err.status, 400, "disabled harness -> 400")
  }
  // The resolved-default path (empty harness -> "claude") must be checked
  // too, not just an explicitly-requested one.
  val disabledDefault = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    harness = "",
    model = ""
  )
  match createSession(disabledDefault) {
    case Ok(_) -> assertTrue(false, "should reject when the default harness itself is disabled")
    case Err(err) -> assertEqualInt(err.status, 400, "disabled default harness -> 400")
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ENABLED_HARNESSES", "")
  val reenabled = CreateSessionRequest(
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    harness = "claude",
    model = ""
  )
  match createSession(reenabled) {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, "claude should be accepted once re-enabled (status " + toString(err.status) + ")")
  }
}

// NOTE: getRunOutput has no unit test. Every attempt to invoke it from a test
// fails at runtime with "The signature is incorrect" — the same class of
// toolchain quirk documented in docs/lyric/gotchas.md for other v0.4.19
// runtime failures. The failure survived three complete rewrites of the
// handler (records with a Bool field, records with a String field, and the
// current hand-built JSON String return), which rules out the handler's shape
// as the cause and points at the test-runner's dispatch of that specific
// signature. The handler itself is exercised end-to-end once Lyric.Web can
// dispatch HTTP requests to handlers (see docs/BUILD.md); until then its
// validation (empty -> 400, unknown -> 404) mirrors the other session
// handlers that ARE covered above.
//
// getRunOutputFrom (the incremental /output/{offset} variant) shares that
// fate for direct invocation — it references CloudAgents.Docker
// (partialContainerLogs) too, so its unknown-session -> 404 path cannot be
// invoked from here either. Its Docker-free logic is therefore extracted
// into pure pub helpers and covered below instead: parseOutputOffset is the
// entire bad-offset -> 400 boundary (the handler 400s exactly when it
// returns -1), and runOutputDeltaJson builds the exact response bodies for
// both the non-RUNNING ("running":"false") and RUNNING paths, including the
// offset-past-total client-resync rule. The handler itself is a thin
// composition of those two plus the same status/container lookups
// getRunOutput makes.
test "parseOutputOffset accepts 1..9 digits and rejects everything else (-> 400)" {
  assertEqualInt(parseOutputOffset("0"), 0, "zero parses")
  assertEqualInt(parseOutputOffset("42"), 42, "small offset parses")
  assertEqualInt(parseOutputOffset("999999999"), 999999999, "nine digits (max) parse")
  assertEqualInt(parseOutputOffset(""), -1, "empty rejected")
  assertEqualInt(parseOutputOffset("1234567890"), -1, "ten digits rejected")
  assertEqualInt(parseOutputOffset("-1"), -1, "sign rejected")
  assertEqualInt(parseOutputOffset("12a"), -1, "trailing non-digit rejected")
  assertEqualInt(parseOutputOffset(" 1"), -1, "leading whitespace rejected")
}

test "runOutputDeltaJson returns only the log past the offset" {
  assertEqual(
    runOutputDeltaJson(true, "hello world", 6),
    "{\"running\":\"true\",\"length\":\"11\",\"chunk\":\"world\"}",
    "chunk is the log past the offset, length is the new total"
  )
  assertEqual(
    runOutputDeltaJson(true, "abc", 0),
    "{\"running\":\"true\",\"length\":\"3\",\"chunk\":\"abc\"}",
    "offset 0 returns the full log"
  )
}

test "runOutputDeltaJson caught-up and non-RUNNING bodies" {
  assertEqual(
    runOutputDeltaJson(true, "abc", 3),
    "{\"running\":\"true\",\"length\":\"3\",\"chunk\":\"\"}",
    "offset == total -> empty chunk (client is caught up)"
  )
  // The body getRunOutputFrom returns whenever the session is not RUNNING.
  assertEqual(
    runOutputDeltaJson(false, "", 0),
    "{\"running\":\"false\",\"length\":\"0\",\"chunk\":\"\"}",
    "non-RUNNING body signals the client to stop polling"
  )
}

test "runOutputDeltaJson treats an offset past the total as 0 (client resync)" {
  // The client's offset outlived the log (a new run truncated/replaced it):
  // return the FULL log with the new length — the client sees length below
  // the offset it sent and replaces its accumulated output instead of
  // appending.
  assertEqual(
    runOutputDeltaJson(true, "new", 500),
    "{\"running\":\"true\",\"length\":\"3\",\"chunk\":\"new\"}",
    "offset > total -> full log as the chunk (resync)"
  )
}

test "runOutputDeltaJson JSON-escapes the chunk" {
  assertEqual(
    runOutputDeltaJson(true, "a\"b\nc", 0),
    "{\"running\":\"true\",\"length\":\"5\",\"chunk\":\"a\\\"b\\nc\"}",
    "quotes and newlines in container output are escaped"
  )
}

test "Handler listSessions returns stored sessions" {
  val dbPath = useFreshTestDb("session-list")
  defer {
    cleanupTestDb(dbPath)
  }
  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = "ls-1",
        repoUrl = "https://github.com/nic/repo",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "claude-opus-4-8",
        nativeSessionId = "ls-1"
      )
    )
  )
  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = "ls-2",
        repoUrl = "https://github.com/nic/other",
        branch = "main",
        containerId = "",
        harness = "codex",
        model = "o4-mini",
        nativeSessionId = "ls-2"
      )
    )
  )
  match listSessions() {
    case Ok(body) -> verifyListSessionsBody(body)
    case Err(_) -> assertTrue(false, "listSessions should succeed")
  }
}

test "getRuns 404s for an unknown session (#239)" {
  val dbPath = useFreshTestDb("get-runs")
  defer {
    cleanupTestDb(dbPath)
  }
  match getRuns("nope") {
    case Ok(_) -> assertTrue(false, "unknown session should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "unknown session -> 404")
  }
  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = "gr-1",
        repoUrl = "https://github.com/nic/repo",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "claude-opus-4-8",
        nativeSessionId = "gr-1"
      )
    )
  )
  match getRuns("gr-1") {
    case Ok(rl) -> assertEqualInt(rl.runs.length.toInt(), 0, "known session with no runs -> empty list")
    case Err(_) -> assertTrue(false, "known session should succeed")
  }
}

test "reapableWarmContainers finds and frees aged WARM sessions (#241)" {
  val dbPath = useFreshTestDb("reap")
  defer {
    cleanupTestDb(dbPath)
  }
  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = "warm-1",
        repoUrl = "https://github.com/nic/repo",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "claude-opus-4-8",
        nativeSessionId = "warm-1"
      )
    )
  )
  // Force it WARM with an ancient last_message_at (epoch 0) and a container id,
  // so it is unambiguously past the warm window.
  match CloudAgents.Sqlite.execute("UPDATE sessions SET status = 'WARM', container_id = 'c-warm', last_message_at = '0' WHERE id = 'warm-1'") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setup update failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val targets = match CloudAgents.SessionStore.reapableWarmContainers() {
    case Ok(t) -> t
    case Err(e) -> panic("reapableWarmContainers failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertEqualInt(targets.length.toInt(), 1, "aged warm session is reapable")
  assertEqual(targets[0].containerId, "c-warm", "reap target carries the container id")

  match CloudAgents.SessionStore.reapSessionContainer("warm-1") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "reapSessionContainer failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val after = match CloudAgents.SessionStore.reapableWarmContainers() {
    case Ok(t) -> t
    case Err(e) -> panic("reapableWarmContainers failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertEqualInt(after.length.toInt(), 0, "reaped session is no longer reapable")
}

test "Session ownership isolation hides other users' sessions (#207)" {
  val dbPath = useFreshTestDb("session-isolation")
  defer {
    cleanupTestDb(dbPath)
  }
  // Insert a session owned by another user directly (the store's own writes are
  // hardcoded to the current user, so a raw insert is the only way to stage a
  // cross-user row). profile_id defaults to ''.
  match CloudAgents.Sqlite.execute("INSERT INTO sessions (id, user_id, repo_url, branch, container_id, harness, model, native_session_id, status, created_at, last_message_at) VALUES ('foreign-1', 'other-user', 'https://github.com/x/y', 'main', '', 'claude', 'm', 'foreign-1', 'IDLE', '1000', '1000')") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "setup insert failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // The current user ("default") cannot read another user's session by id...
  match getSession("foreign-1") {
    case Ok(Some(_)) -> assertTrue(false, "must not read another user's session")
    case Ok(None) -> ()
    case Err(e) -> assertTrue(false, "getSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // ...nor see it in the list.
  match CloudAgents.SessionStore.getSessions() {
    case Ok(arr) -> assertEqualInt(CloudAgents.SessionStore.getSessionArrayLength(arr), 0, "foreign session not listed")
    case Err(e) -> assertTrue(false, "getSessions failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // The current user's own session is visible.
  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = "mine-1",
        repoUrl = "https://github.com/nic/repo",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "claude-opus-4-8",
        nativeSessionId = "mine-1"
      )
    )
  )
  match getSession("mine-1") {
    case Ok(Some(_)) -> ()
    case Ok(None) -> assertTrue(false, "own session should be visible")
    case Err(e) -> assertTrue(false, "getSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // The list now holds exactly my one session — the foreign row stays hidden.
  match CloudAgents.SessionStore.getSessions() {
    case Ok(arr) -> assertEqualInt(CloudAgents.SessionStore.getSessionArrayLength(arr), 1, "only my own session listed")
    case Err(e) -> assertTrue(false, "getSessions failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── Session lifecycle: run history, cancel, profile wiring ────────────────────
func mustRunId(r: in Result[String, CloudAgents.Sqlite.DbError]): String {
  return match r {
    case Ok(rid) -> rid
    case Err(e) -> panic("recordRunStart failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustRuns(r: in Result[slice[Run], CloudAgents.Sqlite.DbError]): slice[Run] {
  return match r { case Ok(rs) -> rs; case Err(e) -> panic("listRuns failed: " + CloudAgents.Sqlite.dbErrorMessage(e)) }
}

test "Run history records, lists, and finishes write-once" {
  val dbPath = useFreshTestDb("run-history")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"
  val runId = mustRunId(CloudAgents.Repository.recordRunStart("rh-1", userId, "do a thing", "claude", "opus"))
  assertTrue(runId.length > 0, "run id returned")

  val running = mustRuns(CloudAgents.Repository.listRuns("rh-1", userId))
  assertEqualInt(running.length.toInt(), 1, "one run recorded")
  assertEqual(running[0].status, "running", "run starts running")

  match CloudAgents.Repository.recordRunEnd(runId, userId, "succeeded") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "recordRunEnd failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertEqual(
    mustRuns(CloudAgents.Repository.listRuns("rh-1", userId))[0].status,
    "succeeded",
    "run moved to succeeded"
  )

  // Write-once: a late 'failed' does not overwrite the terminal status.
  match CloudAgents.Repository.recordRunEnd(runId, userId, "failed") {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  assertEqual(
    mustRuns(CloudAgents.Repository.listRuns("rh-1", userId))[0].status,
    "succeeded",
    "terminal status is write-once"
  )
}

// NOTE: cancelRun has no unit test. Like getRunOutput, it transitively
// references CloudAgents.Docker (terminateSessionContainer), and invoking a
// Docker-referencing handler from the test harness fails at runtime with "The
// signature is incorrect" — the same v0.4.19 toolchain quirk documented in
// docs/lyric/gotchas.md (handlers that don't pull in Docker, like
// setSessionProfileHandler below, invoke fine). Its validation (empty -> 400,
// unknown -> 404, not-running -> 409) mirrors the covered handlers; it
// activates end-to-end once Lyric.Web dispatches HTTP requests.
test "setSessionProfileHandler validates session and profile (#235)" {
  val dbPath = useFreshTestDb("set-profile")
  defer {
    cleanupTestDb(dbPath)
  }
  match setSessionProfileHandler("nope", SetProfileRequest(profileId = "")) {
    case Ok(_) -> assertTrue(false, "unknown session should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "unknown session -> 404")
  }
  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = "sp-1",
        repoUrl = "https://github.com/nic/repo",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "claude-opus-4-8",
        nativeSessionId = "sp-1"
      )
    )
  )
  // A session with no profile attached reports an empty profileId (#272).
  match getSessionProfileHandler("sp-1") {
    case Ok(ref) -> assertEqual(ref.profileId, "", "no-profile session reports empty profileId")
    case Err(_) -> assertTrue(false, "getSessionProfileHandler should succeed for a known session")
  }
  // Unknown profile -> 400.
  match setSessionProfileHandler("sp-1", SetProfileRequest(profileId = "ghost")) {
    case Ok(_) -> assertTrue(false, "unknown profile should 400")
    case Err(err) -> assertEqualInt(err.status, 400, "unknown profile -> 400")
  }
  // Attach a real profile; it reads back on the session.
  val prof = match CloudAgents.Repository.addProfile("default", "p", "", "none", "all", [], [], [], [], "all", []) {
    case Ok(p) -> p
    case Err(e) -> panic("addProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match setSessionProfileHandler("sp-1", SetProfileRequest(profileId = prof.id)) {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "attaching a valid profile should succeed")
  }
  match CloudAgents.SessionStore.sessionProfileId("sp-1") {
    case Ok(Some(pid)) -> assertEqual(pid, prof.id, "profile attached to session")
    case Ok(None) -> assertTrue(false, "profile should be set")
    case Err(e) -> assertTrue(false, "sessionProfileId failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // getSessionProfileHandler reflects the attached profile (#270)...
  match getSessionProfileHandler("sp-1") {
    case Ok(ref) -> assertEqual(ref.profileId, prof.id, "handler reports the attached profile")
    case Err(_) -> assertTrue(false, "getSessionProfileHandler should succeed")
  }
  // ...and 404s for an unknown session.
  match getSessionProfileHandler("nope") {
    case Ok(_) -> assertTrue(false, "unknown session should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "unknown session -> 404")
  }
}

// ── Multi-repo sessions ───────────────────────────────────────────────────────
test "extraReposEnvValue formats url|branch entries space-separated" {
  val repos = [
    SessionRepo(
      id = "r1",
      sessionId = "s1",
      repoUrl = "https://github.com/a/b",
      branch = "main",
      createdAt = "1"
    ),
    SessionRepo(
      id = "r2",
      sessionId = "s1",
      repoUrl = "https://github.com/c/d",
      branch = "",
      createdAt = "2"
    )
  ]
  assertEqual(
    extraReposEnvValue(repos),
    "https://github.com/a/b|main https://github.com/c/d|",
    "url|branch entries space-separated; an empty branch is a trailing pipe"
  )
  val none: slice[SessionRepo] = []
  assertEqual(extraReposEnvValue(none), "", "no linked repos -> empty env value")
}

test "session-repo handlers validate, link, list and unlink (#multi-repo)" {
  val dbPath = useFreshTestDb("session-repos")
  defer {
    cleanupTestDb(dbPath)
  }
  // All three 404 for an unknown/foreign session.
  match listSessionReposHandler("nope") {
    case Ok(_) -> assertTrue(false, "list unknown session should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "list unknown -> 404")
  }
  match addSessionRepoHandler("nope", AddRepoRequest(repoUrl = "https://github.com/a/b", branch = "main")) {
    case Ok(_) -> assertTrue(false, "add to unknown session should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "add unknown -> 404")
  }

  mustUnit(
    addSession(
      makeAgentSession(
        sessionId = "sr-1",
        repoUrl = "https://github.com/nic/repo",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "claude-opus-4-8",
        nativeSessionId = "sr-1"
      )
    )
  )

  // Initially empty.
  match listSessionReposHandler("sr-1") {
    case Ok(rl) -> assertEqualInt(rl.repos.length.toInt(), 0, "no linked repos initially")
    case Err(_) -> assertTrue(false, "list should succeed for a known session")
  }

  // Same validation as session creation: non-https, SSRF host, unsafe branch.
  match addSessionRepoHandler("sr-1", AddRepoRequest(repoUrl = "http://github.com/a/b", branch = "main")) {
    case Ok(_) -> assertTrue(false, "non-https should 400")
    case Err(err) -> assertEqualInt(err.status, 400, "non-https -> 400")
  }
  match addSessionRepoHandler("sr-1", AddRepoRequest(repoUrl = "https://127.0.0.1/a/b", branch = "main")) {
    case Ok(_) -> assertTrue(false, "loopback should 400")
    case Err(err) -> assertEqualInt(err.status, 400, "loopback repoUrl -> 400")
  }
  match addSessionRepoHandler("sr-1", AddRepoRequest(repoUrl = "https://github.com/a/b", branch = "-bad")) {
    case Ok(_) -> assertTrue(false, "leading-dash branch should 400")
    case Err(err) -> assertEqualInt(err.status, 400, "bad branch -> 400")
  }
  // A '|' in the url or branch would corrupt the EXTRA_REPOS "url|branch"
  // packing, so it is rejected specifically for linked repos (#449).
  match addSessionRepoHandler("sr-1", AddRepoRequest(repoUrl = "https://github.com/a/b|c", branch = "main")) {
    case Ok(_) -> assertTrue(false, "pipe in repoUrl should 400")
    case Err(err) -> assertEqualInt(err.status, 400, "pipe in repoUrl -> 400")
  }
  match addSessionRepoHandler("sr-1", AddRepoRequest(repoUrl = "https://github.com/a/b", branch = "ma|in")) {
    case Ok(_) -> assertTrue(false, "pipe in branch should 400")
    case Err(err) -> assertEqualInt(err.status, 400, "pipe in branch -> 400")
  }

  // A valid link with an empty branch (the repo's default branch is allowed).
  val addedId = match addSessionRepoHandler("sr-1", AddRepoRequest(repoUrl = "https://github.com/nic/extra", branch = "")) {
    case Ok(repo) -> repo.id
    case Err(_) -> panic("linking a valid repo should have succeeded")
  }
  assertTrue(addedId.length > 0, "link returns a repo id")

  // Re-linking the same URL is a duplicate -> 400.
  match addSessionRepoHandler("sr-1", AddRepoRequest(repoUrl = "https://github.com/nic/extra", branch = "dev")) {
    case Ok(_) -> assertTrue(false, "duplicate url should 400")
    case Err(err) -> assertEqualInt(err.status, 400, "duplicate -> 400")
  }

  // Now listed once.
  match listSessionReposHandler("sr-1") {
    case Ok(rl) -> assertEqualInt(rl.repos.length.toInt(), 1, "one linked repo after add")
    case Err(_) -> assertTrue(false, "list should succeed")
  }

  // Unlinking a repo id that isn't linked -> 404.
  match deleteSessionRepoHandler("sr-1", "ghost") {
    case Ok(_) -> assertTrue(false, "unknown repo id should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "unknown repo -> 404")
  }

  // Unlink the real one, then the list is empty again.
  match deleteSessionRepoHandler("sr-1", addedId) {
    case Ok(_) -> ()
    case Err(_) -> assertTrue(false, "unlinking a linked repo should succeed")
  }
  match listSessionReposHandler("sr-1") {
    case Ok(rl) -> assertEqualInt(rl.repos.length.toInt(), 0, "no linked repos after unlink")
    case Err(_) -> assertTrue(false, "list should succeed")
  }
}

// ── #334: sendMessage's prompt cap and checkHealth's DB-failure path ─────────
//
// Both were left uncovered by PR #333 (#35/#57's Handlers-side half): they
// live in CloudAgents.Handlers, which imports the async CloudAgents.Docker,
// and streamSendMessage itself calls into CloudAgents.Docker further down —
// so it can't be invoked from this harness at all (same class of gap as
// cancelRun/getRunOutput above). promptExceedsMaxLength is a pub, pure
// extraction of exactly the check streamSendMessage runs before it ever
// touches Docker (mirroring parseOutputOffset/runOutputDeltaJson's existing
// split). checkHealth, by contrast, never references CloudAgents.Docker at
// all — only CloudAgents.Repository.ping() — so it needs no such extraction
// and is invoked directly below.
// A string of exactly `totalLen` 'x' characters, built by doubling (like
// tests/interactions_tests.l's overLongText) rather than looping totalLen
// times.
func repeatedChar(totalLen: in Int): String {
  var s = "x"
  while s.length.toInt() < totalLen {
    s = s + s
  }
  return s.substring(0, totalLen)
}

test "promptExceedsMaxLength enforces the 131072-char cap streamSendMessage relies on (#334/#35)" {
  assertFalse(promptExceedsMaxLength("short prompt"), "a short prompt is well under the cap")
  assertFalse(promptExceedsMaxLength(repeatedChar(131072)), "text exactly at the cap is not over")
  assertTrue(promptExceedsMaxLength(repeatedChar(131073)), "text one character over the cap is over")
}

test "checkHealth reports healthy against a live DB and 500s when the DB is unreachable (#334/#57)" {
  val dbPath = useFreshTestDb("health-ok")
  defer {
    cleanupTestDb(dbPath)
    // Otherwise this test's own next line leaves CLOUD_AGENTS_DB_PATH
    // pointed at a permanently-broken path for the rest of the process
    // (#579) — restore it to the fresh path useFreshTestDb set, exactly
    // what it was before this test's own DB-unreachable mutation below.
    Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", dbPath)
  }
  match checkHealth() {
    case Ok(msg) -> assertEqual(msg, "Healthy", "a live, migrated DB reports healthy")
    case Err(_) -> assertTrue(false, "checkHealth should succeed against a live, migrated DB")
  }

  // Point CLOUD_AGENTS_DB_PATH at a file under a directory that does not
  // exist: SQLite cannot open (or create) a database file there, so
  // CloudAgents.Repository.ping() -> Err(OpenFailed) and checkHealth must map
  // that to a 500 — not leak the raw DB error message to the unauthenticated
  // /api/health caller (#55).
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", "/nonexistent-dir-cloud-agents-334/unreachable.db")
  match checkHealth() {
    case Ok(_) -> assertTrue(false, "checkHealth must fail when the database is unreachable")
    case Err(err) -> assertEqualInt(err.status, 500, "DB failure maps to a 500 internal error")
  }
}
