//! Tests for the session-ledger observer's orchestration (docs/session-
//! ledger.md §10, CloudAgents.ObserverHandlers): the settings endpoints, the
//! run triggers, whole passes through the real window/report callbacks, and
//! the pass limits. Containers are replaced by FakeRunner, which plays the
//! observer agent: it reads the window and sends a recorded report with the
//! observer session's own callback token, exactly as the shim would. Live
//! SQLite, no Docker, no network.
@test_module
package CloudAgents.ObserverHandlersTests

import Std.Core
import Std.File
import Std.Testing
import Std.Uuid
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.SessionStore
import CloudAgents.Capture
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Store
import CloudAgents.Scope as TestScope
import CloudAgents.Ledger.Service
import CloudAgents.Ledger.ObserverPolicy
import CloudAgents.Ledger.Observer
import CloudAgents.LedgerHandlers
import CloudAgents.ObserverHandlers
import extern System.Environment as Env
import extern System.Text.Encoding as Encoding

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func utf8FromBytes(enc: in Encoding, bytes: in slice[Byte]): String = ""

func readFixture(path: in String): String {
  return match Std.File.readBytes(path) { case Ok(bytes) -> utf8FromBytes(utf8Encoding(), bytes); case Err(_) -> "" }
}

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  CloudAgents.Auth.setCurrentUserId("alice")
  return path
}

func cleanupTestDb(path: in String): Unit {
  try {
    fileDelete(path)
  } catch Bug as b {
    // locked or already gone
  }
}

func exec(sql: in String): Unit {
  match CloudAgents.Sqlite.execute(sql) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "exec failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func seedProfile(id: in String, owner: in String): Unit {
  exec(
    "INSERT INTO profiles (id, user_id, name, harness, network_policy, credential_mode, created_at, updated_at) VALUES ('" +
      id +
      "', '" +
      owner +
      "', '" +
      id +
      "', '', 'full', 'all', '1', '1')"
  )
}

func seedSession(id: in String, profileId: in String, status: in String): Unit {
  exec(
    "INSERT INTO sessions (id, user_id, repo_url, branch, container_id, harness, model, native_session_id, status, created_at, last_message_at, callback_token_hash) VALUES ('" +
      id +
      "', 'alice', 'https://github.com/acme/shop', 'main', '', 'claude', '', '" +
      id +
      "', '" +
      status +
      "', '1', '1', '" +
      CloudAgents.Auth.hashCallbackToken("tok-" + id) +
      "')"
  )
  exec("UPDATE sessions SET profile_id = '" + profileId + "' WHERE id = '" + id + "'")
}

func settings(enabled: in String, access: in String, cap: in String): ObserverSettings {
  return ObserverSettings(
    enabled = enabled,
    harness = "claude",
    model = "claude-haiku-4-5",
    repoAccess = access,
    midRunMinutes = "15",
    maxPassesPerDay = cap
  )
}

