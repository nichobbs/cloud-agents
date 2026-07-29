//! HTTP handlers for the per-user library: skills, subagents, and MCP
//! servers a profile can grant to a session (src/handlers/profiles.l wires
//! the grant lists in). Storage and grant resolution live in
//! CloudAgents.Repository; ownership is scoped by
//! CloudAgents.Auth.currentUserId(), exactly like profiles/credentials/
//! prompts. Names become directory/file names inside a runner container at
//! injection time (CloudAgents.Docker / docker/inject-library.sh), so
//! isValidLibraryName restricts the charset the same way credential grant
//! names are restricted in CloudAgents.Profiles.
package CloudAgents.Library

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Sqlite

val maxNameLen = 128

val maxDescriptionLen = 2000

val maxBodyLen = 200000

val maxModelLen = 200

val maxMcpFieldLen = 4096

val maxMcpArgCount = 64

val maxMcpEnvCount = 64

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

/// A library item name must be a filesystem-safe slug: a leading letter,
/// digit, or underscore, then letters/digits/hyphens/underscores, ≤128
/// chars. Rendered directly into a directory or file name inside the runner
/// container (docker/inject-library.sh), so this is the boundary that keeps
/// a malicious/malformed name from escaping its own injected path.
pub func isValidLibraryName(name: in String): Bool {
  if name.length == 0 or name.length > maxNameLen {
    return false
  }
  var i = 0
  while i < name.length {
    val c = name.substring(i, 1)
    val isUpper = c >= "A" and c <= "Z"
    val isLower = c >= "a" and c <= "z"
    val isDigit = c >= "0" and c <= "9"
    val isDash = c == "-" or c == "_"
    if not (isUpper or isLower or isDigit or isDash) {
      return false
    }
    i = i + 1
  }
  return true
}

pub func isValidMcpTransport(t: in String): Bool {
  return t == "stdio" or t == "url"
}

/// A literal MCP env entry must be a non-empty "KEY=VALUE" pair (the key
/// half non-empty) — checked with `.contains`/`.substring` rather than
/// splitting on "=" (String.split is undocumented-as-working in this
/// toolchain; docs/lyric/gotchas.md), since storage keeps the entry whole.
func isValidMcpEnvEntry(entry: in String): Bool {
  if entry.length == 0 or entry.length > maxMcpFieldLen {
    return false
  }
  if not entry.contains("=") {
    return false
  }
  return entry.substring(0, 1) != "="
}

// ─── Skills ─────────────────────────────────────────────────────────────────
@generate(Json)
pub record SaveSkillRequest {
  pub name: String
  pub description: String
  pub body: String
}

func validateSaveSkill(req: in SaveSkillRequest): Option[Web.ApiError] {
  if not isValidLibraryName(req.name) {
    return Some(value = Web.badRequest("name must be 1-128 chars of letters, digits, '-', or '_'"))
  }
  if req.description.length == 0 or req.description.length > maxDescriptionLen {
    return Some(value = Web.badRequest("description is required (max 2000 characters)"))
  }
  if req.body.length == 0 or req.body.length > maxBodyLen {
    return Some(value = Web.badRequest("body is required (max 200000 characters)"))
  }
  return None
}

pub func listSkillsHandler(): Result[SkillList, Web.ApiError] {
  match listSkills(CloudAgents.Auth.currentUserId()) {
    case Ok(ss) -> return Ok(SkillList(skills = ss))
    case Err(e) -> return Err(dbError(e))
  }
}

