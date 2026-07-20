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
import Std.Collections
import Std.Errors
import Std.File
import Std.Uuid
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.RepoKey
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Text
import extern System.Environment as Env
import extern System.String as DotNetString

// Caps below are checked with withinMaxByteLength, not withinMaxLength,
// wherever the field is free text or JSON that could hold multi-byte UTF-8
// (a char-count check alone lets such a payload land up to ~4x over the
// stated budget, #64/#566) — except maxToolNameLen/maxSecretNameLen/
// maxArtifactMimeTypeLen (narrow-charset identifiers, where char vs byte
// doesn't matter) and maxArtifactBase64Len (base64 is pure ASCII by
// construction, so char count and byte count are always equal).
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
  if not CloudAgents.Text.withinMaxByteLength(req.inputJson, maxInputJsonLen) {
    return Err(Web.badRequest("inputJson is too long (max " + toString(maxInputJsonLen) + " bytes)"))
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
  if not CloudAgents.Text.withinMaxByteLength(req.note, maxNoteLen) {
    return Err(Web.badRequest("note is too long (max " + toString(maxNoteLen) + " bytes)"))
  }
  if not CloudAgents.Text.withinMaxByteLength(req.updatedInputJson, maxInputJsonLen) {
    return Err(Web.badRequest("updatedInputJson is too long (max " + toString(maxInputJsonLen) + " bytes)"))
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
  if not CloudAgents.Text.withinMaxByteLength(req.question, maxQuestionLen) {
    return Err(Web.badRequest("question is too long (max " + toString(maxQuestionLen) + " bytes)"))
  }
  if not CloudAgents.Text.withinMaxByteLength(req.optionsJson, maxOptionsJsonLen) {
    return Err(Web.badRequest("optionsJson is too long (max " + toString(maxOptionsJsonLen) + " bytes)"))
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
  if not CloudAgents.Text.withinMaxByteLength(req.answer, maxAnswerLen) {
    return Err(Web.badRequest("answer is too long (max " + toString(maxAnswerLen) + " bytes)"))
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
  if not CloudAgents.Text.withinMaxByteLength(req.summary, maxProgressSummaryLen) {
    return Err(Web.badRequest("summary is too long (max " + toString(maxProgressSummaryLen) + " bytes)"))
  }
  if not isValidPercent(req.percentComplete) {
    return Err(Web.badRequest("percentComplete must be a decimal 0-100"))
  }
  match CloudAgents.Repository.updateSessionProgress(id, req.summary, req.percentComplete) {
    case Ok(_) -> return Ok(())
    case Err(e) -> return Err(dbError(e))
  }
}

// ─── Phase 6 §7: request_secret ──────────────────────────────────────────────
//
// docs/phase6-mcp-callbacks.md §7.1. Threat model: the primary risk is
// prompt-injected exfiltration, so the credential VALUE never enters an
// SSE frame, never gets logged, and is returned from the long-poll response
// AT MOST ONCE (CloudAgents.Repository.markSecretRequestDelivered's
// write-once guard). No allow-always — every request prompts a human.
val maxSecretNameLen = 128

val maxSecretReasonLen = 2048

@generate(Json)
pub record CreateSecretRequestRequest {
  pub name: String
  pub reason: String
}

@generate(Json)
pub record CreateSecretRequestResponse {
  pub id: String
  pub status: String
}

@generate(Json)
pub record SecretDecision {
  pub status: String
  pub value: String
}

@generate(Json)
pub record AnswerSecretRequestRequest {
  pub decision: String
}

/// POST /api/sessions/{id}/callbacks/secret — container-originated. Fails
/// fast (400) when the named credential isn't configured for the session
/// owner, instead of creating a pending row a human could only ever deny —
/// the error names the requested name but reveals nothing about which
/// OTHER credentials exist (docs/phase6 §7.1).
pub func createSecretRequestHandler(
  id: in String, authHeaderValue: in String, req: in CreateSecretRequestRequest
): Result[CreateSecretRequestResponse, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  if req.name.length == 0 {
    return Err(Web.badRequest("name is required"))
  }
  if not CloudAgents.Text.withinMaxLength(req.name, maxSecretNameLen) {
    return Err(Web.badRequest("name is too long (max " + toString(maxSecretNameLen) + " characters)"))
  }
  if not CloudAgents.Text.withinMaxByteLength(req.reason, maxSecretReasonLen) {
    return Err(Web.badRequest("reason is too long (max " + toString(maxSecretReasonLen) + " bytes)"))
  }
  val ownerUserId = match CloudAgents.SessionStore.sessionOwnerUserId(id) {
    case Ok(Some(u)) -> u
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
  val credentialExists = match CloudAgents.Repository.credentialNameExists(ownerUserId, req.name) {
    case Ok(b) -> b
    case Err(e) -> return Err(dbError(e))
  }
  if not credentialExists {
    return Err(Web.badRequest("no credential named '" + req.name + "' is configured for this session"))
  }
  match CloudAgents.Repository.createSecretRequest(id, req.name, req.reason) {
    case Ok(sr) -> return Ok(CreateSecretRequestResponse(id = sr.id, status = sr.status))
    case Err(e) -> return Err(dbError(e))
  }
}

/// GET /api/sessions/{id}/callbacks/secret/{rid} — container-originated
/// long-poll. On the FIRST poll to observe an 'approved' decision, decrypts
/// and returns the value; every later poll of the same request sees
/// status='approved' with an empty value (docs/phase6 §7.1 step 3 — the
/// value is handed back exactly once).
pub func getSecretRequestHandler(
  id: in String, rid: in String, authHeaderValue: in String
): Result[SecretDecision, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if rid.length == 0 {
    return Err(Web.badRequest("request id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  match CloudAgents.Repository.timeoutPendingSecretRequest(rid, callbackTimeoutMillis()) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  val sr = match CloudAgents.Repository.getSecretRequest(rid) {
    case Ok(Some(s)) -> s
    case Ok(None) -> return Err(Web.notFound("secret request not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if sr.sessionId != id {
    return Err(Web.notFound("secret request not found"))
  }
  if sr.status != "approved" {
    return Ok(SecretDecision(status = sr.status, value = ""))
  }
  val delivering = match CloudAgents.Repository.markSecretRequestDelivered(rid) {
    case Ok(b) -> b
    case Err(e) -> return Err(dbError(e))
  }
  if not delivering {
    // Already delivered on an earlier poll — same decision, never the value
    // twice.
    return Ok(SecretDecision(status = "approved", value = ""))
  }
  val ownerUserId = match CloudAgents.SessionStore.sessionOwnerUserId(id) {
    case Ok(Some(u)) -> u
    // The session vanished between approval and delivery — nothing sane to
    // decrypt against; fail closed to an empty value rather than erroring
    // out a poll that already consumed its one delivery attempt.
    case Ok(None) -> return Ok(SecretDecision(status = "approved", value = ""))
    case Err(e) -> return Err(dbError(e))
  }
  return match CloudAgents.Repository.decryptedCredentialValue(ownerUserId, sr.name) {
    case Ok(Some(v)) -> Ok(SecretDecision(status = "approved", value = v))
    // Credential deleted between create/approve and this delivery, or
    // undecryptable (rotated key) — fail closed to an empty value; the
    // delivery slot is already consumed either way.
    case Ok(None) -> Ok(SecretDecision(status = "approved", value = ""))
    case Err(_) -> Ok(SecretDecision(status = "approved", value = ""))
  }
}

/// POST /api/sessions/{id}/callbacks/secret/{rid}/answer — user-originated.
/// `decision` is "approve" or "deny" — no allow-always (docs/phase6 §7.1:
/// "every request prompts"). The secret_requests row IS the audit record
/// (session, name, reason, decision, decidedAt); the value is never written
/// to it or anywhere else outside the existing encrypted credential store.
pub func answerSecretRequestHandler(
  id: in String, rid: in String, req: in AnswerSecretRequestRequest
): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if rid.length == 0 {
    return Err(Web.badRequest("request id is required"))
  }
  if req.decision != "approve" and req.decision != "deny" {
    return Err(Web.badRequest("decision must be one of: approve, deny"))
  }
  requireOwnedSession(id)?
  val sr = match CloudAgents.Repository.getSecretRequest(rid) {
    case Ok(Some(s)) -> s
    case Ok(None) -> return Err(Web.notFound("secret request not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if sr.sessionId != id {
    return Err(Web.notFound("secret request not found"))
  }
  if req.decision == "approve" {
    // Defensive re-check: the create path already fails fast on a missing
    // credential, so this only fires on the race where it was deleted
    // between create and this answer. requireOwnedSession above already
    // established the current caller owns this session, so currentUserId()
    // IS the session owner here.
    val credentialExists = match CloudAgents.Repository.credentialNameExists(CloudAgents.Auth.currentUserId(), sr.name) {
      case Ok(b) -> b
      case Err(e) -> return Err(dbError(e))
    }
    if not credentialExists {
      return Err(Web.badRequest("the credential '" + sr.name + "' no longer exists; you can only deny this request"))
    }
  }
  val status = if req.decision == "deny" { "denied" } else { "approved" }
  val affected = match CloudAgents.Repository.answerSecretRequest(rid, status) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.conflict("secret request has already been decided"))
  }
  return Ok(())
}

// ─── Phase 6 §7: add_followup_task ────────────────────────────────────────────
//
// docs/phase6-mcp-callbacks.md §7.2. Reuses the same storage
// CloudAgents.Interactions.addTodoHandler uses (CloudAgents.Repository.addTodo)
// — unanchored (no messageId), since a container-originated tool call has no
// specific transcript message to anchor to.
val maxFollowupDescriptionLen = 32768

@generate(Json)
pub record CreateFollowupTaskRequest {
  pub description: String
}

@generate(Json)
pub record CreateFollowupTaskResponse {
  pub id: String
}

/// POST /api/sessions/{id}/callbacks/todo — container-originated
/// (add_followup_task MCP tool). No new SSE event: this codebase has no
/// existing todo SSE signal today — todos are refreshed by the frontend's
/// own GET /api/sessions/{id}/todos poll on page load / manual actions, the
/// same path a human-created todo already goes through. Reusing that
/// existing (REST, not SSE) refresh path is docs/phase6 §7.2's "reuse the
/// existing todo SSE/refresh signal" — there is no dedicated SSE frame type
/// to reuse, so nothing new is invented here.
pub func createFollowupTaskHandler(
  id: in String, authHeaderValue: in String, req: in CreateFollowupTaskRequest
): Result[CreateFollowupTaskResponse, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  if req.description.length == 0 {
    return Err(Web.badRequest("description is required"))
  }
  if not CloudAgents.Text.withinMaxByteLength(req.description, maxFollowupDescriptionLen) {
    return Err(Web.badRequest("description is too long (max " + toString(maxFollowupDescriptionLen) + " bytes)"))
  }
  match CloudAgents.Repository.addTodo(id, "", req.description) {
    case Ok(t) -> return Ok(CreateFollowupTaskResponse(id = t.id))
    case Err(e) -> return Err(dbError(e))
  }
}

// ─── Phase 6 §7: report_artifact ─────────────────────────────────────────────
//
// docs/phase6-mcp-callbacks.md §7.3. Metadata lives in CloudAgents.Repository's
// `artifacts` table; bytes live on disk under artifactsBaseDir()/<sessionId>/
// <storedName> — never in SQLite. The 8 MiB cap is enforced twice: a cheap
// pre-decode length check on the base64 text, then the authoritative check
// on the actual decoded byte count (non-standard base64 padding can't be
// used to sneak past the first check).
val maxArtifactFileNameLen = 255

val maxArtifactMimeTypeLen = 256

val maxArtifactDescriptionLen = 2048

/// 8 MiB, the decoded-bytes cap (docs/phase6 §7.3).
val maxArtifactBytes = 8388608

/// ceil(maxArtifactBytes / 3) * 4 — the largest base64 text that could
/// possibly decode to <= maxArtifactBytes, used as a cheap pre-decode reject
/// so an oversized upload never reaches the (comparatively expensive)
/// base64 decode at all.
val maxArtifactBase64Len = 11184812

@externTarget("System.Convert.FromBase64String")
func decodeBase64Bytes(s: in String): slice[Byte] = []

func tryDecodeArtifactBytes(base64: in String): Result[slice[Byte], String] {
  return try {
    Ok(value = decodeBase64Bytes(base64))
  } catch Bug as b {
    Err(error = "contentBase64 is not valid base64")
  }
}

/// `slice[Byte]` -> `List[Byte]`, for Std.File.writeBytes (which takes
/// `List[Byte]`, not `slice[Byte]`). `slice[Byte].toList()` compiles but
/// fails at runtime ("unsupported method 'toList'", confirmed by this
/// package's own tests) — the same "convenience method that compiles but
/// doesn't resolve at runtime" family docs/lyric/gotchas.md catalogues for
/// Result/Option methods, so build the list by hand instead, mirroring
/// CloudAgents.Repository.sliceContains' plain-Int indexing loop.
func sliceBytesToList(b: in slice[Byte]): List[Byte] {
  val acc: List[Byte] = newList()
  var i = 0
  while i < b.length {
    acc.add(b[i])
    i = i + 1
  }
  return acc
}

/// The final path segment of `name`, defending against `../` traversal in a
/// client-supplied fileName (docs/phase6 §7.3: "neutralized server-side —
/// basename only"). None for a result that is empty, '.', or '..' — a name
/// with no separator that would still resolve to a directory entry.
func basenameOf(name: in String): Option[String] {
  var lastSep = -1
  var i = 0
  while i < name.length {
    val c = name.substring(i, 1)
    if c == "/" or c == "\\" {
      lastSep = i
    }
    i = i + 1
  }
  val base = if lastSep < 0 { name } else { name.substring(lastSep + 1, name.length - lastSep - 1) }
  if base.length == 0 or base == "." or base == ".." {
    return None
  }
  return Some(value = base)
}

@generate(Json)
pub record UploadArtifactRequest {
  pub fileName: String
  pub mimeType: String
  pub description: String
  pub contentBase64: String
}

@generate(Json)
pub record UploadArtifactResponse {
  pub id: String
}

/// The API-facing shape of a stored artifact — deliberately omits
/// CloudAgents.Repository.Artifact's internal `storedName` field (an
/// on-disk implementation detail, not something a client needs or should
/// see).
@generate(Json)
pub record ArtifactSummary {
  pub id: String
  pub fileName: String
  pub mimeType: String
  pub description: String
  pub sizeBytes: String
  pub createdAt: String
}

@generate(Json)
pub record ArtifactListResponse {
  pub artifacts: slice[ArtifactSummary]
}

func artifactSummaryOf(a: in CloudAgents.Repository.Artifact): ArtifactSummary {
  return ArtifactSummary(
    id = a.id,
    fileName = a.fileName,
    mimeType = a.mimeType,
    description = a.description,
    sizeBytes = a.sizeBytes,
    createdAt = a.createdAt
  )
}

/// POST /api/sessions/{id}/callbacks/artifact — container-originated
/// (report_artifact MCP tool).
pub func uploadArtifactHandler(
  id: in String, authHeaderValue: in String, req: in UploadArtifactRequest
): Result[UploadArtifactResponse, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  if req.fileName.length == 0 {
    return Err(Web.badRequest("fileName is required"))
  }
  if not CloudAgents.Text.withinMaxByteLength(req.fileName, maxArtifactFileNameLen) {
    return Err(Web.badRequest("fileName is too long (max " + toString(maxArtifactFileNameLen) + " bytes)"))
  }
  val fileName = match basenameOf(req.fileName) {
    case Some(b) -> b
    case None -> return Err(Web.badRequest("fileName is invalid"))
  }
  if req.mimeType.length == 0 {
    return Err(Web.badRequest("mimeType is required"))
  }
  if not CloudAgents.Text.withinMaxLength(req.mimeType, maxArtifactMimeTypeLen) {
    return Err(Web.badRequest("mimeType is too long (max " + toString(maxArtifactMimeTypeLen) + " characters)"))
  }
  if not CloudAgents.Text.withinMaxByteLength(req.description, maxArtifactDescriptionLen) {
    return Err(Web.badRequest("description is too long (max " + toString(maxArtifactDescriptionLen) + " bytes)"))
  }
  if req.contentBase64.length == 0 {
    return Err(Web.badRequest("contentBase64 is required"))
  }
  if not CloudAgents.Text.withinMaxLength(req.contentBase64, maxArtifactBase64Len) {
    return Err(Web.badRequest("artifact exceeds the 8 MiB size limit"))
  }
  val bytes = match tryDecodeArtifactBytes(req.contentBase64) {
    case Ok(b) -> b
    case Err(msg) -> return Err(Web.badRequest(msg))
  }
  val sizeBytes = bytes.length.toInt()
  if sizeBytes > maxArtifactBytes {
    return Err(Web.badRequest("artifact exceeds the 8 MiB size limit"))
  }
  val artifactId = Std.Uuid.uuidToString(Std.Uuid.newUuid())
  val storedName = artifactId + "_" + fileName
  val sessionDir = CloudAgents.Repository.artifactsBaseDir() + "/" + id
  match Std.File.createDir(sessionDir) {
    case Ok(_) -> ()
    case Err(e) -> return Err(Web.internalError("failed to create artifact storage: " + IOError.message(e)))
  }
  match Std.File.writeBytes(sessionDir + "/" + storedName, sliceBytesToList(bytes)) {
    case Ok(_) -> ()
    case Err(e) -> return Err(Web.internalError("failed to store artifact: " + IOError.message(e)))
  }
  match CloudAgents.Repository.createArtifact(id, fileName, storedName, req.mimeType, req.description, toString(sizeBytes)) {
    case Ok(a) -> return Ok(UploadArtifactResponse(id = a.id))
    case Err(e) -> return Err(dbError(e))
  }
}

/// GET /api/sessions/{id}/artifacts — user-originated.
pub func listArtifactsHandler(id: in String): Result[ArtifactListResponse, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  requireOwnedSession(id)?
  match CloudAgents.Repository.listArtifacts(id) {
    case Ok(arts) -> {
      var acc: slice[ArtifactSummary] = []
      for a in arts {
        acc = acc.append(artifactSummaryOf(a))
      }
      return Ok(ArtifactListResponse(artifacts = acc))
    }
    case Err(e) -> return Err(dbError(e))
  }
}

/// GET /api/sessions/{id}/artifacts/{aid} — user-originated. Streams the
/// Escape a filename for an RFC 6266 `filename="..."` quoted-string: a `"`
/// or `\` in the (already basename-sanitized) name would otherwise break
/// out of the quotes, and a CR/LF would split the header — so backslash-
/// escape the two quoted-string metacharacters and drop control characters
/// (< 0x20) entirely (#547).
pub func contentDispositionQuoted(name: in String): String {
  var escaped = ""
  var i = 0
  while i < name.length {
    val c = name.substring(i, 1)
    if c == "\"" or c == "\\" {
      escaped = escaped + "\\" + c
    } else if c >= " " {
      escaped = escaped + c
    }
    i = i + 1
  }
  return escaped
}

/// stored bytes with Content-Disposition set from the sanitized fileName.
/// Returns the full Response directly (not a JSON body) since this is a
/// binary download.
pub func downloadArtifactHandler(id: in String, aid: in String): Result[Web.Response, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if aid.length == 0 {
    return Err(Web.badRequest("artifact id is required"))
  }
  requireOwnedSession(id)?
  val a = match CloudAgents.Repository.getArtifact(aid) {
    case Ok(Some(art)) -> art
    case Ok(None) -> return Err(Web.notFound("artifact not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if a.sessionId != id {
    return Err(Web.notFound("artifact not found"))
  }
  val path = CloudAgents.Repository.artifactsBaseDir() + "/" + id + "/" + a.storedName
  val bytes = match Std.File.readBytes(path) {
    case Ok(b) -> b
    case Err(e) -> return Err(Web.internalError("failed to read artifact: " + IOError.message(e)))
  }
  val resp = Web.bytesResponse(200, a.mimeType, bytes.toArray())
  return Ok(
    Web.withResponseHeader(
      resp,
      "Content-Disposition",
      "attachment; filename=\"" + contentDispositionQuoted(a.fileName) + "\""
    )
  )
}

// ─── Phase 7 §4: repo-scoped memory (remember / recall) ──────────────────────
//
// docs/phase7-autonomy.md §4. A key/value store scoped to
// (session-owner user_id, normalized repo_key) so a later session on the same
// repo can read back what an earlier one learned. Container-originated writes
// and reads authenticate with the callback token; the user-facing list
// endpoint uses normal owner auth. No SSE event — memory is not a live
// notification surface, and the `memory` row's updated_at is its own audit
// trail (docs/phase7 §4.2).
val maxMemoryKeyLen = 256

/// 65,536 characters (UTF-16 code units, as CloudAgents.Text.withinMaxLength
/// counts — not bytes, #596). A memory value is short accumulated context
/// (build quirks, test layout, deploy steps), not a file; report_artifact is
/// the path for bytes.
val maxMemoryValueLen = 65536

/// Per-repo memory entry cap (#575): bounds a repo's store at
/// 256 keys (≤ ~16 MiB at the value cap) so it can't grow without limit.
/// Overwrites of an existing key are always allowed; only new keys count.
val maxMemoryEntries = 256

@generate(Json)
pub record RememberRequest {
  pub key: String
  pub value: String
}

@generate(Json)
pub record RememberResponse {
  pub key: String
}

@generate(Json)
pub record MemoryEntry {
  pub key: String
  pub value: String
}

@generate(Json)
pub record MemoryListResponse {
  pub entries: slice[MemoryEntry]
}

@generate(Json)
pub record ForgetRequest {
  pub key: String
}

/// `status` is "deleted" (a row was removed) or "absent" (no such key) — a
/// String rather than a Bool since this schema's JSON records are all
/// TEXT-valued.
@generate(Json)
pub record ForgetResponse {
  pub key: String
  pub status: String
}

/// The (owner, repo) a session's memory is scoped to.
record SessionMemoryScope {
  userId: String
  repoKey: String
}

/// Resolve the owning user + normalized repo key for a session, or an
/// ApiError. A session whose repo_url yields no usable key (empty / host-only)
/// is rejected rather than writing an unscoped row.
func resolveMemoryScope(id: in String): Result[SessionMemoryScope, Web.ApiError] {
  val ownerRepo = match CloudAgents.Repository.sessionOwnerAndRepo(id) {
    case Ok(Some(sr)) -> sr
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
  val repoKey = CloudAgents.RepoKey.repoKeyOf(ownerRepo.repoUrl)
  if repoKey.length == 0 {
    return Err(Web.badRequest("this session has no repository to scope memory to"))
  }
  return Ok(SessionMemoryScope(userId = ownerRepo.userId, repoKey = repoKey))
}

func memoryListFor(id: in String): Result[MemoryListResponse, Web.ApiError] {
  val memScope = resolveMemoryScope(id)?
  match CloudAgents.Repository.listMemory(memScope.userId, memScope.repoKey) {
    case Ok(rows) -> {
      var acc: slice[MemoryEntry] = []
      for m in rows {
        acc = acc.append(MemoryEntry(key = m.memKey, value = m.value))
      }
      return Ok(MemoryListResponse(entries = acc))
    }
    case Err(e) -> return Err(dbError(e))
  }
}

/// POST /api/sessions/{id}/callbacks/memory — container-originated
/// (remember MCP tool). Upserts one entry for the session's repo.
pub func rememberHandler(
  id: in String, authHeaderValue: in String, req: in RememberRequest
): Result[RememberResponse, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  if req.key.length == 0 {
    return Err(Web.badRequest("key is required"))
  }
  if not CloudAgents.Text.withinMaxLength(req.key, maxMemoryKeyLen) {
    return Err(Web.badRequest("key is too long (max " + toString(maxMemoryKeyLen) + " characters)"))
  }
  if req.value.length == 0 {
    return Err(Web.badRequest("value is required"))
  }
  if not CloudAgents.Text.withinMaxLength(req.value, maxMemoryValueLen) {
    return Err(Web.badRequest("value is too long (max " + toString(maxMemoryValueLen) + " characters)"))
  }
  val memScope = resolveMemoryScope(id)?
  // Per-repo entry cap (#575), enforced atomically (#586): overwriting an
  // existing key is always allowed (it doesn't grow the store); a NEW key is
  // written only while the repo is under the cap. A `false` result means the
  // cap blocked a new key.
  match CloudAgents.Repository.upsertMemoryCapped(memScope.userId, memScope.repoKey, req.key, req.value, maxMemoryEntries) {
    case Ok(true) -> return Ok(RememberResponse(key = req.key))
    case Ok(false) -> return Err(
      Web.badRequest(
        "this repository is at the memory limit (max " + toString(maxMemoryEntries) +
          " entries); update or remove an existing key instead"
      )
    )
    case Err(e) -> return Err(dbError(e))
  }
}

/// GET /api/sessions/{id}/callbacks/memory — container-originated (recall MCP
/// tool). Returns every entry for the session's repo; the shim filters to a
/// single key client-side when `recall(key)` is called with one. Fetching the
/// whole set even for a keyed recall (#590) is deliberate: the store is
/// hard-capped (maxMemoryEntries, 256 entries) so the response is bounded and
/// small, and one list endpoint keeps the host simple and avoids URL-encoding
/// a free-form key into a query string. A dedicated single-key endpoint is a
/// cheap future optimization if a real store ever grows large.
pub func recallHandler(id: in String, authHeaderValue: in String): Result[MemoryListResponse, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  return memoryListFor(id)
}

/// GET /api/sessions/{id}/memory — user-originated. Lets the UI inspect a
/// session's repo memory.
pub func listMemoryHandler(id: in String): Result[MemoryListResponse, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  requireOwnedSession(id)?
  return memoryListFor(id)
}

/// POST /api/sessions/{id}/callbacks/memory/forget — container-originated
/// (forget MCP tool, #592). Deletes one entry for the session's repo so a slot
/// can be freed under the cap. Idempotent: forgetting an absent key is a
/// success with status "absent", not an error.
pub func forgetHandler(
  id: in String, authHeaderValue: in String, req: in ForgetRequest
): Result[ForgetResponse, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  authorizeCallbackToken(id, authHeaderValue)?
  if req.key.length == 0 {
    return Err(Web.badRequest("key is required"))
  }
  // Validate the key length the same way rememberHandler does, for
  // consistency (#594) — a valid key can never exceed this, so an over-length
  // key is a malformed request, not a lookup that should quietly miss.
  if not CloudAgents.Text.withinMaxLength(req.key, maxMemoryKeyLen) {
    return Err(Web.badRequest("key is too long (max " + toString(maxMemoryKeyLen) + " characters)"))
  }
  val memScope = resolveMemoryScope(id)?
  match CloudAgents.Repository.deleteMemory(memScope.userId, memScope.repoKey, req.key) {
    case Ok(true) -> return Ok(ForgetResponse(key = req.key, status = "deleted"))
    case Ok(false) -> return Ok(ForgetResponse(key = req.key, status = "absent"))
    case Err(e) -> return Err(dbError(e))
  }
}