func enable(profileId: in String, st: in ObserverSettings): Unit {
  match saveObserverSettings(profileId, testScope(), st) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func captureFixture(sid: in String): Unit {
  val b = parseStreamJson(readFixture("tests/fixtures/observer/session.ndjson"), 0.toLong(), "")
  match CloudAgents.Repository.appendSessionEvents(sid, CloudAgents.Auth.requestScope(), b.events) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func stateOf(sid: in String): ObserverState {
  match observerState(sid, testScope()) {
    case Ok(s) -> return s
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func observedCount(sid: in String): Int {
  var n = 0
  match listEntries(sid, testScope()) {
    case Ok(es) -> {
      var i = 0
      while i < es.length.toInt() {
        if es[i].source == "observed" {
          n = n + 1
        }
        i = i + 1
      }
    }
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return n
}

// Plays the observer agent. `report` is the observer_report body it sends
// ("" = it ends without reporting); every call is recorded.
record FakeRunner {
  pub var report: String
  pub var runs: Int
  pub var lastHarness: String
  pub var lastModel: String
  pub var lastPrompt: String
  pub var lastObserver: String
  pub var windowFinal: String
  pub var diffCalls: Int
  pub var replies: slice[String]
}

func fakeRunner(report: in String): FakeRunner {
  val none: slice[String] = []
  return FakeRunner(
    report = report,
    runs = 0,
    lastHarness = "",
    lastModel = "",
    lastPrompt = "",
    lastObserver = "",
    windowFinal = "",
    diffCalls = 0,
    replies = none
  )
}

impl ObserverRunner for FakeRunner {
  func runObserver(
    observerSessionId: in String,
    repoUrl: in String,
    branch: in String,
    harness: in String,
    model: in String,
    profileId: in String,
    userId: in String,
    prompt: in String,
  ): Result[String, String] {
    self.runs = self.runs + 1
    self.lastHarness = harness
    self.lastModel = model
    self.lastPrompt = prompt
    self.lastObserver = observerSessionId
    // The container would receive a freshly minted token; stand one in.
    match CloudAgents.Sqlite.execute("UPDATE sessions SET callback_token_hash = '" + CloudAgents.Auth.hashCallbackToken("tok-" + observerSessionId) + "' WHERE id = '" + observerSessionId + "'") {
      case Ok(_) -> ()
      case Err(e) -> return Err(error = CloudAgents.Sqlite.dbErrorMessage(e))
    }
    val w = match observerCallbackHandler(observerSessionId, "window", "Bearer tok-" + observerSessionId, "{}", self) {
      case Ok(env) -> env
      case Err(e) -> return Err(error = "window: HTTP " + toString(e.status) + " " + e.message)
    }
    if w.ok != "true" {
      return Err(error = "window: " + w.error)
    }
    self.windowFinal = if w.reply.contains("\"final\":\"true\"") { "true" } else { "false" }
    if self.report.length.toInt() == 0 {
      return Ok(value = "ended without reporting")
    }
    match observerCallbackHandler(observerSessionId, "report", "Bearer tok-" + observerSessionId, self.report, self) {
      case Ok(env) -> {
        self.replies = self.replies.append(env.ok + ":" + env.error + env.reply)
        return Ok(value = "reported")
      }
      case Err(e) -> return Err(error = "report: HTTP " + toString(e.status) + " " + e.message)
    }
  }

  func workspaceDiff(sessionId: in String, harness: in String, userId: in String): Result[String, String] {
    self.diffCalls = self.diffCalls + 1
    return Ok(value = "diff --git a/tests/test_payments.py b/tests/test_payments.py\n+@pytest.mark.skip")
  }
}

func runAsOperator(runner: in FakeRunner): ObserverRunReport {
  val prior = CloudAgents.Auth.currentUserId()
  defer {
    CloudAgents.Auth.setCurrentUserId(prior)
  }
  CloudAgents.Auth.setCurrentUserId(CloudAgents.Auth.operatorUserId())
  match observerMaintenanceHandler(runner) {
    case Ok(r) -> return r
    case Err(e) -> panic("observerMaintenanceHandler: " + e.message)
  }
}

// ── Settings ──────────────────────────────────────────────────────────────────
test "a profile's observer settings are the owner's to read and change" {
  val path = useFreshTestDb("obs-settings")
  defer {
    cleanupTestDb(path)
  }
  seedProfile("p1", "alice")
  seedProfile("p2", "bob")
  match getObserverSettingsHandler("p1") {
    case Ok(st) -> assertEqual(st.enabled, "false", "off until set")
    case Err(e) -> assertTrue(false, e.message)
  }
  val body = "{\"enabled\":\"true\",\"harness\":\"codex\",\"model\":\"o4-mini\",\"repoAccess\":\"workspace\",\"midRunMinutes\":\"30\",\"maxPassesPerDay\":\"20\"}"
  match putObserverSettingsHandler("p1", body) {
    case Ok(st) -> assertEqual(st.harness, "codex", "saved")
    case Err(e) -> assertTrue(false, e.message)
  }
  match getObserverSettingsHandler("p1") {
    case Ok(st) -> {
      assertEqual(st.enabled, "true", "enabled")
      assertEqual(st.repoAccess, "workspace", "repo access kept")
      assertEqual(st.midRunMinutes, "30", "interval kept")
    }
    case Err(e) -> assertTrue(false, e.message)
  }
  match putObserverSettingsHandler("p1", "{\"enabled\":\"true\",\"harness\":\"claude\",\"model\":\"\",\"repoAccess\":\"clone\",\"midRunMinutes\":\"15\",\"maxPassesPerDay\":\"5\"}") {
    case Ok(_) -> assertTrue(false, "an unknown repo access is refused")
    case Err(e) -> assertEqualInt(e.status, 400, "a bad value is a 400")
  }
  match putObserverSettingsHandler("p1", "not json") {
    case Ok(_) -> assertTrue(false, "garbage is refused")
    case Err(e) -> assertEqualInt(e.status, 400, "not JSON is a 400, not a crash")
  }
  match getObserverSettingsHandler("p2") {
    case Ok(_) -> assertTrue(false, "another user's profile is not visible")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
  match putObserverSettingsHandler("p2", body) {
    case Ok(_) -> assertTrue(false, "nor changeable")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
}

// ── Triggers ──────────────────────────────────────────────────────────────────
test "a run's end queues a pass only for an observed session" {
  val path = useFreshTestDb("obs-trigger")
  defer {
    cleanupTestDb(path)
  }
  seedProfile("p1", "alice")
  seedProfile("p2", "alice")
  enable("p1", settings("true", "none", "10"))
  enable("p2", settings("false", "none", "10"))
  seedSession("watched", "p1", "IDLE")
  seedSession("unwatched", "p2", "IDLE")
  onRunFinished("watched")
  onRunFinished("unwatched")
  assertEqual(stateOf("watched").pending, "1", "an observed session gets a pass")
  assertEqual(stateOf("unwatched").pending, "0", "a disabled observer doesn't")
  // An observer session is never observed, whatever its profile says.
  seedSession("obs", "p1", "IDLE")
  exec("UPDATE sessions SET observes_session_id = 'watched' WHERE id = 'obs'")
  onRunFinished("obs")
  assertEqual(stateOf("obs").pending, "0", "observers aren't observed")
  // An archived session isn't either.
  seedSession("old", "p1", "IDLE")
  exec("UPDATE sessions SET is_archived = '1' WHERE id = 'old'")
  onRunFinished("old")
  assertEqual(stateOf("old").pending, "0", "archived sessions aren't observed")
}

test "a long run is due a mid-run pass once the interval passes" {
  val path = useFreshTestDb("obs-midrun")
  defer {
    cleanupTestDb(path)
  }
  seedProfile("p1", "alice")
  enable("p1", settings("true", "none", "10"))
  seedSession("s1", "p1", "RUNNING")
  val now = CloudAgents.Repository.nowMillisLong()
  midRunTick("s1", toString(now - 5.toLong() * 60000.toLong()))
  assertEqual(stateOf("s1").pending, "0", "5 minutes in: not yet")
  midRunTick("s1", toString(now - 16.toLong() * 60000.toLong()))
  assertEqual(stateOf("s1").pending, "1", "16 minutes in: due")
}

test "the owner can ask for a pass; nobody else can" {
  val path = useFreshTestDb("obs-now")
  defer {
    cleanupTestDb(path)
  }
  seedProfile("p1", "alice")
  seedProfile("p2", "alice")
  enable("p1", settings("true", "none", "10"))
  seedSession("s1", "p1", "IDLE")
  seedSession("s2", "p2", "IDLE")
  match observeNowHandler("s1") {
    case Ok(q) -> assertEqual(q.queued, "true", "queued")
    case Err(e) -> assertTrue(false, e.message)
  }
  assertEqual(stateOf("s1").pending, "1", "pending")
  match observerStatusHandler("s1") {
    case Ok(st) -> {
      assertEqual(st.enabled, "true", "observed")
      assertEqual(st.pending, "1", "a pass is queued")
      assertEqual(st.model, "claude-haiku-4-5", "the observer's model")
    }
    case Err(e) -> assertTrue(false, e.message)
  }
  match observerStatusHandler("s2") {
    case Ok(st) -> assertEqual(st.enabled, "false", "not observed")
    case Err(e) -> assertTrue(false, e.message)
  }
  match observeNowHandler("s2") {
    case Ok(_) -> assertTrue(false, "a session without an observer can't be observed")
    case Err(e) -> assertEqualInt(e.status, 400, "400")
  }
  CloudAgents.Auth.setCurrentUserId("bob")
  match observeNowHandler("s1") {
    case Ok(_) -> assertTrue(false, "not bob's session")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
  match observerStatusHandler("s1") {
    case Ok(_) -> assertTrue(false, "nor bob's to inspect")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
}

// ── Passes ────────────────────────────────────────────────────────────────────
test "a pass runs the observer, which reads the window and reports into the ledger" {
  val path = useFreshTestDb("obs-pass")
  defer {
    cleanupTestDb(path)
  }
  seedProfile("p1", "alice")
  enable("p1", settings("true", "diff", "10"))
  seedSession("s1", "p1", "IDLE")
  captureFixture("s1")
  onRunFinished("s1")
  val runner = fakeRunner(readFixture("tests/fixtures/observer/report.json"))
  val report = runAsOperator(runner)
  assertEqual(report.passes, "1", "one pass")
  assertEqualInt(
    report.errors.length.toInt(),
    0,
    "no errors: " + (if report.errors.length.toInt() > 0 { report.errors[0] } else { "" })
  )
  assertEqualInt(runner.runs, 1, "the observer ran once")
  assertEqual(runner.lastHarness, "claude", "with the profile's harness")
  assertEqual(runner.lastModel, "claude-haiku-4-5", "and model")
  assertTrue(runner.lastPrompt.contains("observer_get_window"), "told how to work")
  assertTrue(runner.lastPrompt.contains("has ended"), "and that the run is over")
  assertEqual(runner.windowFinal, "true", "the window says the run is over")
  assertEqualInt(runner.diffCalls, 1, "diff access reads the workspace diff")
  assertTrue(runner.replies[0].startsWith("true:"), "the report was accepted: " + runner.replies[0])
  assertEqualInt(observedCount("s1"), 4, "three undeclared and one matched... ")
  val st = stateOf("s1")
  assertEqual(st.cursorSeq, "28", "the cursor moved past the run")
  assertEqual(st.passesToday, "1", "one pass counted")
  assertEqual(st.lastError, "", "no error")
  assertEqual(st.pending, "0", "nothing more to do")
  assertTrue(st.observerSessionId.length.toInt() > 0, "an observer session exists")
  match sessionRunFacts(st.observerSessionId, testScope()) {
    case Ok(Some(f)) -> {
      assertEqual(f.observesSessionId, "s1", "linked to the session it observes")
      assertEqual(f.profileId, "p1", "on the observed profile's credentials")
      assertEqual(f.status, "IDLE", "and idle again after the pass")
    }
    case _ -> assertTrue(false, "the observer session row is missing")
  }
  match CloudAgents.SessionStore.sessionSummariesJson(CloudAgents.Auth.requestScope()) {
    case Ok(json) -> assertTrue(not json.contains(st.observerSessionId), "observer sessions are not listed")
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // A second pass has nothing new to read, so no container starts.
  val _ = markObserverPending("s1", testScope())
  val again = runAsOperator(runner)
  assertEqual(again.skipped, "1", "skipped")
  assertEqualInt(runner.runs, 1, "no second run")
}

test "a mid-run pass sees the run as live and its findings are provisional" {
  val path = useFreshTestDb("obs-live")
  defer {
    cleanupTestDb(path)
  }
  seedProfile("p1", "alice")
  enable("p1", settings("true", "none", "10"))
  seedSession("s1", "p1", "RUNNING")
  captureFixture("s1")
  val _ = markObserverPending("s1", testScope())
  val runner = fakeRunner(
    "{\"candidates\":[{\"kind\":\"shortcut\",\"summary\":\"Skipped test_refund_rounding\",\"seqStart\":\"18\",\"seqEnd\":\"22\",\"confidence\":\"0.9\",\"evidence\":\"Skipping it\"}]}"
  )
  val report = runAsOperator(runner)
  assertEqual(report.passes, "1", "ran")
  assertEqual(runner.windowFinal, "false", "the window says the run is still going")
  assertTrue(runner.lastPrompt.contains("still going"), "and so does the prompt")
  assertEqualInt(runner.diffCalls, 0, "no repo access, no diff")
  match listEntries("s1", testScope()) {
    case Ok(es) -> {
      var provisional = 0
      var i = 0
      while i < es.length.toInt() {
        if es[i].provisional == "true" {
          provisional = provisional + 1
        }
        i = i + 1
      }
      assertEqualInt(provisional, 1, "the finding is provisional")
    }
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "a window of nothing but reads is skipped without a container" {
  val path = useFreshTestDb("obs-lowsignal")
  defer {
    cleanupTestDb(path)
  }
  seedProfile("p1", "alice")
  enable("p1", settings("true", "none", "10"))
  seedSession("s1", "p1", "IDLE")
  // The task, then a Read and its result: nothing that can be undeclared work.
  val head = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Fix the timeout\"}}\n" +
    "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Read\",\"input\":{\"file_path\":\"/workspace/auth/session.py\"}}]}}\n" +
    "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"def expiry(ts): ...\"}]}}\n"
  val b = parseStreamJson(head, 0.toLong(), "")
  match CloudAgents.Repository.appendSessionEvents("s1", CloudAgents.Auth.requestScope(), b.events) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val _ = markObserverPending("s1", testScope())
  val runner = fakeRunner("{\"candidates\":[]}")
  val report = runAsOperator(runner)
  assertEqual(report.skipped, "1", "skipped")
  assertEqualInt(runner.runs, 0, "no observer run")
  assertEqual(stateOf("s1").cursorSeq, "2", "but the reads are behind the cursor now")
}

test "the daily cap stops passes, and an observer that never reports is noted" {
  val path = useFreshTestDb("obs-cap")
  defer {
    cleanupTestDb(path)
  }
  seedProfile("p1", "alice")
  enable("p1", settings("true", "none", "1"))
  seedSession("s1", "p1", "IDLE")
  captureFixture("s1")
  val _ = markObserverPending("s1", testScope())
  val silent = fakeRunner("")
  val first = runAsOperator(silent)
  assertEqualInt(first.errors.length.toInt(), 1, "the silent observer is an error")
  assertTrue(first.errors[0].contains("without reporting"), first.errors[0])
  val st = stateOf("s1")
  assertEqual(st.cursorSeq, "", "the cursor did not move")
  assertEqual(st.windowEnd, "", "the unreported window is closed, to be read again")
  assertEqual(st.passesToday, "1", "it still counts")
  val _ = markObserverPending("s1", testScope())
  val second = runAsOperator(fakeRunner("{\"candidates\":[]}"))
  assertEqual(second.skipped, "1", "the daily cap of one is reached")
  assertTrue(stateOf("s1").lastError.contains("daily pass limit"), "and says so")
}

test "changing the observer's harness starts a fresh observer and keeps the cursor" {
  val path = useFreshTestDb("obs-reconfig")
  defer {
    cleanupTestDb(path)
  }
  seedProfile("p1", "alice")
  enable("p1", settings("true", "none", "10"))
  seedSession("s1", "p1", "IDLE")
  captureFixture("s1")
  val _ = markObserverPending("s1", testScope())
  val _ = runAsOperator(fakeRunner(readFixture("tests/fixtures/observer/report.json")))
  val firstObserver = stateOf("s1").observerSessionId
  enable(
    "p1",
    ObserverSettings(
      enabled = "true",
      harness = "codex",
      model = "",
      repoAccess = "none",
      midRunMinutes = "15",
      maxPassesPerDay = "10"
    )
  )
  // New transcript after the first pass.
  val more = parseStreamJson(readFixture("tests/fixtures/observer/session.ndjson"), 29.toLong(), "")
  match CloudAgents.Repository.appendSessionEvents("s1", CloudAgents.Auth.requestScope(), more.events) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val _ = markObserverPending("s1", testScope())
  val runner = fakeRunner("{\"candidates\":[]}")
  val _ = runAsOperator(runner)
  val st = stateOf("s1")
  assertTrue(st.observerSessionId != firstObserver, "a new observer session")
  assertEqual(runner.lastHarness, "codex", "on the new harness")
  assertEqual(runner.lastModel, "o4-mini", "with that harness's default model")
  assertEqual(st.cursorSeq, "57", "the cursor carried over and moved on")
  match sessionRunFacts(firstObserver, testScope()) {
    case Ok(None) -> ()
    case _ -> assertTrue(false, "the replaced observer session is removed")
  }
}

test "observer callbacks need the observer's own token" {
  val path = useFreshTestDb("obs-auth")
  defer {
    cleanupTestDb(path)
  }
  seedProfile("p1", "alice")
  enable("p1", settings("true", "none", "10"))
  seedSession("s1", "p1", "IDLE")
  seedSession("obs", "p1", "IDLE")
  exec("UPDATE sessions SET observes_session_id = 's1' WHERE id = 'obs'")
  exec(
    "INSERT INTO ledger_observer (session_id, observer_session_id, cursor_seq, window_end, pending, pass_day, passes_today, last_pass_at, config_hash, last_error) VALUES ('s1', 'obs', '', '', '0', '', '0', '', '', '')"
  )
  val runner = fakeRunner("")
  match observerCallbackHandler("obs", "window", "Bearer tok-s1", "{}", runner) {
    case Ok(_) -> assertTrue(false, "the observed session's token is not the observer's")
    case Err(e) -> assertEqualInt(e.status, 401, "401")
  }
  match observerCallbackHandler("s1", "window", "Bearer tok-s1", "{}", runner) {
    case Ok(_) -> assertTrue(false, "a session that observes nothing has no observer routes")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
  match observerCallbackHandler("obs", "window", "Bearer tok-obs", "{}", runner) {
    case Ok(env) -> assertEqual(env.ok, "true", "the observer's own token works")
    case Err(e) -> assertTrue(false, e.message)
  }
  match observerCallbackHandler("obs", "rewrite", "Bearer tok-obs", "{}", runner) {
    case Ok(_) -> assertTrue(false, "only window and report exist")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
}

test "a session whose profile was deleted is no longer observed" {
  val path = useFreshTestDb("obs-noprofile")
  defer {
    cleanupTestDb(path)
  }
  seedProfile("p1", "alice")
  enable("p1", settings("true", "workspace", "10"))
  seedSession("s1", "p1", "IDLE")
  exec("DELETE FROM profiles WHERE id = 'p1'")
  onRunFinished("s1")
  assertEqual(stateOf("s1").pending, "0", "no pass for a deleted profile")
}

// The scope the store calls run under: SQLite keys ledger rows by session
// alone, so only the inbox reads the user from it.
func testScope(): TestScope.TenantScope {
  return TestScope.personalScope("alice")
}
