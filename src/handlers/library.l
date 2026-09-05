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
import Std.Json
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.Streaming
import CloudAgents.Text

val maxNameLen = 128

val maxDescriptionLen = 2000

val maxBodyLen = 200000

val maxModelLen = 200

val maxMcpFieldLen = 4096

val maxMcpArgCount = 64

val maxMcpEnvCount = 64

val maxMcpHeaderCount = 64

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
/// Reused as-is for a url-transport server's `headers` entries (#768,
/// "Name=Value" HTTP headers) — same "NAME=VALUE" shape, same delimiter
/// hazard at injection time (docker/inject-library.sh), same fix.
/// Also rejects any raw control character (below U+0020, including NUL and
/// a literal newline) in the entry, mirroring the C0-range stripping
/// docker/entrypoint.sh already does for GITHUB_TOKEN et al
/// (`tr -d '\000-\037'`) for exactly this class of problem: whatever
/// delimiter docker/inject-library.sh's render_mcp_json/render_mcp_codex use
/// to split a stored env value out of jq's output (previously newline, now
/// a NUL byte via `read -r -d ''`), a control character embedded in the
/// value can collide with it and mis-split the entry — a JSON-encoded NUL
/// (valid JSON, decoded to a real NUL by `jq -j`) is indistinguishable from
/// the NUL delimiter itself (#782, the same bug class as #775's
/// embedded-newline case). Banning the whole C0 range closes this for good
/// instead of chasing the next delimiter choice.
func isValidMcpEnvEntry(entry: in String): Bool {
  if entry.length == 0 or entry.length > maxMcpFieldLen {
    return false
  }
  if not entry.contains("=") {
    return false
  }
  if CloudAgents.Text.containsControlChar(entry) {
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
  pub enabled: String = "1"
  // "Name=Value" HTTP header entries, only meaningful for transport "url"
  // (#768 — lets a url-transport server carry e.g. an Authorization header
  // for a hosted remote MCP endpoint). Same shape/validation as `env`.
  pub headers: slice[String] = []
}

/// Same last-'}'-splice trick as CloudAgents.Profiles.patchMissingToolFields
/// (see its doc comment) applied to `enabled`, the newest field on this
/// request shape: `@generate(Json)`'s derived `fromJson` requires every
/// field present in the body (docs/lyric/stdlib.md) regardless of this
/// record's own Lyric-level `= "1"` default, so a not-yet-updated frontend
/// that doesn't send `enabled` yet would 400 at the decode boundary the
/// moment this ships. Patches in `defaultEnabled` only when the key is
/// actually absent; a body that already sends it passes through unchanged.
///
/// The caller supplies `defaultEnabled` rather than this always assuming
/// "1": on add there is no prior state, so "1" is correct, but on update a
/// hardcoded "1" would silently re-enable a previously-disabled server the
/// moment a stale frontend build (one that predates the `enabled` field)
/// submits an unrelated edit — see patchMissingMcpServerEnabledForUpdate,
/// which passes the server's current stored value instead.
func patchMissingMcpServerEnabledWithDefault(body: in String, defaultEnabled: in String): String {
  val doc = match Std.Json.tryParseJson(body) { case Ok(d) -> d; case Err(_) -> return body }
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  match Std.Json.tryGetProperty(root, "enabled") {
    case Some(_) -> return body
    case None -> ()
  }
  val closeIdx = lastIndexOfChar(body, "}")
  if closeIdx < 0 {
    return body
  }
  return body.substring(0, closeIdx) + ",\"enabled\":\"" + defaultEnabled + "\"" + body.substring(closeIdx, body.length - closeIdx)
}

/// Used on add, where there is no prior server to preserve state from.
pub func patchMissingMcpServerEnabled(body: in String): String {
  return patchMissingMcpServerEnabledWithDefault(body, "1")
}

/// Used on update: defaults a missing `enabled` field to the server's
/// current stored value (falling back to "1" only if the server can't be
/// found, e.g. a bad id — the update call itself will report that error).
pub func patchMissingMcpServerEnabledForUpdate(body: in String, id: in String): String {
  val userId = CloudAgents.Auth.currentUserId()
  val defaultEnabled = match getMcpServer(id, userId) {
    case Ok(Some(m)) -> m.enabled
    case _ -> "1"
  }
  return patchMissingMcpServerEnabledWithDefault(body, defaultEnabled)
}

/// Same last-'}'-splice trick as patchMissingMcpServerEnabledWithDefault,
/// applied to `headers` (#768, the newest field on this request shape): a
/// not-yet-updated frontend build that predates header support wouldn't send
/// this key at all, and `@generate(Json)`'s derived `fromJson` requires
/// every field present regardless of this record's own Lyric-level `= []`
/// default — so patch in `defaultHeadersJson` (already-encoded JSON array
/// text) when the key is absent rather than 400 at the decode boundary. A
/// body that already sends `headers` passes through unchanged.
///
/// The caller supplies the default rather than this always assuming `[]`,
/// mirroring patchMissingMcpServerEnabledWithDefault exactly: on add there
/// is no prior server, so `[]` is correct, but on update a hardcoded `[]`
/// would silently wipe every previously-stored header the moment a stale
/// frontend build (one that predates the `headers` field) submits an
/// unrelated edit — mcpServerChildStatements is clear-then-reinsert for
/// headers, so "absent" must mean "preserve", not "clear" (#1043). See
/// patchMissingMcpServerHeadersForUpdate, which passes the server's current
/// stored headers instead.
func patchMissingMcpServerHeadersWithDefault(body: in String, defaultHeadersJson: in String): String {
  val doc = match Std.Json.tryParseJson(body) { case Ok(d) -> d; case Err(_) -> return body }
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  match Std.Json.tryGetProperty(root, "headers") {
    case Some(_) -> return body
    case None -> ()
  }
  val closeIdx = lastIndexOfChar(body, "}")
  if closeIdx < 0 {
    return body
  }
  return body.substring(0, closeIdx) + ",\"headers\":" + defaultHeadersJson + body.substring(closeIdx, body.length - closeIdx)
}

/// JSON-encodes a slice[String] as a JSON array of string literals, escaping
/// each entry the same way any other hand-assembled JSON in this codebase
/// does (CloudAgents.Streaming.jsonEscape) — used to splice a server's
/// currently-stored headers back into a request body as valid JSON text.
func headersToJsonArray(headers: in slice[String]): String {
  var acc = "["
  var i = 0
  while i < headers.length {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + "\"" + CloudAgents.Streaming.jsonEscape(headers[i]) + "\""
    i = i + 1
  }
  return acc + "]"
}

/// Used on add, where there is no prior server to preserve state from.
pub func patchMissingMcpServerHeaders(body: in String): String {
  return patchMissingMcpServerHeadersWithDefault(body, "[]")
}

/// Used on update: defaults a missing `headers` field to the server's
/// current stored headers (falling back to `[]` only if the server can't be
/// found, e.g. a bad id — the update call itself will report that error).
pub func patchMissingMcpServerHeadersForUpdate(body: in String, id: in String): String {
  val userId = CloudAgents.Auth.currentUserId()
  val defaultHeadersJson = match getMcpServer(id, userId) {
    case Ok(Some(m)) -> headersToJsonArray(m.headers)
    case _ -> "[]"
  }
  return patchMissingMcpServerHeadersWithDefault(body, defaultHeadersJson)
}

/// Last index of a single-character needle, hand-rolled the same way
/// CloudAgents.Profiles.lastIndexOfChar is (each package owns its own tiny
/// copy rather than importing another package's private helper).
func lastIndexOfChar(s: in String, target: in String): Int {
  var i = s.length - 1
  while i >= 0 {
    if s.substring(i, 1) == target {
      return i
    }
    i = i - 1
  }
  return -1
}

func validateSaveMcpServer(req: in SaveMcpServerRequest): Option[Web.ApiError] {
  if not isValidLibraryName(req.name) {
    return Some(value = Web.badRequest("name must be 1-128 chars of letters, digits, '-', or '_'"))
  }
  if req.enabled != "0" and req.enabled != "1" {
    return Some(value = Web.badRequest("enabled must be '0' or '1'"))
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
  if req.headers.length > maxMcpHeaderCount {
    return Some(value = Web.badRequest("too many header entries (max 64)"))
  }
  var hi = 0
  while hi < req.headers.length {
    if not isValidMcpEnvEntry(req.headers[hi]) {
      return Some(value = Web.badRequest("header entries must be non-empty 'Name=Value' pairs"))
    }
    hi = hi + 1
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
  match addMcpServer(userId, req.name, req.transport, req.command, req.args, req.url, req.env, req.enabled, req.headers) {
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
  val affected = match updateMcpServer(id, userId, req.name, req.transport, req.command, req.args, req.url, req.env, req.enabled, req.headers) {
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
