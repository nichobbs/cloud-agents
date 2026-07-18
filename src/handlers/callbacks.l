//! Phase 6 (docs/phase6-mcp-callbacks.md): the in-container MCP shim's host
//! endpoints — permission requests, user questions, and progress reports.
//!
//! Two authentication modes on the same session, distinguished by route shape
//! (see CloudAgents.Auth.isContainerCallbackRoute, which routes AuthMiddleware
//! around the endpoints below entirely):
//!
//!   - Container-originated (create a request/question, poll for a decision,
//!     report progress): authenticated with the session's own callback
//!     bearer token (authorizeCallbackToken below), never the user's
//!     OAuth/static token. Minted at container creation in
//!     CloudAgents.Docker, gated by CLOUD_AGENTS_MCP_CALLBACKS.
//!   - User-originated (answer a pending request/question from the UI): flows
//!     through the normal AuthMiddleware bearer check, then an explicit
//!     session-ownership lookup here (CloudAgents.SessionStore.getSession,
//!     owner-scoped by CloudAgents.Auth.currentUserId()) — the same pattern
//!     every other session sub-resource handler in sessions.l/interactions.l
//!     uses.
package CloudAgents.Callbacks

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Text
import extern System.Environment as Env
import extern System.String as DotNetString

val maxToolNameLen = 256

val maxInputJsonLen = 65536

val maxQuestionLen = 8192

val maxOptionsJsonLen = 8192

val maxNoteLen = 8192

val maxAnswerLen = 8192

val maxProgressSummaryLen = 4096

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

/// Host-side fail-closed timeout (docs/phase6 §3 step 4): a still-pending
/// request/question is auto-decided once it has been pending at least this
/// long. Overridable via CLOUD_AGENTS_CALLBACK_TIMEOUT_MS so tests can shrink
/// it to 0 instead of sleeping ten real minutes; defaults to the shim's own
/// documented default (10 minutes) as a host-side backstop in case the shim
/// never enforces its own client-side timeout.
pub func callbackTimeoutMillis(): Long {
  val raw = Env.GetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS")
  if DotNetString.IsNullOrEmpty(raw) {
    return 600000.toLong()
  }
  val n = tryParseMillis(raw)
  if n < 0 {
    return 600000.toLong()
  }
  return n.toLong()
}

func digitValue(c: in String): Int {
  if c == "0" {
    return 0
  }
  if c == "1" {
    return 1
  }
  if c == "2" {
    return 2
  }
  if c == "3" {
    return 3
  }
  if c == "4" {
    return 4
  }
  if c == "5" {
    return 5
  }
  if c == "6" {
    return 6
  }
  if c == "7" {
    return 7
  }
  if c == "8" {
    return 8
  }
  if c == "9" {
    return 9
  }
  return -1
}

/// Parse a run of decimal digits (only) into an Int, or -1 for anything else
/// (empty, too long, non-digit) — mirrors CloudAgents.Handlers.parseOutputOffset.
/// Bounded to 9 digits so the value fits comfortably in Int (realistic
/// timeouts are minutes, not decades of milliseconds); this only ever reads
/// an operator-set env var, never client input.
func tryParseMillis(s: in String): Int {
  if s.length == 0 or s.length > 9 {
    return -1
  }
  var n = 0
  var i = 0
  while i < s.length {
    val d = digitValue(s.substring(i, 1))
    if d < 0 {
      return -1
    }
    n = n * 10 + d
    i = i + 1
  }
  return n
}

/// Whether `s` is empty (unspecified) or a decimal 0..100. Used to validate
/// report_progress's optional percentComplete.
func isValidPercent(s: in String): Bool {
  if s.length == 0 {
    return true
  }
  if s.length > 3 {
    return false
  }
  var n = 0
  var i = 0
  while i < s.length {
    val d = digitValue(s.substring(i, 1))
    if d < 0 {
      return false
    }
    n = n * 10 + d
    i = i + 1
  }
  return n >= 0 and n <= 100
}

