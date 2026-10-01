//! Container callback tests (permission requests, user questions, progress
//! reports, callback-token handling) against the Postgres store.
@test_module
package CloudAgents.CallbacksTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Callbacks
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Db
import extern System.Environment as Env

// ── Live Postgres ─────────────────────────────────────────────────────────────
//
// The store is Postgres (docs/phase11-postgres-tenancy.md). These tests run iff
// LYRIC_CONFIG_DB_CONNECTION_URL (cloudagents_app) and
// CLOUD_AGENTS_MIGRATE_DATABASE_URL (cloudagents_owner) are set, and fail rather
// than skip when CLOUD_AGENTS_REQUIRE_LIVE_PG=1 (CI). Each test acts as a fresh
// user with its own personal tenant, so tests, suites and repeated runs against
// the same database never see each other's rows.
func live(): Bool {
  val ok = CloudAgents.Pg.serviceConfigured() and
    Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "").length.toInt() > 0
  if ok {
    return true
  }
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: callbacks tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
  return false
}

func migrate(): Unit {
  val conn = match CloudAgents.Pg.connectDsn(Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "")) {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(_) -> ()
    case Err(e) -> panic("migrate failed: " + CloudAgents.Pg.pgErrorMessage(e))
  }
}

/// A new user with a provisioned personal tenant. Does not change the request
/// identity.
func newUser(tag: in String): String {
  val uid = "t-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(uid) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  return uid
}

/// Migrate, then make a new user the request identity (what handlers read via
/// CloudAgents.Auth.requestScope()).
func freshUser(tag: in String): String {
  migrate()
  val uid = newUser(tag)
  CloudAgents.Auth.setCurrentUserId(uid)
  return uid
}

