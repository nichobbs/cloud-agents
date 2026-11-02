//! Per-organisation graph-ingest token (docs/capture-ingest-outbox.md §7) over
//! live Postgres: stored encrypted, reported as present but never returned,
//! owner/admin-only, tenant-isolated, and resolved org-token > env fallback >
//! none by the drain layer. Per-run unique users keep it re-runnable.
@test_module
package CloudAgents.GraphIngestTokenTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import Web
import CloudAgents.Auth
import CloudAgents.GraphIngestDrain
import CloudAgents.Orgs
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore
import CloudAgents.PgStore.Orgs
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.Scope
import CloudAgents.Db
import extern System.Environment as Env

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

val envVar = "CLOUDAGENTS_GRAPH_INGEST_TOKEN"

func live(): Bool {
  val ok = CloudAgents.Pg.serviceConfigured() and
    Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "").length.toInt() > 0
  if ok {
    Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
    return true
  }
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: graph-ingest token tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

func uid(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func newUser(): String {
  val u = "t-git-" + uid()
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(u) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  val login = "git" + uid().substring(0, 8)
  match CloudAgents.PgStore.Orgs.recordGitHubLogin(u, "", login) {
    case Ok(_) -> ()
    case Err(e) -> panic("recording login failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  return u
}

func loginOf(userId: in String): String {
  val ms = match CloudAgents.PgStore.Orgs.listMembers(userId, CloudAgents.Scope.personalTenantId(userId)) {
    case Ok(v) -> v
    case Err(f) -> panic(CloudAgents.PgStore.Orgs.orgFailureMessage(f))
  }
  return ms[0].githubLogin
}

/// An org owned by `owner` with `member` joined at role `role`.
func orgWith(owner: in String, member: in String, role: in String): String {
  val org = match CloudAgents.PgStore.Orgs.createNativeOrg(owner, "Tok " + uid().substring(0, 6)) {
    case Ok(o) -> o
    case Err(f) -> panic(CloudAgents.PgStore.Orgs.orgFailureMessage(f))
  }
  val inv = match CloudAgents.PgStore.Orgs.createInvitation(owner, org.id, loginOf(member), role) {
    case Ok(c) -> c
    case Err(f) -> panic(CloudAgents.PgStore.Orgs.orgFailureMessage(f))
  }
  match CloudAgents.PgStore.Orgs.acceptInvitation(member, inv.token) {
    case Ok(_) -> ()
    case Err(f) -> panic(CloudAgents.PgStore.Orgs.orgFailureMessage(f))
  }
  return org.id
}

func scopeOf(orgId: in String, userId: in String): CloudAgents.Pg.TenantScope {
  return CloudAgents.Pg.TenantScope(tenantId = orgId, userId = userId)
}

func resolved(sc: in CloudAgents.Pg.TenantScope): String {
  return match CloudAgents.GraphIngestDrain.resolveIngestToken(sc) {
    case Ok(t) -> t
    case Err(m) -> panic("resolve failed: " + m)
  }
}

func asUser(userId: in String): Unit {
  CloudAgents.Auth.setCurrentUserId(userId)
}

func httpStatus(r: in Result[String, Web.ApiError]): Int {
  return match r { case Ok(_) -> 200; case Err(e) -> e.status }
}

func body(r: in Result[String, Web.ApiError]): String {
  return match r { case Ok(b) -> b; case Err(e) -> panic("expected Ok, got " + e.message) }
}

test "resolution order is org token, then env fallback, then none; replace and clear are read fresh" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser()
  val sc = scopeOf(CloudAgents.Scope.personalTenantId(owner), owner)
  val saved = Std.Environment.getVarOrDefault(envVar, "")
  Env.SetEnvironmentVariable(envVar, "")
  assertEqual(resolved(sc), "", "nothing configured: empty, so the caller skips")
  Env.SetEnvironmentVariable(envVar, "env-fallback")
  assertEqual(resolved(sc), "env-fallback", "no tenant token: the env fallback")
  match CloudAgents.Repository.putTenantGraphIngestToken("tmk_org_secret", sc) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Repository.credentialErrorMessage(e))
  }
  assertEqual(resolved(sc), "tmk_org_secret", "tenant token wins over the env fallback")
  // Another tenant with no token is unaffected by this one's.
  val other = newUser()
  assertEqual(resolved(scopeOf(CloudAgents.Scope.personalTenantId(other), other)), "env-fallback", "tenants are isolated")
  match CloudAgents.Repository.putTenantGraphIngestToken("tmk_org_rotated", sc) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Repository.credentialErrorMessage(e))
  }
  assertEqual(resolved(sc), "tmk_org_rotated", "replace is read fresh")
  match CloudAgents.Repository.deleteTenantGraphIngestToken(sc) {
    case Ok(n) -> assertEqualInt(n, 1, "one row cleared")
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  assertEqual(resolved(sc), "env-fallback", "cleared: back to the fallback")
  Env.SetEnvironmentVariable(envVar, "")
  assertEqual(resolved(sc), "", "cleared and no fallback: skip")
  Env.SetEnvironmentVariable(envVar, saved)
}

