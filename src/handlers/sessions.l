package CloudAgents.Handlers

import Std.Core
import Web
import CloudAgents.Docker
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Streaming
import Std.Uuid

pub func generateSessionId(): String {
  val u = Std.Uuid.newUuid()
  return Std.Uuid.uuidToString(u)
}

val maxPromptLen = 131072
val maxRepoUrlLen = 2048
val maxBranchLen = 255
val maxModelLen = 128

func isHttpsUrl(url: in String): Bool {
  val prefix = "https://"
  if url.length < prefix.length {
    return false
  }
  return url.substring(0, prefix.length) == prefix
}

@externTarget("System.String.CompareOrdinal")
func strCompareOrdinal(a: in String, b: in String): Int = ()

/// True when any character is a raw control character (below U+0020). These
/// have no place in a URL, ref name, or model id, and would otherwise flow
/// into the session store and the container environment.
func containsControlChar(s: in String): Bool {
  var i = 0
  while i < s.length {
    if strCompareOrdinal(s.substring(i, 1), " ") < 0 {
      return true
    }
    i = i + 1
  }
  return false
}

func isSafeRepoUrl(url: in String): Bool {
  if url.length > maxRepoUrlLen {
    return false
  }
  if url.contains(" ") or url.contains("\"") or url.contains("\\") {
    return false
  }
  return not containsControlChar(url)
}

/// Git ref-name safety: rejects names git itself refuses, plus anything that
/// could be misread as a command-line option (leading '-').
func isSafeBranchName(branch: in String): Bool {
  if branch.length == 0 or branch.length > maxBranchLen {
    return false
  }
  if branch == "@" {
    return false // reserved ref name
  }
  if branch.startsWith("-") or branch.startsWith("/") or branch.endsWith("/") or branch.endsWith(".") or
    branch.endsWith(".lock") {
    return false
  }
  // No component may start with '.' (covers a leading '.' and 'x/.y').
  if branch.startsWith(".") or branch.contains("/.") {
    return false
  }
  if branch.contains(" ") or branch.contains("\"") or branch.contains("\\") or branch.contains("~") or
    branch.contains("^") or
    branch.contains(":") or
    branch.contains("?") or
    branch.contains("*") or
    branch.contains("[") or
    branch.contains("..") or
    branch.contains("@{") {
    return false
  }
  return not containsControlChar(branch)
}

func isSafeModelName(model: in String): Bool {
  if model.length > maxModelLen {
    return false
  }
  if model.contains(" ") or model.contains("\"") or model.contains("\\") or model.contains("{") or
    model.contains("}") {
    return false
  }
  return not containsControlChar(model)
}

func isKnownHarness(harness: in String): Bool {
  return harness == "claude" or harness == "codex" or harness == "opencode"
}

@generate(Json)
pub record CreateSessionRequest {
  pub repoUrl: String
  pub branch: String
  pub harness: String
  pub model: String
}

@generate(Json)
pub record UpdateSessionRequest {
  pub model: String
}

@generate(Json)
pub record CreateSessionResponse {
  pub sessionId: String
}

@generate(Json)
pub record SendMessageRequest {
  pub text: String
}


