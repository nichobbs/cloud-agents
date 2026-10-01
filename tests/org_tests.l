//! Organisation store and handler tests over live Postgres
//! (docs/phase11-postgres-tenancy.md §5.2, §6.3, §6.4). Each test creates its
//! own users, so tests and repeated runs never share organisations.
@test_module
package CloudAgents.OrgTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore
import CloudAgents.PgStore.Tenancy
import CloudAgents.PgStore.Orgs
import CloudAgents.Orgs
import CloudAgents.Auth
import CloudAgents.Scope
import CloudAgents.Prompts
import CloudAgents.Db

func live(): Bool {
  val ok = CloudAgents.Pg.serviceConfigured() and
    Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "").length.toInt() > 0
  if ok {
    return true
  }
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: organisation tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
  return false
}

func migrate(): Unit {
  val conn = match CloudAgents.Pg.connectDsn(Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "")) {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(_) -> ()
    case Err(e) -> panic("migrate failed: " + CloudAgents.Pg.pgErrorMessage(e))
  }
}

func shortId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid()).substring(0, 8)
}

/// A provisioned user whose GitHub login is `login`.
func newUser(login: in String): String {
  val uid = "t-org-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(uid) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.Orgs.recordGitHubLogin(uid, "", login) {
    case Ok(_) -> ()
    case Err(e) -> panic("recording login failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  return uid
}

func failureMessage(f: in CloudAgents.PgStore.Orgs.OrgFailure): String {
  return CloudAgents.PgStore.Orgs.orgFailureMessage(f)
}

func mustOrg(
  r: in Result[CloudAgents.PgStore.Orgs.Org, CloudAgents.PgStore.Orgs.OrgFailure]
): CloudAgents.PgStore.Orgs.Org {
  return match r { case Ok(o) -> o; case Err(f) -> panic("expected an organisation: " + failureMessage(f)) }
}

func mustOk(r: in Result[Unit, CloudAgents.PgStore.Orgs.OrgFailure], what: in String): Unit {
  match r {
    case Ok(_) -> ()
    case Err(f) -> assertTrue(false, what + ": " + failureMessage(f))
  }
}

func mustInvite(
  r: in Result[CloudAgents.PgStore.Orgs.CreatedInvitation, CloudAgents.PgStore.Orgs.OrgFailure]
): CloudAgents.PgStore.Orgs.CreatedInvitation {
  return match r { case Ok(c) -> c; case Err(f) -> panic("expected an invitation: " + failureMessage(f)) }
}

func kindOf(f: in CloudAgents.PgStore.Orgs.OrgFailure): String {
  return match f {
    case Db(_) -> "db"
    case Forbidden(_) -> "forbidden"
    case NotFound(_) -> "notfound"
    case Invalid(_) -> "invalid"
    case Conflict(_) -> "conflict"
  }
}

func expectUnitFailure(r: in Result[Unit, CloudAgents.PgStore.Orgs.OrgFailure], kind: in String, what: in String): Unit {
  match r {
    case Ok(_) -> assertTrue(false, what + ": expected " + kind)
    case Err(f) -> assertEqual(kindOf(f), kind, what + " (" + failureMessage(f) + ")")
  }
}

func expectOrgFailure(
  r: in Result[CloudAgents.PgStore.Orgs.Org, CloudAgents.PgStore.Orgs.OrgFailure],
  kind: in String,
  what: in String,
): Unit {
  match r {
    case Ok(_) -> assertTrue(false, what + ": expected " + kind)
    case Err(f) -> assertEqual(kindOf(f), kind, what + " (" + failureMessage(f) + ")")
  }
}

func mustActive(userId: in String, tenantId: in String): Bool {
  return match CloudAgents.PgStore.Orgs.isActiveMember(userId, tenantId) {
    case Ok(b) -> b
    case Err(e) -> panic("isActiveMember failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func roleIn(userId: in String, tenantId: in String): String {
  val orgs = match CloudAgents.PgStore.Orgs.listOrgs(userId) {
    case Ok(v) -> v
    case Err(f) -> panic("listOrgs failed: " + failureMessage(f))
  }
  for o in orgs {
    if o.id == tenantId {
      return o.role
    }
  }
  return ""
}

/// Run a statement as the service role outside any scope (global tables only).
func unscopedExec(sql: in String, params: in slice[String]): Unit {
  val u = match CloudAgents.PgStore.openUnscoped() {
    case Ok(x) -> x
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, sql, params) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
}

test "a new user belongs only to their personal organisation, as owner" {
  if not live() {
    return
  }
  migrate()
  val me = newUser("solo" + shortId())
  val orgs = match CloudAgents.PgStore.Orgs.listOrgs(me) { case Ok(v) -> v; case Err(f) -> panic(failureMessage(f)) }
  assertEqualInt(orgs.length, 1, "only the personal organisation")
  assertEqual(orgs[0].id, CloudAgents.Scope.personalTenantId(me), "its id")
  assertEqual(orgs[0].kind, "personal", "its kind")
  assertEqual(orgs[0].role, "owner", "the user owns it")
}

test "creating a native organisation makes the caller its owner and lists it after the personal one" {
  if not live() {
    return
  }
  migrate()
  val me = newUser("creator" + shortId())
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(me, "  Acme Ltd  "))
  assertTrue(org.id.startsWith("native:"), "a native tenant id")
  assertEqual(org.name, "Acme Ltd", "the name is trimmed")
  assertEqual(org.role, "owner", "the creator owns it")
  val orgs = match CloudAgents.PgStore.Orgs.listOrgs(me) { case Ok(v) -> v; case Err(f) -> panic(failureMessage(f)) }
  assertEqualInt(orgs.length, 2, "personal and native")
  assertEqual(orgs[0].kind, "personal", "personal first")
  assertEqual(orgs[1].id, org.id, "then the new one")
  assertTrue(mustActive(me, org.id), "the creator is an active member")
  expectOrgFailure(CloudAgents.PgStore.Orgs.createNativeOrg(me, "   "), "invalid", "a blank name")
}

test "an invitation is accepted only by the invited GitHub login, once" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + shortId())
  // Invited with different case from the recorded login: matching is
  // case-insensitive, as GitHub logins are.
  val suffix = shortId()
  val inviteeLogin = "Invitee" + suffix
  val invitee = newUser("invitee" + suffix)
  val other = newUser("other" + shortId())
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(owner, "Invites"))
  val created = mustInvite(CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, inviteeLogin, "member"))
  assertTrue(created.token.length > 0, "a token is returned")
  assertEqual(created.invitation.githubLogin, inviteeLogin, "the login as given")
  match CloudAgents.PgStore.Orgs.listInvitations(owner, org.id) {
    case Ok(v) -> assertEqualInt(v.length, 1, "one pending invitation")
    case Err(f) -> assertTrue(false, failureMessage(f))
  }

  expectOrgFailure(CloudAgents.PgStore.Orgs.acceptInvitation(other, created.token), "forbidden", "another login")
  assertFalse(mustActive(other, org.id), "the other user did not join")
  val joined = mustOrg(CloudAgents.PgStore.Orgs.acceptInvitation(invitee, created.token))
  assertEqual(joined.id, org.id, "joined the inviting organisation")
  assertEqual(joined.role, "member", "with the invited role")
  assertEqual(joined.source, "native", "as a native membership")
  assertTrue(mustActive(invitee, org.id), "the invitee is now an active member")
  expectOrgFailure(CloudAgents.PgStore.Orgs.acceptInvitation(invitee, created.token), "invalid", "a used invitation")
  expectOrgFailure(CloudAgents.PgStore.Orgs.acceptInvitation(invitee, "no-such-token"), "notfound", "an unknown token")
  match CloudAgents.PgStore.Orgs.listInvitations(owner, org.id) {
    case Ok(v) -> assertEqualInt(v.length, 0, "an accepted invitation is no longer pending")
    case Err(f) -> assertTrue(false, failureMessage(f))
  }
}

