//! GitHub-synced organisations (docs/phase11-postgres-tenancy.md §6.2):
//! connecting a GitHub organisation, reconciling a user's memberships at
//! sign-in, and the operator-polled hourly re-check
//! (`POST /api/maintenance/membership-sync`).
//!
//! GitHub is the authority for `github`-sourced memberships. A failure to
//! reach GitHub keeps the existing rows (and never touches the personal
//! organisation); a token GitHub rejects suspends them until the user signs
//! in again, which bounds a removed member's access by the sync interval.
package CloudAgents.OrgSync

import Std.Core
import Std.Json
import Web
import CloudAgents.Auth
import CloudAgents.GitHubApi
import CloudAgents.OAuth
import CloudAgents.Orgs
import CloudAgents.PgStore.Orgs
import CloudAgents.Db
import CloudAgents.Streaming

@generate(Json)
pub record ConnectGitHubOrgRequest {
  pub githubOrg: String
}

/// Users re-checked per sweep, and how long each is leased.
val usersPerSweep = 50

val syncLeaseSeconds = 300

/// GitHub pages of 100 memberships; a user in more organisations than this
/// is reconciled against the first 1000.
val maxPages = 10

val kindObject = 1

val kindArray = 2

val kindString = 3

val kindNumber = 4

func apiBase(): String {
  return "https://api.github.com"
}

func stringProp(el: in JsonElement, name: in String): String {
  return match Std.Json.tryGetProperty(el, name) {
    case Some(v) -> if Std.Json.valueKind(v) == kindString { Std.Json.getString(v) } else { "" }
    case _ -> ""
  }
}

func numberProp(el: in JsonElement, name: in String): String {
  return match Std.Json.tryGetProperty(el, name) {
    case Some(v) -> if Std.Json.valueKind(v) == kindNumber { Std.Json.getRawText(v) } else { "" }
    case _ -> ""
  }
}

/// One membership object (`GET /user/memberships/orgs[/{org}]`), or None
/// when it is not an active membership with an organisation id and login.
func membershipOf(el: in JsonElement): Option[CloudAgents.PgStore.Orgs.GitHubOrgMembership] {
  if Std.Json.valueKind(el) != kindObject or stringProp(el, "state") != "active" {
    return None
  }
  return match Std.Json.tryGetProperty(el, "organization") {
    case Some(org) -> {
      val id = numberProp(org, "id")
      val login = stringProp(org, "login")
      if id.length == 0 or login.length == 0 {
        None
      } else {
        Some(
          value = CloudAgents.PgStore.Orgs.GitHubOrgMembership(orgId = id, orgLogin = login, role = stringProp(el, "role"))
        )
      }
    }
    case _ -> None
  }
}

/// Parse one page of `GET /user/memberships/orgs`: the active memberships,
/// and how many entries the page held (to know whether another page exists).
pub record MembershipPage {
  pub items: slice[CloudAgents.PgStore.Orgs.GitHubOrgMembership]
  pub count: Int
}

pub func parseMembershipPage(body: in String): Result[MembershipPage, String] {
  val doc = match Std.Json.tryParseJson(body) {
    case Ok(d) -> d
    case Err(_) -> return Err(error = "unexpected GitHub memberships response")
  }
  defer {
    Std.Json.disposeJson(doc)
  }
  return try {
    val root = Std.Json.rootElement(doc)
    if Std.Json.valueKind(root) != kindArray {
      Err(error = "unexpected GitHub memberships response")
    } else {
      var acc: slice[CloudAgents.PgStore.Orgs.GitHubOrgMembership] = []
      var count = 0
      var cur = Std.Json.enumerateArray(root)
      while Std.Json.arrayMoveNext(cur) {
        count = count + 1
        match membershipOf(Std.Json.arrayCurrent(cur)) {
          case Some(m) -> {
            acc = acc.append(m)
          }
          case None -> ()
        }
      }
      Ok(value = MembershipPage(items = acc, count = count))
    }
  } catch Bug as b {
    Err(error = "unreadable GitHub memberships response")
  }
}

/// Parse `GET /user/memberships/orgs/{org}`.
pub func parseSingleMembership(body: in String): Option[CloudAgents.PgStore.Orgs.GitHubOrgMembership] {
  val doc = match Std.Json.tryParseJson(body) { case Ok(d) -> d; case Err(_) -> return None }
  defer {
    Std.Json.disposeJson(doc)
  }
  return try {
    membershipOf(Std.Json.rootElement(doc))
  } catch Bug as b {
    None
  }
}

/// Every active GitHub organisation membership of the token's user.
pub func fetchMemberships(token: in String): Result[slice[CloudAgents.PgStore.Orgs.GitHubOrgMembership], String] {
  var acc: slice[CloudAgents.PgStore.Orgs.GitHubOrgMembership] = []
  var page = 1
  while page <= maxPages {
    val body = CloudAgents.GitHubApi.httpGetWithBearer(apiBase() + "/user/memberships/orgs?state=active&per_page=100&page=" + toString(page), token, CloudAgents.OAuth.userAgent())?
    val parsed = parseMembershipPage(body)?
    for m in parsed.items {
      acc = acc.append(m)
    }
    if parsed.count < 100 {
      return Ok(value = acc)
    }
    page = page + 1
  }
  return Ok(value = acc)
}

/// Whether a GitHub call failed because the token was refused: revoked,
/// expired, or missing `read:org`.
pub func isTokenRefusal(errorText: in String): Bool {
  return CloudAgents.OAuth.isConfirmedAuthRejection(errorText) or errorText.contains("(404)")
}