pub func addSkillHandler(req: in SaveSkillRequest): Result[Skill, Web.ApiError] {
  match validateSaveSkill(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  val userId = CloudAgents.Auth.currentUserId()
  match skillIdByName(userId, req.name) {
    case Ok(Some(_)) -> return Err(Web.badRequest("a skill with this name already exists"))
    case Ok(None) -> ()
    case Err(e) -> return Err(dbError(e))
  }
  match addSkill(userId, req.name, req.description, req.body) {
    case Ok(s) -> return Ok(s)
    case Err(e) -> return Err(dbError(e))
  }
}

pub func updateSkillHandler(id: in String, req: in SaveSkillRequest): Result[Skill, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("skill id is required"))
  }
  match validateSaveSkill(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  val userId = CloudAgents.Auth.currentUserId()
  match skillIdByName(userId, req.name) {
    case Ok(Some(otherId)) -> if otherId != id { return Err(Web.badRequest("a skill with this name already exists")) }
    case Ok(None) -> ()
    case Err(e) -> return Err(dbError(e))
  }
  val affected = match updateSkill(id, userId, req.name, req.description, req.body) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("skill not found"))
  }
  match getSkill(id, userId) {
    case Ok(Some(s)) -> return Ok(s)
    case Ok(None) -> return Err(Web.notFound("skill not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

pub func deleteSkillHandler(id: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("skill id is required"))
  }
  val affected = match deleteSkill(id, CloudAgents.Auth.currentUserId()) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("skill not found"))
  }
  return Ok(())
}

// ─── Subagents ──────────────────────────────────────────────────────────────
@generate(Json)
pub record SaveSubagentRequest {
  pub name: String
  pub description: String
  pub systemPrompt: String
  pub model: String
}

func validateSaveSubagent(req: in SaveSubagentRequest): Option[Web.ApiError] {
  if not isValidLibraryName(req.name) {
    return Some(value = Web.badRequest("name must be 1-128 chars of letters, digits, '-', or '_'"))
  }
  if req.description.length == 0 or req.description.length > maxDescriptionLen {
    return Some(value = Web.badRequest("description is required (max 2000 characters)"))
  }
  if req.systemPrompt.length == 0 or req.systemPrompt.length > maxBodyLen {
    return Some(value = Web.badRequest("systemPrompt is required (max 200000 characters)"))
  }
  if req.model.length > maxModelLen {
    return Some(value = Web.badRequest("model is too long (max 200 characters)"))
  }
  return None
}

pub func listSubagentsHandler(): Result[SubagentList, Web.ApiError] {
  match listSubagents(CloudAgents.Auth.currentUserId()) {
    case Ok(ss) -> return Ok(SubagentList(subagents = ss))
    case Err(e) -> return Err(dbError(e))
  }
}

pub func addSubagentHandler(req: in SaveSubagentRequest): Result[Subagent, Web.ApiError] {
  match validateSaveSubagent(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  val userId = CloudAgents.Auth.currentUserId()
  match subagentIdByName(userId, req.name) {
    case Ok(Some(_)) -> return Err(Web.badRequest("a subagent with this name already exists"))
    case Ok(None) -> ()
    case Err(e) -> return Err(dbError(e))
  }
  match addSubagent(userId, req.name, req.description, req.systemPrompt, req.model) {
    case Ok(s) -> return Ok(s)
    case Err(e) -> return Err(dbError(e))
  }
}

pub func updateSubagentHandler(id: in String, req: in SaveSubagentRequest): Result[Subagent, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("subagent id is required"))
  }
  match validateSaveSubagent(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  val userId = CloudAgents.Auth.currentUserId()
  match subagentIdByName(userId, req.name) {
    case Ok(Some(otherId)) -> if otherId != id { return Err(Web.badRequest("a subagent with this name already exists")) }
    case Ok(None) -> ()
    case Err(e) -> return Err(dbError(e))
  }
  val affected = match updateSubagent(id, userId, req.name, req.description, req.systemPrompt, req.model) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("subagent not found"))
  }
  match getSubagent(id, userId) {
    case Ok(Some(s)) -> return Ok(s)
    case Ok(None) -> return Err(Web.notFound("subagent not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

pub func deleteSubagentHandler(id: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("subagent id is required"))
  }
  val affected = match deleteSubagent(id, CloudAgents.Auth.currentUserId()) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("subagent not found"))
  }
  return Ok(())
}

