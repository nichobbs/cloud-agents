//! HTTP handlers for container profiles: a per-container policy object naming
//! which harness runs, what network access the runner container gets, and which
//! of the user's credentials are injected (least privilege). Storage lives in
//! CloudAgents.Repository; ownership is scoped by CloudAgents.Auth.currentUserId()
//! (single operator identity in the static-token phase, per-user once GitHub
//! OAuth lands).
package CloudAgents.Profiles

import Std.Core
import Std.Json
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Sqlite

val maxProfileNameLen = 200

// The stable MCP tool names the in-container shim can register (see
// shim/src/main.l — an entirely separate Lyric project with its own
// lyric.toml/build, so there is no dependency edge to share this list
// through code; it is kept in sync by hand). This is exactly the set
// profile_tools.tool_name may be drawn from in 'selected' mode
// (docs/phase7-autonomy.md §7).
val validShimToolNames: slice[String] = ["request_permission", "ask_user", "report_progress", "request_secret", "add_followup_task", "report_artifact", "remember", "recall", "forget", "add_task", "list_tasks", "complete_task", "notify"]

@generate(Json)
pub record SaveProfileRequest {
  pub name: String
  pub harness: String
  pub networkPolicy: String
  pub credentialMode: String
  pub credentials: slice[String]
  pub skillIds: slice[String]
  pub subagentIds: slice[String]
  pub mcpServerIds: slice[String]
  pub toolMode: String
  pub tools: slice[String]
}

/// The index of the last occurrence of a single-character `target` in `s`,
/// or -1. Small local helper (CloudAgents.Text has no reverse search) —
/// only ever called on a string already confirmed to parse as valid JSON,
/// where the last '}' is always that document's own outermost closing
/// brace (see patchMissingToolFields' doc comment).
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

/// `@generate(Json)`'s derived `fromJson` requires every field present in
/// the body — there is no per-field "optional, defaults to X when absent"
/// support (confirmed: a body missing `toolMode` or `tools` fails decode
/// with "missing field '<name>'" before SaveProfileRequest.fromJson ever
/// returns, so validateSaveProfile's own "" == default tolerance
/// (isValidToolMode, normalizedToolMode) never even runs). Since `toolMode`/
/// `tools` are NEW fields on an existing request shape (#614), a
/// not-yet-updated frontend's save-profile request omits them entirely —
/// every such request would 400 at the decode boundary the moment this
/// ships, regardless of the validation layer's own tolerance.
///
/// Patches the two fields' JSON-default values ("" / []) into the raw body
/// BEFORE decoding, but only for whichever of the two keys is actually
/// absent (a body that already sends them is passed through byte-identical).
/// Uses Std.Json's real parser to detect absence (not a blind string
/// search, which could false-positive on a nested object/array that
/// happens to contain the substring `"toolMode"` as a value) and splices
/// the additions in right before the body's own closing '}' — safe because
/// a string that already parsed successfully as one JSON object always has
/// its own outermost closing brace as the last '}' character in the text
/// (no valid JSON document has any unescaped '}' after the true end of its
/// root object, whitespace aside).
pub func patchMissingToolFields(body: in String): String {
  val doc = match Std.Json.tryParseJson(body) { case Ok(d) -> d; case Err(_) -> return body }
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  var toAdd = ""
  match Std.Json.tryGetProperty(root, "toolMode") {
    case None -> {
      toAdd = toAdd + ",\"toolMode\":\"\""
    }
    case Some(_) -> ()
  }
  match Std.Json.tryGetProperty(root, "tools") {
    case None -> {
      toAdd = toAdd + ",\"tools\":[]"
    }
    case Some(_) -> ()
  }
  if toAdd.length == 0 {
    return body
  }
  val closeIdx = lastIndexOfChar(body, "}")
  if closeIdx < 0 {
    return body
  }
  return body.substring(0, closeIdx) + toAdd + body.substring(closeIdx, body.length - closeIdx)
}

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