test "an expired invitation cannot be accepted, and a newer one replaces a pending one" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + shortId())
  val login = "late" + shortId()
  val invitee = newUser(login)
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(owner, "Expiry"))
  val first = mustInvite(CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, login, "member"))
  val second = mustInvite(CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, login, "admin"))
  expectOrgFailure(CloudAgents.PgStore.Orgs.acceptInvitation(invitee, first.token), "notfound", "the replaced link")
  unscopedExec("UPDATE invitations SET expires_at = now() - interval '1 minute' WHERE id = @p0", [second.invitation.id])
  expectOrgFailure(CloudAgents.PgStore.Orgs.acceptInvitation(invitee, second.token), "invalid", "an expired invitation")
  assertFalse(mustActive(invitee, org.id), "not joined")
}

test "only owners and admins manage invitations, and personal organisations have none" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + shortId())
  val memberLogin = "member" + shortId()
  val member = newUser(memberLogin)
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(owner, "Managers"))
  val inv = mustInvite(CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, memberLogin, "member"))
  mustOrg(CloudAgents.PgStore.Orgs.acceptInvitation(member, inv.token))

  match CloudAgents.PgStore.Orgs.createInvitation(member, org.id, "someone", "member") {
    case Ok(_) -> assertTrue(false, "a member cannot invite")
    case Err(f) -> assertEqual(kindOf(f), "forbidden", "a member cannot invite")
  }
  match CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, "bad login!", "member") {
    case Ok(_) -> assertTrue(false, "an invalid login is refused")
    case Err(f) -> assertEqual(kindOf(f), "invalid", "an invalid login is refused")
  }
  match CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, "someone", "owner") {
    case Ok(_) -> assertTrue(false, "ownership is not granted by invitation")
    case Err(f) -> assertEqual(kindOf(f), "invalid", "ownership is not granted by invitation")
  }
  match CloudAgents.PgStore.Orgs.createInvitation(owner, CloudAgents.Scope.personalTenantId(owner), "someone", "member") {
    case Ok(_) -> assertTrue(false, "a personal organisation takes no invitations")
    case Err(f) -> assertEqual(kindOf(f), "invalid", "a personal organisation takes no invitations")
  }
  val outsider = newUser("outsider" + shortId())
  match CloudAgents.PgStore.Orgs.listInvitations(outsider, org.id) {
    case Ok(_) -> assertTrue(false, "a non-member cannot see invitations")
    case Err(f) -> assertEqual(kindOf(f), "notfound", "a non-member cannot see invitations")
  }
  val pending = mustInvite(CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, "someone", "member"))
  expectUnitFailure(
    CloudAgents.PgStore.Orgs.revokeInvitation(member, org.id, pending.invitation.id),
    "forbidden",
    "a member cannot revoke"
  )
  mustOk(CloudAgents.PgStore.Orgs.revokeInvitation(owner, org.id, pending.invitation.id), "the owner revokes")
  expectUnitFailure(
    CloudAgents.PgStore.Orgs.revokeInvitation(owner, org.id, pending.invitation.id),
    "notfound",
    "a second revoke"
  )
}

