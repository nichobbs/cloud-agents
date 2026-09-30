//! CloudAgents.LedgerHandlers — HTTP handlers for the session ledger
//! (docs/session-ledger.md §6).
//!
//! Two audiences:
//!
//! - The agent, via the in-container shim: `POST /api/sessions/{id}/callbacks/
//!   ledger/{op}`, authenticated with the session's callback bearer token
//!   (AuthMiddleware exempts `/callbacks/` paths). The body is the tool's
//!   raw MCP `arguments` object (CloudAgents.Ledger.ToolArgs decodes it).
//!   Every authenticated call
//!   answers 200 with a LedgerToolEnvelope — `ok` false carries the message
//!   the agent should read and act on (an invalid transition, a missing
//!   field). The shim's HttpWebRequest transport loses non-2xx bodies, so
//!   domain errors must not be HTTP errors on this path; only auth and
//!   unknown-session failures are.
//! - The human, via the PWA: owner-scoped `/api/sessions/{id}/ledger...`
//!   routes plus the cross-session `/api/ledger/inbox`.
package CloudAgents.LedgerHandlers

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Sqlite
import CloudAgents.SessionStore
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Summary
import CloudAgents.Ledger.Store
import CloudAgents.Ledger.Service
import CloudAgents.Ledger.ToolArgs
import CloudAgents.Ledger.GitHubPort
import CloudAgents.Ledger.Sync
import CloudAgents.OAuth

// ── Failure mapping ───────────────────────────────────────────────────────────
func toApiError(f: in LedgerFailure): Web.ApiError {
  if f.status == "invalid" {
    return Web.badRequest(f.message)
  }
  if f.status == "not_found" {
    return Web.notFound(f.message)
  }
  if f.status == "conflict" {
    return Web.conflict(f.message)
  }
  return Web.internalError(f.message)
}

// ── Agent side ────────────────────────────────────────────────────────────────
/// The body of every agent-facing ledger callback response. `reply` is the
/// operation's reply as JSON text (the shim hands it to the agent verbatim);
/// `error` is set instead when `ok` is "false".
@generate(Json)
pub record LedgerToolEnvelope {
  pub ok: String
  pub error: String
  pub reply: String
}

func okEnvelope(json: in String): LedgerToolEnvelope {
  return LedgerToolEnvelope(ok = "true", error = "", reply = json)
}

func errEnvelope(message: in String): LedgerToolEnvelope {
  return LedgerToolEnvelope(ok = "false", error = message, reply = "")
}

func envelopeOf(r: in Result[String, LedgerFailure]): LedgerToolEnvelope {
  match r {
    case Ok(json) -> return okEnvelope(json)
    case Err(f) -> return errEnvelope(f.message)
  }
}