/// Whether a DbError is the profiles table's `UNIQUE(user_id, name)`
/// constraint firing at INSERT/UPDATE time. The name-uniqueness pre-check in
/// addProfileHandler/updateProfileHandler (#236) is not atomic with the
/// mutation that follows it — a concurrent create/rename using the same name
/// can slip between the two — so the constraint itself is the actual guarantee
/// (#245); this lets the mutation's own failure be turned into the same clean
/// 400 the pre-check produces in the non-racy case, instead of a raw
/// UNIQUE-constraint 500. SQLite's own error text ("UNIQUE constraint
/// failed: ...") is stable across the Microsoft.Data.Sqlite driver.
///
/// A plain "UNIQUE constraint" substring check isn't specific enough
/// (#558): addProfile/updateProfile run the profiles-row upsert and the
/// caller's credential grants (`profile_credentials`, its own
/// `UNIQUE(profile_id, credential_name)`) in the SAME transaction, so a
/// duplicate credential NAME in the request would trip that other table's
/// constraint and get misreported here as a profile-name collision instead
/// of the real problem (a duplicate grant). CloudAgents.Sqlite.dbErrorMessage
/// embeds the failing statement's own SQL text (`ExecFailed(sql, m)`), so
/// checking for the profiles table's own INSERT/UPDATE keeps this scoped to
/// the constraint it actually names. "profiles " (trailing space, matching
/// insertProfileSql's "INTO profiles (") never matches
/// insertProfileCredentialSql's "INTO profile_credentials (" — different
/// table name, not a prefix of it.
func isDuplicateNameError(e: in CloudAgents.Sqlite.DbError): Bool {
  val msg = CloudAgents.Sqlite.dbErrorMessage(e)
  return msg.contains("UNIQUE constraint") and msg.contains("profiles ")
}

/// Network policy vocabulary — see CloudAgents.Db profiles DDL.
pub func isValidNetworkPolicy(p: in String): Bool {
  return p == "full" or p == "none" or p == "restricted"
}

/// Credential-injection mode: all of the user's credentials, or only the named
/// grants.
pub func isValidCredentialMode(m: in String): Bool {
  return m == "all" or m == "selected"
}

/// Tool-enablement mode: every shim tool registered, or only the named tools
/// (docs/phase7-autonomy.md §7). Mirrors isValidCredentialMode, plus accepts
/// "" (see normalizedToolMode) — unlike credentialMode, toolMode is a NEW
/// field on an existing request shape: a not-yet-updated frontend never
/// sends it, so an absent/empty value must be accepted as the default
/// rather than rejected with a 400, or every profile save breaks the moment
/// this ships (#614). isValidProfileHarness already established this exact
/// "" == default precedent for the same reason.
pub func isValidToolMode(m: in String): Bool {
  return m == "" or m == "all" or m == "selected"
}

/// Normalizes an absent/empty toolMode to "all" before it's persisted or
/// used to decide which tools list to store — see isValidToolMode's doc
/// comment (#614). Anything else (already validated to "all"/"selected" by
/// this point) passes through unchanged.
func normalizedToolMode(m: in String): String {
  if m.length == 0 {
    return "all"
  }
  return m
}

/// Whether `name` is one of the stable MCP tool names the shim can
/// register — see validShimToolNames' doc comment above.
pub func isValidToolName(name: in String): Bool {
  var i = 0
  while i < validShimToolNames.length {
    if validShimToolNames[i] == name {
      return true
    }
    i = i + 1
  }
  return false
}

/// Harness the profile pins, or "" to let the session choose. Mirrors the
/// harnesses CloudAgents.Docker knows how to image.
pub func isValidProfileHarness(h: in String): Bool {
  return h == "" or h == "claude" or h == "codex" or h == "opencode" or h == "gemini"
}