test "owners change roles and remove members; the last owner stays" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + shortId())
  val aLogin = "alice" + shortId()
  val alice = newUser(aLogin)
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(owner, "Roles"))
  mustOrg(
    CloudAgents.PgStore.Orgs.acceptInvitation(
      alice,
      mustInvite(CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, aLogin, "admin")).token
    )
  )
  assertEqual(roleIn(alice, org.id), "admin", "joined as admin")

  expectUnitFailure(
    CloudAgents.PgStore.Orgs.setMemberRole(alice, org.id, owner, "member"),
    "forbidden",
    "an admin cannot change roles"
  )
  expectUnitFailure(
    CloudAgents.PgStore.Orgs.setMemberRole(owner, org.id, owner, "admin"),
    "conflict",
    "the last owner cannot be demoted"
  )
  expectUnitFailure(
    CloudAgents.PgStore.Orgs.removeMember(owner, org.id, owner),
    "conflict",
    "the last owner cannot leave"
  )
  expectUnitFailure(CloudAgents.PgStore.Orgs.setMemberRole(owner, org.id, alice, "boss"), "invalid", "an unknown role")

  mustOk(CloudAgents.PgStore.Orgs.setMemberRole(owner, org.id, alice, "owner"), "promote alice to owner")
  mustOk(CloudAgents.PgStore.Orgs.setMemberRole(alice, org.id, owner, "member"), "alice demotes the first owner")
  assertEqual(roleIn(owner, org.id), "member", "the first owner is now a member")
  expectUnitFailure(
    CloudAgents.PgStore.Orgs.removeMember(owner, org.id, alice),
    "forbidden",
    "a member cannot remove others"
  )
  mustOk(CloudAgents.PgStore.Orgs.removeMember(owner, org.id, owner), "a member can leave")
  assertFalse(mustActive(owner, org.id), "left")
  expectUnitFailure(
    CloudAgents.PgStore.Orgs.removeMember(alice, org.id, alice),
    "conflict",
    "the sole owner cannot leave"
  )
  expectUnitFailure(
    CloudAgents.PgStore.Orgs.setMemberRole(owner, CloudAgents.Scope.personalTenantId(owner), owner, "member"),
    "invalid",
    "personal organisations are not managed"
  )
}