/// Reconcile at sign-in with the token just issued (spec §6.2). Best-effort:
/// a failure is logged and never fails the sign-in.
pub func syncAtSignIn(userId: in String, token: in String): Unit {
  match fetchMemberships(token) {
    case Ok(ms) -> match CloudAgents.PgStore.Orgs.reconcileGitHubMemberships(userId, ms) {
      case Ok(_) -> ()
      case Err(e) -> println(
        "NOTE: could not reconcile GitHub organisations for " + userId + ": " +
          CloudAgents.Db.dbErrorMessage(e)
      )
    }
    case Err(e) -> println("NOTE: could not read GitHub organisation memberships for " + userId + ": " + e)
  }
}

/// `POST /api/orgs/github`: connect a GitHub organisation. Only an admin of
/// that organisation (checked with the caller's own vaulted token) may.
pub func connectGitHubOrgHandler(req: in ConnectGitHubOrgRequest): Result[String, Web.ApiError] {
  val userId = CloudAgents.Auth.currentUserId()
  val orgLogin = req.githubOrg.trim()
  if not CloudAgents.PgStore.Orgs.isValidGitHubLogin(orgLogin) {
    return Err(Web.badRequest("githubOrg is not a valid GitHub organisation login"))
  }
  val token = CloudAgents.OAuth.ensureFreshGitHubToken(userId)?
  val body = match CloudAgents.GitHubApi.httpGetWithBearer(apiBase() + "/user/memberships/orgs/" + orgLogin, token, CloudAgents.OAuth.userAgent()) {
    case Ok(b) -> b
    case Err(e) -> {
      if isTokenRefusal(e) {
        return Err(
          Web.forbidden(
            "GitHub did not confirm your membership of " + orgLogin +
              "; check the name, and sign in again if your token lacks the read:org scope"
          )
        )
      }
      println("WARNING: GitHub membership check for " + orgLogin + " failed: " + e)
      return Err(Web.internalError("could not check the organisation with GitHub"))
    }
  }
  val m = match parseSingleMembership(body) {
    case Some(v) -> v
    case None -> return Err(Web.forbidden("you are not an active member of the GitHub organisation " + orgLogin))
  }
  if m.role != "admin" {
    return Err(Web.forbidden("only an admin of the GitHub organisation " + orgLogin + " can connect it"))
  }
  return match CloudAgents.PgStore.Orgs.connectGitHubOrg(userId, m.orgId, m.orgLogin) {
    case Ok(o) -> Ok(value = "{\"org\":" + CloudAgents.Orgs.orgJson(o) + "}")
    case Err(f) -> Err(CloudAgents.Orgs.apiErrorOf(f))
  }
}

/// What happened to one claimed user.
pub enum SyncResult {
  case UserSynced
  case UserSuspended
  case UserSyncFailed
}

/// Re-check one claimed user against GitHub with their vaulted token.
pub func syncUser(userId: in String): SyncResult {
  val token = match CloudAgents.OAuth.ensureFreshGitHubToken(userId) {
    case Ok(t) -> t
    case Err(e) -> {
      // No vaulted token, or a refresh token GitHub no longer honours: the
      // user must sign in again.
      if e.status == 401 or e.status == 404 {
        return suspend(userId)
      }
      return UserSyncFailed
    }
  }
  match fetchMemberships(token) {
    case Ok(ms) -> match CloudAgents.PgStore.Orgs.reconcileGitHubMemberships(userId, ms) {
      case Ok(_) -> return UserSynced
      case Err(e) -> {
        println("WARNING: membership sync for " + userId + ": " + CloudAgents.Db.dbErrorMessage(e))
        return UserSyncFailed
      }
    }
    case Err(e) -> {
      if isTokenRefusal(e) {
        return suspend(userId)
      }
      // GitHub unreachable: keep the rows; the lease lapses and a later
      // sweep retries.
      println("WARNING: membership sync for " + userId + " could not reach GitHub: " + e)
      return UserSyncFailed
    }
  }
}

func suspend(userId: in String): SyncResult {
  return match CloudAgents.PgStore.Orgs.suspendGitHubMemberships(userId) {
    case Ok(_) -> UserSuspended
    case Err(e) -> {
      println("WARNING: suspending GitHub memberships of " + userId + ": " + CloudAgents.Db.dbErrorMessage(e))
      UserSyncFailed
    }
  }
}

/// `POST /api/maintenance/membership-sync` (operator only): re-check the
/// users whose GitHub memberships are over an hour old.
pub func membershipSyncHandler(): Result[String, Web.ApiError] {
  if CloudAgents.Auth.currentUserId() != CloudAgents.Auth.operatorUserId() {
    return Err(Web.unauthorized("the membership sync may only be triggered by the operator identity"))
  }
  val users = match CloudAgents.PgStore.Orgs.claimMembershipSync(usersPerSweep, syncLeaseSeconds) {
    case Ok(v) -> v
    case Err(e) -> return Err(Web.internalError("failed to claim users for membership sync: " + CloudAgents.Db.dbErrorMessage(e)))
  }
  var synced = 0
  var suspended = 0
  var failed = 0
  for userId in users {
    match syncUser(userId) {
      case UserSynced -> {
        synced = synced + 1
      }
      case UserSuspended -> {
        suspended = suspended + 1
      }
      case UserSyncFailed -> {
        failed = failed + 1
      }
    }
  }
  return Ok(
    value = "{\"synced\":" + toString(synced) + ",\"suspended\":" + toString(suspended) + ",\"failed\":" +
      toString(failed) +
      "}"
  )
}