/// Verify the Authorization bearer is THIS session's callback token — the
/// same contract as CloudAgents.Callbacks: 404 for an unknown session, 401
/// for a missing / wrong token or a session with callbacks off.
func authorizeContainer(sessionId: in String, authHeaderValue: in String): Result[Unit, Web.ApiError] {
  val storedHash = match CloudAgents.SessionStore.callbackTokenHashForSession(sessionId) {
    case Ok(Some(t)) -> t
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  if not CloudAgents.Auth.authorizeCallback(authHeaderValue, storedHash) {
    return Err(Web.unauthorized("invalid callback token"))
  }
  return Ok(())
}

/// The ledger operations the shim can invoke, by URL segment.
pub func isLedgerOp(op: in String): Bool {
  return op == "register-items" or op == "item-status" or op == "decision" or op == "deviation" or op == "ask" or
    op == "note" or
    op == "check-feedback" or
    op == "state"
}

func invalidArgs(msg: in String): Result[String, LedgerFailure] {
  return Err(error = LedgerFailure(status = "invalid", message = msg))
}

// `?` is hoisted out of every expression below: `?` inside a call or
// constructor argument can emit invalid IL (lyric-lang#6448).
func dispatch(ctx: in SessionContext, op: in String, body: in String): Result[String, LedgerFailure] {
  if op == "register-items" {
    match decodeRegisterItems(body) {
      case Ok(req) -> {
        val reply = registerBatch(ctx, req)?
        return Ok(value = reply.toJson())
      }
      case Err(msg) -> return invalidArgs(msg)
    }
  }
  if op == "item-status" {
    match decodeSetItemStatus(body) {
      case Ok(req) -> {
        val reply = agentSetStatus(ctx, req)?
        return Ok(value = reply.toJson())
      }
      case Err(msg) -> return invalidArgs(msg)
    }
  }
  if op == "decision" {
    match decodeDecision(body) {
      case Ok(req) -> {
        val reply = recordDecision(ctx, req)?
        return Ok(value = reply.toJson())
      }
      case Err(msg) -> return invalidArgs(msg)
    }
  }
  if op == "deviation" {
    match decodeDeviation(body) {
      case Ok(req) -> {
        val reply = recordDeviation(ctx, req)?
        return Ok(value = reply.toJson())
      }
      case Err(msg) -> return invalidArgs(msg)
    }
  }
  if op == "ask" {
    match decodeAsk(body) {
      case Ok(req) -> {
        val reply = ask(ctx, req)?
        return Ok(value = reply.toJson())
      }
      case Err(msg) -> return invalidArgs(msg)
    }
  }
  if op == "note" {
    match decodeNote(body) {
      case Ok(req) -> {
        val reply = note(ctx, req)?
        return Ok(value = reply.toJson())
      }
      case Err(msg) -> return invalidArgs(msg)
    }
  }
  if op == "check-feedback" {
    val reply = checkFeedback(ctx)?
    return Ok(value = reply.toJson())
  }
  if op == "state" {
    val reply = agentStateOf(ctx)?
    return Ok(value = reply.toJson())
  }
  return invalidArgs("unknown ledger operation '" + op + "'")
}

/// POST /api/sessions/{id}/callbacks/ledger/{op} — container-originated.
pub func ledgerCallbackHandler(
  id: in String, op: in String, authHeaderValue: in String, body: in String
): Result[LedgerToolEnvelope, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("Session id is required"))
  }
  authorizeContainer(id, authHeaderValue)?
  if not isLedgerOp(op) {
    return Err(Web.notFound("unknown ledger operation"))
  }
  val ctx = match sessionContext(id) { case Ok(c) -> c; case Err(f) -> return Err(toApiError(f)) }
  // The try is the extern-boundary guard: an unexpected panic below must
  // become an in-band error for the agent, never a torn-down request.
  val result = try {
    dispatch(ctx, op, body)
  } catch Bug as b {
    println("WARNING: ledger " + op + " failed: " + b.message)
    invalidArgs("the ledger could not process this " + op + " call")
  }
  return Ok(envelopeOf(result))
}

// ── Human side ────────────────────────────────────────────────────────────────
/// The owner-scoped context for a session: 404 unless the current user owns
/// it (CloudAgents.SessionStore.getSession is scoped by currentUserId).
func ownedContext(id: in String): Result[SessionContext, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("Session id is required"))
  }
  match CloudAgents.SessionStore.getSession(id, CloudAgents.Auth.requestScope()) {
    case Ok(Some(_)) -> ()
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match sessionContext(id) {
    case Ok(c) -> return Ok(c)
    case Err(f) -> return Err(toApiError(f))
  }
}

/// GET /api/sessions/{id}/ledger?after=<cursor>
pub func getLedgerHandler(id: in String, after: in String): Result[LedgerSnapshot, Web.ApiError] {
  val ctx = ownedContext(id)?
  match snapshot(ctx, after) {
    case Ok(s) -> return Ok(s)
    case Err(f) -> return Err(toApiError(f))
  }
}

/// GET /api/sessions/{id}/ledger/entries/{eid}
pub func getLedgerEntryHandler(id: in String, entryId: in String): Result[EntryDetail, Web.ApiError] {
  val ctx = ownedContext(id)?
  match entryDetail(ctx, entryId) {
    case Ok(d) -> return Ok(d)
    case Err(f) -> return Err(toApiError(f))
  }
}

@generate(Json)
pub record ReviewEntryRequest {
  pub kind: String
  pub body: String
}

/// POST /api/sessions/{id}/ledger/entries/{eid}/review
pub func reviewLedgerEntryHandler(
  id: in String, entryId: in String, req: in ReviewEntryRequest
): Result[Feedback, Web.ApiError] {
  val ctx = ownedContext(id)?
  match review(ctx, entryId, req.kind, req.body, CloudAgents.Auth.currentUserId()) {
    case Ok(f) -> return Ok(f)
    case Err(f) -> return Err(toApiError(f))
  }
}