/// Verify the Authorization bearer header carries THIS session's callback
/// token. 404 for an unknown session (mirrors every other session
/// sub-resource route); 401 for a missing/wrong bearer, or for a session that
/// exists but never minted a token (callbacks disabled for it) — both map to
/// the same "invalid callback token" response so a probing container can't
/// distinguish "wrong token" from "callbacks aren't on" for this session.
func authorizeCallbackToken(sessionId: in String, authHeaderValue: in String): Result[Unit, Web.ApiError] {
  val stored = match CloudAgents.SessionStore.callbackTokenForSession(sessionId) {
    case Ok(Some(t)) -> t
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if stored.length == 0 or not CloudAgents.Auth.authorizeCallback(authHeaderValue, stored) {
    return Err(Web.unauthorized("invalid callback token"))
  }
  return Ok(())
}

/// The session a permission request/question belongs to, owner-checked
/// against the CURRENT (human, normally-authenticated) caller. Used by the
/// answer handlers below. 404 both when the session doesn't exist and when it
/// exists but belongs to someone else — getSession is already owner-scoped by
/// CloudAgents.Auth.currentUserId(), so both cases look identical here, the
/// same non-leaking shape every other owner-scoped lookup in this codebase
/// has.
func requireOwnedSession(sessionId: in String): Result[Unit, Web.ApiError] {
  match getSession(sessionId) {
    case Ok(Some(_)) -> return Ok(())
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

// ─── Permission requests ──────────────────────────────────────────────────────
@generate(Json)
pub record CreatePermissionRequestRequest {
  pub toolName: String
  pub inputJson: String
}

@generate(Json)
pub record CreatePermissionRequestResponse {
  pub id: String
  pub status: String
}

@generate(Json)
pub record PermissionDecision {
  pub status: String
  pub updatedInputJson: String
  pub note: String
}

@generate(Json)
pub record AnswerPermissionRequestRequest {
  pub decision: String
  pub note: String
  pub updatedInputJson: String
}

/// POST /api/sessions/{id}/callbacks/permission — container-originated.
/// Creates a pending permission request, unless an allow-always rule already
/// covers this exact (tool, input) pair for the session, in which case the
/// request is created already 'allowed' so the container's first poll returns
/// the decision immediately (docs/phase6 §3).
pub func createPermissionRequestHandler(
  id: in String,
  authHeaderValue: in String,
  req: in CreatePermissionRequestRequest,
): Result[CreatePermissionRequestResponse, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  if req.toolName.length == 0 {
    return Err(Web.badRequest("toolName is required"))
  }
  if not CloudAgents.Text.withinMaxLength(req.toolName, maxToolNameLen) {
    return Err(Web.badRequest("toolName is too long (max " + toString(maxToolNameLen) + " characters)"))
  }
  if not CloudAgents.Text.withinMaxLength(req.inputJson, maxInputJsonLen) {
    return Err(Web.badRequest("inputJson is too long (max " + toString(maxInputJsonLen) + " characters)"))
  }
  val ruleMatched = match CloudAgents.Repository.permissionRuleMatches(id, req.toolName, req.inputJson) {
    case Ok(b) -> b
    case Err(e) -> return Err(dbError(e))
  }
  match CloudAgents.Repository.createPermissionRequest(id, req.toolName, req.inputJson, ruleMatched) {
    case Ok(pr) -> return Ok(CreatePermissionRequestResponse(id = pr.id, status = pr.status))
    case Err(e) -> return Err(dbError(e))
  }
}

/// GET /api/sessions/{id}/callbacks/permission/{rid} — container-originated
/// long-poll. Applies the host-side timeout backstop before reading (so a
/// request that has been pending too long resolves to 'denied' on this very
/// call, not just on some future sweep), then returns the current decision.
pub func getPermissionRequestHandler(
  id: in String, rid: in String, authHeaderValue: in String
): Result[PermissionDecision, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if rid.length == 0 {
    return Err(Web.badRequest("request id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  match CloudAgents.Repository.timeoutPendingPermissionRequest(rid, callbackTimeoutMillis()) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  val pr = match CloudAgents.Repository.getPermissionRequest(rid) {
    case Ok(Some(p)) -> p
    case Ok(None) -> return Err(Web.notFound("permission request not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if pr.sessionId != id {
    return Err(Web.notFound("permission request not found"))
  }
  return Ok(PermissionDecision(status = pr.status, updatedInputJson = pr.updatedInputJson, note = pr.note))
}

/// POST /api/sessions/{id}/callbacks/permission/{rid}/answer —
/// user-originated. `decision` is one of allow/deny/allow_always;
/// allow_always additionally persists a session-scoped rule so a later
/// identical (tool, input) pair auto-approves (docs/phase6 §3).
pub func answerPermissionRequestHandler(
  id: in String, rid: in String, req: in AnswerPermissionRequestRequest
): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if rid.length == 0 {
    return Err(Web.badRequest("request id is required"))
  }
  if req.decision != "allow" and req.decision != "deny" and req.decision != "allow_always" {
    return Err(Web.badRequest("decision must be one of: allow, deny, allow_always"))
  }
  if not CloudAgents.Text.withinMaxLength(req.note, maxNoteLen) {
    return Err(Web.badRequest("note is too long (max " + toString(maxNoteLen) + " characters)"))
  }
  if not CloudAgents.Text.withinMaxLength(req.updatedInputJson, maxInputJsonLen) {
    return Err(Web.badRequest("updatedInputJson is too long (max " + toString(maxInputJsonLen) + " characters)"))
  }
  requireOwnedSession(id)?
  val pr = match CloudAgents.Repository.getPermissionRequest(rid) {
    case Ok(Some(p)) -> p
    case Ok(None) -> return Err(Web.notFound("permission request not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if pr.sessionId != id {
    return Err(Web.notFound("permission request not found"))
  }
  val status = if req.decision == "deny" { "denied" } else { "allowed" }
  val affected = match CloudAgents.Repository.answerPermissionRequest(rid, status, req.updatedInputJson, req.note) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.conflict("permission request has already been decided"))
  }
  if req.decision == "allow_always" {
    match CloudAgents.Repository.addPermissionRule(id, pr.toolName, pr.inputJson) {
      case Ok(_) -> ()
      case Err(e) -> println("WARNING: failed to persist allow-always rule for session " + id + ": " + CloudAgents.Sqlite.dbErrorMessage(e))
    }
  }
  return Ok(())
}

// ─── User questions ────────────────────────────────────────────────────────────
@generate(Json)
pub record CreateUserQuestionRequest {
  pub question: String
  pub optionsJson: String
}

@generate(Json)
pub record CreateUserQuestionResponse {
  pub id: String
}

@generate(Json)
pub record UserQuestionAnswer {
  pub status: String
  pub answer: String
}

@generate(Json)
pub record AnswerUserQuestionRequest {
  pub answer: String
}

/// POST /api/sessions/{id}/callbacks/question — container-originated.
pub func createUserQuestionHandler(
  id: in String, authHeaderValue: in String, req: in CreateUserQuestionRequest
): Result[CreateUserQuestionResponse, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  if req.question.length == 0 {
    return Err(Web.badRequest("question is required"))
  }
  if not CloudAgents.Text.withinMaxLength(req.question, maxQuestionLen) {
    return Err(Web.badRequest("question is too long (max " + toString(maxQuestionLen) + " characters)"))
  }
  if not CloudAgents.Text.withinMaxLength(req.optionsJson, maxOptionsJsonLen) {
    return Err(Web.badRequest("optionsJson is too long (max " + toString(maxOptionsJsonLen) + " characters)"))
  }
  match CloudAgents.Repository.createUserQuestion(id, req.question, req.optionsJson) {
    case Ok(q) -> return Ok(CreateUserQuestionResponse(id = q.id))
    case Err(e) -> return Err(dbError(e))
  }
}

/// GET /api/sessions/{id}/callbacks/question/{rid} — container-originated
/// long-poll, mirroring getPermissionRequestHandler. A timed-out question
/// reports status 'timed_out' (never a bare 'answered' with an empty string,
/// which would be indistinguishable from a human deliberately answering "").
pub func getUserQuestionHandler(
  id: in String, rid: in String, authHeaderValue: in String
): Result[UserQuestionAnswer, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if rid.length == 0 {
    return Err(Web.badRequest("question id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  match CloudAgents.Repository.timeoutPendingUserQuestion(rid, callbackTimeoutMillis()) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  val q = match CloudAgents.Repository.getUserQuestion(rid) {
    case Ok(Some(qq)) -> qq
    case Ok(None) -> return Err(Web.notFound("question not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if q.sessionId != id {
    return Err(Web.notFound("question not found"))
  }
  return Ok(UserQuestionAnswer(status = q.status, answer = q.answer))
}

/// POST /api/sessions/{id}/callbacks/question/{rid}/answer —
/// user-originated.
pub func answerUserQuestionHandler(
  id: in String, rid: in String, req: in AnswerUserQuestionRequest
): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if rid.length == 0 {
    return Err(Web.badRequest("question id is required"))
  }
  if not CloudAgents.Text.withinMaxLength(req.answer, maxAnswerLen) {
    return Err(Web.badRequest("answer is too long (max " + toString(maxAnswerLen) + " characters)"))
  }
  requireOwnedSession(id)?
  val q = match CloudAgents.Repository.getUserQuestion(rid) {
    case Ok(Some(qq)) -> qq
    case Ok(None) -> return Err(Web.notFound("question not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if q.sessionId != id {
    return Err(Web.notFound("question not found"))
  }
  val affected = match CloudAgents.Repository.answerUserQuestion(rid, req.answer) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.conflict("question has already been answered"))
  }
  return Ok(())
}

// ─── Progress reports ──────────────────────────────────────────────────────────
@generate(Json)
pub record ReportProgressRequest {
  pub summary: String
  pub percentComplete: String
}

/// POST /api/sessions/{id}/callbacks/progress — container-originated,
/// fire-and-forget. Persists the latest summary/percent on the session row;
/// the run's poll loop (CloudAgents.Docker.streamSessionMessage) picks up the
/// change and pushes a `progress_update` SSE frame.
pub func reportProgressHandler(
  id: in String, authHeaderValue: in String, req: in ReportProgressRequest
): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  if not CloudAgents.Text.withinMaxLength(req.summary, maxProgressSummaryLen) {
    return Err(Web.badRequest("summary is too long (max " + toString(maxProgressSummaryLen) + " characters)"))
  }
  if not isValidPercent(req.percentComplete) {
    return Err(Web.badRequest("percentComplete must be a decimal 0-100"))
  }
  match CloudAgents.Repository.updateSessionProgress(id, req.summary, req.percentComplete) {
    case Ok(_) -> return Ok(())
    case Err(e) -> return Err(dbError(e))
  }
}