/// A credential grant name must be a valid environment-variable name (the same
/// charset AND max length the credential store enforces on the name it injects,
/// CloudAgents.Credentials.isValidCredentialName — a leading letter or
/// underscore, then letters/digits/underscores, ≤128 chars). Guards against
/// junk grants that could never match a storable credential (#237/#262).
pub func isValidGrantName(name: in String): Bool {
  if name.length == 0 or name.length > 128 {
    return false
  }
  var i = 0
  while i < name.length {
    val c = name.substring(i, 1)
    val isUpper = c >= "A" and c <= "Z"
    val isLower = c >= "a" and c <= "z"
    val isDigit = c >= "0" and c <= "9"
    val isUnderscore = c == "_"
    if i == 0 {
      if not (isUpper or isLower or isUnderscore) {
        return false
      }
    } else {
      if not (isUpper or isLower or isDigit or isUnderscore) {
        return false
      }
    }
    i = i + 1
  }
  return true
}

func validateSaveProfile(req: in SaveProfileRequest): Option[Web.ApiError] {
  if req.name.trim().length == 0 {
    return Some(value = Web.badRequest("name is required"))
  }
  if req.name.length > maxProfileNameLen {
    return Some(value = Web.badRequest("name is too long (max 200 characters)"))
  }
  if not isValidNetworkPolicy(req.networkPolicy) {
    return Some(value = Web.badRequest("networkPolicy must be one of: full, none, restricted"))
  }
  if not isValidCredentialMode(req.credentialMode) {
    return Some(value = Web.badRequest("credentialMode must be one of: all, selected"))
  }
  if not isValidProfileHarness(req.harness) {
    return Some(value = Web.badRequest("harness must be empty or one of: claude, codex, opencode, gemini"))
  }
  if not isValidToolMode(req.toolMode) {
    return Some(value = Web.badRequest("toolMode must be one of: all, selected"))
  }
  // In 'selected' mode, every granted name must be a valid env-var name, and
  // no name may repeat: profileCredentialStatements inserts one row per
  // credential into profile_credentials, whose own UNIQUE(profile_id,
  // credential_name) would otherwise catch a client-submitted duplicate at
  // the DB layer — and isDuplicateNameError can't safely be broadened to
  // treat that as a clean 400 without risking a real profile-name collision
  // going unreported the same way (#558), so it's better rejected here,
  // before the request ever reaches the database.
  if req.credentialMode == "selected" {
    var i = 0
    while i < req.credentials.length {
      if not isValidGrantName(req.credentials[i]) {
        return Some(value = Web.badRequest("credential grant names must be valid environment variable names"))
      }
      var j = 0
      while j < i {
        if req.credentials[j] == req.credentials[i] {
          return Some(value = Web.badRequest("credential grant names must not repeat"))
        }
        j = j + 1
      }
      i = i + 1
    }
  }
  // In 'selected' mode, every enabled tool must be one of the shim's known
  // tool names, and no name may repeat — mirrors the credential-grant
  // duplicate check above exactly (#615): profile_tools' own
  // UNIQUE(profile_id, tool_name) would otherwise just silently dedupe a
  // client-submitted duplicate via ON CONFLICT DO NOTHING, which is a
  // harmless but inconsistent outcome compared to how a duplicate
  // credential grant is rejected before it ever reaches the database.
  if req.toolMode == "selected" {
    var ti = 0
    while ti < req.tools.length {
      if not isValidToolName(req.tools[ti]) {
        return Some(value = Web.badRequest("unknown tool name: " + req.tools[ti]))
      }
      var tj = 0
      while tj < ti {
        if req.tools[tj] == req.tools[ti] {
          return Some(value = Web.badRequest("tool names must not repeat"))
        }
        tj = tj + 1
      }
      ti = ti + 1
    }
  }
  return None
}

/// The credential grants to persist: only meaningful in 'selected' mode, so an
/// 'all'-mode profile always stores an empty set (avoids a stale list lingering
/// if the mode is later flipped without re-sending the names).
func grantsFor(req: in SaveProfileRequest): slice[String] {
  if req.credentialMode == "selected" {
    return req.credentials
  }
  val empty: slice[String] = []
  return empty
}