@generate(Json)
pub record LedgerFeedbackRequest {
  pub item: String
  pub kind: String
  pub body: String
}

/// POST /api/sessions/{id}/ledger/feedback — session- or item-level
/// directive / comment for the agent.
pub func ledgerFeedbackHandler(id: in String, req: in LedgerFeedbackRequest): Result[Feedback, Web.ApiError] {
  val ctx = ownedContext(id)?
  match giveFeedback(ctx, req.item, req.kind, req.body, CloudAgents.Auth.currentUserId()) {
    case Ok(f) -> return Ok(f)
    case Err(f) -> return Err(toApiError(f))
  }
}

/// Decode an add-items body (routes can't name RegisterItemsRequest
/// qualified — see docs/lyric/gotchas.md on package-qualified records).
pub func decodeAddItemsBody(body: in String): Option[RegisterItemsRequest] {
  return try {
    match RegisterItemsRequest.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

/// POST /api/sessions/{id}/ledger/items — the human adds items to the batch.
pub func addLedgerItemsHandler(id: in String, req: in RegisterItemsRequest): Result[RegisterReply, Web.ApiError] {
  val ctx = ownedContext(id)?
  match registerBatch(ctx, req) {
    case Ok(r) -> return Ok(r)
    case Err(f) -> return Err(toApiError(f))
  }
}

@generate(Json)
pub record LedgerItemStateRequest {
  pub item: String
  pub to: String
  pub reason: String
}

/// POST /api/sessions/{id}/ledger/item-state — the human unblocks, skips,
/// requeues or reopens an item. The item id travels in the body: canonical
/// refs contain '/', '#' and ':'.
pub func ledgerItemStateHandler(id: in String, req: in LedgerItemStateRequest): Result[WorkItem, Web.ApiError] {
  val ctx = ownedContext(id)?
  match humanSetStatus(ctx, req.item, req.to, req.reason) {
    case Ok(w) -> return Ok(w)
    case Err(f) -> return Err(toApiError(f))
  }
}

/// GET /api/ledger/inbox — every pending review / blocking entry across the
/// current user's sessions.
pub func ledgerInboxHandler(): Result[InboxView, Web.ApiError] {
  match inbox(CloudAgents.Auth.requestScope()) {
    case Ok(v) -> return Ok(v)
    case Err(f) -> return Err(toApiError(f))
  }
}

// Guarded body decoders: `@generate(Json)`'s fromJson returns Err for a
// wrong shape but throws on input that is not JSON at all.
pub func decodeReviewBody(body: in String): Option[ReviewEntryRequest] {
  return try {
    match ReviewEntryRequest.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

pub func decodeFeedbackBody(body: in String): Option[LedgerFeedbackRequest] {
  return try {
    match LedgerFeedbackRequest.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

pub func decodeItemStateBody(body: in String): Option[LedgerItemStateRequest] {
  return try {
    match LedgerItemStateRequest.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

// ── GitHub reconciliation (Phase 3) ───────────────────────────────────────────
/// What a sync run did. Counts are decimal strings (the wire convention).
@generate(Json)
pub record LedgerSyncReport {
  pub sessions: String
  pub items: String
  pub transitions: String
  pub calls: String
  pub errors: slice[String]
}

/// GitHub calls one maintenance run may make across all sessions, and one
/// session may make in a run. Leftover work waits for the next run.
pub val syncRunBudget: Int = 300

pub val syncSessionBudget: Int = 60

pub val syncMaxSessions: Int = 20

/// POST /api/maintenance/ledger-sync — reconcile the sessions that need it
/// with GitHub. Operator only, polled by an external scheduler like the other
/// maintenance endpoints (there is no in-process timer).
pub func ledgerSyncHandler(): Result[String, Web.ApiError] {
  if CloudAgents.Auth.currentUserId() != CloudAgents.Auth.operatorUserId() {
    return Err(Web.unauthorized("the ledger sync may only be triggered by the operator identity"))
  }
  val ids = match sessionsToSync(syncMaxSessions) {
    case Ok(xs) -> xs
    case Err(e) -> return Err(Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  var sessions = 0
  var items = 0
  var transitions = 0
  var calls = 0
  var errors: slice[String] = []
  var i = 0
  while i < ids.length.toInt() and calls < syncRunBudget {
    var budget = syncRunBudget - calls
    if budget > syncSessionBudget {
      budget = syncSessionBudget
    }
    match syncOne(ids[i], budget) {
      case Ok(o) -> {
        sessions = sessions + 1
        items = items + o.items
        transitions = transitions + o.transitions
        calls = calls + o.calls
        errors = appendPrefixed(errors, ids[i], o.errors)
      }
      case Err(msg) -> {
        errors = errors.append(ids[i] + ": " + msg)
      }
    }
    i = i + 1
  }
  return Ok(value = syncReportJson(sessions, items, transitions, calls, errors))
}

/// POST /api/sessions/{id}/ledger/sync — reconcile one of the caller's
/// sessions now.
pub func ledgerSessionSyncHandler(id: in String): Result[String, Web.ApiError] {
  val ctx = ownedContext(id)?
  match syncOne(ctx.sessionId, syncSessionBudget) {
    case Ok(o) -> return Ok(value = syncReportJson(1, o.items, o.transitions, o.calls, o.errors))
    case Err(msg) -> {
      if msg == syncBusyMessage {
        return Err(Web.conflict(msg))
      }
      return Err(Web.badRequest(msg))
    }
  }
}

/// How long a pass may hold a session's sync lease: comfortably above a full
/// budget of calls at the 15s timeout. A crashed pass's lease just expires.
val syncLeaseMillis: Long = 1800000.toLong()

/// Why a pass didn't run because another holds the session.
pub val syncBusyMessage: String = "a GitHub sync of this session is already running; try again shortly"

func syncOne(sessionId: in String, budget: in Int): Result[SyncOutcome, String] {
  val ctx = match sessionContext(sessionId) { case Ok(c) -> c; case Err(f) -> return Err(error = f.message) }
  // One pass per session at a time: two at once could each post the blocker
  // comment before either records its id.
  val lease = match acquireSyncLease(sessionId, ctx.tenantScope, syncLeaseMillis) {
    case Ok(t) -> t
    case Err(e) -> return Err(error = CloudAgents.Sqlite.dbErrorMessage(e))
  }
  if lease.length.toInt() == 0 {
    return Err(error = syncBusyMessage)
  }
  defer {
    match releaseSyncLease(sessionId, ctx.tenantScope, lease) {
      case Ok(_) -> ()
      case Err(e) -> println(
        "WARNING: ledger sync lease for " + sessionId + " not released: " +
          CloudAgents.Sqlite.dbErrorMessage(e)
      )
    }
  }
  val token = match CloudAgents.OAuth.ensureFreshGitHubToken(ctx.ownerUserId) {
    case Ok(t) -> t
    case Err(_) -> {
      val msg = "the session owner has no usable GitHub token; reconnect GitHub to sync"
      noteAttempt(ctx, msg)
      return Err(error = msg)
    }
  }
  noteAttempt(ctx, "")
  return Ok(value = syncSession(ctx, HttpGitHubPort(token = token), budget))
}

// Best-effort: a failure here only affects which session goes first next run.
func noteAttempt(ctx: in SessionContext, error: in String): Unit {
  match markSyncAttempt(ctx.sessionId, ctx.tenantScope, error) {
    case Ok(_) -> ()
    case Err(e) -> println(
      "WARNING: ledger sync attempt for " + ctx.sessionId + " not recorded: " +
        CloudAgents.Sqlite.dbErrorMessage(e)
    )
  }
}

func appendPrefixed(acc: in slice[String], sessionId: in String, errors: in slice[String]): slice[String] {
  var merged = acc
  var i = 0
  while i < errors.length.toInt() {
    merged = merged.append(sessionId + ": " + errors[i])
    i = i + 1
  }
  return merged
}

func syncReportJson(
  sessions: in Int, items: in Int, transitions: in Int, calls: in Int, errors: in slice[String]
): String {
  return LedgerSyncReport(sessions = toString(sessions), items = toString(items), transitions = toString(transitions), calls = toString(calls), errors = errors).toJson()
}
