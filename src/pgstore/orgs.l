//! CloudAgents.PgStore.Orgs — organisations, memberships and invitations
//! (docs/phase11-postgres-tenancy.md §6.1, §6.3, §6.4).
//!
//! `tenants`, `memberships`, `invitations` and `users` are global tables
//! (spec §4.2): they are read before a tenant is chosen, so they have no
//! row-level security and every unit here is unscoped. Authorisation is
//! therefore enforced by this package, in SQL, against the caller's own
//! membership row: a caller acts only on organisations they are an active
//! member of, and only owners change roles or remove other members.
//!
//! Changes that could remove an organisation's last owner lock the tenant
//! row first (`SELECT ... FOR UPDATE`), so two concurrent demotions cannot
//! both see "another owner remains".
@runtime_checked
package CloudAgents.PgStore.Orgs

import Std.Core
import Std.Uuid
import Db
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Db
import CloudAgents.Crypto
import CloudAgents.Scope

/// Why an organisation operation was refused. `Db` carries a store failure;
/// the others carry a message fit to show the caller.
pub union OrgFailure {
  case Db(error: CloudAgents.Db.DbError)
  case Forbidden(message: String)
  case NotFound(message: String)
  case Invalid(message: String)
  case Conflict(message: String)
}

pub func orgFailureMessage(f: in OrgFailure): String {
  return match f {
    case Db(e) -> CloudAgents.Db.dbErrorMessage(e)
    case Forbidden(m) -> m
    case NotFound(m) -> m
    case Invalid(m) -> m
    case Conflict(m) -> m
  }
}

/// One of the caller's organisations, with the caller's membership in it.
pub record Org {
  pub id: String
  pub name: String
  pub kind: String
  pub role: String
  pub source: String
  pub suspended: Bool
}

pub record Member {
  pub userId: String
  pub githubLogin: String
  pub role: String
  pub source: String
  pub suspended: Bool
}

/// A pending invitation. Times are epoch-millisecond text.
pub record Invitation {
  pub id: String
  pub tenantId: String
  pub githubLogin: String
  pub role: String
  pub createdAt: String
  pub expiresAt: String
}

/// A newly created invitation and its single-use token. Only the token's
/// hash is stored, so this is the one time the token is available.
pub record CreatedInvitation {
  pub invitation: Invitation
  pub token: String
}

/// How long an invitation can be accepted.
pub val invitationTtlDays = 7

pub val maxOrgNameLen = 100

// ─── Unit-of-work wrappers with OrgFailure errors ──────────────────────────
func openU(): Result[CloudAgents.PgStore.PgUnit, OrgFailure] {
  return match CloudAgents.PgStore.openUnscoped() {
    case Ok(u) -> Ok(value = u)
    case Err(e) -> Err(error = Db(error = e))
  }
}

func qo(u: in CloudAgents.PgStore.PgUnit, sql: in String, params: in slice[String]): Result[slice[DbRow], OrgFailure] {
  return match CloudAgents.PgStore.q(u, sql, params) {
    case Ok(r) -> Ok(value = r)
    case Err(e) -> Err(error = Db(error = e))
  }
}

func exo(u: in CloudAgents.PgStore.PgUnit, sql: in String, params: in slice[String]): Result[Int, OrgFailure] {
  return match CloudAgents.PgStore.ex(u, sql, params) {
    case Ok(n) -> Ok(value = n)
    case Err(e) -> Err(error = Db(error = e))
  }
}

func commitO(u: in CloudAgents.PgStore.PgUnit): Result[Unit, OrgFailure] {
  return match CloudAgents.PgStore.commit(u) { case Ok(_) -> Ok(value = ()); case Err(e) -> Err(error = Db(error = e)) }
}

func col(r: in DbRow, name: in String): String {
  return CloudAgents.PgStore.col(r, name)
}

func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

// ─── Validation ─────────────────────────────────────────────────────────────
pub func isValidRole(role: in String): Bool {
  return role == "owner" or role == "admin" or role == "member"
}

