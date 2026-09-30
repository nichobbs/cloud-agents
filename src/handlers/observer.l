//! CloudAgents.ObserverHandlers — HTTP handlers and pass orchestration for
//! the session-ledger observer (docs/session-ledger.md §10).
//!
//! An observer is a hidden agent session that watches another session (the
//! "observed" session) and reports what that session's agent did without
//! declaring it in the ledger. Three audiences:
//!
//! - The observer's container, via the shim: `POST /api/sessions/{id}/
//!   callbacks/observer/{window|report}`, authenticated with the OBSERVER's
//!   callback token; the host maps it to the session it observes. Answers
//!   200 with a LedgerToolEnvelope, like the ledger callbacks.
//! - The owner: `GET`/`PUT /api/profiles/{id}/observer` (the settings) and
//!   `POST /api/sessions/{id}/ledger/observe` (queue a pass now).
//! - The operator's scheduler: `POST /api/maintenance/observe` runs the passes
//!   that are due. Like scheduled jobs there is no in-process timer: a run's
//!   end (or a mid-run tick) only marks a pass due.
//!
//! Containers are started through the ObserverRunner interface so the pass
//! logic is tested against a fake (CloudAgents.ObserverDocker is the real one).
package CloudAgents.ObserverHandlers

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Sqlite
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Handlers
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Store
import CloudAgents.Ledger.Service
import CloudAgents.Ledger.Reconcile
import CloudAgents.Ledger.ObserverPolicy
import CloudAgents.Ledger.ObserverWindow
import CloudAgents.Ledger.Observer
import CloudAgents.Ledger.ToolArgs
import CloudAgents.LedgerHandlers

/// What a pass needs from the container world.
pub interface ObserverRunner {
  /// Run one message on the observer session (blocking until it ends).
  func runObserver(observerSessionId: in String, repoUrl: in String, branch: in String, harness: in String, model: in String, profileId: in String, userId: in String, prompt: in String): Result[String, String]

  /// The observed workspace's diff against HEAD ("" when there is none).
  func workspaceDiff(sessionId: in String, harness: in String, userId: in String): Result[String, String]
}

/// The most diff text a window carries.
pub val windowMaxDiffChars: Int = 30000

/// Passes one maintenance call may run (each can take minutes).
pub val maxPassesPerCall: Int = 3

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

