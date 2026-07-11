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
val maxRenderVars = 100
val maxRenderKeyLen = 128
val maxRenderValueLen = 8192

@generate(Json)
pub record SavePromptRequest {
  pub name: String
  pub body: String
  pub tags: slice[String]
}

val maxTagLen = 64

/// A tag is a short label: letters, digits, dash or underscore, non-empty. Dupes
/// are collapsed by the UNIQUE(prompt_id, tag) constraint at the DB layer.
pub func isValidTag(tag: in String): Bool {
  if tag.length == 0 or tag.length > maxTagLen {
    return false
  }
  var i = 0
  while i < tag.length {
    val c = tag.substring(i, 1)
    val isUpper = c >= "A" and c <= "Z"
    val isLower = c >= "a" and c <= "z"
    val isDigit = c >= "0" and c <= "9"
    if not (isUpper or isLower or isDigit or c == "-" or c == "_") {
      return false
    }
    i = i + 1
  }
  return true
}

/// Variable bindings for rendering a prompt template. Parallel slices (rather
/// than a nested key/value record) keep the JSON shape flat and within the
/// toolchain's reliable @generate(Json) surface.
@generate(Json)
pub record RenderPromptRequest {
  pub keys: slice[String]
  pub values: slice[String]
}

@generate(Json)
pub record RenderedPrompt {
  pub rendered: String
}

/// The index of `key` in `keys` (over the first `n` entries), or -1.
func indexOfKey(keys: in slice[String], key: in String, n: in Int): Int {
  var k = 0
  while k < n {
    if keys[k] == key {
      return k
    }
    k = k + 1
  }
  return -1
}

/// Render a prompt body by substituting `{{key}}` placeholders with the paired
/// value. Unbound placeholders are left intact. Pub for direct unit testing.
///
/// Single left-to-right pass: once a `{{key}}` is replaced, scanning resumes
/// AFTER the substituted value, so a value that itself contains `{{...}}` text
/// is never re-expanded (#265) — one variable's value can't inject another
/// variable reference. The old approach ran replaceAll per key over the whole
/// growing string, which did re-expand.
pub func renderTemplate(body: in String, keys: in slice[String], values: in slice[String]): String {
  val n = if keys.length < values.length { keys.length.toInt() } else { values.length.toInt() }
  val blen = body.length.toInt()
  var acc = ""
  var i = 0
  while i < blen {
    if i + 2 <= blen and body.substring(i, 2) == "{{" {
      // Find the closing "}}".
      var j = i + 2
      var closeAt = -1
      while j + 2 <= blen and closeAt < 0 {
        if body.substring(j, 2) == "}}" {
          closeAt = j
        } else {
          j = j + 1
        }
      }
      if closeAt < 0 {
        // No closing "}}" — emit the "{{" literally and continue past it.
        acc = acc + "{{"
        i = i + 2
      } else {
        // Trim the key so `{{ name }}` (natural spacing) matches the key
        // `name` — callers send trimmed keys, so the extracted token must be
        // trimmed too or the value would be silently dropped (#274).
        val key = body.substring(i + 2, closeAt - (i + 2)).trim()
        val vidx = indexOfKey(keys, key, n)
        if vidx < 0 {
          // Unbound — leave the "{{" literal; the rest re-scans as plain text.
          acc = acc + "{{"
          i = i + 2
        } else {
          acc = acc + values[vidx]
          i = closeAt + 2 // resume AFTER "}}", not inside the substituted value
        }
      }
    } else {
      acc = acc + body.substring(i, 1)
      i = i + 1
    }
  }
  return acc
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
  var i = 0
  while i < req.tags.length {
    if not isValidTag(req.tags[i]) {
      return Some(value = Web.badRequest("tags must be short labels of letters, digits, dash or underscore"))
    }
    i = i + 1
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

/// List the caller's prompts most-used first — the "popular" ordering the UI
/// uses to surface frequently-run prompts.
@get("/api/prompts/popular")
pub func listPopularPromptsHandler(): Result[PromptList, Web.ApiError] {
  match listPromptsByUsage(CloudAgents.Auth.currentUserId()) {
    case Ok(ps) -> return Ok(PromptList(prompts = ps))
    case Err(e) -> return Err(dbError(e))
  }
}

/// List the caller's prompts carrying a given tag, alphabetical by name.
@get("/api/prompts/tag/{tag}")
pub func listPromptsByTagHandler(tag: in String): Result[PromptList, Web.ApiError] {
  if tag.length == 0 {
    return Err(Web.badRequest("tag is required"))
  }
  match listPromptsByTag(CloudAgents.Auth.currentUserId(), tag) {
    case Ok(ps) -> return Ok(PromptList(prompts = ps))
    case Err(e) -> return Err(dbError(e))
  }
}

/// Render a prompt template with variable bindings and return the result.
/// Rendering counts as a use (bumps use_count). 404 for an unknown prompt.
@post("/api/prompts/{pid}/render")
pub func renderPromptHandler(pid: in String, @body req: in RenderPromptRequest): Result[RenderedPrompt, Web.ApiError] {
  if pid.length == 0 {
    return Err(Web.badRequest("prompt id is required"))
  }
  // Bound the substitution work (#249): too many keys, or an oversized value,
  // would make each replaceAll pass over the body arbitrarily expensive.
  if req.keys.length > maxRenderVars or req.values.length > maxRenderVars {
    return Err(Web.badRequest("too many template variables (max 100)"))
  }
  var ki = 0
  while ki < req.keys.length {
    if req.keys[ki].length > maxRenderKeyLen {
      return Err(Web.badRequest("a template key is too long (max 128 characters)"))
    }
    ki = ki + 1
  }
  var vi = 0
  while vi < req.values.length {
    if req.values[vi].length > maxRenderValueLen {
      return Err(Web.badRequest("a template value is too long (max 8192 characters)"))
    }
    vi = vi + 1
  }
  val userId = CloudAgents.Auth.currentUserId()
  val prompt = match getPrompt(pid, userId) {
    case Ok(Some(p)) -> p
    case Ok(None) -> return Err(Web.notFound("prompt not found"))
    case Err(e) -> return Err(dbError(e))
  }
  val rendered = renderTemplate(prompt.body, req.keys, req.values)
  // Rendering a prompt is a use; best-effort bookkeeping.
  val _ = markPromptUsed(pid, userId)
  return Ok(RenderedPrompt(rendered = rendered))
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
  val userId = CloudAgents.Auth.currentUserId()
  // Prompt row + its tags commit together (#244); the returned record carries
  // its tags, so no re-read is needed.
  match addPromptWithTags(userId, req.name.trim(), req.body, req.tags) {
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
  // Name/body + the replaced tag set commit together (#244).
  val affected = match updatePromptWithTags(pid, userId, req.name.trim(), req.body, req.tags) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("prompt not found"))
  }
  // Return the stored record so the client gets the fresh updated_at + tags.
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
