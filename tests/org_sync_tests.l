//! GitHub organisation sync tests (docs/phase11-postgres-tenancy.md §6.2):
//! parsing GitHub's membership responses offline, and connecting,
//! reconciling, suspending and claiming over live Postgres. GitHub itself is
//! not called; the reconciliation is driven with the memberships GitHub
//! would report.
@test_module
package CloudAgents.OrgSyncTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore
import CloudAgents.PgStore.Tenancy
import CloudAgents.PgStore.Orgs
import CloudAgents.OrgSync
import CloudAgents.Auth
import CloudAgents.Scope
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
  println("SKIP: organisation sync tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

func newUser(login: in String): String {
  val uid = "t-sync-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
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

/// A fresh 15-digit numeric id, so every test connects its own organisation.
func freshOrgId(): String {
  val hex = Std.Uuid.uuidToString(Std.Uuid.newUuid())
  var acc = "9"
  var i = 0
  while i < hex.length and acc.length < 15 {
    val c = hex.substring(i, 1)
    if c >= "0" and c <= "9" {
      acc = acc + c
    } else if c >= "a" and c <= "f" {
      acc = acc + "1"
    }
    i = i + 1
  }
  return acc
}

func short(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid()).substring(0, 8)
}

func gm(orgId: in String, login: in String, role: in String): CloudAgents.PgStore.Orgs.GitHubOrgMembership {
  return CloudAgents.PgStore.Orgs.GitHubOrgMembership(orgId = orgId, orgLogin = login, role = role)
}

func connect(owner: in String, orgId: in String, login: in String): CloudAgents.PgStore.Orgs.Org {
  return match CloudAgents.PgStore.Orgs.connectGitHubOrg(owner, orgId, login) {
    case Ok(o) -> o
    case Err(f) -> panic("connect failed: " + CloudAgents.PgStore.Orgs.orgFailureMessage(f))
  }
}

func reconcile(
  userId: in String, reported: in slice[CloudAgents.PgStore.Orgs.GitHubOrgMembership]
): CloudAgents.PgStore.Orgs.SyncOutcome {
  return match CloudAgents.PgStore.Orgs.reconcileGitHubMemberships(userId, reported, true) {
    case Ok(o) -> o
    case Err(e) -> panic("reconcile failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func membership(userId: in String, tenantId: in String): Option[CloudAgents.PgStore.Orgs.Org] {
  val orgs = match CloudAgents.PgStore.Orgs.listOrgs(userId) {
    case Ok(v) -> v
    case Err(f) -> panic(CloudAgents.PgStore.Orgs.orgFailureMessage(f))
  }
  for o in orgs {
    if o.id == tenantId {
      return Some(value = o)
    }
  }
  return None
}

func roleOf(userId: in String, tenantId: in String): String {
  return match membership(userId, tenantId) { case Some(o) -> o.role; case None -> "" }
}

func active(userId: in String, tenantId: in String): Bool {
  return match CloudAgents.PgStore.Orgs.isActiveMember(userId, tenantId) {
    case Ok(b) -> b
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
}

/// Backdate a user's last sync so the hourly claim picks them up.
func backdateSync(userId: in String): Unit {
  val u = match CloudAgents.PgStore.openUser(CloudAgents.Scope.userScope(userId)) {
    case Ok(x) -> x
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, "UPDATE user_sync_state SET github_synced_at = now() - interval '2 hours', claimed_until = NULL WHERE user_id = @p0", [userId]) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
}

func claimedNow(): slice[String] {
  return match CloudAgents.PgStore.Orgs.claimMembershipSync(100, 300) {
    case Ok(v) -> v
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
}

func containsId(ids: in slice[String], id: in String): Bool {
  for x in ids {
    if x == id {
      return true
    }
  }
  return false
}

// ── Parsing GitHub responses ──────────────────────────────────────────────────
test "a memberships page yields active memberships with organisation id, login and role" {
  val body = "[" + "{\"state\":\"active\",\"role\":\"admin\",\"organization\":{\"login\":\"acme\",\"id\":123}}," +
    "{\"state\":\"pending\",\"role\":\"member\",\"organization\":{\"login\":\"later\",\"id\":456}}," +
    "{\"state\":\"active\",\"role\":\"member\",\"organization\":{\"login\":\"beta\",\"id\":789}}," +
    "{\"state\":\"active\",\"role\":\"member\"}" +
    "]"
  match CloudAgents.OrgSync.parseMembershipPage(body) {
    case Ok(p) -> {
      assertEqualInt(p.count, 4, "every entry is counted for paging")
      assertEqualInt(p.items.length, 2, "only active memberships with an organisation")
      assertEqual(p.items[0].orgId, "123", "the numeric id")
      assertEqual(p.items[0].orgLogin, "acme", "the login")
      assertEqual(p.items[0].role, "admin", "the role")
      assertEqual(p.items[1].orgLogin, "beta", "the second")
    }
    case Err(e) -> assertTrue(false, e)
  }
  match CloudAgents.OrgSync.parseMembershipPage("{\"message\":\"Bad credentials\"}") {
    case Ok(_) -> assertTrue(false, "an error object is not a page")
    case Err(_) -> ()
  }
}

test "a single membership response is parsed, and anything else is not a membership" {
  match CloudAgents.OrgSync.parseSingleMembership("{\"state\":\"active\",\"role\":\"admin\",\"organization\":{\"login\":\"acme\",\"id\":42}}") {
    case Some(m) -> {
      assertEqual(m.orgId, "42", "id")
      assertEqual(m.role, "admin", "role")
    }
    case None -> assertTrue(false, "an active membership")
  }
  match CloudAgents.OrgSync.parseSingleMembership("{\"state\":\"pending\",\"role\":\"admin\",\"organization\":{\"login\":\"acme\",\"id\":42}}") {
    case Some(_) -> assertTrue(false, "a pending membership is not one yet")
    case None -> ()
  }
  match CloudAgents.OrgSync.parseSingleMembership("not json") {
    case Some(_) -> assertTrue(false, "garbage")
    case None -> ()
  }
}

test "a 401 refuses the token; a 403 or 404 needs a second look; anything else keeps the rows" {
  assertTrue(
    CloudAgents.OrgSync.isUnauthorized("GET x failed: The remote server returned an error: (401) Unauthorized."),
    "401"
  )
  assertFalse(
    CloudAgents.OrgSync.isUnauthorized("GET x failed: The remote server returned an error: (403) Forbidden."),
    "403 is not decided by status alone"
  )
  assertTrue(
    CloudAgents.OrgSync.isForbiddenOrMissing("GET x failed: The remote server returned an error: (403) Forbidden."),
    "403"
  )
  assertTrue(
    CloudAgents.OrgSync.isForbiddenOrMissing("GET x failed: The remote server returned an error: (404) Not Found."),
    "404"
  )
  assertFalse(CloudAgents.OrgSync.isForbiddenOrMissing("GET x failed: No such host is known."), "a transport failure")
  assertFalse(
    CloudAgents.OrgSync.isUnauthorized("GET x failed: The remote server returned an error: (502) Bad Gateway."),
    "a GitHub outage"
  )
}

// ── Connecting and reconciling ────────────────────────────────────────────────
test "connecting a GitHub organisation creates its tenant with the caller as owner, once" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + short())
  val orgId = freshOrgId()
  val org = connect(owner, orgId, "acme-" + short())
  assertEqual(org.id, "github:" + orgId, "the tenant id")
  assertEqual(org.kind, "github_org", "the kind")
  assertEqual(org.role, "owner", "the caller owns it")
  assertEqual(org.source, "github", "a GitHub-sourced membership")
  assertEqual(connect(owner, orgId, "acme").id, org.id, "connecting again returns the same organisation")
  val other = newUser("other" + short())
  match CloudAgents.PgStore.Orgs.connectGitHubOrg(other, orgId, "acme") {
    case Ok(_) -> assertTrue(false, "a second connection is refused")
    case Err(f) -> assertTrue(
      CloudAgents.PgStore.Orgs.orgFailureMessage(f).contains("already connected"),
      "already connected"
    )
  }
  match CloudAgents.PgStore.Orgs.connectGitHubOrg(owner, "12x", "acme") {
    case Ok(_) -> assertTrue(false, "a non-numeric id")
    case Err(_) -> ()
  }
}

test "reconciliation adds, updates and removes GitHub memberships of connected organisations" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + short())
  val user = newUser("dev" + short())
  val connectedId = freshOrgId()
  val tenantId = connect(owner, connectedId, "co-" + short()).id
  val unconnected = freshOrgId()

  val first = reconcile(user, [gm(connectedId, "co", "admin"), gm(unconnected, "nope", "admin")])
  assertEqualInt(first.added, 1, "added to the connected organisation only")
  assertEqual(roleOf(user, tenantId), "admin", "GitHub admin maps to admin")
  assertEqual(roleOf(user, "github:" + unconnected), "", "no tenant for an unconnected organisation")

  val second = reconcile(user, [gm(connectedId, "co", "member")])
  assertEqualInt(second.updated, 1, "the role is updated")
  assertEqual(roleOf(user, tenantId), "member", "now a member")

  val third = reconcile(user, [])
  assertEqualInt(third.removed, 1, "GitHub no longer reports it")
  assertEqual(roleOf(user, tenantId), "", "removed")
  assertTrue(active(owner, tenantId), "other members are unaffected")
}

test "reconciliation never demotes an owner and never touches native memberships" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + short())
  val orgId = freshOrgId()
  val tenantId = connect(owner, orgId, "keep-" + short()).id
  reconcile(owner, [gm(orgId, "keep", "member")])
  assertEqual(roleOf(owner, tenantId), "owner", "the owner stays owner")

  val nativeLogin = "native" + short()
  val nativeUser = newUser(nativeLogin)
  val inv = match CloudAgents.PgStore.Orgs.createInvitation(owner, tenantId, nativeLogin, "admin") {
    case Ok(c) -> c
    case Err(f) -> panic(CloudAgents.PgStore.Orgs.orgFailureMessage(f))
  }
  match CloudAgents.PgStore.Orgs.acceptInvitation(nativeUser, inv.token) {
    case Ok(_) -> ()
    case Err(f) -> panic(CloudAgents.PgStore.Orgs.orgFailureMessage(f))
  }
  reconcile(nativeUser, [])
  assertEqual(roleOf(nativeUser, tenantId), "admin", "a native membership survives GitHub not reporting it")
  reconcile(nativeUser, [gm(orgId, "keep", "member")])
  match membership(nativeUser, tenantId) {
    case Some(o) -> {
      assertEqual(o.source, "native", "still native")
      assertEqual(o.role, "admin", "role unchanged")
    }
    case None -> assertTrue(false, "still a member")
  }
}

