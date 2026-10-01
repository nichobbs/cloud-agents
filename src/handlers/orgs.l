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
