//! Tests for the session-ledger observer's orchestration (docs/session-
//! ledger.md §10, CloudAgents.ObserverHandlers): the settings endpoints, the
//! run triggers, whole passes through the real window/report callbacks, and
//! the pass limits. Containers are replaced by FakeRunner, which plays the
//! observer agent: it reads the window and sends a recorded report with the
//! observer session's own callback token, exactly as the shim would. Live
//! Postgres, no Docker, no network.
//!
//! The observer sweep (`pendingObserverSessions`, `observerMaintenanceHandler`)
//! lists passes across ALL tenants and takes at most three per call, so other
//! tests' sessions would crowd out a test's own. Whole passes therefore run
//! through `runPass` on the test's own session; the sweep itself is checked for
//! its operator gate and for listing (only) this test's pending sessions.
//! Every session is archived on exit so it leaves no pass pending.
@test_module
package CloudAgents.ObserverHandlersTests

import Std.Core
import Std.Environment
import Std.File
import Std.Testing
import Std.Uuid
import Web
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
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
import extern System.Text.Encoding as Encoding

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func utf8FromBytes(enc: in Encoding, bytes: in slice[Byte]): String = ""

func readFixture(path: in String): String {
  return match Std.File.readBytes(path) { case Ok(bytes) -> utf8FromBytes(utf8Encoding(), bytes); case Err(_) -> "" }
}

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
  println("SKIP: observer tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
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

func seedProfile(owner: in String): String {
  val sc = CloudAgents.Pg.personalScope(owner)
  match CloudAgents.Repository.addProfile(sc, "prof-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()), "", "full", "all", [], [], [], [], "all", []) {
    case Ok(pr) -> return pr.id
    case Err(e) -> panic("addProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// Point a session's route at a known callback token, "tok-" + its id, stored
// (like a real session's) only as its hash.
func setToken(sid: in String, userId: in String): Unit {
  val sc = CloudAgents.Pg.personalScope(userId)
  val u = match CloudAgents.PgStore.open(sc) {
    case Ok(x) -> x
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, "UPDATE session_routes SET callback_token_hash = @p1 WHERE session_id = @p0 AND tenant_id = @p2", [sid, CloudAgents.Auth.hashCallbackToken("tok-" + sid), sc.tenantId]) {
    case Ok(n) -> assertEqualInt(n, 1, "token stored on the session's route")
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// A new session owned by the current test user on github.com/acme/shop, in
// `profileId`'s profile, with callback token "tok-" + its id. Session ids are
// global (session_routes), so each is unique.
func seedSession(profileId: in String, status: in String): String {
  val id = "s-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  val sc = testScope()
  match CloudAgents.SessionStore.addSession(makeAgentSession(sessionId = id, repoUrl = "https://github.com/acme/shop", branch = "main", containerId = "", harness = "claude", model = "", nativeSessionId = id, status = status), sc) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.SessionStore.setSessionProfile(id, sc, profileId) {
    case Ok(_) -> ()
    case Err(e) -> panic("setSessionProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  setToken(id, sc.userId)
  return id
}

// Archive a session so the cross-tenant observer sweep stops listing it.
func retire(sid: in String): Unit {
  match CloudAgents.SessionStore.updateSessionArchived(sid, testScope(), "1") {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: could not archive " + sid + ": " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func linkObserver(observerId: in String, observedId: in String, profileId: in String): Unit {
  match linkObserverSession(observerId, testScope(), observedId, profileId) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
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
    setToken(observerSessionId, userId)
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

// One pass for the test's own session: "ran", "skipped: <why>" or "error: <why>".
func runPassFor(runner: in FakeRunner, sid: in String): String {
  return runPass(sid, testScope(), runner)
}

// ── Settings ──────────────────────────────────────────────────────────────────
test "a profile's observer settings are the owner's to read and change" {
  if not live() {
    return
  }
  val me = freshUser("obs-settings")
  val p1 = seedProfile(me)
  val bob = newUser("obs-bob")
  val p2 = seedProfile(bob)
  match getObserverSettingsHandler(p1) {
    case Ok(st) -> assertEqual(st.enabled, "false", "off until set")
    case Err(e) -> assertTrue(false, e.message)
  }
  val body = "{\"enabled\":\"true\",\"harness\":\"codex\",\"model\":\"o4-mini\",\"repoAccess\":\"workspace\",\"midRunMinutes\":\"30\",\"maxPassesPerDay\":\"20\"}"
  match putObserverSettingsHandler(p1, body) {
    case Ok(st) -> assertEqual(st.harness, "codex", "saved")
    case Err(e) -> assertTrue(false, e.message)
  }
  match getObserverSettingsHandler(p1) {
    case Ok(st) -> {
      assertEqual(st.enabled, "true", "enabled")
      assertEqual(st.repoAccess, "workspace", "repo access kept")
      assertEqual(st.midRunMinutes, "30", "interval kept")
    }
    case Err(e) -> assertTrue(false, e.message)
  }
  match putObserverSettingsHandler(p1, "{\"enabled\":\"true\",\"harness\":\"claude\",\"model\":\"\",\"repoAccess\":\"clone\",\"midRunMinutes\":\"15\",\"maxPassesPerDay\":\"5\"}") {
    case Ok(_) -> assertTrue(false, "an unknown repo access is refused")
    case Err(e) -> assertEqualInt(e.status, 400, "a bad value is a 400")
  }
  match putObserverSettingsHandler(p1, "not json") {
    case Ok(_) -> assertTrue(false, "garbage is refused")
    case Err(e) -> assertEqualInt(e.status, 400, "not JSON is a 400, not a crash")
  }
  match getObserverSettingsHandler(p2) {
    case Ok(_) -> assertTrue(false, "another user's profile is not visible")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
  match putObserverSettingsHandler(p2, body) {
    case Ok(_) -> assertTrue(false, "nor changeable")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
}

// ── Triggers ──────────────────────────────────────────────────────────────────
test "a run's end queues a pass only for an observed session" {
  if not live() {
    return
  }
  val me = freshUser("obs-trigger")
  val p1 = seedProfile(me)
  val p2 = seedProfile(me)
  enable(p1, settings("true", "none", "10"))
  enable(p2, settings("false", "none", "10"))
  val watched = seedSession(p1, "IDLE")
  defer {
    retire(watched)
  }
  val unwatched = seedSession(p2, "IDLE")
  defer {
    retire(unwatched)
  }
  onRunFinished(watched)
  onRunFinished(unwatched)
  assertEqual(stateOf(watched).pending, "1", "an observed session gets a pass")
  assertEqual(stateOf(unwatched).pending, "0", "a disabled observer doesn't")
  // An observer session is never observed, whatever its profile says.
  val obs = seedSession(p1, "IDLE")
  defer {
    retire(obs)
  }
  linkObserver(obs, watched, p1)
  onRunFinished(obs)
  assertEqual(stateOf(obs).pending, "0", "observers aren't observed")
  // An archived session isn't either.
  val oldSess = seedSession(p1, "IDLE")
  defer {
    retire(oldSess)
  }
  retire(oldSess)
  onRunFinished(oldSess)
  assertEqual(stateOf(oldSess).pending, "0", "archived sessions aren't observed")
}

test "a long run is due a mid-run pass once the interval passes" {
  if not live() {
    return
  }
  val me = freshUser("obs-midrun")
  val p1 = seedProfile(me)
  enable(p1, settings("true", "none", "10"))
  val s1 = seedSession(p1, "RUNNING")
  defer {
    retire(s1)
  }
  val now = CloudAgents.Repository.nowMillisLong()
  midRunTick(s1, toString(now - 5.toLong() * 60000.toLong()))
  assertEqual(stateOf(s1).pending, "0", "5 minutes in: not yet")
  midRunTick(s1, toString(now - 16.toLong() * 60000.toLong()))
  assertEqual(stateOf(s1).pending, "1", "16 minutes in: due")
}

test "the owner can ask for a pass; nobody else can" {
  if not live() {
    return
  }
  val me = freshUser("obs-now")
  val p1 = seedProfile(me)
  val p2 = seedProfile(me)
  enable(p1, settings("true", "none", "10"))
  val s1 = seedSession(p1, "IDLE")
  defer {
    retire(s1)
  }
  val s2 = seedSession(p2, "IDLE")
  defer {
    retire(s2)
  }
  val bob = newUser("obs-bob")
  match observeNowHandler(s1) {
    case Ok(q) -> assertEqual(q.queued, "true", "queued")
    case Err(e) -> assertTrue(false, e.message)
  }
  assertEqual(stateOf(s1).pending, "1", "pending")
  match observerStatusHandler(s1) {
    case Ok(st) -> {
      assertEqual(st.enabled, "true", "observed")
      assertEqual(st.pending, "1", "a pass is queued")
      assertEqual(st.model, "claude-haiku-4-5", "the observer's model")
    }
    case Err(e) -> assertTrue(false, e.message)
  }
  match observerStatusHandler(s2) {
    case Ok(st) -> assertEqual(st.enabled, "false", "not observed")
    case Err(e) -> assertTrue(false, e.message)
  }
  match observeNowHandler(s2) {
    case Ok(_) -> assertTrue(false, "a session without an observer can't be observed")
    case Err(e) -> assertEqualInt(e.status, 400, "400")
  }
  CloudAgents.Auth.setCurrentUserId(bob)
  match observeNowHandler(s1) {
    case Ok(_) -> assertTrue(false, "not bob's session")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
  match observerStatusHandler(s1) {
    case Ok(_) -> assertTrue(false, "nor bob's to inspect")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
}

// The sweep lists pending passes across tenants, so it is checked by
// membership: this test's pending session is listed, its archived one is not.
test "the observer sweep is operator-only and lists a pending pass until it is archived" {
  if not live() {
    return
  }
  val me = freshUser("obs-sweep")
  val p1 = seedProfile(me)
  enable(p1, settings("true", "none", "10"))
  val live1 = seedSession(p1, "IDLE")
  val gone = seedSession(p1, "IDLE")
  defer {
    retire(live1)
    retire(gone)
  }
  onRunFinished(live1)
  onRunFinished(gone)
  retire(gone)
  match observerMaintenanceHandler(fakeRunner("")) {
    case Ok(_) -> assertTrue(false, "a non-operator may not trigger the sweep")
    case Err(e) -> assertEqualInt(e.status, 401, "401")
  }
  val listed = match pendingObserverSessions(100) {
    case Ok(ids) -> ids
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  var seenLive = false
  var seenGone = false
  var i = 0
  while i < listed.length.toInt() {
    if listed[i] == live1 {
      seenLive = true
    }
    if listed[i] == gone {
      seenGone = true
    }
    i = i + 1
  }
  assertTrue(seenLive, "the pending session is due")
  assertTrue(not seenGone, "an archived session is not")
}

// ── Passes ────────────────────────────────────────────────────────────────────
test "a pass runs the observer, which reads the window and reports into the ledger" {
  if not live() {
    return
  }
  val me = freshUser("obs-pass")
  val p1 = seedProfile(me)
  enable(p1, settings("true", "diff", "10"))
  val s1 = seedSession(p1, "IDLE")
  defer {
    retire(s1)
  }
  captureFixture(s1)
  onRunFinished(s1)
  val runner = fakeRunner(readFixture("tests/fixtures/observer/report.json"))
  assertEqual(runPassFor(runner, s1), "ran", "one pass, no errors")
  assertEqualInt(runner.runs, 1, "the observer ran once")
  assertEqual(runner.lastHarness, "claude", "with the profile's harness")
  assertEqual(runner.lastModel, "claude-haiku-4-5", "and model")
  assertTrue(runner.lastPrompt.contains("observer_get_window"), "told how to work")
  assertTrue(runner.lastPrompt.contains("has ended"), "and that the run is over")
  assertEqual(runner.windowFinal, "true", "the window says the run is over")
  assertEqualInt(runner.diffCalls, 1, "diff access reads the workspace diff")
  assertTrue(runner.replies[0].startsWith("true:"), "the report was accepted: " + runner.replies[0])
  assertEqualInt(observedCount(s1), 4, "three undeclared and one matched... ")
  val st = stateOf(s1)
  assertEqual(st.cursorSeq, "28", "the cursor moved past the run")
  assertEqual(st.passesToday, "1", "one pass counted")
  assertEqual(st.lastError, "", "no error")
  assertEqual(st.pending, "0", "nothing more to do")
  assertTrue(st.observerSessionId.length.toInt() > 0, "an observer session exists")
  match sessionRunFacts(st.observerSessionId, testScope()) {
    case Ok(Some(f)) -> {
      assertEqual(f.observesSessionId, s1, "linked to the session it observes")
      assertEqual(f.profileId, p1, "on the observed profile's credentials")
      assertEqual(f.status, "IDLE", "and idle again after the pass")
    }
    case _ -> assertTrue(false, "the observer session row is missing")
  }
  match CloudAgents.SessionStore.sessionSummariesJson(CloudAgents.Auth.requestScope()) {
    case Ok(json) -> assertTrue(not json.contains(st.observerSessionId), "observer sessions are not listed")
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // A second pass has nothing new to read, so no container starts.
  val _ = markObserverPending(s1, testScope())
  assertTrue(runPassFor(runner, s1).startsWith("skipped"), "skipped")
  assertEqualInt(runner.runs, 1, "no second run")
}

test "a mid-run pass sees the run as live and its findings are provisional" {
  if not live() {
    return
  }
  val me = freshUser("obs-live")
  val p1 = seedProfile(me)
  enable(p1, settings("true", "none", "10"))
  val s1 = seedSession(p1, "RUNNING")
  defer {
    retire(s1)
  }
  captureFixture(s1)
  val _ = markObserverPending(s1, testScope())
  val runner = fakeRunner(
    "{\"candidates\":[{\"kind\":\"shortcut\",\"summary\":\"Skipped test_refund_rounding\",\"seqStart\":\"18\",\"seqEnd\":\"22\",\"confidence\":\"0.9\",\"evidence\":\"Skipping it\"}]}"
  )
  assertEqual(runPassFor(runner, s1), "ran", "ran")
  assertEqual(runner.windowFinal, "false", "the window says the run is still going")
  assertTrue(runner.lastPrompt.contains("still going"), "and so does the prompt")
  assertEqualInt(runner.diffCalls, 0, "no repo access, no diff")
  match listEntries(s1, testScope()) {
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
  if not live() {
    return
  }
  val me = freshUser("obs-lowsignal")
  val p1 = seedProfile(me)
  enable(p1, settings("true", "none", "10"))
  val s1 = seedSession(p1, "IDLE")
  defer {
    retire(s1)
  }
  // The task, then a Read and its result: nothing that can be undeclared work.
  val head = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Fix the timeout\"}}\n" +
    "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Read\",\"input\":{\"file_path\":\"/workspace/auth/session.py\"}}]}}\n" +
    "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"def expiry(ts): ...\"}]}}\n"
  val b = parseStreamJson(head, 0.toLong(), "")
  match CloudAgents.Repository.appendSessionEvents(s1, CloudAgents.Auth.requestScope(), b.events) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val _ = markObserverPending(s1, testScope())
  val runner = fakeRunner("{\"candidates\":[]}")
  assertTrue(runPassFor(runner, s1).startsWith("skipped"), "skipped")
  assertEqualInt(runner.runs, 0, "no observer run")
  assertEqual(stateOf(s1).cursorSeq, "2", "but the reads are behind the cursor now")
}

test "the daily cap stops passes, and an observer that never reports is noted" {
  if not live() {
    return
  }
  val me = freshUser("obs-cap")
  val p1 = seedProfile(me)
  enable(p1, settings("true", "none", "1"))
  val s1 = seedSession(p1, "IDLE")
  defer {
    retire(s1)
  }
  captureFixture(s1)
  val _ = markObserverPending(s1, testScope())
  val silent = fakeRunner("")
  val first = runPassFor(silent, s1)
  assertTrue(first.startsWith("error: "), "the silent observer is an error: " + first)
  assertTrue(first.contains("without reporting"), first)
  val st = stateOf(s1)
  assertEqual(st.cursorSeq, "", "the cursor did not move")
  assertEqual(st.windowEnd, "", "the unreported window is closed, to be read again")
  assertEqual(st.passesToday, "1", "it still counts")
  val _ = markObserverPending(s1, testScope())
  val second = runPassFor(fakeRunner("{\"candidates\":[]}"), s1)
  assertTrue(second.startsWith("skipped"), "the daily cap of one is reached: " + second)
  assertTrue(stateOf(s1).lastError.contains("daily pass limit"), "and says so")
}

test "changing the observer's harness starts a fresh observer and keeps the cursor" {
  if not live() {
    return
  }
  val me = freshUser("obs-reconfig")
  val p1 = seedProfile(me)
  enable(p1, settings("true", "none", "10"))
  val s1 = seedSession(p1, "IDLE")
  defer {
    retire(s1)
  }
  captureFixture(s1)
  val _ = markObserverPending(s1, testScope())
  val _ = runPassFor(fakeRunner(readFixture("tests/fixtures/observer/report.json")), s1)
  val firstObserver = stateOf(s1).observerSessionId
  enable(
    p1,
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
  match CloudAgents.Repository.appendSessionEvents(s1, CloudAgents.Auth.requestScope(), more.events) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val _ = markObserverPending(s1, testScope())
  val runner = fakeRunner("{\"candidates\":[]}")
  val _ = runPassFor(runner, s1)
  val st = stateOf(s1)
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
  if not live() {
    return
  }
  val me = freshUser("obs-auth")
  val p1 = seedProfile(me)
  enable(p1, settings("true", "none", "10"))
  val s1 = seedSession(p1, "IDLE")
  defer {
    retire(s1)
  }
  val obs = seedSession(p1, "IDLE")
  defer {
    retire(obs)
  }
  linkObserver(obs, s1, p1)
  match saveObserverState(testScope(), ObserverState(sessionId = s1, observerSessionId = obs, cursorSeq = "", windowEnd = "", pending = "0", passDay = "", passesToday = "0", lastPassAt = "", configHash = "", lastError = "")) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val runner = fakeRunner("")
  match observerCallbackHandler(obs, "window", "Bearer tok-" + s1, "{}", runner) {
    case Ok(_) -> assertTrue(false, "the observed session's token is not the observer's")
    case Err(e) -> assertEqualInt(e.status, 401, "401")
  }
  match observerCallbackHandler(s1, "window", "Bearer tok-" + s1, "{}", runner) {
    case Ok(_) -> assertTrue(false, "a session that observes nothing has no observer routes")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
  match observerCallbackHandler(obs, "window", "Bearer tok-" + obs, "{}", runner) {
    case Ok(env) -> assertEqual(env.ok, "true", "the observer's own token works")
    case Err(e) -> assertTrue(false, e.message)
  }
  match observerCallbackHandler(obs, "rewrite", "Bearer tok-" + obs, "{}", runner) {
    case Ok(_) -> assertTrue(false, "only window and report exist")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
}

test "a session whose profile was deleted is no longer observed" {
  if not live() {
    return
  }
  val me = freshUser("obs-noprofile")
  val p1 = seedProfile(me)
  enable(p1, settings("true", "workspace", "10"))
  val s1 = seedSession(p1, "IDLE")
  defer {
    retire(s1)
  }
  match CloudAgents.Repository.deleteProfile(p1, testScope()) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  onRunFinished(s1)
  assertEqual(stateOf(s1).pending, "0", "no pass for a deleted profile")
}

// The scope the store calls run under: the current test's fresh user.
func testScope(): TestScope.TenantScope {
  return CloudAgents.Auth.requestScope()
}