/// The tool grants to persist: only meaningful in 'selected' mode, so an
/// 'all'-mode profile always stores an empty set (avoids a stale list
/// lingering if the mode is later flipped without re-sending the names).
/// Mirrors grantsFor exactly (docs/phase7-autonomy.md §7). Compares against
/// the NORMALIZED toolMode (#614) so an absent/empty toolMode — which
/// normalizes to "all" — correctly stores no tools, exactly like an
/// explicit "all" does.
func toolsFor(req: in SaveProfileRequest): slice[String] {
  if normalizedToolMode(req.toolMode) == "selected" {
    return req.tools
  }
  val empty: slice[String] = []
  return empty
}

/// List the caller's profiles, alphabetical by name.
pub func listProfilesHandler(): Result[ProfileList, Web.ApiError] {
  match listProfiles(CloudAgents.Auth.currentUserId()) {
    case Ok(ps) -> return Ok(ProfileList(profiles = ps))
    case Err(e) -> return Err(dbError(e))
  }
}

/// Create a new profile.
pub func addProfileHandler(req: in SaveProfileRequest): Result[Profile, Web.ApiError] {
  match validateSaveProfile(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  val userId = CloudAgents.Auth.currentUserId()
  val name = req.name.trim()
  // Turn a duplicate name into a 400 rather than a UNIQUE-constraint 500 (#236).
  match profileIdByName(userId, name) {
    case Ok(Some(_)) -> return Err(Web.badRequest("a profile with this name already exists"))
    case Ok(None) -> ()
    case Err(e) -> return Err(dbError(e))
  }
  match addProfile(userId, name, req.harness, req.networkPolicy, req.credentialMode, grantsFor(req), req.skillIds, req.subagentIds, req.mcpServerIds, normalizedToolMode(req.toolMode), toolsFor(req)) {
    case Ok(p) -> return Ok(p)
    case Err(e) -> {
      // A concurrent create with the same name can slip past the pre-check
      // above and only fail here, at the UNIQUE constraint (#245) — report it
      // the same way the pre-check would have, not as a raw 500.
      if isDuplicateNameError(e) {
        return Err(Web.badRequest("a profile with this name already exists"))
      }
      return Err(dbError(e))
    }
  }
}

/// Update an existing profile.
pub func updateProfileHandler(pid: in String, req: in SaveProfileRequest): Result[Profile, Web.ApiError] {
  if pid.length == 0 {
    return Err(Web.badRequest("profile id is required"))
  }
  match validateSaveProfile(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  val userId = CloudAgents.Auth.currentUserId()
  val name = req.name.trim()
  // A rename that collides with another profile's name is a 400, not a 500.
  match profileIdByName(userId, name) {
    case Ok(Some(otherId)) -> if otherId != pid { return Err(Web.badRequest("a profile with this name already exists")) }
    case Ok(None) -> ()
    case Err(e) -> return Err(dbError(e))
  }
  val affected = match updateProfile(pid, userId, name, req.harness, req.networkPolicy, req.credentialMode, grantsFor(req), req.skillIds, req.subagentIds, req.mcpServerIds, normalizedToolMode(req.toolMode), toolsFor(req)) {
    case Ok(n) -> n
    case Err(e) -> {
      // A concurrent rename onto the same name can slip past the pre-check
      // above and only fail here, at the UNIQUE constraint (#245) — report it
      // the same way the pre-check would have, not as a raw 500.
      if isDuplicateNameError(e) {
        return Err(Web.badRequest("a profile with this name already exists"))
      }
      return Err(dbError(e))
    }
  }
  if affected == 0 {
    return Err(Web.notFound("profile not found"))
  }
  match getProfile(pid, userId) {
    case Ok(Some(p)) -> return Ok(p)
    case Ok(None) -> return Err(Web.notFound("profile not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

/// Delete a profile (and its credential grants).
pub func deleteProfileHandler(pid: in String): Result[Unit, Web.ApiError] {
  if pid.length == 0 {
    return Err(Web.badRequest("profile id is required"))
  }
  val affected = match deleteProfile(pid, CloudAgents.Auth.currentUserId()) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("profile not found"))
  }
  return Ok(())
}
