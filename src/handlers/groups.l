//! HTTP handlers for session groups: a user-owned tree of named folders a
//! session can be filed under (migration 0029), plus the "viewed" stamp the
//! session list's attention states derive from. Storage lives in
//! CloudAgents.Repository (groups) and CloudAgents.SessionStore (the
//! sessions-table group/viewed columns); ownership is scoped by
//! CloudAgents.Auth.currentUserId(), the same shape as CloudAgents.Profiles.
//!
//! The tree invariant — no cycles, at most maxGroupDepth levels — is enforced
//! here at the handler layer by walking parent chains before every write
//! (checkParentChain): the depth cap alone already makes a cycle impossible
//! to create, and it also bounds every walk so validation always terminates.
//!
//! Deliberately no async anywhere in this package so @test_module suites can
//! import and invoke every handler directly (docs/lyric/gotchas.md's
//! async-bearing-package rule).
package CloudAgents.Groups

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Text

val maxGroupNameLen = 200

/// Maximum number of ancestors a group may have (a parent chain of 10 walks
/// from the immediate parent up to a root). Rejecting anything deeper both
/// keeps the tree sane and prevents cycles: a cycle could only ever be formed
/// through a parent chain, and every chain is re-validated to this bound
/// before any write.
val maxGroupDepth = 10

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

