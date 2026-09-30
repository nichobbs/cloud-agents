//! Live-Postgres tests for CloudAgents.PgStore.Credentials
//! (docs/phase11-postgres-tenancy.md §4.3a, §9 slices B/C): the user-owned
//! vault, GitHub refresh metadata and model-listing cache behave like the
//! SQLite store, follow the user across tenants, and are private to them.
//! Runs iff the Postgres DSNs are set (see tests/pg_live_tests.l). Per-run
//! unique user ids keep it re-runnable.
@test_module
package CloudAgents.PgStoreCredentialsTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import Db
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Credentials as Vault
import CloudAgents.PgStore.Library as Library
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

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
  println("SKIP: PgStore credential tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

func freshUser(): String {
  return "gh-pgc-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func us(userId: in String): CloudAgents.Pg.UserScope {
  return CloudAgents.Pg.UserScope(userId = userId)
}

func put(userId: in String, name: in String, value: in String): Unit {
  match Vault.putCredential(us(userId), name, value) {
    case Ok(_) -> ()
    case Err(e) -> panic("putCredential failed: " + credentialErrorMessage(e))
  }
}

func names(userId: in String): String {
  val xs = match Vault.listCredentialNames(us(userId)) {
    case Ok(v) -> v
    case Err(e) -> panic("listCredentialNames failed: " + dbErrorMessage(e))
  }
  var acc = ""
  for x in xs {
    acc = acc + x.name + ","
  }
  return acc
}

func pairs(r: in Result[slice[CredentialValue], CredentialError]): String {
  val xs = match r { case Ok(v) -> v; case Err(e) -> panic("decrypt failed: " + credentialErrorMessage(e)) }
  var acc = ""
  for x in xs {
    acc = acc + x.name + "=" + x.value + ","
  }
  return acc
}

func value(userId: in String, name: in String): String {
  return match Vault.decryptedCredentialValue(us(userId), name) {
    case Ok(Some(v)) -> v
    case Ok(None) -> "<none>"
    case Err(e) -> "<error: " + credentialErrorMessage(e) + ">"
  }
}

func refreshState(userId: in String): String {
  return match Vault.githubOAuthRefreshStatus(us(userId)) {
    case Ok(Some(s)) -> {
      var a = "fresh"
      if s.accessTokenExpired {
        a = "expired"
      }
      var r = "fresh"
      if s.refreshTokenExpired {
        r = "expired"
      }
      s.refreshToken + ":" + a + ":" + r
    }
    case Ok(None) -> "<none>"
    case Err(e) -> panic("githubOAuthRefreshStatus failed: " + credentialErrorMessage(e))
  }
}

func upsertRefresh(userId: in String, token: in String, access: in String, refresh: in String): Unit {
  match Vault.upsertGitHubOAuthRefresh(us(userId), token, access, refresh) {
    case Ok(_) -> ()
    case Err(e) -> panic("upsertGitHubOAuthRefresh failed: " + credentialErrorMessage(e))
  }
}

func listing(userId: in String, provider: in String): String {
  return match Vault.cachedModelListing(us(userId), provider) {
    case Ok(Some(b)) -> b
    case Ok(None) -> "<none>"
    case Err(e) -> panic("cachedModelListing failed: " + dbErrorMessage(e))
  }
}

func cache(userId: in String, provider: in String, body: in String): Unit {
  match Vault.cacheModelListing(us(userId), provider, body) {
    case Ok(_) -> ()
    case Err(e) -> panic("cacheModelListing failed: " + dbErrorMessage(e))
  }
}

func int(r: in Result[Int, DbError]): Int {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

test "SQLite integer-cast parity for GitHub's expiry fields" {
  assertEqual(Vault.sqliteIntPrefix("3600"), "3600", "plain digits")
  assertEqual(Vault.sqliteIntPrefix("  42abc"), "42", "leading spaces and trailing junk")
  assertEqual(Vault.sqliteIntPrefix("-100"), "-100", "negative")
  assertEqual(Vault.sqliteIntPrefix("+7"), "7", "explicit plus")
  assertEqual(Vault.sqliteIntPrefix(""), "0", "empty is 0")
  assertEqual(Vault.sqliteIntPrefix("abc"), "0", "no digits is 0")
  assertEqual(Vault.sqliteIntPrefix("-"), "0", "a lone sign is 0")
}

test "credentials round-trip encrypted, byte-ordered, and a re-put replaces the value" {
  if not live() {
    return
  }
  migrate()
  val u = freshUser()
  put(u, "_LATE", "l")
  put(u, "B_KEY", "b1")
  put(u, "A_2", "a")
  put(u, "B_KEY", "b2")
  assertEqual(names(u), "A_2,B_KEY,_LATE,", "names in byte order, no duplicate after re-put")
  assertEqual(pairs(Vault.decryptedCredentials(us(u))), "A_2=a,B_KEY=b2,_LATE=l,", "values decrypt, re-put wins")
  assertEqual(value(u, "B_KEY"), "b2", "single lookup")
  assertEqual(value(u, "MISSING"), "<none>", "absent is None")
  match Vault.credentialNameExists(us(u), "A_2") {
    case Ok(b) -> assertTrue(b, "A_2 exists")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Vault.credentialNameExists(us(u), "a_2") {
    case Ok(b) -> assertFalse(b, "names are case-sensitive")
    case Err(e) -> panic(dbErrorMessage(e))
  }
}

test "an undecryptable row is skipped in bulk and an error when asked for by name" {
  if not live() {
    return
  }
  migrate()
  val u = freshUser()
  put(u, "GOOD", "ok")
  val conn = match CloudAgents.Pg.connectService() {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  val tx = match CloudAgents.Pg.beginUserUnit(conn, us(u)) {
    case Ok(t) -> t
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  match CloudAgents.Pg.execIn(tx, "INSERT INTO credentials (user_id, id, name, value_encrypted, created_at, updated_at) " + "VALUES (@p0, @p1, 'BROKEN', 'not-a-ciphertext', now(), now())", [u, Std.Uuid.uuidToString(Std.Uuid.newUuid())]) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  match CloudAgents.Pg.commitUnit(tx) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  assertEqual(pairs(Vault.decryptedCredentials(us(u))), "GOOD=ok,", "bulk decrypt skips the broken row")
  assertTrue(value(u, "BROKEN").startsWith("<error"), "a named lookup of the broken row is an error")
}

test "deleting GITHUB_TOKEN drops refresh metadata; deleting anything else keeps it" {
  if not live() {
    return
  }
  migrate()
  val a = freshUser()
  put(a, "GITHUB_TOKEN", "gho_a")
  upsertRefresh(a, "refresh-a", "3600", "604800")
  assertEqualInt(int(Vault.deleteCredential(us(a), "GITHUB_TOKEN")), 1, "token deleted")
  assertEqual(refreshState(a), "<none>", "refresh metadata dropped with the token")
  assertEqualInt(int(Vault.deleteCredential(us(a), "GITHUB_TOKEN")), 0, "a second delete finds nothing")
  val b = freshUser()
  put(b, "OTHER", "x")
  upsertRefresh(b, "refresh-b", "3600", "604800")
  assertEqualInt(int(Vault.deleteCredential(us(b), "OTHER")), 1, "other credential deleted")
  assertEqual(refreshState(b), "refresh-b:fresh:fresh", "refresh metadata kept")
}

test "refresh status applies the five-minute access margin and SQLite's cast semantics" {
  if not live() {
    return
  }
  migrate()
  val u = freshUser()
  assertEqual(refreshState(u), "<none>", "no metadata is a non-expiring token")
  upsertRefresh(u, "r1", "3600", "604800")
  assertEqual(refreshState(u), "r1:fresh:fresh", "an hour left is fresh")
  upsertRefresh(u, "r2", "120", "604800")
  assertEqual(refreshState(u), "r2:expired:fresh", "two minutes left is inside the margin")
  upsertRefresh(u, "r3", "-100", "-100")
  assertEqual(refreshState(u), "r3:expired:expired", "both past")
  upsertRefresh(u, "r4", "", "junk")
  assertEqual(refreshState(u), "r4:expired:expired", "missing or malformed expiries are 0, as on SQLite")
  match Vault.deleteGitHubOAuthRefresh(us(u)) {
    case Ok(_) -> ()
    case Err(e) -> panic(credentialErrorMessage(e))
  }
  assertEqual(refreshState(u), "<none>", "deleted")
}

test "profile injection: all, selected, missing profile, no profile" {
  if not live() {
    return
  }
  migrate()
  val u = freshUser()
  val sc = CloudAgents.Pg.personalScope(u)
  put(u, "A", "1")
  put(u, "B", "2")
  put(u, "C", "3")
  val none: slice[String] = []
  val granted: slice[String] = ["C", "A", "NOT_STORED"]
  val selected = match Library.addProfile(sc, "sel", "claude", "full", "selected", granted, none, none, none, "all", none) {
    case Ok(p) -> p
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val all = match Library.addProfile(sc, "all", "claude", "full", "all", none, none, none, none, "all", none) {
    case Ok(p) -> p
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqual(pairs(Vault.decryptedCredentialsForProfile(sc, selected.id)), "A=1,C=3,", "only granted and stored")
  assertEqual(pairs(Vault.decryptedCredentialsForProfile(sc, all.id)), "A=1,B=2,C=3,", "all mode")
  assertEqual(pairs(Vault.decryptedCredentialsForProfile(sc, "")), "A=1,B=2,C=3,", "no profile is every credential")
  assertEqual(
    pairs(Vault.decryptedCredentialsForProfile(sc, "no-such-profile")),
    "",
    "a missing profile injects nothing"
  )
}

test "the vault is private to its user and follows them across tenants" {
  if not live() {
    return
  }
  migrate()
  val a = freshUser()
  val b = freshUser()
  put(a, "SHARED_NAME", "from-a")
  put(b, "SHARED_NAME", "from-b")
  assertEqual(value(a, "SHARED_NAME"), "from-a", "a reads its own value")
  assertEqual(value(b, "SHARED_NAME"), "from-b", "b reads its own value")
  assertEqualInt(int(Vault.deleteCredential(us(b), "SHARED_NAME")), 1, "b deletes its own")
  assertEqual(value(a, "SHARED_NAME"), "from-a", "a's value survives b's delete")
  val otherTenant = CloudAgents.Pg.TenantScope(
    tenantId = "org:pgc-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()),
    userId = a
  )
  assertEqual(
    pairs(Vault.decryptedCredentialsForProfile(otherTenant, "")),
    "SHARED_NAME=from-a,",
    "same credentials under another tenant"
  )
  // Directly, under RLS: b's unit (tenant-scoped or not) sees none of a's rows.
  val conn = match CloudAgents.Pg.connectService() {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  val tx = match CloudAgents.Pg.beginTenantUnit(conn, CloudAgents.Pg.personalScope(b)) {
    case Ok(t) -> t
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  val seen = match CloudAgents.Pg.queryIn(tx, "SELECT count(*)::text AS n FROM credentials WHERE user_id = @p0", [a]) {
    case Ok(rows) -> Db.dbGetString(rows[0], "n")
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  CloudAgents.Pg.rollbackUnit(tx)
  assertEqual(seen, "0", "another user's unit cannot read a's credentials")
  match Vault.listCredentialNames(us("")) {
    case Ok(_) -> assertTrue(false, "an empty user scope must be rejected")
    case Err(e) -> assertTrue(
      dbErrorMessage(e).contains("invalid scope"),
      "rejected before any SQL: " + dbErrorMessage(e)
    )
  }
}

test "model listings are cached per user and provider" {
  if not live() {
    return
  }
  migrate()
  val a = freshUser()
  val b = freshUser()
  assertEqual(listing(a, "anthropic"), "<none>", "cold cache")
  cache(a, "anthropic", "{\"data\":[1]}")
  assertEqual(listing(a, "anthropic"), "{\"data\":[1]}", "hit after write")
  assertEqual(listing(a, "openai"), "<none>", "per provider")
  assertEqual(listing(b, "anthropic"), "<none>", "per user")
  cache(a, "anthropic", "{\"data\":[2]}")
  assertEqual(listing(a, "anthropic"), "{\"data\":[2]}", "a rewrite replaces the body")
}
