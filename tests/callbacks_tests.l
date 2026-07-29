@test_module
package CloudAgents.CallbacksTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Callbacks
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/session_tests.l) ──────────────────
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
  // Reset the injectable timeout so it never leaks into a later test.
  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS", "")
  CloudAgents.Auth.setCurrentUserId("default")
}

// ── Helpers ──────────────────────────────────────────────────────────────────
func mkSession(id: in String): Unit {
  val s = makeAgentSession(
    sessionId = id,
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = id
  )
  match addSession(s) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mintToken(id: in String, ownerUserId: in String): String {
  return match CloudAgents.SessionStore.mintCallbackToken(id, ownerUserId) {
    case Ok(t) -> t
    case Err(e) -> panic("mintCallbackToken failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func bearer(token: in String): String {
  return "Bearer " + token
}

// ── Permission requests ────────────────────────────────────────────────────
test "permission request round trip: create -> poll pending -> answer allow -> poll allowed" {
  val dbPath = useFreshTestDb("perm-roundtrip")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-perm-1"
  mkSession(sid)
  val token = mintToken(sid, "default")

  val created = match createPermissionRequestHandler(sid, bearer(token), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{\"command\":\"ls\"}")) {
    case Ok(r) -> r
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  assertEqual(created.status, "pending", "fresh request starts pending")

  match getPermissionRequestHandler(sid, created.id, bearer(token)) {
    case Ok(d) -> assertEqual(d.status, "pending", "poll before answer sees pending")
    case Err(e) -> assertTrue(false, "poll failed: " + toString(e.status))
  }

  match answerPermissionRequestHandler(sid, created.id, AnswerPermissionRequestRequest(decision = "allow", note = "looks fine", updatedInputJson = "")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "answer failed: " + toString(e.status))
  }

  match getPermissionRequestHandler(sid, created.id, bearer(token)) {
    case Ok(d) -> {
      assertEqual(d.status, "allowed", "poll after answer sees allowed")
      assertEqual(d.note, "looks fine", "note round-trips")
    }
    case Err(e) -> assertTrue(false, "poll after answer failed: " + toString(e.status))
  }

  // A second answer is a 409 (write-once).
  match answerPermissionRequestHandler(sid, created.id, AnswerPermissionRequestRequest(decision = "deny", note = "", updatedInputJson = "")) {
    case Ok(_) -> assertTrue(false, "an already-decided request must not be answered twice")
    case Err(e) -> assertEqualInt(e.status, 409, "double-answer returns 409")
  }
}

test "allow-always rule short-circuits an identical second request" {
  val dbPath = useFreshTestDb("perm-allow-always")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-perm-2"
  mkSession(sid)
  val token = mintToken(sid, "default")
  val toolReq = CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{\"command\":\"git status\"}")

  val first = match createPermissionRequestHandler(sid, bearer(token), toolReq) {
    case Ok(r) -> r
    case Err(e) -> panic("first create failed: " + toString(e.status))
  }
  assertEqual(first.status, "pending", "first request starts pending")
  match answerPermissionRequestHandler(sid, first.id, AnswerPermissionRequestRequest(decision = "allow_always", note = "", updatedInputJson = "")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "allow_always answer failed: " + toString(e.status))
  }

  // A second, IDENTICAL request short-circuits: already 'allowed' at creation,
  // no prompt round trip needed.
  val second = match createPermissionRequestHandler(sid, bearer(token), toolReq) {
    case Ok(r) -> r
    case Err(e) -> panic("second create failed: " + toString(e.status))
  }
  assertEqual(second.status, "allowed", "identical request is pre-approved by the allow-always rule")
  assertTrue(second.id != first.id, "the rule pre-decides a NEW request row, not reusing the old one")

  // A DIFFERENT input for the same tool is not covered by the rule.
  val different = match createPermissionRequestHandler(sid, bearer(token), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{\"command\":\"rm -rf /\"}")) {
    case Ok(r) -> r
    case Err(e) -> panic("different-input create failed: " + toString(e.status))
  }
  assertEqual(different.status, "pending", "a different input is not covered by the rule")
}

test "deny-on-timeout backstop (injectable, no real sleep)" {
  val dbPath = useFreshTestDb("perm-timeout")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-perm-3"
  mkSession(sid)
  val token = mintToken(sid, "default")

  // A 0ms timeout makes the request eligible for the fail-closed sweep on its
  // very first poll — no sleeping ten real minutes.
  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS", "0")
  val created = match createPermissionRequestHandler(sid, bearer(token), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(r) -> r
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  match getPermissionRequestHandler(sid, created.id, bearer(token)) {
    case Ok(d) -> {
      assertEqual(d.status, "denied", "an expired-timeout poll fails closed to denied")
      assertTrue(d.note.contains("timed out"), "note explains the timeout")
    }
    case Err(e) -> assertTrue(false, "poll failed: " + toString(e.status))
  }

  // A human answer after the timeout has already fired sees a 409 (write-once).
  match answerPermissionRequestHandler(sid, created.id, AnswerPermissionRequestRequest(decision = "allow", note = "", updatedInputJson = "")) {
    case Ok(_) -> assertTrue(false, "a timed-out request must not be answerable afterwards")
    case Err(e) -> assertEqualInt(e.status, 409, "post-timeout answer returns 409")
  }
}

test "callback auth failures: bad token, missing header, cross-session token, non-owner answer" {
  val dbPath = useFreshTestDb("callback-auth")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sidA = "sess-auth-a"
  val sidB = "sess-auth-b"
  mkSession(sidA)
  mkSession(sidB)
  val tokenA = mintToken(sidA, "default")
  val _tokenB = mintToken(sidB, "default")

  // Bad token entirely.
  match createPermissionRequestHandler(sidA, bearer("not-the-real-token"), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(_) -> assertTrue(false, "a wrong callback token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 401, "wrong token returns 401")
  }
  // Missing Authorization header entirely.
  match createPermissionRequestHandler(sidA, "", CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(_) -> assertTrue(false, "a missing Authorization header must be rejected")
    case Err(e) -> assertEqualInt(e.status, 401, "missing header returns 401")
  }

  // Cross-session token: A's token presented against B's session id.
  match createPermissionRequestHandler(sidB, bearer(tokenA), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(_) -> assertTrue(false, "session A's token must not authorize session B's callbacks")
    case Err(e) -> assertEqualInt(e.status, 401, "cross-session token returns 401")
  }

  // Non-owner answer: session C is owned by a different user; a caller
  // stamped as "default" must not be able to answer C's requests, even
  // though they know the request id (derived via getSession's owner scoping,
  // same as every other session sub-resource handler).
  CloudAgents.Auth.setCurrentUserId("other-user")
  val sidC = "sess-auth-c"
  mkSession(sidC)
  val tokenC = mintToken(sidC, "other-user")
  val reqC = match createPermissionRequestHandler(sidC, bearer(tokenC), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(r) -> r
    case Err(e) -> panic("setup create failed: " + toString(e.status))
  }
  CloudAgents.Auth.setCurrentUserId("default")
  match answerPermissionRequestHandler(sidC, reqC.id, AnswerPermissionRequestRequest(decision = "allow", note = "", updatedInputJson = "")) {
    case Ok(_) -> assertTrue(false, "a caller who does not own the session must not answer its requests")
    case Err(e) -> assertEqualInt(e.status, 404, "non-owner answer returns 404 (no ownership leak)")
  }
}

// ── User questions ──────────────────────────────────────────────────────────
test "user question round trip: create -> poll pending -> answer -> poll answered" {
  val dbPath = useFreshTestDb("question-roundtrip")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-question-1"
  mkSession(sid)
  val token = mintToken(sid, "default")

  val created = match createUserQuestionHandler(sid, bearer(token), CreateUserQuestionRequest(question = "Which package?", optionsJson = "[\"A\",\"B\"]")) {
    case Ok(r) -> r
    case Err(e) -> panic("create failed: " + toString(e.status))
  }

  match getUserQuestionHandler(sid, created.id, bearer(token)) {
    case Ok(a) -> assertEqual(a.status, "pending", "poll before answer sees pending")
    case Err(e) -> assertTrue(false, "poll failed: " + toString(e.status))
  }

  match answerUserQuestionHandler(sid, created.id, AnswerUserQuestionRequest(answer = "A")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "answer failed: " + toString(e.status))
  }

  match getUserQuestionHandler(sid, created.id, bearer(token)) {
    case Ok(a) -> {
      assertEqual(a.status, "answered", "poll after answer sees answered")
      assertEqual(a.answer, "A", "answer round-trips")
    }
    case Err(e) -> assertTrue(false, "poll after answer failed: " + toString(e.status))
  }

  // A second answer is a 409 (write-once), mirroring permission requests.
  match answerUserQuestionHandler(sid, created.id, AnswerUserQuestionRequest(answer = "B")) {
    case Ok(_) -> assertTrue(false, "an already-answered question must not be answered twice")
    case Err(e) -> assertEqualInt(e.status, 409, "double-answer returns 409")
  }
}

test "question timeout is distinct from an empty-string answer" {
  val dbPath = useFreshTestDb("question-timeout")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-question-2"
  mkSession(sid)
  val token = mintToken(sid, "default")

  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS", "0")
  val created = match createUserQuestionHandler(sid, bearer(token), CreateUserQuestionRequest(question = "Proceed?", optionsJson = "")) {
    case Ok(r) -> r
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  match getUserQuestionHandler(sid, created.id, bearer(token)) {
    case Ok(a) -> {
      assertEqual(a.status, "timed_out", "an expired-timeout poll reports timed_out, not answered")
      assertEqual(a.answer, "", "no answer value on timeout")
    }
    case Err(e) -> assertTrue(false, "poll failed: " + toString(e.status))
  }
}

// ── Progress reports ────────────────────────────────────────────────────────
test "report_progress persists and validates percentComplete" {
  val dbPath = useFreshTestDb("progress")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-progress-1"
  mkSession(sid)
  val token = mintToken(sid, "default")

  match reportProgressHandler(sid, bearer(token), ReportProgressRequest(summary = "cloning repo", percentComplete = "10")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "report failed: " + toString(e.status))
  }
  match CloudAgents.Repository.sessionProgress(sid) {
    case Ok(p) -> {
      assertEqual(p.summary, "cloning repo", "summary persisted")
      assertEqual(p.percent, "10", "percent persisted")
    }
    case Err(e) -> assertTrue(false, "sessionProgress lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // A later report replaces the prior one (latest-only, not a history log).
  match reportProgressHandler(sid, bearer(token), ReportProgressRequest(summary = "running tests", percentComplete = "80")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "second report failed: " + toString(e.status))
  }
  match CloudAgents.Repository.sessionProgress(sid) {
    case Ok(p) -> assertEqual(p.summary, "running tests", "latest report replaces the prior one")
    case Err(e) -> assertTrue(false, "sessionProgress lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Out-of-range percent is rejected before anything is written.
  match reportProgressHandler(sid, bearer(token), ReportProgressRequest(summary = "x", percentComplete = "150")) {
    case Ok(_) -> assertTrue(false, "percentComplete over 100 must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "out-of-range percent returns 400")
  }
  match CloudAgents.Repository.sessionProgress(sid) {
    case Ok(p) -> assertEqual(p.summary, "running tests", "rejected report leaves the prior state untouched")
    case Err(e) -> assertTrue(false, "sessionProgress lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── Validation ───────────────────────────────────────────────────────────────
test "callback endpoints reject an empty session id before touching the database" {
  val dbPath = useFreshTestDb("empty-id")
  defer {
    cleanupTestDb(dbPath)
  }
  match createPermissionRequestHandler("", "", CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id returns 400")
  }
  match createUserQuestionHandler("", "", CreateUserQuestionRequest(question = "x", optionsJson = "")) {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id returns 400")
  }
  match reportProgressHandler("", "", ReportProgressRequest(summary = "x", percentComplete = "")) {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id returns 400")
  }
}
