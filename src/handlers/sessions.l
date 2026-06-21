package CloudAgents.Handlers

import Std.Core
import Web
import CloudAgents.SessionStore
import CloudAgents.Docker
import CloudAgents.Streaming
import CloudAgents.Repository

import Std.Uuid

pub func generateSessionId(): String {
  val u = Std.Uuid.newUuid()
  return Std.Uuid.uuidToString(u)
}

@generate(Json)
pub record CreateSessionRequest {
  pub repoUrl: String
  pub branch: String
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
pub func createSession(
  @body req: in CreateSessionRequest
): Result[CreateSessionResponse, Web.ApiError] {
  if req.repoUrl.length == 0 {
    return Err(Web.badRequest("repoUrl is required"))
  }
  if req.branch.length == 0 {
    return Err(Web.badRequest("branch is required"))
  }

  val sessionId = generateSessionId()
  val session = makeAgentSession(
    sessionId = sessionId,
    repoUrl = req.repoUrl,
    branch = req.branch,
    containerId = ""
  )

  addSession(session)

  return Ok(CreateSessionResponse(sessionId = sessionId))
}

/// Accept user prompt, run container, and return output synchronously.
@post("/api/sessions/{id}/messages")
pub func sendMessage(
  id: in String,
  @body req: in SendMessageRequest
): Result[String, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if req.text.length == 0 {
    return Err(Web.badRequest("text is required"))
  }

  val maybeSession = getSession(id)
  if maybeSession.isNone() {
    return Err(Web.notFound("Session not found"))
  }
  val session = maybeSession.unwrapOption()

  // Persist the user's prompt as an addressable transcript message. Best-effort:
  // a storage hiccup must not stop the agent from running.
  match CloudAgents.Repository.addMessage(id, "user", req.text) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val runResult = CloudAgents.Docker.runSessionMessage(
    repoUrl = session.repoUrl,
    branch = session.branch,
    prompt = req.text,
    sessionId = id
  )

  // Frame the captured container output as a Server-Sent Events stream:
  // one `data: {"chunk":"..."}` frame per line, then a `done` event. ANSI
  // colour codes are preserved in the payload and rendered on the frontend
  // with ansi_up (see docs/phase1-core-loop.md).
  //
  // The agent reply is persisted too; on success the `done` frame carries the
  // stored message id so the client can attach comments/todos to this response.
  match runResult {
    case Ok(logs) -> {
      match CloudAgents.Repository.addMessage(id, "agent", logs) {
        case Ok(m)  -> return Ok(value = CloudAgents.Streaming.formatLogsAsSseWithId(logs, m.id))
        case Err(_) -> return Ok(value = CloudAgents.Streaming.formatLogsAsSse(logs))
      }
    }
    case Err(err) -> return Err(Web.internalError("Failed to execute message: " + err))
  }
}

/// Stop and tear down container and associated session synchronously.
@delete("/api/sessions/{id}")
pub func deleteSession(
  id: in String
): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }

  val maybeSession = removeSession(id)
  if maybeSession.isNone() {
    return Err(Web.notFound("Session not found"))
  }
  val session = maybeSession.unwrapOption()

  val containerId = session.containerId
  if containerId.length == 0 {
    return Ok(())
  }

  val terminateResult = CloudAgents.Docker.terminateSessionContainer(containerId)
  match terminateResult {
    case Ok(_) -> return Ok(())
    case Err(err) -> return Err(Web.internalError("Failed to terminate container: " + err))
  }
}

/// Retrieve status of the service.
@get("/api/health")
pub func checkHealth(): Result[String, Web.ApiError] {
  return Ok("Healthy")
}