/// A GitHub login: 1 to 39 letters, digits or single inner hyphens.
pub func isValidGitHubLogin(login: in String): Bool {
  if login.length == 0 or login.length > 39 {
    return false
  }
  if login.startsWith("-") or login.endsWith("-") {
    return false
  }
  var i = 0
  var prevHyphen = false
  while i < login.length {
    val c = login.substring(i, 1)
    val isAlnum = (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")
    if c == "-" {
      if prevHyphen {
        return false
      }
      prevHyphen = true
    } else if isAlnum {
      prevHyphen = false
    } else {
      return false
    }
    i = i + 1
  }
  return true
}

/// The hash stored for an invitation token.
pub func hashInvitationToken(token: in String): String {
  return CloudAgents.Crypto.sha256Base64("invitation:" + token)
}

func roleRank(role: in String): Int {
  if role == "owner" {
    return 3
  }
  if role == "admin" {
    return 2
  }
  if role == "member" {
    return 1
  }
  return 0
}

// ─── Reads ──────────────────────────────────────────────────────────────────
func orgCols(): String {
  return "t.id AS id, t.name AS name, t.kind AS kind, m.role AS role, m.source AS source, " +
    "m.suspended::text AS suspended"
}

func toOrg(r: in DbRow): Org {
  return Org(
    id = col(r, "id"),
    name = col(r, "name"),
    kind = col(r, "kind"),
    role = col(r, "role"),
    source = col(r, "source"),
    suspended = col(r, "suspended") == "true"
  )
}

/// The caller's active (not suspended) role in `tenantId`, or "" when they
/// are not an active member.
func activeRole(u: in CloudAgents.PgStore.PgUnit, tenantId: in String, userId: in String): Result[String, OrgFailure] {
  val rows = qo(u, "SELECT role FROM memberships WHERE tenant_id = @p0 AND user_id = @p1 AND NOT suspended", [tenantId, userId])?
  if rows.length == 0 {
    return Ok(value = "")
  }
  return Ok(value = col(rows[0], "role"))
}

func tenantKind(u: in CloudAgents.PgStore.PgUnit, tenantId: in String, lock: in Bool): Result[String, OrgFailure] {
  val sql = if lock {
    "SELECT kind FROM tenants WHERE id = @p0 FOR UPDATE"
  } else {
    "SELECT kind FROM tenants WHERE id = @p0"
  }
  val rows = qo(u, sql, [tenantId])?
  if rows.length == 0 {
    return Ok(value = "")
  }
  return Ok(value = col(rows[0], "kind"))
}

/// Whether `userId` may act in `tenantId`: an active membership exists. The
/// auth middleware calls this for the `X-CloudAgents-Org` header (spec §5.2).
pub func isActiveMember(userId: in String, tenantId: in String): Result[Bool, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT 1 AS one FROM memberships WHERE tenant_id = @p0 AND user_id = @p1 AND NOT suspended", [tenantId, userId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = rows.length > 0)
}

/// Every organisation the user belongs to, the personal one first, then by
/// name. Suspended memberships are included and flagged.
pub func listOrgs(userId: in String): Result[slice[Org], OrgFailure] {
  val u = openU()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = qo(u, "SELECT " + orgCols() + " FROM memberships m JOIN tenants t ON t.id = m.tenant_id " + "WHERE m.user_id = @p0 ORDER BY (t.kind = 'personal') DESC, t.name COLLATE \"C\", t.id COLLATE \"C\"", [userId])?
  commitO(u)?
  var acc: slice[Org] = []
  for r in rows {
    acc = acc.append(toOrg(r))
  }
  return Ok(value = acc)
}

func orgFor(u: in CloudAgents.PgStore.PgUnit, tenantId: in String, userId: in String): Result[Org, OrgFailure] {
  val rows = qo(u, "SELECT " + orgCols() + " FROM memberships m JOIN tenants t ON t.id = m.tenant_id " + "WHERE m.tenant_id = @p0 AND m.user_id = @p1", [tenantId, userId])?
  if rows.length == 0 {
    return Err(error = NotFound(message = "organisation not found"))
  }
  return Ok(value = toOrg(rows[0]))
}

/// The members of `tenantId`, readable by any active member.
pub func listMembers(callerId: in String, tenantId: in String): Result[slice[Member], OrgFailure] {
  val u = openU()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val role = activeRole(u, tenantId, callerId)?
  if role.length == 0 {
    return Err(error = NotFound(message = "organisation not found"))
  }
  val rows = qo(u, "SELECT m.user_id AS user_id, COALESCE(us.github_login, '') AS github_login, m.role AS role, " + "m.source AS source, m.suspended::text AS suspended FROM memberships m " + "LEFT JOIN users us ON us.id = m.user_id WHERE m.tenant_id = @p0 " + "ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, m.user_id COLLATE \"C\"", [tenantId])?
  commitO(u)?
  var acc: slice[Member] = []
  for r in rows {
    acc = acc.append(
      Member(
        userId = col(r, "user_id"),
        githubLogin = col(r, "github_login"),
        role = col(r, "role"),
        source = col(r, "source"),
        suspended = col(r, "suspended") == "true"
      )
    )
  }
  return Ok(value = acc)
}

// ─── Users ──────────────────────────────────────────────────────────────────
/// Record a user's GitHub login (spec §4.2), which invitations are matched
/// against. Creates the `users` row if this is the user's first sign-in.
pub func recordGitHubLogin(
  userId: in String, githubId: in String, login: in String
): Result[Unit, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  // GitHub logins are recycled after a rename: the newest sign-in holds the
  // login, and any other user still recorded with it loses it, so they
  // cannot accept an invitation meant for the new holder.
  if login.length > 0 {
    CloudAgents.PgStore.ex(u, "UPDATE users SET github_login = '' WHERE lower(github_login) = lower(@p1) AND id <> @p0", [userId, login])?
  }
  if githubId.length > 0 {
    CloudAgents.PgStore.ex(u, "INSERT INTO users (id, github_id, github_login) VALUES (@p0, @p1::bigint, @p2) " + "ON CONFLICT (id) DO UPDATE SET github_login = EXCLUDED.github_login", [userId, githubId, login])?
  } else {
    CloudAgents.PgStore.ex(u, "INSERT INTO users (id, github_login) VALUES (@p0, @p1) " + "ON CONFLICT (id) DO UPDATE SET github_login = EXCLUDED.github_login", [userId, login])?
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

// ─── Native organisations ───────────────────────────────────────────────────
/// Create a native organisation with the caller as its owner (spec §6.3).
/// The caller's `users` row must exist (it is created with their personal
/// tenant on their first request).
pub func createNativeOrg(callerId: in String, name: in String): Result[Org, OrgFailure] {
  val trimmed = name.trim()
  if trimmed.length == 0 {
    return Err(error = Invalid(message = "name is required"))
  }
  if trimmed.length > maxOrgNameLen {
    return Err(error = Invalid(message = "name must be at most " + toString(maxOrgNameLen) + " characters"))
  }
  val id = "native:" + newId()
  val u = openU()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  exo(u, "INSERT INTO tenants (id, name, kind) VALUES (@p0, @p1, 'native')", [id, trimmed])?
  exo(u, "INSERT INTO memberships (tenant_id, user_id, role, source) VALUES (@p0, @p1, 'owner', 'native')", [id, callerId])?
  val org = orgFor(u, id, callerId)?
  commitO(u)?
  return Ok(value = org)
}

/// Whether a tenant whose row the unit has locked has an active (not
/// suspended) owner other than `exceptUserId`.
func hasOtherOwner(
  u: in CloudAgents.PgStore.PgUnit, tenantId: in String, exceptUserId: in String
): Result[Bool, OrgFailure] {
  val rows = qo(u, "SELECT 1 AS one FROM memberships WHERE tenant_id = @p0 AND role = 'owner' AND NOT suspended AND user_id <> @p1 LIMIT 1", [tenantId, exceptUserId])?
  return Ok(value = rows.length > 0)
}

/// Lock the tenant and refuse personal organisations, whose single member
/// cannot be changed.
func lockManagedTenant(u: in CloudAgents.PgStore.PgUnit, tenantId: in String): Result[Unit, OrgFailure] {
  val kind = tenantKind(u, tenantId, true)?
  if kind.length == 0 {
    return Err(error = NotFound(message = "organisation not found"))
  }
  if kind == "personal" {
    return Err(error = Invalid(message = "a personal organisation has no other members to manage"))
  }
  return Ok(value = ())
}

/// Change a member's role. Owners only; the last owner cannot be demoted.
pub func setMemberRole(
  callerId: in String, tenantId: in String, targetId: in String, role: in String
): Result[Unit, OrgFailure] {
  if not isValidRole(role) {
    return Err(error = Invalid(message = "role must be owner, admin or member"))
  }
  val u = openU()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  // Lock before reading the caller's role, so a concurrent change to it
  // cannot slip in between the check and the write.
  lockManagedTenant(u, tenantId)?
  val callerRole = activeRole(u, tenantId, callerId)?
  if callerRole.length == 0 {
    return Err(error = NotFound(message = "organisation not found"))
  }
  if callerRole != "owner" {
    return Err(error = Forbidden(message = "only an owner can change roles"))
  }
  val rows = qo(u, "SELECT role FROM memberships WHERE tenant_id = @p0 AND user_id = @p1", [tenantId, targetId])?
  if rows.length == 0 {
    return Err(error = NotFound(message = "member not found"))
  }
  if col(rows[0], "role") == "owner" and role != "owner" {
    val another = hasOtherOwner(u, tenantId, targetId)?
    if not another {
      return Err(error = Conflict(message = "the last owner cannot be demoted; make another member an owner first"))
    }
  }
  exo(u, "UPDATE memberships SET role = @p2 WHERE tenant_id = @p0 AND user_id = @p1", [tenantId, targetId, role])?
  commitO(u)?
  return Ok(value = ())
}

/// Remove a member. Owners may remove anyone; any member may remove
/// themselves (leave). The last owner cannot be removed.
pub func removeMember(callerId: in String, tenantId: in String, targetId: in String): Result[Unit, OrgFailure] {
  val u = openU()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  lockManagedTenant(u, tenantId)?
  val callerRole = activeRole(u, tenantId, callerId)?
  // A suspended member may still leave; everything else needs an active role.
  if callerRole.length == 0 and callerId != targetId {
    return Err(error = NotFound(message = "organisation not found"))
  }
  if callerRole != "owner" and callerId != targetId {
    return Err(error = Forbidden(message = "only an owner can remove other members"))
  }
  val rows = qo(u, "SELECT role FROM memberships WHERE tenant_id = @p0 AND user_id = @p1", [tenantId, targetId])?
  if rows.length == 0 {
    return Err(error = NotFound(message = "member not found"))
  }
  if col(rows[0], "role") == "owner" {
    val another = hasOtherOwner(u, tenantId, targetId)?
    if not another {
      return Err(
        error = Conflict(message = "the last owner cannot leave or be removed; make another member an owner first")
      )
    }
  }
  exo(u, "DELETE FROM memberships WHERE tenant_id = @p0 AND user_id = @p1", [tenantId, targetId])?
  commitO(u)?
  return Ok(value = ())
}

// ─── Invitations ────────────────────────────────────────────────────────────
func invitationCols(): String {
  return "id, tenant_id, github_login, role, " + CloudAgents.Pg.msOut("created_at") + " AS created_at, " +
    CloudAgents.Pg.msOut("expires_at") +
    " AS expires_at"
}

func toInvitation(r: in DbRow): Invitation {
  return Invitation(
    id = col(r, "id"),
    tenantId = col(r, "tenant_id"),
    githubLogin = col(r, "github_login"),
    role = col(r, "role"),
    createdAt = col(r, "created_at"),
    expiresAt = col(r, "expires_at")
  )
}

func requireManager(
  u: in CloudAgents.PgStore.PgUnit, tenantId: in String, callerId: in String
): Result[Unit, OrgFailure] {
  val role = activeRole(u, tenantId, callerId)?
  if role.length == 0 {
    return Err(error = NotFound(message = "organisation not found"))
  }
  val kind = tenantKind(u, tenantId, false)?
  if kind == "personal" {
    return Err(error = Invalid(message = "a personal organisation has no other members to manage"))
  }
  if role != "owner" and role != "admin" {
    return Err(error = Forbidden(message = "only an owner or admin can manage invitations"))
  }
  return Ok(value = ())
}

/// Invite a GitHub login (spec §6.3). Owners and admins; an earlier pending
/// invitation for the same login is replaced, so only the newest link works.
pub func createInvitation(
  callerId: in String, tenantId: in String, githubLogin: in String, role: in String
): Result[CreatedInvitation, OrgFailure] {
  if not isValidGitHubLogin(githubLogin) {
    return Err(error = Invalid(message = "githubLogin is not a valid GitHub login"))
  }
  if role != "admin" and role != "member" {
    return Err(error = Invalid(message = "role must be admin or member"))
  }
  val u = openU()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  requireManager(u, tenantId, callerId)?
  val token = newId() + newId()
  val id = newId()
  exo(u, "DELETE FROM invitations WHERE tenant_id = @p0 AND lower(github_login) = lower(@p1) AND accepted_at IS NULL", [tenantId, githubLogin])?
  exo(u, "INSERT INTO invitations (id, tenant_id, token_hash, github_login, role, created_by, expires_at) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, now() + @p6::integer * interval '1 day')", [id, tenantId, hashInvitationToken(token), githubLogin, role, callerId, toString(invitationTtlDays)])?
  val rows = qo(u, "SELECT " + invitationCols() + " FROM invitations WHERE id = @p0", [id])?
  commitO(u)?
  return Ok(value = CreatedInvitation(invitation = toInvitation(rows[0]), token = token))
}

/// Pending (unaccepted, unexpired) invitations of a tenant.
pub func listInvitations(callerId: in String, tenantId: in String): Result[slice[Invitation], OrgFailure] {
  val u = openU()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  requireManager(u, tenantId, callerId)?
  val rows = qo(u, "SELECT " + invitationCols() + " FROM invitations WHERE tenant_id = @p0 AND accepted_at IS NULL " + "AND expires_at > now() ORDER BY created_at, id", [tenantId])?
  commitO(u)?
  var acc: slice[Invitation] = []
  for r in rows {
    acc = acc.append(toInvitation(r))
  }
  return Ok(value = acc)
}

pub func revokeInvitation(callerId: in String, tenantId: in String, invitationId: in String): Result[Unit, OrgFailure] {
  val u = openU()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  requireManager(u, tenantId, callerId)?
  val n = exo(u, "DELETE FROM invitations WHERE id = @p0 AND tenant_id = @p1 AND accepted_at IS NULL", [invitationId, tenantId])?
  if n == 0 {
    return Err(error = NotFound(message = "invitation not found"))
  }
  commitO(u)?
  return Ok(value = ())
}

/// Accept an invitation as `callerId`. The caller's recorded GitHub login
/// must match the invited login (case-insensitively), and the invitation
/// must be unexpired and unused. An existing membership becomes native,
/// unsuspended, and keeps the higher of its role and the invited one.
pub func acceptInvitation(callerId: in String, token: in String): Result[Org, OrgFailure] {
  if token.length == 0 {
    return Err(error = Invalid(message = "token is required"))
  }
  val u = openU()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = qo(u, "SELECT id, tenant_id, github_login, role, (accepted_at IS NOT NULL)::text AS used, " + "(expires_at <= now())::text AS expired FROM invitations WHERE token_hash = @p0 FOR UPDATE", [hashInvitationToken(token)])?
  if rows.length == 0 {
    return Err(error = NotFound(message = "invitation not found"))
  }
  val inv = rows[0]
  if col(inv, "used") == "true" {
    return Err(error = Invalid(message = "this invitation has already been used"))
  }
  if col(inv, "expired") == "true" {
    return Err(error = Invalid(message = "this invitation has expired; ask for a new one"))
  }
  val matches = qo(u, "SELECT 1 AS one FROM users WHERE id = @p0 AND github_login <> '' AND lower(github_login) = lower(@p1)", [callerId, col(inv, "github_login")])?
  if matches.length == 0 {
    return Err(
      error = Forbidden(
        message = "this invitation is for GitHub user " + col(inv, "github_login") +
          "; sign in as that user to accept it"
      )
    )
  }
  val tenantId = col(inv, "tenant_id")
  val invitedRole = col(inv, "role")
  val existing = qo(u, "SELECT role FROM memberships WHERE tenant_id = @p0 AND user_id = @p1 FOR UPDATE", [tenantId, callerId])?
  if existing.length == 0 {
    exo(u, "INSERT INTO memberships (tenant_id, user_id, role, source) VALUES (@p0, @p1, @p2, 'native')", [tenantId, callerId, invitedRole])?
  } else {
    val current = col(existing[0], "role")
    val role = if roleRank(current) >= roleRank(invitedRole) { current } else { invitedRole }
    exo(u, "UPDATE memberships SET role = @p2, source = 'native', suspended = false WHERE tenant_id = @p0 AND user_id = @p1", [tenantId, callerId, role])?
  }
  exo(u, "UPDATE invitations SET accepted_at = now() WHERE id = @p0", [col(inv, "id")])?
  val org = orgFor(u, tenantId, callerId)?
  commitO(u)?
  return Ok(value = org)
}

// ─── GitHub organisations (spec §6.2) ──────────────────────────────────────
/// One GitHub organisation membership as GitHub reports it: the
/// organisation's numeric id and login, and the user's role there
/// (`admin` or `member`).
pub record GitHubOrgMembership {
  pub orgId: String
  pub orgLogin: String
  pub role: String
}

/// What one reconciliation changed.
pub record SyncOutcome {
  pub added: Int
  pub updated: Int
  pub removed: Int
}

pub func tenantIdForGitHubOrg(orgId: in String): String {
  return "github:" + orgId
}

func isDigits(s: in String): Bool {
  if s.length == 0 or s.length > 19 {
    return false
  }
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    if c < "0" or c > "9" {
      return false
    }
    i = i + 1
  }
  return true
}

/// Mark the user's sync done now and free its claim. Runs in a user unit:
/// `user_sync_state` is user-owned (spec §4.3a).
func markSynced(u: in CloudAgents.PgStore.PgUnit, userId: in String): Result[Unit, CloudAgents.Db.DbError] {
  CloudAgents.PgStore.ex(u, "INSERT INTO user_sync_state (user_id, github_synced_at, claimed_until) VALUES (@p0, now(), NULL) " + "ON CONFLICT (user_id) DO UPDATE SET github_synced_at = now(), claimed_until = NULL", [userId])?
  return Ok(value = ())
}

/// Reconcile the user's `github`-sourced memberships with what GitHub reports
/// (spec §6.2): add a membership for each reported organisation that is
/// connected, update roles (GitHub `admin` maps to `admin`, otherwise
/// `member`; an owner is never demoted), lift any suspension, and remove
/// `github` memberships of connected organisations GitHub no longer reports.
/// `native` memberships are never touched. With `complete` false (GitHub's
/// list was cut short), nothing is removed.
pub func reconcileGitHubMemberships(
  userId: in String, reported: in slice[GitHubOrgMembership], complete: in Bool
): Result[SyncOutcome, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.openUser(CloudAgents.Scope.userScope(userId))?
  defer {
    CloudAgents.PgStore.release(u)
  }
  var added = 0
  var updated = 0
  var keep = ""
  for m in reported {
    if isDigits(m.orgId) {
      keep = if keep.length == 0 { m.orgId } else { keep + "," + m.orgId }
      val role = if m.role == "admin" { "admin" } else { "member" }
      val tenants = CloudAgents.PgStore.q(u, "SELECT id FROM tenants WHERE github_org_id = @p0::bigint", [m.orgId])?
      if tenants.length > 0 {
        val tenantId = CloudAgents.PgStore.col(tenants[0], "id")
        val existing = CloudAgents.PgStore.q(u, "SELECT role, source FROM memberships WHERE tenant_id = @p0 AND user_id = @p1 FOR UPDATE", [tenantId, userId])?
        if existing.length == 0 {
          CloudAgents.PgStore.ex(u, "INSERT INTO memberships (tenant_id, user_id, role, source, synced_at) VALUES (@p0, @p1, @p2, 'github', now())", [tenantId, userId, role])?
          added = added + 1
        } else if CloudAgents.PgStore.col(existing[0], "source") == "github" {
          val current = CloudAgents.PgStore.col(existing[0], "role")
          val next = if current == "owner" { "owner" } else { role }
          val n = CloudAgents.PgStore.ex(u, "UPDATE memberships SET role = @p2, suspended = false, synced_at = now() " + "WHERE tenant_id = @p0 AND user_id = @p1 AND (role <> @p2 OR suspended)", [tenantId, userId, next])?
          CloudAgents.PgStore.ex(u, "UPDATE memberships SET synced_at = now() WHERE tenant_id = @p0 AND user_id = @p1", [tenantId, userId])?
          updated = updated + n
        }
      }
    }
  }
  // A partial list (more organisations than one fetch reads) removes
  // nothing: a membership missing from it may simply be on a later page.
  var removed = 0
  if complete {
    val n = CloudAgents.PgStore.ex(u, "DELETE FROM memberships m USING tenants t WHERE m.tenant_id = t.id AND m.user_id = @p0 " + "AND m.source = 'github' AND NOT (t.github_org_id = ANY (string_to_array(@p1, ',')::bigint[]))", [userId, keep])?
    removed = n
  }
  markSynced(u, userId)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = SyncOutcome(added = added, updated = updated, removed = removed))
}

/// Suspend the user's `github`-sourced memberships until they sign in again
/// (spec §6.2: the token was revoked or lacks `read:org`). Returns how many
/// were suspended.
pub func suspendGitHubMemberships(userId: in String): Result[Int, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.openUser(CloudAgents.Scope.userScope(userId))?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "UPDATE memberships SET suspended = true WHERE user_id = @p0 AND source = 'github' AND NOT suspended", [userId])?
  markSynced(u, userId)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

/// Users due a membership re-check (over an hour since their last sync, with
/// at least one `github` membership), each leased for `leaseSeconds` (spec
/// §6.2, §5.3).
pub func claimMembershipSync(limit: in Int, leaseSeconds: in Int): Result[slice[String], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT user_id FROM public.claim_membership_sync(@p0::integer, @p1::integer)", [toString(limit), toString(leaseSeconds)])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[String] = []
  for r in rows {
    acc = acc.append(CloudAgents.PgStore.col(r, "user_id"))
  }
  return Ok(value = acc)
}

/// Connect a GitHub organisation the caller administers (the caller has
/// already been checked against GitHub). Creates the tenant with the caller
/// as `owner`; an organisation that is already connected is refused unless
/// it has lost every owner, in which case the caller becomes its owner. A
/// caller who is already a member gets their organisation back unchanged.
pub func connectGitHubOrg(callerId: in String, orgId: in String, orgLogin: in String): Result[Org, OrgFailure] {
  if not isDigits(orgId) {
    return Err(error = Invalid(message = "not a GitHub organisation id"))
  }
  if not isValidGitHubLogin(orgLogin) {
    return Err(error = Invalid(message = "not a GitHub organisation login"))
  }
  val u = match CloudAgents.PgStore.openUser(CloudAgents.Scope.userScope(callerId)) {
    case Ok(x) -> x
    case Err(e) -> return Err(error = Db(error = e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  val tenants = qo(u, "SELECT id FROM tenants WHERE github_org_id = @p0::bigint FOR UPDATE", [orgId])?
  var tenantId = tenantIdForGitHubOrg(orgId)
  if tenants.length == 0 {
    exo(u, "INSERT INTO tenants (id, name, kind, github_org_id) VALUES (@p0, @p1, 'github_org', @p2::bigint)", [tenantId, orgLogin, orgId])?
  } else {
    tenantId = col(tenants[0], "id")
    val mine = qo(u, "SELECT 1 AS one FROM memberships WHERE tenant_id = @p0 AND user_id = @p1", [tenantId, callerId])?
    val owners = qo(u, "SELECT 1 AS one FROM memberships WHERE tenant_id = @p0 AND role = 'owner' LIMIT 1", [tenantId])?
    if mine.length > 0 and owners.length > 0 {
      val org = orgFor(u, tenantId, callerId)?
      commitO(u)?
      return Ok(value = org)
    }
    if owners.length > 0 {
      return Err(
        error = Conflict(
          message = "this GitHub organisation is already connected; its members join it when they next sign in"
        )
      )
    }
  }
  exo(u, "INSERT INTO memberships (tenant_id, user_id, role, source, synced_at) VALUES (@p0, @p1, 'owner', 'github', now()) " + "ON CONFLICT (tenant_id, user_id) DO UPDATE SET role = 'owner', suspended = false, synced_at = now()", [tenantId, callerId])?
  match markSynced(u, callerId) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = Db(error = e))
  }
  val org = orgFor(u, tenantId, callerId)?
  commitO(u)?
  return Ok(value = org)
}
