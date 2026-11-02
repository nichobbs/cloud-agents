//! HTTP handlers for organisations (docs/phase11-postgres-tenancy.md §6.3,
//! §6.4): list the caller's organisations, create a native organisation,
//! manage its members and invitations, and accept an invitation. Storage and
//! authorisation live in CloudAgents.PgStore.Orgs; these handlers read the
//! caller's identity once at entry and shape the JSON.
package CloudAgents.Orgs

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Scope
import CloudAgents.Streaming
import CloudAgents.PgStore.Orgs
import CloudAgents.Pg
import CloudAgents.Repository
import CloudAgents.Db

@generate(Json)
pub record CreateOrgRequest {
  pub name: String
}

@generate(Json)
pub record SetRoleRequest {
  pub role: String
}

@generate(Json)
pub record CreateInvitationRequest {
  pub githubLogin: String
  pub role: String
}

@generate(Json)
pub record SetGraphIngestTokenRequest {
  pub token: String
}

@generate(Json)
pub record AcceptInvitationRequest {
  pub token: String
}

pub func apiErrorOf(f: in CloudAgents.PgStore.Orgs.OrgFailure): Web.ApiError {
  return match f {
    case Db(e) -> {
      println("ERROR: organisation store: " + CloudAgents.PgStore.Orgs.orgFailureMessage(f))
      Web.internalError("database unavailable")
    }
    case Forbidden(m) -> Web.forbidden(m)
    case NotFound(m) -> Web.notFound(m)
    case Invalid(m) -> Web.badRequest(m)
    case Conflict(m) -> Web.conflict(m)
  }
}

func str(s: in String): String {
  return "\"" + CloudAgents.Streaming.jsonEscape(s) + "\""
}

func boolJson(b: in Bool): String {
  return if b { "true" } else { "false" }
}

pub func orgJson(o: in CloudAgents.PgStore.Orgs.Org): String {
  return "{\"id\":" + str(o.id) + ",\"name\":" + str(o.name) + ",\"kind\":" + str(o.kind) + ",\"role\":" + str(o.role) +
    ",\"source\":" +
    str(o.source) +
    ",\"suspended\":" +
    boolJson(o.suspended) +
    "}"
}

func memberJson(m: in CloudAgents.PgStore.Orgs.Member): String {
  return "{\"userId\":" + str(m.userId) + ",\"githubLogin\":" + str(m.githubLogin) + ",\"role\":" + str(m.role) +
    ",\"source\":" +
    str(m.source) +
    ",\"suspended\":" +
    boolJson(m.suspended) +
    "}"
}

func invitationJson(i: in CloudAgents.PgStore.Orgs.Invitation): String {
  return "{\"id\":" + str(i.id) + ",\"githubLogin\":" + str(i.githubLogin) + ",\"role\":" + str(i.role) +
    ",\"createdAt\":" +
    str(i.createdAt) +
    ",\"expiresAt\":" +
    str(i.expiresAt) +
    "}"
}

func commaJoin(parts: in slice[String]): String {
  var acc = ""
  var first = true
  for p in parts {
    if not first {
      acc = acc + ","
    }
    acc = acc + p
    first = false
  }
  return acc
}

func okJson(): String {
  return "{\"ok\":true}"
}

/// `GET /api/orgs`: the caller's organisations, personal first.
pub func listOrgsHandler(): Result[String, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  val orgs = match CloudAgents.PgStore.Orgs.listOrgs(userId) {
    case Ok(v) -> v
    case Err(f) -> return Err(apiErrorOf(f))
  }
  var parts: slice[String] = []
  for o in orgs {
    parts = parts.append(orgJson(o))
  }
  return Ok(
    value = "{\"personal\":" + str(CloudAgents.Scope.personalTenantId(userId)) + ",\"orgs\":[" + commaJoin(parts) +
      "]}"
  )
}

/// `POST /api/orgs`: create a native organisation owned by the caller.
pub func createOrgHandler(req: in CreateOrgRequest): Result[String, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  return match CloudAgents.PgStore.Orgs.createNativeOrg(userId, req.name) {
    case Ok(o) -> Ok(value = "{\"org\":" + orgJson(o) + "}")
    case Err(f) -> Err(apiErrorOf(f))
  }
}

/// `GET /api/orgs/{id}/members`.
pub func listMembersHandler(orgId: in String): Result[String, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  val members = match CloudAgents.PgStore.Orgs.listMembers(userId, orgId) {
    case Ok(v) -> v
    case Err(f) -> return Err(apiErrorOf(f))
  }
  var parts: slice[String] = []
  for m in members {
    parts = parts.append(memberJson(m))
  }
  return Ok(value = "{\"members\":[" + commaJoin(parts) + "]}")
}

/// `POST /api/orgs/{id}/members/{userId}`: change a member's role.
pub func setRoleHandler(orgId: in String, targetId: in String, req: in SetRoleRequest): Result[String, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  return match CloudAgents.PgStore.Orgs.setMemberRole(userId, orgId, targetId, req.role) {
    case Ok(_) -> Ok(value = okJson())
    case Err(f) -> Err(apiErrorOf(f))
  }
}