// ── Container callbacks ───────────────────────────────────────────────────────
func authorizeObserver(observerSessionId: in String, authHeaderValue: in String): Result[String, Web.ApiError] {
  val storedHash = match CloudAgents.SessionStore.callbackTokenHashForSession(observerSessionId) {
    case Ok(Some(t)) -> t
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if not CloudAgents.Auth.authorizeCallback(authHeaderValue, storedHash) {
    return Err(Web.unauthorized("invalid callback token"))
  }
  val observed = match observedSessionOf(observerSessionId) { case Ok(s) -> s; case Err(e) -> return Err(dbError(e)) }
  if observed.length.toInt() == 0 {
    // A valid token, but this session observes nothing: not an observer.
    return Err(Web.notFound("this session is not a ledger observer"))
  }
  return Ok(value = observed)
}

/// `POST /api/sessions/{id}/callbacks/observer/{op}`: `window` or `report`.
pub func observerCallbackHandler(
  observerSessionId: in String,
  op: in String,
  authHeaderValue: in String,
  body: in String,
  runner: in ObserverRunner,
): Result[LedgerToolEnvelope, Web.ApiError] {
  val observedId = authorizeObserver(observerSessionId, authHeaderValue)?
  if op != "window" and op != "report" {
    return Err(Web.notFound("unknown observer operation: " + op))
  }
  val facts = match sessionRunFacts(observedId) {
    case Ok(Some(f)) -> f
    case Ok(None) -> return Err(Web.notFound("the observed session no longer exists"))
    case Err(e) -> return Err(dbError(e))
  }
  val ctx = match sessionContext(observedId) {
    case Ok(c) -> c
    case Err(f) -> return Ok(value = LedgerToolEnvelope(ok = "false", error = f.message, reply = ""))
  }
  val final = facts.status != "RUNNING"
  if op == "window" {
    val diff = diffFor(facts, runner)
    match buildWindow(ctx, final, diff) {
      case Ok(w) -> return Ok(value = LedgerToolEnvelope(ok = "true", error = "", reply = w.toJson()))
      case Err(f) -> return Ok(value = LedgerToolEnvelope(ok = "false", error = f.message, reply = ""))
    }
  }
  val candidates = match decodeObserverReport(body) {
    case Ok(cs) -> cs
    case Err(msg) -> return Ok(value = LedgerToolEnvelope(ok = "false", error = msg, reply = ""))
  }
  match acceptReport(ctx, candidates, not final, defaultReconcileConfig()) {
    case Ok(r) -> return Ok(value = LedgerToolEnvelope(ok = "true", error = "", reply = r.toJson()))
    case Err(f) -> return Ok(value = LedgerToolEnvelope(ok = "false", error = f.message, reply = ""))
  }
}

// The observed workspace's diff when the profile grants it, clipped; "" when
// it doesn't, or when reading it fails (a window without a diff is still
// useful, so a failure is logged, not fatal).
func diffFor(facts: in SessionRunFacts, runner: in ObserverRunner): String {
  val settings = match observerSettingsFor(facts.profileId) { case Ok(Some(st)) -> st; case _ -> return "" }
  if settings.repoAccess == "none" {
    return ""
  }
  match runner.workspaceDiff(facts.sessionId, facts.harness, facts.userId) {
    case Ok(d) -> {
      if d.length.toInt() > windowMaxDiffChars {
        return d.substring(0, windowMaxDiffChars) + "\n[diff clipped at " + toString(windowMaxDiffChars) + " characters]"
      }
      return d
    }
    case Err(e) -> {
      println("WARNING: observer could not read the workspace diff of " + facts.sessionId + ": " + e)
      return ""
    }
  }
}

// ── Owner routes ──────────────────────────────────────────────────────────────
func ownedProfile(pid: in String): Result[Unit, Web.ApiError] {
  match CloudAgents.Repository.getProfile(pid, CloudAgents.Auth.requestScope()) {
    case Ok(Some(_)) -> return Ok(())
    case Ok(None) -> return Err(Web.notFound("Profile not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

/// `GET /api/profiles/{id}/observer`: the profile's observer settings (the
/// disabled defaults when it has none).
pub func getObserverSettingsHandler(pid: in String): Result[ObserverSettings, Web.ApiError] {
  ownedProfile(pid)?
  match observerSettingsFor(pid) {
    case Ok(Some(st)) -> return Ok(value = st)
    case Ok(None) -> return Ok(value = disabledObserverSettings())
    case Err(e) -> return Err(dbError(e))
  }
}

/// `PUT /api/profiles/{id}/observer`.
pub func putObserverSettingsHandler(pid: in String, body: in String): Result[ObserverSettings, Web.ApiError] {
  ownedProfile(pid)?
  val st = match decodeSettings(body) {
    case Some(s) -> s
    case None -> return Err(Web.badRequest("body must be {enabled, harness, model, repoAccess, midRunMinutes, maxPassesPerDay}"))
  }
  val problem = validateObserverSettings(st)
  if problem.length.toInt() > 0 {
    return Err(Web.badRequest(problem))
  }
  match saveObserverSettings(pid, st) {
    case Ok(_) -> return Ok(value = st)
    case Err(e) -> return Err(dbError(e))
  }
}

// @generate(Json)'s fromJson throws on text that isn't JSON at all.
func decodeSettings(body: in String): Option[ObserverSettings] {
  return try {
    match ObserverSettings.fromJson(body) {
      case Ok(s) -> Some(value = s)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

/// What `POST /api/sessions/{id}/ledger/observe` returns.
@generate(Json)
pub record ObserveQueued {
  pub queued: String
}

/// `POST /api/sessions/{id}/ledger/observe`: queue a pass for one of the
/// caller's sessions. It runs at the next maintenance call.
pub func observeNowHandler(sessionId: in String): Result[ObserveQueued, Web.ApiError] {
  val facts = match sessionRunFacts(sessionId) {
    case Ok(Some(f)) -> f
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if facts.userId != CloudAgents.Auth.currentUserId() {
    return Err(Web.notFound("Session not found"))
  }
  match observerSettingsForSession(sessionId) {
    case Ok(Some(_)) -> ()
    case Ok(None) -> return Err(Web.badRequest("this session's profile has no observer enabled"))
    case Err(e) -> return Err(dbError(e))
  }
  match markObserverPending(sessionId) {
    case Ok(_) -> return Ok(value = ObserveQueued(queued = "true"))
    case Err(e) -> return Err(dbError(e))
  }
}

/// What `GET /api/sessions/{id}/ledger/observer` returns: whether the
/// session is observed, and what its observer last did. `lastPassAt` is epoch
/// millis ("" before the first pass); `lastError` is "" after a clean pass.
@generate(Json)
pub record ObserverStatus {
  pub enabled: String
  pub harness: String
  pub model: String
  pub repoAccess: String
  pub pending: String
  pub lastPassAt: String
  pub lastError: String
  pub passesToday: String
  pub maxPassesPerDay: String
}

pub func observerStatusHandler(sessionId: in String): Result[ObserverStatus, Web.ApiError] {
  val facts = match sessionRunFacts(sessionId) {
    case Ok(Some(f)) -> f
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if facts.userId != CloudAgents.Auth.currentUserId() {
    return Err(Web.notFound("Session not found"))
  }
  val settings = match observerSettingsForSession(sessionId) {
    case Ok(Some(s)) -> s
    case Ok(None) -> {
      val off = disabledObserverSettings()
      return Ok(
        value = ObserverStatus(
          enabled = "false",
          harness = off.harness,
          model = "",
          repoAccess = off.repoAccess,
          pending = "0",
          lastPassAt = "",
          lastError = "",
          passesToday = "0",
          maxPassesPerDay = off.maxPassesPerDay
        )
      )
    }
    case Err(e) -> return Err(dbError(e))
  }
  val st = match observerState(sessionId) { case Ok(s) -> s; case Err(e) -> return Err(dbError(e)) }
  return Ok(
    value = ObserverStatus(
      enabled = "true",
      harness = settings.harness,
      model = settings.model,
      repoAccess = settings.repoAccess,
      pending = st.pending,
      lastPassAt = st.lastPassAt,
      lastError = st.lastError,
      passesToday = toString(passesToday(st.passDay, st.passesToday, CloudAgents.Repository.nowMillisLong())),
      maxPassesPerDay = settings.maxPassesPerDay
    )
  )
}

// ── Passes ────────────────────────────────────────────────────────────────────
/// What one maintenance call did.
@generate(Json)
pub record ObserverRunReport {
  pub passes: String
  pub skipped: String
  pub errors: slice[String]
}

/// `POST /api/maintenance/observe`: run the passes that are due. Operator only.
pub func observerMaintenanceHandler(runner: in ObserverRunner): Result[ObserverRunReport, Web.ApiError] {
  if CloudAgents.Auth.currentUserId() != CloudAgents.Auth.operatorUserId() {
    return Err(Web.unauthorized("the observer sweep may only be triggered by the operator identity"))
  }
  return Ok(value = runDuePasses(runner, maxPassesPerCall))
}

/// Run up to `limit` due passes. Every outcome is recorded on the observed
/// session's observer state; nothing here fails the call.
pub func runDuePasses(runner: in ObserverRunner, limit: in Int): ObserverRunReport {
  var passes = 0
  var skipped = 0
  var errors: slice[String] = []
  val due = match pendingObserverSessions(limit) {
    case Ok(ids) -> ids
    case Err(e) -> return ObserverRunReport(passes = "0", skipped = "0", errors = [CloudAgents.Sqlite.dbErrorMessage(e)])
  }
  var i = 0
  while i < due.length.toInt() {
    val outcome = runPass(due[i], runner)
    if outcome == "ran" {
      passes = passes + 1
    } else if outcome.startsWith("error: ") {
      errors = errors.append(due[i] + ": " + outcome.substring(7, outcome.length.toInt() - 7))
    } else {
      skipped = skipped + 1
    }
    i = i + 1
  }
  return ObserverRunReport(passes = toString(passes), skipped = toString(skipped), errors = errors)
}

/// One pass for an observed session. Returns "ran", "skipped: <why>" or
/// "error: <why>".
pub func runPass(observedId: in String, runner: in ObserverRunner): String {
  val claimed = match claimObserverPass(observedId) {
    case Ok(b) -> b
    case Err(e) -> return "error: " + CloudAgents.Sqlite.dbErrorMessage(e)
  }
  if not claimed {
    return "skipped: another caller took this pass"
  }
  val facts = match sessionRunFacts(observedId) {
    case Ok(Some(f)) -> f
    case Ok(None) -> {
      val _ = deleteObserverState(observedId)
      return "skipped: the session no longer exists"
    }
    case Err(e) -> return "error: " + CloudAgents.Sqlite.dbErrorMessage(e)
  }
  val settings = match observerSettingsForSession(observedId) {
    case Ok(Some(s)) -> s
    case Ok(None) -> return "skipped: not observed"
    case Err(e) -> return "error: " + CloudAgents.Sqlite.dbErrorMessage(e)
  }
  var st = match observerState(observedId) {
    case Ok(s) -> s
    case Err(e) -> return "error: " + CloudAgents.Sqlite.dbErrorMessage(e)
  }
  val now = CloudAgents.Repository.nowMillisLong()
  if not underDailyCap(settings, st.passDay, st.passesToday, now) {
    recordOutcome(st, "the daily pass limit (" + settings.maxPassesPerDay + ") is reached", false, now)
    return "skipped: daily limit"
  }
  // Nothing new, or nothing but reading and searching: no container.
  val preview = match CloudAgents.Repository.sessionEventsAfterSeqLimited(observedId, st.cursorSeq, windowMaxEvents) {
    case Ok(es) -> renderWindow(es, windowMaxChars)
    case Err(e) -> return "error: " + CloudAgents.Sqlite.dbErrorMessage(e)
  }
  if preview.events == 0 {
    return "skipped: nothing new"
  }
  if not windowWorthAPass(preview.signal) {
    st = withCursor(st, preview.lastSeq)
    recordOutcome(st, "", false, now)
    return "skipped: nothing but reads"
  }

  // Act as the observed session's owner for the session store, as a
  // scheduled job does, and put the caller's identity back afterwards.
  val callerUserId = CloudAgents.Auth.currentUserId()
  defer {
    CloudAgents.Auth.setCurrentUserId(callerUserId)
  }
  CloudAgents.Auth.setCurrentUserId(facts.userId)

  val observerId = match ensureObserverSession(facts, settings, st) {
    case Ok(id) -> id
    case Err(msg) -> {
      recordOutcome(st, msg, false, now)
      return "error: " + msg
    }
  }
  st = match observerState(observedId) {
    case Ok(s) -> s
    case Err(e) -> return "error: " + CloudAgents.Sqlite.dbErrorMessage(e)
  }
  val began = match CloudAgents.SessionStore.tryBeginRun(observerId) {
    case Ok(b) -> b
    case Err(e) -> return "error: " + CloudAgents.Sqlite.dbErrorMessage(e)
  }
  if not began {
    // The observer is still busy with the last pass: try again next call.
    val _ = markObserverPending(observedId)
    return "skipped: the observer is still running"
  }
  defer {
    val _ = CloudAgents.SessionStore.endRun(observerId)
  }
  var model = settings.model
  if model.length.toInt() == 0 {
    model = CloudAgents.SessionStore.defaultModelForHarness(settings.harness)
  }
  val final = facts.status != "RUNNING"
  val result = runner.runObserver(
    observerId,
    facts.repoUrl,
    facts.branch,
    settings.harness,
    model,
    facts.profileId,
    facts.userId,
    observerPrompt(final)
  )
  val after = match observerState(observedId) {
    case Ok(s) -> s
    case Err(e) -> return "error: " + CloudAgents.Sqlite.dbErrorMessage(e)
  }
  var problem = ""
  match result {
    case Ok(_) -> {
      if after.windowEnd.length.toInt() > 0 {
        problem = "the observer ended without reporting on its window"
      }
    }
    case Err(e) -> {
      problem = "the observer run failed: " + e
    }
  }
  // A window handed out but never reported is simply read again next time.
  recordOutcome(withWindowClosed(after), problem, true, now)
  // The observed run has ended and there is still unread transcript (a pass
  // capped by its window, or one that failed): queue another.
  if final and problem.length.toInt() == 0 {
    match CloudAgents.Repository.sessionEventsAfterSeqLimited(observedId, after.cursorSeq, 1) {
      case Ok(es) -> {
        if es.length.toInt() > 0 {
          val _ = markObserverPending(observedId)
        }
      }
      case Err(_) -> ()
    }
  }
  if problem.length.toInt() > 0 {
    return "error: " + problem
  }
  return "ran"
}

func withCursor(st: in ObserverState, cursor: in String): ObserverState {
  return ObserverState(
    sessionId = st.sessionId,
    observerSessionId = st.observerSessionId,
    cursorSeq = cursor,
    windowEnd = "",
    pending = st.pending,
    passDay = st.passDay,
    passesToday = st.passesToday,
    lastPassAt = st.lastPassAt,
    configHash = st.configHash,
    lastError = st.lastError
  )
}

func withWindowClosed(st: in ObserverState): ObserverState {
  return withCursor(st, st.cursorSeq)
}

// Persist a pass's outcome: `counted` passes count towards the daily cap and
// pace mid-run passes.
func recordOutcome(st: in ObserverState, problem: in String, counted: in Bool, now: in Long): Unit {
  var day = st.passDay
  var count = st.passesToday
  var last = st.lastPassAt
  if counted {
    val today = utcDay(now)
    val sofar = passesToday(st.passDay, st.passesToday, now)
    day = today
    count = toString(sofar + 1)
    last = toString(now)
  }
  val next = ObserverState(
    sessionId = st.sessionId,
    observerSessionId = st.observerSessionId,
    cursorSeq = st.cursorSeq,
    windowEnd = st.windowEnd,
    pending = "0",
    passDay = day,
    passesToday = count,
    lastPassAt = last,
    configHash = st.configHash,
    lastError = problem
  )
  // Keep a pending flag a trigger set while this pass ran.
  match observerState(st.sessionId) {
    case Ok(cur) -> {
      val merged = ObserverState(
        sessionId = next.sessionId,
        observerSessionId = next.observerSessionId,
        cursorSeq = next.cursorSeq,
        windowEnd = next.windowEnd,
        pending = cur.pending,
        passDay = next.passDay,
        passesToday = next.passesToday,
        lastPassAt = next.lastPassAt,
        configHash = next.configHash,
        lastError = next.lastError
      )
      match saveObserverState(merged) {
        case Ok(_) -> ()
        case Err(e) -> println(
          "WARNING: saving the observer state of " + st.sessionId + " failed: " +
            CloudAgents.Sqlite.dbErrorMessage(e)
        )
      }
    }
    case Err(e) -> println(
      "WARNING: reading the observer state of " + st.sessionId + " failed: " +
        CloudAgents.Sqlite.dbErrorMessage(e)
    )
  }
  if problem.length.toInt() > 0 {
    println("WARNING: observer pass for " + st.sessionId + ": " + problem)
  }
}

/// The observer session for `facts`, created on first use and replaced when
/// the profile's observer harness, model or repo access changed (the cursor
/// is kept, so nothing is reported twice). Runs as the observed session's
/// owner (the caller stamped the identity).
pub func ensureObserverSession(
  facts: in SessionRunFacts, settings: in ObserverSettings, st: in ObserverState
): Result[String, String] {
  val key = observerConfigKey(settings)
  if st.observerSessionId.length.toInt() > 0 and st.configHash == key {
    return Ok(value = st.observerSessionId)
  }
  val observerId = CloudAgents.Handlers.generateSessionId()
  var model = settings.model
  if model.length.toInt() == 0 {
    model = CloudAgents.SessionStore.defaultModelForHarness(settings.harness)
  }
  val session = CloudAgents.SessionStore.makeAgentSession(
    sessionId = observerId,
    repoUrl = facts.repoUrl,
    branch = facts.branch,
    containerId = "",
    harness = settings.harness,
    model = model,
    nativeSessionId = observerId
  )
  match CloudAgents.SessionStore.addSession(session) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = "creating the observer session failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match linkObserverSession(observerId, facts.sessionId, facts.profileId) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = "linking the observer session failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val previous = st.observerSessionId
  val next = ObserverState(
    sessionId = st.sessionId,
    observerSessionId = observerId,
    cursorSeq = st.cursorSeq,
    windowEnd = "",
    pending = st.pending,
    passDay = st.passDay,
    passesToday = st.passesToday,
    lastPassAt = st.lastPassAt,
    configHash = key,
    lastError = st.lastError
  )
  match saveObserverState(next) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = "saving the observer state failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match deleteObserverSessionRow(previous) {
    case Ok(_) -> ()
    case Err(e) -> println(
      "WARNING: removing the replaced observer session " + previous + " failed: " +
        CloudAgents.Sqlite.dbErrorMessage(e)
    )
  }
  return Ok(value = observerId)
}