/// Create a persistent session workspace.
@post("/api/sessions")
pub func createSession(@body req: in CreateSessionRequest): Result[CreateSessionResponse, Web.ApiError] {
  if req.repoUrl.length == 0 {
    return Err(Web.badRequest("repoUrl is required"))
  }
  if not isHttpsUrl(req.repoUrl) {
    return Err(Web.badRequest("repoUrl must use the https:// scheme"))
  }
  if not isSafeRepoUrl(req.repoUrl) {
    return Err(Web.badRequest("repoUrl contains invalid characters or is too long"))
  }
  if req.branch.length == 0 {
    return Err(Web.badRequest("branch is required"))
  }
  if not isSafeBranchName(req.branch) {
    return Err(Web.badRequest("branch is not a valid git branch name"))
  }
  if req.harness.length > 0 and not isKnownHarness(req.harness) {
    return Err(Web.badRequest("harness must be one of: claude, codex, opencode"))
  }
  if not isSafeModelName(req.model) {
    return Err(Web.badRequest("model contains invalid characters or is too long"))
  }

  val sessionId = generateSessionId()
  val harness = if req.harness.length == 0 { "claude" } else { req.harness }
  val model = if req.model.length == 0 { CloudAgents.SessionStore.defaultModelForHarness(harness) } else { req.model }
  val session = makeAgentSession(
    sessionId = sessionId,
    repoUrl = req.repoUrl,
    branch = req.branch,
    containerId = "",
    harness = harness,
    model = model,
    nativeSessionId = sessionId
  )  // pre-assigned so every run gets a stable resume ID

  match addSession(session) {
    case Ok(_) -> return Ok(CreateSessionResponse(sessionId = sessionId))
    case Err(e) -> return Err(Web.internalError("failed to persist session: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
}

/// Public projection of a session for the list endpoint: only what a client
/// needs to rebuild its list. Internal fields (containerId, nativeSessionId)
/// are deliberately excluded — this is the first bulk-read surface for
/// session data and should not enumerate infrastructure handles.
func sessionSummaryJson(s: in AgentSession): String {
  return "{\"sessionId\":\"" + CloudAgents.SessionStore.jsonEscapeField(s.sessionId) + "\",\"repoUrl\":\"" +
    CloudAgents.SessionStore.jsonEscapeField(s.repoUrl) +
    "\",\"branch\":\"" +
    CloudAgents.SessionStore.jsonEscapeField(s.branch) +
    "\",\"harness\":\"" +
    CloudAgents.SessionStore.jsonEscapeField(s.harness) +
    "\",\"model\":\"" +
    CloudAgents.SessionStore.jsonEscapeField(s.model) +
    "\"}"
}

/// List every stored session as `{"sessions":[...]}`. Lets a client rebuild
/// its session list after local state is lost (new browser, cleared storage)
/// instead of stranding server-side sessions forever.
@get("/api/sessions")
pub func listSessions(): Result[String, Web.ApiError] {
  val arr = match CloudAgents.SessionStore.getSessions() {
    case Ok(a) -> a
    case Err(e) -> return Err(Web.internalError("failed to list sessions: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  var json = "{\"sessions\":["
  var i = 0
  val len = CloudAgents.SessionStore.getSessionArrayLength(arr)
  while i < len {
    if i > 0 {
      json = json + ","
    }
    json = json + sessionSummaryJson(CloudAgents.SessionStore.getSessionArrayValue(arr, i))
    i = i + 1
  }
  return Ok(value = json + "]}")
}

/// Accept user prompt, run container, and return output synchronously.
@post("/api/sessions/{id}/messages")
pub func sendMessage(id: in String, @body req: in SendMessageRequest): Result[String, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if req.text.length == 0 {
    return Err(Web.badRequest("text is required"))
  }
  if req.text.length > maxPromptLen {
    return Err(Web.badRequest("text is too long (max 131072 characters)"))
  }

  val maybeSession = match getSession(id) {
    case Ok(m) -> m
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match maybeSession {
    case None -> return Err(Web.notFound("Session not found"))
    case Some(session) -> {
      // One run per session at a time: atomically claim the RUNNING status
      // (a single guarded UPDATE, so two concurrent sends cannot both win).
      // Without this, concurrent runs race the same workspace volume.
      val began = match CloudAgents.SessionStore.tryBeginRun(id) {
        case Ok(b) -> b
        case Err(e) -> return Err(Web.internalError("failed to claim session for run: " + CloudAgents.Sqlite.dbErrorMessage(e)))
      }
      if not began {
        return Err(Web.conflict("a run is already in progress for this session"))
      }

      // Release the claim on every exit — normal return, error, or a Bug/panic
      // mid-run — so a failure can never strand the session in RUNNING (which
      // would 409 every future send until a restart's recovery sweep). `defer`
      // runs on all scope exits.
      defer {
        val _ = CloudAgents.SessionStore.endRun(id)
      }

      // Persist the user's prompt as an addressable transcript message. Best-effort:
      // a storage hiccup must not stop the agent from running.
      match CloudAgents.Repository.addMessage(id, "user", req.text) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }

      val runResult = CloudAgents.Docker.runSessionMessage(
        repoUrl = session.repoUrl,
        branch = session.branch,
        prompt = req.text,
        sessionId = id,
        harness = session.harness,
        model = session.model,
        nativeSessionId = session.nativeSessionId
      )

      // Frame the captured container output as a Server-Sent Events stream:
      // one `data: {"chunk":"..."}` frame per line, then a `done` event. ANSI
      // colour codes are preserved in the payload and rendered on the frontend
      // with ansi_up (see docs/phase1-core-loop.md).
      //
      // The agent reply is persisted too; on success the `done` frame carries the
      // stored message id so the client can attach comments/todos to this response.
      match runResult {
        case Ok(logs) -> match CloudAgents.Repository.addMessage(id, "agent", logs) { case Ok(m) -> return Ok(value = CloudAgents.Streaming.formatLogsAsSseWithId(logs, m.id)); case Err(_) -> return Ok(value = CloudAgents.Streaming.formatLogsAsSse(logs)) }
        case Err(err) -> return Err(Web.internalError("Failed to execute message: " + err))
      }
    }
  }
}

/// Live output for an in-progress run. The frontend polls this while a send is
/// outstanding to show incremental container output, since the send itself
/// blocks until the run finishes and Lyric.Web cannot stream a response.
///
/// A run is in progress exactly when the session's status is `RUNNING` (set
/// synchronously at send time, before the container exists, and cleared when
/// the run ends). While running, we return the container's logs-so-far once it
/// exists; otherwise `running` is false and the client stops polling and
/// reloads the persisted transcript. Status — not container id — drives this,
/// so the first poll (which races container creation) doesn't see an empty id
/// and wrongly report "not running"; see the inline comment below.
/// Returns `{"running":"true|false","output":"..."}` as a hand-built JSON
/// string, mirroring listSessions — no @generate(Json) response record on this
/// path (a fresh record here tripped the JSON source generator at runtime with
/// "The signature is incorrect").
@get("/api/sessions/{id}/output")
pub func getRunOutput(id: in String): Result[String, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  val maybeStatus = match CloudAgents.SessionStore.sessionStatus(id) {
    case Ok(m) -> m
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match maybeStatus {
    case None -> return Err(Web.notFound("Session not found"))
    case Some(status) -> {
      // A run is in progress while status is RUNNING (set synchronously at
      // send time, before the container is created). Basing this on the
      // container id would make the first poll — which races container
      // creation — see an empty id and report "not running", causing the
      // client to stop polling for the whole run.
      if status != "RUNNING" {
        return Ok(value = "{\"running\":\"false\",\"output\":\"\"}")
      }
      // Logs only once the container exists; until then the run is up but has
      // produced nothing to fetch yet.
      val containerId = match getSession(id) {
        case Ok(Some(s)) -> s.containerId
        case Ok(None) -> ""
        case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
      }
      val logs = if containerId.length > 0 { CloudAgents.Docker.partialContainerLogs(containerId) } else { "" }
      return Ok(value = "{\"running\":\"true\",\"output\":\"" + CloudAgents.Streaming.jsonEscape(logs) + "\"}")
    }
  }
}

/// Stop and tear down container and associated session synchronously.
@delete("/api/sessions/{id}")
pub func deleteSession(id: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }

  // Terminate the container BEFORE dropping the session record: if teardown
  // fails, the session (and its containerId) survives so the delete can be
  // retried, instead of orphaning a running container with no record of it.
  val maybeSession = match getSession(id) {
    case Ok(m) -> m
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match maybeSession {
    case None -> return Err(Web.notFound("Session not found"))
    case Some(session) -> {
      val containerId = session.containerId
      if containerId.length > 0 {
        val terminateResult = CloudAgents.Docker.terminateSessionContainer(containerId)
        match terminateResult {
          case Ok(_) -> ()
          case Err(err) -> return Err(Web.internalError("Failed to terminate container (session retained, retry delete): " + err))
        }
      }
      match removeSession(id) {
        case Ok(_) -> return Ok(())
        case Err(e) -> return Err(Web.internalError("failed to remove session: " + CloudAgents.Sqlite.dbErrorMessage(e)))
      }
    }
  }
}

/// Switch the active model for a session (stays on the same harness).
/// The next message will use this model; existing transcript is unaffected.
@post("/api/sessions/{id}/model")
pub func updateSessionModel(id: in String, @body req: in UpdateSessionRequest): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if req.model.length == 0 {
    return Err(Web.badRequest("model is required"))
  }
  if not isSafeModelName(req.model) {
    return Err(Web.badRequest("model contains invalid characters or is too long"))
  }
  val maybeSession = match getSession(id) {
    case Ok(m) -> m
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match maybeSession {
    case None -> return Err(Web.notFound("Session not found"))
    case Some(_) -> match CloudAgents.SessionStore.updateSessionModel(id, req.model) {
      case Ok(_) -> return Ok(())
      case Err(e) -> return Err(Web.internalError("failed to update model: " + CloudAgents.Sqlite.dbErrorMessage(e)))
    }
  }
}

/// Retrieve service health, including a live SQLite probe.
@get("/api/health")
pub func checkHealth(): Result[String, Web.ApiError] {
  match CloudAgents.Repository.ping() {
    case Ok(_) -> return Ok("Healthy")
    case Err(e) -> return Err(Web.internalError("database unavailable: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
}