test "a partial membership list adds and updates but removes nothing" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + short())
  val user = newUser("dev" + short())
  val a = freshOrgId()
  val b = freshOrgId()
  val ta = connect(owner, a, "pa-" + short()).id
  val tb = connect(owner, b, "pb-" + short()).id
  reconcile(user, [gm(a, "pa", "member"), gm(b, "pb", "member")])
  val partial = match CloudAgents.PgStore.Orgs.reconcileGitHubMemberships(user, [gm(a, "pa", "admin")], false) {
    case Ok(o) -> o
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  assertEqualInt(partial.removed, 0, "nothing removed from a partial list")
  assertEqual(roleOf(user, ta), "admin", "updated from the partial list")
  assertEqual(roleOf(user, tb), "member", "kept although missing from the partial list")
}

test "a refused token suspends GitHub memberships until the next sync reports them" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + short())
  val user = newUser("dev" + short())
  val orgId = freshOrgId()
  val tenantId = connect(owner, orgId, "sus-" + short()).id
  reconcile(user, [gm(orgId, "sus", "member")])
  assertTrue(active(user, tenantId), "active after sync")
  match CloudAgents.PgStore.Orgs.isActiveMemberCached(user, tenantId) {
    case Ok(b) -> assertTrue(b, "confirmed and cached")
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.Orgs.suspendGitHubMemberships(user) {
    case Ok(n) -> assertEqualInt(n, 1, "one membership suspended")
    case Err(e) -> assertTrue(false, CloudAgents.Db.dbErrorMessage(e))
  }
  assertFalse(active(user, tenantId), "a suspended member cannot act in the organisation")
  match CloudAgents.PgStore.Orgs.isActiveMemberCached(user, tenantId) {
    case Ok(b) -> assertFalse(b, "the suspension clears the middleware's cached confirmation")
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  match membership(user, tenantId) {
    case Some(o) -> assertTrue(o.suspended, "listed as suspended")
    case None -> assertTrue(false, "suspended, not deleted")
  }
  assertTrue(active(user, CloudAgents.Scope.personalTenantId(user)), "the personal organisation is unaffected")
  reconcile(user, [gm(orgId, "sus", "member")])
  assertTrue(active(user, tenantId), "a later sync lifts the suspension")
}

test "the hourly claim returns users with stale GitHub memberships, once per lease" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + short())
  val user = newUser("dev" + short())
  val orgId = freshOrgId()
  connect(owner, orgId, "claim-" + short())
  reconcile(user, [gm(orgId, "claim", "member")])
  assertFalse(containsId(claimedNow(), user), "a fresh sync is not due")
  backdateSync(user)
  assertTrue(containsId(claimedNow(), user), "a sync over an hour old is claimed")
  assertFalse(containsId(claimedNow(), user), "not again while leased")

  val nativeOnly = newUser("plain" + short())
  reconcile(nativeOnly, [])
  backdateSync(nativeOnly)
  assertFalse(containsId(claimedNow(), nativeOnly), "a user with no GitHub memberships is never claimed")
}

