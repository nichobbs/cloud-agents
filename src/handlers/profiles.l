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
  return None
}

/// The credential grants to persist: only meaningful in 'selected' mode, so an
/// 'all'-mode profile always stores an empty set (avoids a stale list lingering
/// if the mode is later flipped without re-sending the names).
func grantsFor(req: in SaveProfileRequest): slice[String] {
  if req.credentialMode == "selected" {
    return req.credentials
  }
  val none: slice[String] = []
  return none
}

/// List the caller's profiles, alphabetical by name.
@get("/api/profiles")
pub func listProfilesHandler(): Result[ProfileList, Web.ApiError] {
  match listProfiles(CloudAgents.Auth.currentUserId()) {
    case Ok(ps) -> return Ok(ProfileList(profiles = ps))
    case Err(e) -> return Err(dbError(e))
  }
}

/// Create a new profile.
@post("/api/profiles")
pub func addProfileHandler(@body req: in SaveProfileRequest): Result[Profile, Web.ApiError] {
  match validateSaveProfile(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  match addProfile(
    CloudAgents.Auth.currentUserId(),
    req.name.trim(),
    req.harness,
    req.networkPolicy,
    req.credentialMode,
    grantsFor(req)
  ) {
    case Ok(p) -> return Ok(p)
    case Err(e) -> return Err(dbError(e))
  }
}

/// Update an existing profile.
@post("/api/profiles/{pid}")
pub func updateProfileHandler(pid: in String, @body req: in SaveProfileRequest): Result[Profile, Web.ApiError] {
  if pid.length == 0 {
    return Err(Web.badRequest("profile id is required"))
  }
  match validateSaveProfile(req) {
    case Some(err) -> return Err(err)
    case None -> ()
  }
  val userId = CloudAgents.Auth.currentUserId()
  val affected = match updateProfile(
    pid,
    userId,
    req.name.trim(),
    req.harness,
    req.networkPolicy,
    req.credentialMode,
    grantsFor(req)
  ) {
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
@delete("/api/profiles/{pid}")
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
