//! HTTP handlers for container profiles: a per-container policy object naming
//! which harness runs, what network access the runner container gets, and which
//! of the user's credentials are injected (least privilege). Storage lives in
//! CloudAgents.Repository; ownership is scoped by CloudAgents.Auth.currentUserId()
//! (single operator identity in the static-token phase, per-user once GitHub
//! OAuth lands).
package CloudAgents.Profiles

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Sqlite

val maxProfileNameLen = 200

@generate(Json)
pub record SaveProfileRequest {
  pub name: String
  pub harness: String
  pub networkPolicy: String
  pub credentialMode: String
  pub credentials: slice[String]
}

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
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

/// Harness the profile pins, or "" to let the session choose. Mirrors the
/// harnesses CloudAgents.Docker knows how to image.
pub func isValidProfileHarness(h: in String): Bool {
  return h == "" or h == "claude" or h == "codex" or h == "opencode"
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
    return Some(value = Web.badRequest("harness must be empty or one of: claude, codex, opencode"))
  }
  // In 'selected' mode, every granted name must be a valid env-var name.
  if req.credentialMode == "selected" {
    var i = 0
    while i < req.credentials.length {
      if not isValidGrantName(req.credentials[i]) {
        return Some(value = Web.badRequest("credential grant names must be valid environment variable names"))
      }
      i = i + 1
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
  match addProfile(userId, name, req.harness, req.networkPolicy, req.credentialMode, grantsFor(req)) {
    case Ok(p) -> return Ok(p)
    case Err(e) -> return Err(dbError(e))
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
  val affected = match updateProfile(pid, userId, name, req.harness, req.networkPolicy, req.credentialMode, grantsFor(req)) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
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
