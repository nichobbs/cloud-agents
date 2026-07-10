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
  if branch.startsWith("-") or branch.startsWith("/") or branch.endsWith("/") or branch.endsWith(".") or
    branch.endsWith(".lock") {
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

  addSession(session)

  return Ok(CreateSessionResponse(sessionId = sessionId))
}

/// List every stored session as `{"sessions":[...]}`. Lets a client rebuild
/// its session list after local state is lost (new browser, cleared storage)
/// instead of stranding server-side sessions forever. Serialised with the
/// same escaping-aware builder the store itself uses.
@get("/api/sessions")
pub func listSessions(): Result[String, Web.ApiError] {
  val arr = CloudAgents.SessionStore.getSessions()
  var json = "{\"sessions\":["
  var i = 0
  val len = CloudAgents.SessionStore.getSessionArrayLength(arr)
  while i < len {
    if i > 0 {
      json = json + ","
    }
    json = json + CloudAgents.SessionStore.agentSessionToJson(CloudAgents.SessionStore.getSessionArrayValue(arr, i))
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

  val maybeSession = getSession(id)
  match maybeSession {
    case None -> return Err(Web.notFound("Session not found"))
    case Some(session) -> {
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

/// Stop and tear down container and associated session synchronously.
@delete("/api/sessions/{id}")
pub func deleteSession(id: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }

  // Terminate the container BEFORE dropping the session record: if teardown
  // fails, the session (and its containerId) survives so the delete can be
  // retried, instead of orphaning a running container with no record of it.
  val maybeSession = getSession(id)
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
      val _ = removeSession(id)
      return Ok(())
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
  val maybeSession = getSession(id)
  match maybeSession {
    case None -> return Err(Web.notFound("Session not found"))
    case Some(_) -> {
      CloudAgents.SessionStore.updateSessionModel(id, req.model)
      return Ok(())
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