// ─── MCP servers ────────────────────────────────────────────────────────────
@generate(Json)
pub record SaveMcpServerRequest {
  pub name: String
  pub transport: String
  pub command: String
  pub args: slice[String]
  pub url: String
  pub env: slice[String]
}

func validateSaveMcpServer(req: in SaveMcpServerRequest): Option[Web.ApiError] {
  if not isValidLibraryName(req.name) {
    return Some(value = Web.badRequest("name must be 1-128 chars of letters, digits, '-', or '_'"))
  }
  if not isValidMcpTransport(req.transport) {
    return Some(value = Web.badRequest("transport must be one of: stdio, url"))
  }
  if req.transport == "stdio" {
    if req.command.length == 0 or req.command.length > maxMcpFieldLen {
      return Some(value = Web.badRequest("command is required for a stdio server (max 4096 characters)"))
    }
    if req.args.length > maxMcpArgCount {
      return Some(value = Web.badRequest("too many args (max 64)"))
    }
    var ai = 0
    while ai < req.args.length {
      if req.args[ai].length > maxMcpFieldLen {
        return Some(value = Web.badRequest("an arg is too long (max 4096 characters)"))
      }
      ai = ai + 1
    }
  } else {
    if req.url.length == 0 or req.url.length > maxMcpFieldLen {
      return Some(value = Web.badRequest("url is required for a url server (max 4096 characters)"))
    }
  }
  if req.env.length > maxMcpEnvCount {
    return Some(value = Web.badRequest("too many env entries (max 64)"))
  }
  var ei = 0
  while ei < req.env.length {
    if not isValidMcpEnvEntry(req.env[ei]) {
      return Some(value = Web.badRequest("env entries must be non-empty 'KEY=VALUE' pairs"))
    }
    ei = ei + 1
  }
  return None
}

pub func listMcpServersHandler(): Result[McpServerList, Web.ApiError] {
  match listMcpServers(CloudAgents.Auth.currentUserId()) {
    case Ok(ms) -> return Ok(McpServerList(mcpServers = ms))
    case Err(e) -> return Err(dbError(e))
  }
}

pub func addMcpServerHandler(req: in SaveMcpServerRequest): Result[McpServer, Web.ApiError] {
  match validateSaveMcpServer(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  val userId = CloudAgents.Auth.currentUserId()
  match mcpServerIdByName(userId, req.name) {
    case Ok(Some(_)) -> return Err(Web.badRequest("an MCP server with this name already exists"))
    case Ok(None) -> ()
    case Err(e) -> return Err(dbError(e))
  }
  match addMcpServer(userId, req.name, req.transport, req.command, req.args, req.url, req.env) {
    case Ok(m) -> return Ok(m)
    case Err(e) -> return Err(dbError(e))
  }
}

pub func updateMcpServerHandler(id: in String, req: in SaveMcpServerRequest): Result[McpServer, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("mcp server id is required"))
  }
  match validateSaveMcpServer(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  val userId = CloudAgents.Auth.currentUserId()
  match mcpServerIdByName(userId, req.name) {
    case Ok(Some(otherId)) -> if otherId != id { return Err(Web.badRequest("an MCP server with this name already exists")) }
    case Ok(None) -> ()
    case Err(e) -> return Err(dbError(e))
  }
  val affected = match updateMcpServer(id, userId, req.name, req.transport, req.command, req.args, req.url, req.env) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("mcp server not found"))
  }
  match getMcpServer(id, userId) {
    case Ok(Some(m)) -> return Ok(m)
    case Ok(None) -> return Err(Web.notFound("mcp server not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

pub func deleteMcpServerHandler(id: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("mcp server id is required"))
  }
  val affected = match deleteMcpServer(id, CloudAgents.Auth.currentUserId()) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("mcp server not found"))
  }
  return Ok(())
}
