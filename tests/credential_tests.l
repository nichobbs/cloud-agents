//! Credential vault tests: the user-owned vault on the Postgres store (phase
//! 11 cut-over, spec section 4.3a) and the credential handlers.
@test_module
package CloudAgents.CredentialTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Credentials
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.Scope
import CloudAgents.Sqlite
import extern System.Environment as Env

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

// ── Live Postgres ─────────────────────────────────────────────────────────────
//
// The store is Postgres (docs/phase11-postgres-tenancy.md). These tests run iff
// LYRIC_CONFIG_DB_CONNECTION_URL (cloudagents_app) and
// CLOUD_AGENTS_MIGRATE_DATABASE_URL (cloudagents_owner) are set, and fail rather
// than skip when CLOUD_AGENTS_REQUIRE_LIVE_PG=1 (CI). Each test acts as a fresh
// user with its own personal tenant, so tests, suites and repeated runs against
// the same database never see each other's rows.
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
  println("SKIP: credential tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

/// A new user with a provisioned personal tenant. Does not change the request
/// identity.
func newUser(tag: in String): String {
  val uid = "t-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(uid) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return uid
}

/// Migrate, then make a new user the request identity (what handlers read via
/// CloudAgents.Auth.requestScope()).
func freshUser(tag: in String): String {
  migrate()
  val uid = newUser(tag)
  CloudAgents.Auth.setCurrentUserId(uid)
  return uid
}

func mustPut(userId: in String, name: in String, value: in String): Unit {
  match putCredential(CloudAgents.Scope.userScope(userId), name, value) {
    case Ok(_) -> ()
    case Err(e) -> panic("putCredential failed: " + credentialErrorMessage(e))
  }
}

func mustNames(userId: in String): slice[CredentialName] {
  return match listCredentialNames(CloudAgents.Scope.userScope(userId)) {
    case Ok(ns) -> ns
    case Err(e) -> panic("listCredentialNames failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustDecrypted(userId: in String): slice[CredentialValue] {
  return match decryptedCredentials(CloudAgents.Scope.userScope(userId)) {
    case Ok(cs) -> cs
    case Err(e) -> panic("decryptedCredentials failed: " + credentialErrorMessage(e))
  }
}

func findValue(creds: in slice[CredentialValue], name: in String): String {
  var i = 0
  while i < creds.length {
    if creds[i].name == name {
      return creds[i].value
    }
    i = i + 1
  }
  return "<missing>"
}

test "Credentials store, list names, and decrypt for injection" {
  if not live() {
    return
  }
  val me = freshUser("cred-cred-crud")
  val userId = me

  mustPut(userId, "GITHUB_TOKEN", "ghp_secret_value")
  mustPut(userId, "GOOGLE_PROJECT", "my-project-123")

  val names = mustNames(userId)
  assertEqualInt(names.length.toInt(), 2, "two credential names listed")
  // Alphabetical: GITHUB_TOKEN before GOOGLE_PROJECT.
  assertEqual(names[0].name, "GITHUB_TOKEN", "first name")
  assertEqual(names[1].name, "GOOGLE_PROJECT", "second name")

  // Values decrypt back for container injection.
  val decrypted = mustDecrypted(userId)
  assertEqual(findValue(decrypted, "GITHUB_TOKEN"), "ghp_secret_value", "github token decrypts")
  assertEqual(findValue(decrypted, "GOOGLE_PROJECT"), "my-project-123", "google project decrypts")
}

test "Upsert replaces a credential value in place" {
  if not live() {
    return
  }
  val me = freshUser("cred-cred-upsert")
  val userId = me
  mustPut(userId, "API_KEY", "old-value")
  mustPut(userId, "API_KEY", "new-value")

  assertEqualInt(mustNames(userId).length.toInt(), 1, "upsert does not duplicate the name")
  assertEqual(findValue(mustDecrypted(userId), "API_KEY"), "new-value", "value was replaced")
}

test "Credential handler rejects invalid and reserved names" {
  if not live() {
    return
  }
  val me = freshUser("cred-cred-validate")
  // Reserved runner env-var names must not be storable (would override the
  // runner's own value on injection).
  match putCredentialHandler(PutCredentialRequest(name = "MODEL", value = "x")) {
    case Ok(_) -> assertTrue(false, "reserved name MODEL must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "reserved name -> 400")
  }
  match putCredentialHandler(PutCredentialRequest(name = "NATIVE_SESSION_ID", value = "x")) {
    case Ok(_) -> assertTrue(false, "reserved name NATIVE_SESSION_ID must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "reserved name -> 400")
  }
  // SESSION_ID is the cloud-agents session id used for fallback branch naming
  // (#730): a same-named credential would shadow the runner's real value.
  match putCredentialHandler(PutCredentialRequest(name = "SESSION_ID", value = "x")) {
    case Ok(_) -> assertTrue(false, "reserved name SESSION_ID must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "reserved name -> 400")
  }
  // EXTRA_REPOS is server-computed from a session's linked repos (#454): a
  // same-named credential would be appended after it and, since Docker keeps
  // the last value, hijack which repos the runner clones.
  match putCredentialHandler(PutCredentialRequest(name = "EXTRA_REPOS", value = "x")) {
    case Ok(_) -> assertTrue(false, "reserved name EXTRA_REPOS must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "reserved name -> 400")
  }
  // System- and loader-critical env vars are reserved too: PATH/HOME would
  // break the runner, LD_PRELOAD/LD_LIBRARY_PATH could hijack it (#226).
  match putCredentialHandler(PutCredentialRequest(name = "PATH", value = "x")) {
    case Ok(_) -> assertTrue(false, "reserved name PATH must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "reserved name -> 400")
  }
  match putCredentialHandler(PutCredentialRequest(name = "LD_PRELOAD", value = "x")) {
    case Ok(_) -> assertTrue(false, "reserved name LD_PRELOAD must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "reserved name -> 400")
  }
  // The whole CLOUD_AGENTS_ prefix is reserved (#1041): a credential named
  // CLOUD_AGENTS_ENTRYPOINT_STAGE=user would, if storable, be injected
  // verbatim as a container env var and could otherwise be used to try to
  // trick docker/entrypoint.sh's root-only prelude into thinking it had
  // already dropped privilege (that decision is now gated on `id -u`, not
  // this var, but the name is denylisted here too as defense in depth).
  match putCredentialHandler(PutCredentialRequest(name = "CLOUD_AGENTS_ENTRYPOINT_STAGE", value = "user")) {
    case Ok(_) -> assertTrue(false, "reserved name CLOUD_AGENTS_ENTRYPOINT_STAGE must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "reserved name -> 400")
  }
  // Any other CLOUD_AGENTS_-prefixed name is reserved too, not just the one
  // above — the whole prefix is denylisted (mirrors inject-library.sh's
  // expand_env_value deny-list).
  match putCredentialHandler(PutCredentialRequest(name = "CLOUD_AGENTS_SOMETHING_ELSE", value = "x")) {
    case Ok(_) -> assertTrue(false, "reserved prefix CLOUD_AGENTS_ must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "reserved prefix -> 400")
  }
  // Malformed env-var names rejected too.
  match putCredentialHandler(PutCredentialRequest(name = "1BAD", value = "x")) {
    case Ok(_) -> assertTrue(false, "leading digit must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "bad name -> 400")
  }
  match putCredentialHandler(PutCredentialRequest(name = "has space", value = "x")) {
    case Ok(_) -> assertTrue(false, "space must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "bad name -> 400")
  }
  // A valid, non-reserved name succeeds.
  match putCredentialHandler(PutCredentialRequest(name = "GITHUB_TOKEN", value = "ok")) {
    case Ok(_) -> assertTrue(true, "valid name accepted")
    case Err(_) -> assertTrue(false, "valid credential should store")
  }
}

test "Credentials are per-user isolated and deletable" {
  if not live() {
    return
  }
  val me = freshUser("cred-cred-scope")
  val other = newUser("cred-other")
  mustPut(me, "SECRET", "mine")
  mustPut(other, "SECRET", "theirs")

  assertEqualInt(mustNames(me).length.toInt(), 1, "only my credential listed")
  assertEqual(findValue(mustDecrypted(me), "SECRET"), "mine", "I see my own value")

  // Deleting another user's credential touches nothing.
  match deleteCredential(CloudAgents.Scope.userScope(me), "SECRET") {
    case Ok(n) -> assertEqualInt(n, 1, "delete my own credential")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match deleteCredential(CloudAgents.Scope.userScope(me), "SECRET") {
    case Ok(n) -> assertEqualInt(n, 0, "second delete finds nothing")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertEqualInt(mustNames(other).length.toInt(), 1, "other user's credential untouched")
}

test "deleting GITHUB_TOKEN also drops GitHub OAuth refresh metadata, preventing silent resurrection (#668)" {
  if not live() {
    return
  }
  val me = freshUser("cred-cred-github-token-refresh-cleanup")
  val gh1 = newUser("cred-gh1")
  mustPut(gh1, "GITHUB_TOKEN", "gho_original")
  match CloudAgents.Repository.upsertGitHubOAuthRefresh(CloudAgents.Scope.userScope(gh1), "refresh-still-valid", "3600", "604800") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "upsert failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }

  match deleteCredential(CloudAgents.Scope.userScope(gh1), "GITHUB_TOKEN") {
    case Ok(n) -> assertEqualInt(n, 1, "GITHUB_TOKEN deleted")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // The refresh row must be gone too, or a still-valid refresh token would
  // silently re-vault a fresh GITHUB_TOKEN on the next request despite the
  // tenant having just deleted it.
  match CloudAgents.Repository.githubOAuthRefreshStatus(CloudAgents.Scope.userScope(gh1)) {
    case Ok(None) -> ()
    case Ok(Some(_)) -> assertTrue(false, "refresh metadata must be dropped alongside GITHUB_TOKEN")
    case Err(e) -> assertTrue(false, "status read failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }

  // Deleting an unrelated credential must never touch refresh metadata.
  val gh2 = newUser("cred-gh2")
  mustPut(gh2, "GITHUB_TOKEN", "gho_other")
  mustPut(gh2, "OTHER_SECRET", "unrelated")
  match CloudAgents.Repository.upsertGitHubOAuthRefresh(CloudAgents.Scope.userScope(gh2), "refresh-888", "3600", "604800") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "upsert failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
  match deleteCredential(CloudAgents.Scope.userScope(gh2), "OTHER_SECRET") {
    case Ok(n) -> assertEqualInt(n, 1, "unrelated credential deleted")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.githubOAuthRefreshStatus(CloudAgents.Scope.userScope(gh2)) {
    case Ok(Some(_)) -> ()
    case Ok(None) -> assertTrue(false, "refresh metadata must survive deleting an unrelated credential")
    case Err(e) -> assertTrue(false, "status read failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
}