/// Session ids are global primary keys that persist across runs.
func uniq(prefix: in String): String {
  return prefix + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
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
  match addSession(s, CloudAgents.Auth.requestScope()) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func mintToken(id: in String, ownerUserId: in String): String {
  return match CloudAgents.SessionStore.mintCallbackToken(id, CloudAgents.Pg.personalScope(ownerUserId)) {
    case Ok(t) -> t
    case Err(e) -> panic("mintCallbackToken failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func bearer(token: in String): String {
  return "Bearer " + token
}

// ── Permission requests ────────────────────────────────────────────────────
test "permission request round trip: create -> poll pending -> answer allow -> poll allowed" {
  if not live() {
    return
  }
  val me = freshUser("perm-roundtrip")
  val sid = uniq("sess-perm-1")
  mkSession(sid)
  val token = mintToken(sid, me)

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
  if not live() {
    return
  }
  val me = freshUser("perm-allow-always")
  val sid = uniq("sess-perm-2")
  mkSession(sid)
  val token = mintToken(sid, me)
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
  if not live() {
    return
  }
  val me = freshUser("perm-timeout")
  val sid = uniq("sess-perm-3")
  mkSession(sid)
  val token = mintToken(sid, me)

  // A 0ms timeout makes the request eligible for the fail-closed sweep on its
  // very first poll — no sleeping ten real minutes.
  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS", "0")
  defer {
    Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS", "")
  }
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
  if not live() {
    return
  }
  val me = freshUser("callback-auth")
  val sidA = uniq("sess-auth-a")
  val sidB = uniq("sess-auth-b")
  mkSession(sidA)
  mkSession(sidB)
  val tokenA = mintToken(sidA, me)
  val _tokenB = mintToken(sidB, me)

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
  // stamped as a different user must not be able to answer C's requests, even
  // though they know the request id (derived via getSession's owner scoping,
  // same as every other session sub-resource handler).
  val other = newUser("callback-auth-other")
  CloudAgents.Auth.setCurrentUserId(other)
  val sidC = uniq("sess-auth-c")
  mkSession(sidC)
  val tokenC = mintToken(sidC, other)
  val reqC = match createPermissionRequestHandler(sidC, bearer(tokenC), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(r) -> r
    case Err(e) -> panic("setup create failed: " + toString(e.status))
  }
  CloudAgents.Auth.setCurrentUserId(me)
  match answerPermissionRequestHandler(sidC, reqC.id, AnswerPermissionRequestRequest(decision = "allow", note = "", updatedInputJson = "")) {
    case Ok(_) -> assertTrue(false, "a caller who does not own the session must not answer its requests")
    case Err(e) -> assertEqualInt(e.status, 404, "non-owner answer returns 404 (no ownership leak)")
  }
}

test "callback token is persisted only as its SHA-256 hash" {
  if not live() {
    return
  }
  val me = freshUser("callback-token-hash")
  val sid = uniq("sess-token-hash")
  mkSession(sid)
  val token = mintToken(sid, me)

  val storedHash = match CloudAgents.SessionStore.callbackTokenHashForSession(sid) {
    case Ok(Some(h)) -> h
    case Ok(None) -> panic("session vanished")
    case Err(e) -> panic("callbackTokenHashForSession failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  assertEqual(storedHash, CloudAgents.Auth.hashCallbackToken(token), "the stored value is the token's hash")
  assertTrue(storedHash != token, "the raw token is not what is stored")

  // Hash round trip: the raw token authorizes; the stored hash does not.
  match createPermissionRequestHandler(sid, bearer(token), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "the minted token must authorize, got " + toString(e.status))
  }
  match createPermissionRequestHandler(sid, bearer(storedHash), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(_) -> assertTrue(false, "presenting the stored hash must not authorize")
    case Err(e) -> assertEqualInt(e.status, 401, "stored hash as bearer returns 401")
  }

  // Re-minting (a new container start) replaces the hash: the old token stops working.
  val fresh = mintToken(sid, me)
  match createPermissionRequestHandler(sid, bearer(token), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(_) -> assertTrue(false, "a superseded token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 401, "superseded token returns 401")
  }
  match createPermissionRequestHandler(sid, bearer(fresh), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "the re-minted token must authorize, got " + toString(e.status))
  }
}

test "a session route with an empty stored hash fails closed" {
  if not live() {
    return
  }
  val me = freshUser("callback-token-empty-hash")
  val sid = uniq("sess-token-empty-hash")
  mkSession(sid)
  val token = mintToken(sid, me)
  // A route that never minted a token (or was blanked) stores ''; nothing a
  // caller can present may hash to it.
  val u = match CloudAgents.PgStore.open(CloudAgents.Pg.personalScope(me)) {
    case Ok(x) -> x
    case Err(e) -> panic("open failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, "UPDATE session_routes SET callback_token_hash = '' WHERE session_id = @p0", [sid]) {
    case Ok(n) -> assertEqualInt(n, 1, "the route's hash was blanked")
    case Err(e) -> panic("blanking the hash failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> panic("commit failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match createPermissionRequestHandler(sid, bearer(token), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(_) -> assertTrue(false, "a token must not authorize against an empty stored hash")
    case Err(e) -> assertEqualInt(e.status, 401, "empty stored hash returns 401")
  }
  match createPermissionRequestHandler(sid, "Bearer ", CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(_) -> assertTrue(false, "an empty bearer token must not authorize against an empty stored hash")
    case Err(e) -> assertEqualInt(e.status, 401, "empty bearer returns 401")
  }
}

// ── User questions ──────────────────────────────────────────────────────────
test "user question round trip: create -> poll pending -> answer -> poll answered" {
  if not live() {
    return
  }
  val me = freshUser("question-roundtrip")
  val sid = uniq("sess-question-1")
  mkSession(sid)
  val token = mintToken(sid, me)

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
  if not live() {
    return
  }
  val me = freshUser("question-timeout")
  val sid = uniq("sess-question-2")
  mkSession(sid)
  val token = mintToken(sid, me)

  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS", "0")
  defer {
    Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS", "")
  }
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
  if not live() {
    return
  }
  val me = freshUser("progress")
  val sid = uniq("sess-progress-1")
  mkSession(sid)
  val token = mintToken(sid, me)

  match reportProgressHandler(sid, bearer(token), ReportProgressRequest(summary = "cloning repo", percentComplete = "10")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "report failed: " + toString(e.status))
  }
  match CloudAgents.Repository.sessionProgress(sid, CloudAgents.Auth.requestScope()) {
    case Ok(p) -> {
      assertEqual(p.summary, "cloning repo", "summary persisted")
      assertEqual(p.percent, "10", "percent persisted")
    }
    case Err(e) -> assertTrue(false, "sessionProgress lookup failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // A later report replaces the prior one (latest-only, not a history log).
  match reportProgressHandler(sid, bearer(token), ReportProgressRequest(summary = "running tests", percentComplete = "80")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "second report failed: " + toString(e.status))
  }
  match CloudAgents.Repository.sessionProgress(sid, CloudAgents.Auth.requestScope()) {
    case Ok(p) -> assertEqual(p.summary, "running tests", "latest report replaces the prior one")
    case Err(e) -> assertTrue(false, "sessionProgress lookup failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // Out-of-range percent is rejected before anything is written.
  match reportProgressHandler(sid, bearer(token), ReportProgressRequest(summary = "x", percentComplete = "150")) {
    case Ok(_) -> assertTrue(false, "percentComplete over 100 must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "out-of-range percent returns 400")
  }
  match CloudAgents.Repository.sessionProgress(sid, CloudAgents.Auth.requestScope()) {
    case Ok(p) -> assertEqual(p.summary, "running tests", "rejected report leaves the prior state untouched")
    case Err(e) -> assertTrue(false, "sessionProgress lookup failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

// ── Validation ───────────────────────────────────────────────────────────────
test "callback endpoints reject an empty session id before touching the database" {
  if not live() {
    return
  }
  val me = freshUser("empty-id")
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

test "listPendingCallbacksHandler returns all currently active callbacks" {
  if not live() {
    return
  }
  val me = freshUser("pending-callbacks")
  val sid = uniq("sess-pending-1")
  mkSession(sid)
  val token = mintToken(sid, me)

  // Starts empty
  match CloudAgents.Callbacks.listPendingCallbacksHandler(sid) {
    case Ok(res) -> {
      assertEqualInt(res.permissionRequests.length, 0, "initially zero pending permissions")
      assertEqualInt(res.userQuestions.length, 0, "initially zero pending questions")
      assertEqualInt(res.secretRequests.length, 0, "initially zero pending secrets")
    }
    case Err(e) -> panic("init failed: " + toString(e.status))
  }

  // Create one permission request and one user question
  val perm = match createPermissionRequestHandler(sid, bearer(token), CreatePermissionRequestRequest(toolName = "Bash", inputJson = "{}")) {
    case Ok(r) -> r
    case Err(e) -> panic("perm create failed")
  }
  val quest = match createUserQuestionHandler(sid, bearer(token), CreateUserQuestionRequest(question = "Proceed?", optionsJson = "")) {
    case Ok(r) -> r
    case Err(e) -> panic("question create failed")
  }

  // Verify they list in the pending endpoint
  match CloudAgents.Callbacks.listPendingCallbacksHandler(sid) {
    case Ok(res) -> {
      assertEqualInt(res.permissionRequests.length, 1, "has one pending permission")
      assertEqual(res.permissionRequests[0].id, perm.id, "has correct perm id")
      assertEqualInt(res.userQuestions.length, 1, "has one pending question")
      assertEqual(res.userQuestions[0].id, quest.id, "has correct question id")
      assertEqualInt(res.secretRequests.length, 0, "has zero pending secrets")
    }
    case Err(e) -> panic("pending lookup failed")
  }

  // Answer the question, then verify it is removed from the pending list
  match answerUserQuestionHandler(sid, quest.id, AnswerUserQuestionRequest(answer = "yes")) {
    case Ok(_) -> ()
    case Err(e) -> panic("answer question failed")
  }

  match CloudAgents.Callbacks.listPendingCallbacksHandler(sid) {
    case Ok(res) -> {
      assertEqualInt(res.permissionRequests.length, 1, "still has one pending permission")
      assertEqualInt(res.userQuestions.length, 0, "question is now answered, so removed from pending")
    }
    case Err(e) -> panic("post-answer lookup failed")
  }
}