/// Small local copy of CloudAgents.Callbacks.requireOwnedSession (that one is
/// package-private): 404 both when the session doesn't exist and when it
/// belongs to someone else — getSession is already owner-scoped.
func requireOwnedSession(sessionId: in String): Result[Unit, Web.ApiError] {
  match CloudAgents.SessionStore.getSession(sessionId) {
    case Ok(Some(_)) -> return Ok(())
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

@generate(Json)
pub record SaveGroupRequest {
  pub name: String
  pub parentId: String
}

@generate(Json)
pub record SetSessionGroupRequest {
  pub groupId: String
}

/// Walk the parent chain starting AT `startId` (inclusive), at most
/// maxGroupDepth steps. 400 when the chain is deeper than maxGroupDepth, or
/// when a non-empty `forbiddenId` appears anywhere in it — the
/// self/descendant guard for updates (assigning a group's own descendant as
/// its parent would make that descendant's chain pass through the group,
/// i.e. a cycle). A missing ancestor ends the walk like a root: the
/// immediate parent's existence is checked separately by the callers, and a
/// dangling deeper link should not 500 a write that would not extend it.
func checkParentChain(userId: in String, startId: in String, forbiddenId: in String): Result[Unit, Web.ApiError] {
  var cur = startId
  var depth = 0
  while cur.length > 0 {
    if forbiddenId.length > 0 and cur == forbiddenId {
      return Err(Web.badRequest("parentId must not be the group itself or one of its descendants"))
    }
    depth = depth + 1
    if depth > maxGroupDepth {
      return Err(Web.badRequest("parent chain too deep"))
    }
    val next = match CloudAgents.Repository.getSessionGroup(cur, userId) {
      case Ok(Some(g)) -> g.parentId
      case Ok(None) -> ""
      case Err(e) -> return Err(dbError(e))
    }
    cur = next
  }
  return Ok(())
}

/// Shared name/parent validation for create and update. `selfId` is "" on
/// create (no cycle possible yet) and the group's own id on update. The
/// parent, when non-empty, must exist and be owned — 404, indistinguishable
/// from absent, like every other owner-scoped lookup in this codebase.
func validateGroupWrite(userId: in String, req: in SaveGroupRequest, selfId: in String): Result[Unit, Web.ApiError] {
  if req.name.trim().length == 0 {
    return Err(Web.badRequest("name is required"))
  }
  if not CloudAgents.Text.withinMaxLength(req.name, maxGroupNameLen) {
    return Err(Web.badRequest("name is too long (max " + toString(maxGroupNameLen) + " characters)"))
  }
  if req.parentId.length > 0 {
    if selfId.length > 0 and req.parentId == selfId {
      return Err(Web.badRequest("parentId must not be the group itself or one of its descendants"))
    }
    match CloudAgents.Repository.getSessionGroup(req.parentId, userId) {
      case Ok(Some(_)) -> ()
      case Ok(None) -> return Err(Web.notFound("Group not found"))
      case Err(e) -> return Err(dbError(e))
    }
    checkParentChain(userId, req.parentId, selfId)?
  }
  return Ok(())
}

/// GET /api/groups — the caller's groups, alphabetical by name.
pub func listGroupsHandler(): Result[CloudAgents.Repository.SessionGroupList, Web.ApiError] {
  match CloudAgents.Repository.listSessionGroups(CloudAgents.Auth.currentUserId()) {
    // Constructed unqualified — package-qualified record construction
    // compiles but dies at runtime (docs/lyric/gotchas.md).
    case Ok(gs) -> return Ok(SessionGroupList(groups = gs))
    case Err(e) -> return Err(dbError(e))
  }
}

/// POST /api/groups — create a group. 200 with the stored group object.
pub func createGroupHandler(req: in SaveGroupRequest): Result[CloudAgents.Repository.SessionGroup, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  validateGroupWrite(userId, req, "")?
  match CloudAgents.Repository.addSessionGroup(userId, req.name.trim(), req.parentId) {
    case Ok(g) -> return Ok(g)
    case Err(e) -> return Err(dbError(e))
  }
}

/// POST /api/groups/{gid} — full update (name AND parentId both apply; there
/// is no PATCH verb in this router). 200 with the updated group object.
pub func updateGroupHandler(gid: in String, req: in SaveGroupRequest): Result[CloudAgents.Repository.SessionGroup, Web.ApiError] {
  if gid.length == 0 {
    return Err(Web.badRequest("group id is required"))
  }
  val userId = CloudAgents.Auth.currentUserId()
  match CloudAgents.Repository.getSessionGroup(gid, userId) {
    case Ok(Some(_)) -> ()
    case Ok(None) -> return Err(Web.notFound("Group not found"))
    case Err(e) -> return Err(dbError(e))
  }
  validateGroupWrite(userId, req, gid)?
  val affected = match CloudAgents.Repository.updateSessionGroup(gid, userId, req.name.trim(), req.parentId) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("Group not found"))
  }
  match CloudAgents.Repository.getSessionGroup(gid, userId) {
    case Ok(Some(g)) -> return Ok(g)
    case Ok(None) -> return Err(Web.notFound("Group not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

/// DELETE /api/groups/{gid} — 204. Child groups are reparented to the
/// deleted group's own parent and its sessions reassigned the same way, all
/// in one transaction (CloudAgents.Repository.deleteSessionGroupReparenting).
pub func deleteGroupHandler(gid: in String): Result[Unit, Web.ApiError] {
  if gid.length == 0 {
    return Err(Web.badRequest("group id is required"))
  }
  val userId = CloudAgents.Auth.currentUserId()
  val existing = match CloudAgents.Repository.getSessionGroup(gid, userId) {
    case Ok(Some(g)) -> g
    case Ok(None) -> return Err(Web.notFound("Group not found"))
    case Err(e) -> return Err(dbError(e))
  }
  match CloudAgents.Repository.deleteSessionGroupReparenting(gid, userId, existing.parentId) {
    case Ok(_) -> return Ok(())
    case Err(e) -> return Err(dbError(e))
  }
}

/// POST /api/sessions/{id}/group — file a session under a group ("" clears).
/// 404 for an unknown/foreign session or group; 204 on success.
pub func setSessionGroupHandler(id: in String, req: in SetSessionGroupRequest): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  requireOwnedSession(id)?
  if req.groupId.length > 0 {
    match CloudAgents.Repository.getSessionGroup(req.groupId, CloudAgents.Auth.currentUserId()) {
      case Ok(Some(_)) -> ()
      case Ok(None) -> return Err(Web.notFound("Group not found"))
      case Err(e) -> return Err(dbError(e))
    }
  }
  match CloudAgents.SessionStore.setSessionGroup(id, req.groupId) {
    case Ok(_) -> return Ok(())
    case Err(e) -> return Err(dbError(e))
  }
}

/// POST /api/sessions/{id}/viewed — stamp "the user looked at this session
/// just now" (empty body by design — the route adapter never JSON-decodes).
/// 404 unknown/foreign session; 204 on success.
pub func markSessionViewedHandler(id: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  requireOwnedSession(id)?
  match CloudAgents.SessionStore.markSessionViewed(id) {
    case Ok(_) -> return Ok(())
    case Err(e) -> return Err(dbError(e))
  }
}