test "the token is stored as ciphertext" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser()
  val sc = scopeOf(CloudAgents.Scope.personalTenantId(owner), owner)
  match CloudAgents.Repository.putTenantGraphIngestToken("tmk_plain_marker", sc) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Repository.credentialErrorMessage(e))
  }
  val u = match CloudAgents.PgStore.open(sc) { case Ok(x) -> x; case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e)) }
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = match CloudAgents.PgStore.q(u, "SELECT value_encrypted FROM tenant_graph_ingest_tokens", []) {
    case Ok(r) -> r
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  assertEqualInt(rows.length, 1, "one row")
  val raw = CloudAgents.PgStore.col(rows[0], "value_encrypted")
  assertTrue(raw.length > 0 and not raw.contains("tmk_plain_marker"), "stored value is ciphertext")
}

test "handlers authorise owner/admin only, report presence, and never return the token" {
  if not live() {
    return
  }
  migrate()
  val owner = newUser()
  val admin = newUser()
  val member = newUser()
  val stranger = newUser()
  val orgId = orgWith(owner, admin, "admin")
  val joined = match CloudAgents.PgStore.Orgs.acceptInvitation(member, match CloudAgents.PgStore.Orgs.createInvitation(owner, orgId, loginOf(member), "member") { case Ok(c) -> c.token; case Err(f) -> panic("invite") }) {
    case Ok(o) -> o.id
    case Err(f) -> panic(CloudAgents.PgStore.Orgs.orgFailureMessage(f))
  }
  assertEqual(joined, orgId, "member joined")
  val req = CloudAgents.Orgs.SetGraphIngestTokenRequest(token = "  tmk_h_secret  ")

  asUser(owner)
  assertEqual(body(CloudAgents.Orgs.getGraphIngestTokenHandler(orgId)), "{\"configured\":false}", "absent at first")
  val setBody = body(CloudAgents.Orgs.setGraphIngestTokenHandler(orgId, req))
  assertTrue(setBody.startsWith("{\"configured\":true,\"updatedAt\":"), "set reports presence")
  assertTrue(not setBody.contains("tmk_h_secret"), "set never echoes the token")
  assertTrue(not body(CloudAgents.Orgs.getGraphIngestTokenHandler(orgId)).contains("tmk_h_secret"), "get never returns the token")
  assertEqualInt(
    httpStatus(CloudAgents.Orgs.setGraphIngestTokenHandler(orgId, CloudAgents.Orgs.SetGraphIngestTokenRequest(token = "   "))),
    400,
    "blank token is rejected"
  )
  // The stored value is trimmed and is what the drain would send.
  assertEqual(resolved(scopeOf(orgId, owner)), "tmk_h_secret", "stored trimmed, resolved for the org")

  asUser(admin)
  assertEqualInt(httpStatus(CloudAgents.Orgs.getGraphIngestTokenHandler(orgId)), 200, "admin may read presence")

  asUser(member)
  assertEqualInt(httpStatus(CloudAgents.Orgs.getGraphIngestTokenHandler(orgId)), 403, "member may not read")
  assertEqualInt(httpStatus(CloudAgents.Orgs.setGraphIngestTokenHandler(orgId, req)), 403, "member may not set")
  assertEqualInt(httpStatus(CloudAgents.Orgs.clearGraphIngestTokenHandler(orgId)), 403, "member may not clear")

  asUser(stranger)
  assertEqualInt(httpStatus(CloudAgents.Orgs.getGraphIngestTokenHandler(orgId)), 404, "non-member sees not found")
  assertEqualInt(httpStatus(CloudAgents.Orgs.clearGraphIngestTokenHandler(orgId)), 404, "non-member cannot clear")
  assertEqualInt(
    httpStatus(CloudAgents.Orgs.getGraphIngestTokenHandler(CloudAgents.Scope.personalTenantId(owner))),
    404,
    "another user's personal tenant is not reachable"
  )

  asUser(admin)
  assertTrue(httpStatus(CloudAgents.Orgs.clearGraphIngestTokenHandler(orgId)) == 200, "admin may clear")
  assertEqual(body(CloudAgents.Orgs.getGraphIngestTokenHandler(orgId)), "{\"configured\":false}", "absent after clear")

  // A user manages their own personal tenant's token.
  asUser(stranger)
  val personal = CloudAgents.Scope.personalTenantId(stranger)
  assertEqualInt(httpStatus(CloudAgents.Orgs.setGraphIngestTokenHandler(personal, req)), 200, "personal tenant owner may set")
  asUser("")
}