/// `DELETE /api/orgs/{id}/members/{userId}`: remove a member, or leave.
pub func removeMemberHandler(orgId: in String, targetId: in String): Result[String, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  return match CloudAgents.PgStore.Orgs.removeMember(userId, orgId, targetId) {
    case Ok(_) -> Ok(value = okJson())
    case Err(f) -> Err(apiErrorOf(f))
  }
}

/// `POST /api/orgs/{id}/invitations`. The token is in this response only.
pub func createInvitationHandler(orgId: in String, req: in CreateInvitationRequest): Result[String, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  return match CloudAgents.PgStore.Orgs.createInvitation(userId, orgId, req.githubLogin.trim(), req.role) {
    case Ok(c) -> Ok(
      value = "{\"invitation\":" + invitationJson(c.invitation) + ",\"token\":" + str(c.token) +
        "}"
    )
    case Err(f) -> Err(apiErrorOf(f))
  }
}

/// `GET /api/orgs/{id}/invitations`: pending invitations.
pub func listInvitationsHandler(orgId: in String): Result[String, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  val invs = match CloudAgents.PgStore.Orgs.listInvitations(userId, orgId) {
    case Ok(v) -> v
    case Err(f) -> return Err(apiErrorOf(f))
  }
  var parts: slice[String] = []
  for i in invs {
    parts = parts.append(invitationJson(i))
  }
  return Ok(value = "{\"invitations\":[" + commaJoin(parts) + "]}")
}

/// `DELETE /api/orgs/{id}/invitations/{invitationId}`.
pub func revokeInvitationHandler(orgId: in String, invitationId: in String): Result[String, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  return match CloudAgents.PgStore.Orgs.revokeInvitation(userId, orgId, invitationId) {
    case Ok(_) -> Ok(value = okJson())
    case Err(f) -> Err(apiErrorOf(f))
  }
}

/// `POST /api/invitations/accept`.
pub func acceptInvitationHandler(req: in AcceptInvitationRequest): Result[String, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  return match CloudAgents.PgStore.Orgs.acceptInvitation(userId, req.token.trim()) {
    case Ok(o) -> Ok(value = "{\"org\":" + orgJson(o) + "}")
    case Err(f) -> Err(apiErrorOf(f))
  }
}

/// Largest accepted graph-ingest token (an opaque bearer; cloud-agents does not interpret it).
pub val maxGraphIngestTokenLen = 4096

/// The scope an owner/admin acts under on `orgId`'s graph-ingest token, or the failure.
func graphIngestScope(orgId: in String): Result[CloudAgents.Pg.TenantScope, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  match CloudAgents.PgStore.Orgs.requireGraphIngestManager(userId, orgId) {
    case Ok(_) -> ()
    case Err(f) -> return Err(apiErrorOf(f))
  }
  return Ok(value = CloudAgents.Pg.TenantScope(tenantId = orgId, userId = userId))
}

func graphIngestStatusJson(updatedAt: in Option[String]): String {
  return match updatedAt {
    case Some(t) -> "{\"configured\":true,\"updatedAt\":" + str(t) + "}"
    case None -> "{\"configured\":false}"
  }
}

/// `GET /api/orgs/{id}/graph-ingest-token`: whether a token is set. Owner/admin
/// only. The token itself is never returned.
pub func getGraphIngestTokenHandler(orgId: in String): Result[String, Web.ApiError] {
  val sc = graphIngestScope(orgId)?
  return match CloudAgents.Repository.tenantGraphIngestTokenStatus(sc) {
    case Ok(s) -> Ok(value = graphIngestStatusJson(s))
    case Err(e) -> {
      println("ERROR: graph ingest token status: " + CloudAgents.Db.dbErrorMessage(e))
      Err(Web.internalError("database unavailable"))
    }
  }
}

/// `POST /api/orgs/{id}/graph-ingest-token`: set or replace the token (encrypted
/// at rest). Owner/admin only; the response never echoes it.
pub func setGraphIngestTokenHandler(orgId: in String, req: in SetGraphIngestTokenRequest): Result[String, Web.ApiError] {
  val sc = graphIngestScope(orgId)?
  val token = req.token.trim()
  if token.length == 0 {
    return Err(Web.badRequest("token is required"))
  }
  if token.length > maxGraphIngestTokenLen {
    return Err(Web.badRequest("token is too long (max 4096 characters)"))
  }
  match CloudAgents.Repository.putTenantGraphIngestToken(token, sc) {
    case Ok(_) -> ()
    case Err(e) -> {
      println("ERROR: graph ingest token store: " + CloudAgents.Repository.credentialErrorMessage(e))
      return Err(Web.internalError("failed to store the graph ingest token"))
    }
  }
  return getGraphIngestTokenHandler(orgId)
}

/// `DELETE /api/orgs/{id}/graph-ingest-token`: clear it (the env fallback then applies).
pub func clearGraphIngestTokenHandler(orgId: in String): Result[String, Web.ApiError] {
  val sc = graphIngestScope(orgId)?
  return match CloudAgents.Repository.deleteTenantGraphIngestToken(sc) {
    case Ok(_) -> Ok(value = okJson())
    case Err(e) -> {
      println("ERROR: graph ingest token clear: " + CloudAgents.Db.dbErrorMessage(e))
      Err(Web.internalError("database unavailable"))
    }
  }
}