test "members are visible to members only" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + shortId())
  val outsider = newUser("outsider" + shortId())
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(owner, "Visible"))
  match CloudAgents.PgStore.Orgs.listMembers(owner, org.id) {
    case Ok(v) -> {
      assertEqualInt(v.length, 1, "one member")
      assertEqual(v[0].userId, owner, "the owner")
      assertTrue(v[0].githubLogin.startsWith("owner"), "with their login")
    }
    case Err(f) -> assertTrue(false, failureMessage(f))
  }
  match CloudAgents.PgStore.Orgs.listMembers(outsider, org.id) {
    case Ok(_) -> assertTrue(false, "an outsider cannot list members")
    case Err(f) -> assertEqual(kindOf(f), "notfound", "an outsider cannot list members")
  }
}

test "a suspended membership is not active" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + shortId())
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(owner, "Suspended"))
  unscopedExec("UPDATE memberships SET suspended = true WHERE tenant_id = @p0 AND user_id = @p1", [org.id, owner])
  assertFalse(mustActive(owner, org.id), "suspended memberships do not authorise requests")
}

test "the request scope follows the validated organisation and resets with the user" {
  CloudAgents.Auth.setCurrentUserId("u-scope")
  assertEqual(CloudAgents.Auth.requestScope().tenantId, "personal:u-scope", "personal by default")
  CloudAgents.Auth.setCurrentTenantId("native:abc")
  assertEqual(CloudAgents.Auth.requestScope().tenantId, "native:abc", "the selected organisation")
  assertEqual(CloudAgents.Auth.requestScope().userId, "u-scope", "for the same user")
  CloudAgents.Auth.setCurrentUserId("u-next")
  assertEqual(CloudAgents.Auth.requestScope().tenantId, "personal:u-next", "a new identity starts personal")
  CloudAgents.Auth.setCurrentUserId("")
}

test "data created in an organisation is separate from the same user's personal data" {
  if not live() {
    return
  }
  migrate()
  val me = newUser("split" + shortId())
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(me, "Split"))
  CloudAgents.Auth.setCurrentUserId(me)
  CloudAgents.Auth.setCurrentTenantId(org.id)
  match CloudAgents.Prompts.addPromptHandler(CloudAgents.Prompts.SavePromptRequest(name = "org prompt", body = "b", tags = [])) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "adding a prompt in the organisation: " + e.message)
  }
  match CloudAgents.Prompts.listPromptsHandler() {
    case Ok(l) -> assertEqualInt(l.prompts.length, 1, "visible in the organisation")
    case Err(e) -> assertTrue(false, e.message)
  }
  CloudAgents.Auth.setCurrentUserId(me)
  match CloudAgents.Prompts.listPromptsHandler() {
    case Ok(l) -> assertEqualInt(l.prompts.length, 0, "not visible in the personal organisation")
    case Err(e) -> assertTrue(false, e.message)
  }
  CloudAgents.Auth.setCurrentUserId("")
}