test "the membership sync endpoint is operator-only" {
  CloudAgents.Auth.setCurrentUserId("gh-42")
  match CloudAgents.OrgSync.membershipSyncHandler() {
    case Ok(_) -> assertTrue(false, "a user cannot trigger the sweep")
    case Err(e) -> assertEqualInt(e.status, 401, "non-operator -> 401")
  }
  CloudAgents.Auth.setCurrentUserId("")
}

test "the sweep re-checks due users one at a time and suspends those without a usable token" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser("owner" + short())
  val a = newUser("sweepa" + short())
  val b = newUser("sweepb" + short())
  val orgId = freshOrgId()
  val tenantId = connect(owner, orgId, "sweep-" + short()).id
  reconcile(a, [gm(orgId, "sweep", "member")])
  reconcile(b, [gm(orgId, "sweep", "member")])
  backdateSync(a)
  backdateSync(b)
  // Neither user has a vaulted GITHUB_TOKEN, so each check ends in a
  // suspension without any call to GitHub.
  CloudAgents.Auth.setCurrentUserId(CloudAgents.Auth.operatorUserId())
  match CloudAgents.OrgSync.membershipSyncHandler() {
    case Ok(body) -> assertTrue(body.startsWith("{\"synced\":"), "sweep summary: " + body)
    case Err(e) -> assertTrue(false, "the operator sweep failed: " + e.message)
  }
  CloudAgents.Auth.setCurrentUserId("")
  assertFalse(active(a, tenantId), "the first due user was checked and suspended")
  assertFalse(active(b, tenantId), "so was the second")
  assertFalse(containsId(claimedNow(), a), "a checked user is not due again")
}

test "a sweep stops when the queue is empty, at the user cap, or at the deadline" {
  val now = 1000.toLong()
  val deadline = 2000.toLong()
  assertTrue(CloudAgents.OrgSync.sweepContinues(true, 0, now, deadline), "work left, under the cap and the budget")
  assertFalse(CloudAgents.OrgSync.sweepContinues(false, 0, now, deadline), "the last claim found nobody")
  assertTrue(CloudAgents.OrgSync.sweepContinues(true, 49, now, deadline), "one below the cap")
  assertFalse(CloudAgents.OrgSync.sweepContinues(true, 50, now, deadline), "the cap of 50 users")
  assertFalse(CloudAgents.OrgSync.sweepContinues(true, 0, deadline, deadline), "at the deadline")
  assertFalse(CloudAgents.OrgSync.sweepContinues(true, 0, deadline + 1.toLong(), deadline), "past the deadline")
}
