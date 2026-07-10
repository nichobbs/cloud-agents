//! HTTP handlers for the prompt library: save, list, edit, delete and mark
//! prompts as used. Storage lives in CloudAgents.Repository; ownership is
//! scoped by CloudAgents.Auth.currentUserId() (single operator identity in
//! the static-token phase, per-user once GitHub OAuth lands).
package CloudAgents.Prompts

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Sqlite

val maxPromptNameLen = 200
val maxPromptBodyLen = 131072

@generate(Json)
pub record SavePromptRequest {
  pub name: String
  pub body: String
}

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

func validateSavePrompt(req: in SavePromptRequest): Option[Web.ApiError] {
  // Trim before the empty check so a whitespace-only name (which a direct API
  // call can send) is rejected, not stored as a blank-looking prompt.
  if req.name.trim().length == 0 {
    return Some(value = Web.badRequest("name is required"))
  }
  if req.name.length > maxPromptNameLen {
    return Some(value = Web.badRequest("name is too long (max 200 characters)"))
  }
  if req.body.length == 0 {
    return Some(value = Web.badRequest("body is required"))
  }
  if req.body.length > maxPromptBodyLen {
    return Some(value = Web.badRequest("body is too long (max 131072 characters)"))
  }
  return None
}

/// List the caller's saved prompts, alphabetical by name.
@get("/api/prompts")
pub func listPromptsHandler(): Result[PromptList, Web.ApiError] {
  match listPrompts(CloudAgents.Auth.currentUserId()) {
    case Ok(ps) -> return Ok(PromptList(prompts = ps))
    case Err(e) -> return Err(dbError(e))
  }
}

/// Save a new prompt to the library.
@post("/api/prompts")
pub func addPromptHandler(@body req: in SavePromptRequest): Result[Prompt, Web.ApiError] {
  match validateSavePrompt(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  // Store the trimmed name — validation trims for the emptiness check, so the
  // stored value must match or a " foo " name would round-trip with the
  // surrounding whitespace the check quietly ignored. Body is stored as-is
  // (leading/trailing whitespace in a prompt body can be meaningful).
  match addPrompt(CloudAgents.Auth.currentUserId(), req.name.trim(), req.body) {
    case Ok(p) -> return Ok(p)
    case Err(e) -> return Err(dbError(e))
  }
}

/// Update an existing prompt's name and body.
@post("/api/prompts/{pid}")
pub func updatePromptHandler(pid: in String, @body req: in SavePromptRequest): Result[Prompt, Web.ApiError] {
  if pid.length == 0 {
    return Err(Web.badRequest("prompt id is required"))
  }
  match validateSavePrompt(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  val userId = CloudAgents.Auth.currentUserId()
  // Store the trimmed name for the same reason as addPromptHandler above.
  val affected = match updatePrompt(pid, userId, req.name.trim(), req.body) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("prompt not found"))
  }
  // Return the stored record so the client gets the fresh updated_at.
  match getPrompt(pid, userId) {
    case Ok(Some(p)) -> return Ok(p)
    case Ok(None) -> return Err(Web.notFound("prompt not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

/// Record one use of a prompt (bumps use_count; the client fetches the body
/// from its own list, so this is fire-and-forget bookkeeping).
@post("/api/prompts/{pid}/use")
pub func usePromptHandler(pid: in String): Result[Unit, Web.ApiError] {
  if pid.length == 0 {
    return Err(Web.badRequest("prompt id is required"))
  }
  val affected = match markPromptUsed(pid, CloudAgents.Auth.currentUserId()) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("prompt not found"))
  }
  return Ok(())
}

/// Delete a prompt from the library.
@delete("/api/prompts/{pid}")
pub func deletePromptHandler(pid: in String): Result[Unit, Web.ApiError] {
  if pid.length == 0 {
    return Err(Web.badRequest("prompt id is required"))
  }
  val affected = match deletePrompt(pid, CloudAgents.Auth.currentUserId()) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("prompt not found"))
  }
  return Ok(())
}