test "the organisation handlers shape JSON and map failures to HTTP statuses" {
  if not live() {
    return
  }
  migrate()
  val me = newUser("http" + shortId())
  CloudAgents.Auth.setCurrentUserId(me)
  val created = match CloudAgents.Orgs.createOrgHandler(CloudAgents.Orgs.CreateOrgRequest(name = "Quote \"me\"")) {
    case Ok(body) -> body
    case Err(e) -> panic(e.message)
  }
  assertTrue(created.startsWith("{\"org\":{\"id\":\"native:"), "an org envelope: " + created)
  assertTrue(created.contains("\"name\":\"Quote \\\"me\\\"\""), "the name is escaped: " + created)
  match CloudAgents.Orgs.listOrgsHandler() {
    case Ok(body) -> {
      assertTrue(body.startsWith("{\"personal\":\"personal:" + me + "\",\"orgs\":["), "the list envelope: " + body)
      assertTrue(body.contains("\"suspended\":false"), "booleans are JSON booleans")
    }
    case Err(e) -> assertTrue(false, e.message)
  }
  match CloudAgents.Orgs.listMembersHandler("native:missing") {
    case Ok(_) -> assertTrue(false, "an unknown organisation")
    case Err(e) -> assertEqualInt(e.status, 404, "an unknown organisation is 404")
  }
  match CloudAgents.Orgs.acceptInvitationHandler(CloudAgents.Orgs.AcceptInvitationRequest(token = "")) {
    case Ok(_) -> assertTrue(false, "an empty token")
    case Err(e) -> assertEqualInt(e.status, 400, "an empty token is 400")
  }
  CloudAgents.Auth.setCurrentUserId("")
}

test "a suspended member can still leave" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + shortId())
  val login = "leaver" + shortId()
  val leaver = newUser(login)
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(owner, "Leavers"))
  mustOrg(
    CloudAgents.PgStore.Orgs.acceptInvitation(
      leaver,
      mustInvite(CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, login, "member")).token
    )
  )
  unscopedExec("UPDATE memberships SET suspended = true WHERE tenant_id = @p0 AND user_id = @p1", [org.id, leaver])
  mustOk(CloudAgents.PgStore.Orgs.removeMember(leaver, org.id, leaver), "a suspended member leaves")
  assertEqual(roleIn(leaver, org.id), "", "gone")
  expectUnitFailure(
    CloudAgents.PgStore.Orgs.removeMember(leaver, org.id, owner),
    "notfound",
    "but cannot remove others"
  )
}

test "a recycled GitHub login belongs only to its newest holder" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + shortId())
  val login = "recycled" + shortId()
  val oldHolder = newUser(login)
  val newHolder = newUser(login)
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(owner, "Recycled"))
  val inv = mustInvite(CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, login, "member"))
  expectOrgFailure(
    CloudAgents.PgStore.Orgs.acceptInvitation(oldHolder, inv.token),
    "forbidden",
    "the earlier holder lost the login"
  )
  val joined = mustOrg(CloudAgents.PgStore.Orgs.acceptInvitation(newHolder, inv.token))
  assertEqual(joined.id, org.id, "the newest holder accepts")
}

test "a suspended owner does not count as the remaining owner" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + shortId())
  val login = "second" + shortId()
  val second = newUser(login)
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(owner, "Suspended owners"))
  mustOrg(
    CloudAgents.PgStore.Orgs.acceptInvitation(
      second,
      mustInvite(CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, login, "member")).token
    )
  )
  mustOk(CloudAgents.PgStore.Orgs.setMemberRole(owner, org.id, second, "owner"), "a second owner")
  unscopedExec("UPDATE memberships SET suspended = true WHERE tenant_id = @p0 AND user_id = @p1", [org.id, second])
  expectUnitFailure(
    CloudAgents.PgStore.Orgs.removeMember(owner, org.id, owner),
    "conflict",
    "the only active owner cannot leave"
  )
  expectUnitFailure(
    CloudAgents.PgStore.Orgs.setMemberRole(owner, org.id, owner, "member"),
    "conflict",
    "nor be demoted"
  )
}

test "the cached membership check forgets a member as soon as they are removed" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + shortId())
  val login = "cached" + shortId()
  val member = newUser(login)
  val org = mustOrg(CloudAgents.PgStore.Orgs.createNativeOrg(owner, "Cached"))
  val joined = mustOrg(
    CloudAgents.PgStore.Orgs.acceptInvitation(
      member,
      mustInvite(CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, login, "member")).token
    )
  )
  assertEqual(joined.id, org.id, "joined")
  match CloudAgents.PgStore.Orgs.isActiveMemberCached(member, org.id) {
    case Ok(b) -> assertTrue(b, "confirmed and cached")
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  mustOk(CloudAgents.PgStore.Orgs.removeMember(owner, org.id, member), "removed")
  match CloudAgents.PgStore.Orgs.isActiveMemberCached(member, org.id) {
    case Ok(b) -> assertFalse(b, "the removal is seen at once, not after the cache window")
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
}
