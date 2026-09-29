//! Live-Postgres suite for the phase 11 foundations
//! (docs/phase11-postgres-tenancy.md §9 slice A, §10).
//!
//! Runs iff LYRIC_CONFIG_DB_CONNECTION_URL (the cloudagents_app DSN) and
//! CLOUD_AGENTS_MIGRATE_DATABASE_URL (the cloudagents_owner DSN) are set;
//! otherwise every test records a visible "skipped" assertion rather than
//! passing silently. The database must be provisioned with
//! deploy/postgres/provision.sql. Tests use per-run unique ids, so the suite
//! can re-run against the same database.
//!
//! It must run as cloudagents_app: FORCE ROW LEVEL SECURITY does not bind a
//! superuser or BYPASSRLS role, so the isolation assertions would be vacuous
//! under one. The self-check test below fails the suite if that is the case.
@test_module
package CloudAgents.PgLiveTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import Db
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.Pg.SelfCheck

func live(): Bool {
  val ok = CloudAgents.Pg.serviceConfigured() and
    Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "").length.toInt() > 0
  if ok {
    return true
  }
  // CI sets CLOUD_AGENTS_REQUIRE_LIVE_PG=1 so a missing DSN fails the suite
  // instead of letting it pass on skips alone.
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: live Postgres suite needs LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
  return false
}

func skipped(): Unit {
  assertTrue(true, "skipped: no Postgres DSN configured")
}

func uid(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func appConn(): DbConnection {
  return match CloudAgents.Pg.connectService() {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
}

func ownerConn(): DbConnection {
  return match CloudAgents.Pg.connectDsn(Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "")) {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
}

func ensureMigrated(): Unit {
  val conn = ownerConn()
  defer {
    conn.close()
  }
  match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(_) -> ()
    case Err(e) -> panic("migrate failed: " + CloudAgents.Pg.pgErrorMessage(e))
  }
}

func tenantUnit(conn: in DbConnection, tenantId: in String, userId: in String): DbTransaction {
  return match CloudAgents.Pg.beginTenantUnit(conn, TenantScope(tenantId = tenantId, userId = userId)) {
    case Ok(tx) -> tx
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
}

func userUnit(conn: in DbConnection, userId: in String): DbTransaction {
  return match CloudAgents.Pg.beginUserUnit(conn, UserScope(userId = userId)) {
    case Ok(tx) -> tx
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
}

func unscoped(conn: in DbConnection): DbTransaction {
  return match CloudAgents.Pg.beginUnscopedUnit(conn) {
    case Ok(tx) -> tx
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
}

func exec(tx: in DbTransaction, sql: in String, params: in slice[String]): Int {
  return match tx.execute(sql, params) {
    case Ok(n) -> n
    case Err(e) -> panic("execute failed: " + e.message + " — " + sql)
  }
}

/// Execute expecting failure; returns the error message ("" if it succeeded).
func execErr(tx: in DbTransaction, sql: in String, params: in slice[String]): String {
  return match tx.execute(sql, params) { case Ok(_) -> ""; case Err(e) -> e.message }
}

func rows(tx: in DbTransaction, sql: in String, params: in slice[String]): slice[DbRow] {
  return match tx.query(sql, params) {
    case Ok(r) -> r
    case Err(e) -> panic("query failed: " + e.message + " — " + sql)
  }
}

func str1(tx: in DbTransaction, sql: in String, params: in slice[String]): String {
  val r = rows(tx, sql, params)
  if r.length == 0 {
    return "<no rows>"
  }
  return Db.dbGetString(r[0], "v")
}

func commit(tx: in DbTransaction): Unit {
  match CloudAgents.Pg.commitUnit(tx) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
}

func insertSessionSql(): String {
  return "INSERT INTO sessions (id, user_id, repo_url, harness, status, created_at, last_message_at) " +
    "VALUES (@p0, @p1, 'https://example.com/r.git', 'claude', 'IDLE', now(), now())"
}

func countSessionsSql(): String {
  return "SELECT count(*)::text AS v FROM sessions WHERE id = @p0"
}

func contains(xs: in slice[String], x: in String): Bool {
  for y in xs {
    if y == x {
      return true
    }
  }
  return false
}

// ── Migrations and unit of work ────────────────────────────────────────────
test "migrations are idempotent and the schema is current" {
  if not live() {
    skipped()
    return
  }
  ensureMigrated()
  val conn = ownerConn()
  defer {
    conn.close()
  }
  match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(ran) -> assertEqualInt(ran.length.toInt(), 0, "a second run applies nothing")
    case Err(e) -> assertTrue(false, "second migrate failed: " + CloudAgents.Pg.pgErrorMessage(e))
  }
}

test "migrations refuse to run as the service role" {
  if not live() {
    skipped()
    return
  }
  val conn = appConn()
  defer {
    conn.close()
  }
  match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(_) -> assertTrue(false, "migrate must refuse cloudagents_app")
    case Err(e) -> assertTrue(
      CloudAgents.Pg.pgErrorMessage(e).contains("must run as cloudagents_owner"),
      "refusal names the required role"
    )
  }
}

test "a scope set in a unit is visible inside it and gone after commit on the same backend" {
  if not live() {
    skipped()
    return
  }
  ensureMigrated()
  val conn = appConn()
  defer {
    conn.close()
  }
  val tx = tenantUnit(conn, "t-uow-" + uid(), "u-uow")
  assertTrue(
    str1(tx, "SELECT current_setting('app.current_tenant', true) AS v", []).startsWith("t-uow-"),
    "tenant visible inside the unit"
  )
  assertEqual(str1(tx, "SELECT current_setting('app.current_user', true) AS v", []), "u-uow", "user visible inside")
  commit(tx)
  val after = unscoped(conn)
  assertEqual(
    str1(after, "SELECT coalesce(NULLIF(current_setting('app.current_tenant', true), ''), '<unset>') AS v", []),
    "<unset>",
    "tenant setting does not outlive the unit on a reused connection"
  )
  assertEqual(
    str1(after, "SELECT coalesce(NULLIF(current_setting('app.current_user', true), ''), '<unset>') AS v", []),
    "<unset>",
    "user setting does not outlive the unit"
  )
  commit(after)
}

// ── Tenant isolation ───────────────────────────────────────────────────────
test "two tenants see only their own rows, even with colliding ids" {
  if not live() {
    skipped()
    return
  }
  ensureMigrated()
  val run = uid()
  val ta = "t-a-" + run
  val tb = "t-b-" + run
  val sid = "s-" + run
  val conn = appConn()
  defer {
    conn.close()
  }
  val a = tenantUnit(conn, ta, "u-a")
  exec(a, insertSessionSql(), [sid, "u-a"])
  exec(
    a,
    "INSERT INTO session_events (session_id, seq, event_type, payload, hash, created_at) " +
      "VALUES (@p0, 0, 'assistant', @p1, 'h0', now())",
    [sid, "{\"from\":\"a\"}"]
  )
  commit(a)
  val b = tenantUnit(conn, tb, "u-b")
  exec(b, insertSessionSql(), [sid, "u-b"])
  commit(b)

  val ra = tenantUnit(conn, ta, "u-a")
  assertEqual(str1(ra, "SELECT user_id AS v FROM sessions WHERE id = @p0", [sid]), "u-a", "A sees its own copy")
  assertEqual(
    str1(ra, "SELECT count(*)::text AS v FROM session_events WHERE session_id = @p0", [sid]),
    "1",
    "A sees its event"
  )
  commit(ra)
  val rb = tenantUnit(conn, tb, "u-b")
  assertEqual(str1(rb, "SELECT user_id AS v FROM sessions WHERE id = @p0", [sid]), "u-b", "B sees its own copy")
  assertEqual(
    str1(rb, "SELECT count(*)::text AS v FROM session_events WHERE session_id = @p0", [sid]),
    "0",
    "B cannot see A's event"
  )
  assertEqual(
    str1(rb, "SELECT count(*)::text AS v FROM sessions WHERE tenant_id = @p0", [ta]),
    "0",
    "B cannot read A's rows even by naming A's tenant"
  )
  commit(rb)
}

test "a cross-tenant write is rejected and cannot touch the other tenant's rows" {
  if not live() {
    skipped()
    return
  }
  ensureMigrated()
  val run = uid()
  val ta = "t-a-" + run
  val tb = "t-b-" + run
  val conn = appConn()
  defer {
    conn.close()
  }
  val b = tenantUnit(conn, tb, "u-b")
  exec(b, insertSessionSql(), ["s-b-" + run, "u-b"])
  commit(b)

  val a = tenantUnit(conn, ta, "u-a")
  val err = execErr(
    a,
    "INSERT INTO sessions (tenant_id, id, user_id, repo_url, harness, status, created_at, last_message_at) " +
      "VALUES (@p0, @p1, 'u-a', 'r', 'claude', 'IDLE', now(), now())",
    [tb, "s-x-" + run]
  )
  assertTrue(err.contains("row-level security"), "insert naming another tenant is rejected by RLS")
  CloudAgents.Pg.rollbackUnit(a)

  val a2 = tenantUnit(conn, ta, "u-a")
  assertEqualInt(
    exec(a2, "UPDATE sessions SET model = 'hijacked' WHERE id = @p0", ["s-b-" + run]),
    0,
    "update of another tenant's row matches nothing"
  )
  assertEqualInt(exec(a2, "DELETE FROM sessions WHERE id = @p0", ["s-b-" + run]), 0, "delete matches nothing")
  commit(a2)

  val rb = tenantUnit(conn, tb, "u-b")
  assertEqual(str1(rb, "SELECT model AS v FROM sessions WHERE id = @p0", ["s-b-" + run]), "", "B's row untouched")
  commit(rb)
}

test "an unscoped unit reads nothing and cannot insert, even on a reused connection" {
  if not live() {
    skipped()
    return
  }
  ensureMigrated()
  val run = uid()
  val conn = appConn()
  defer {
    conn.close()
  }
  val a = tenantUnit(conn, "t-a-" + run, "u-a")
  exec(a, insertSessionSql(), ["s-" + run, "u-a"])
  commit(a)
  val u = unscoped(conn)
  assertEqual(str1(u, countSessionsSql(), ["s-" + run]), "0", "unscoped read sees nothing")
  commit(u)
  val u2 = unscoped(conn)
  assertTrue(execErr(u2, insertSessionSql(), ["s2-" + run, "u-a"]).length.toInt() > 0, "unscoped insert rejected")
  CloudAgents.Pg.rollbackUnit(u2)
  val u3 = unscoped(conn)
  assertEqual(
    str1(u3, "SELECT count(*)::text AS v FROM sessions WHERE tenant_id = ''", []),
    "0",
    "no empty-tenant row exists"
  )
  commit(u3)
}

test "an empty scope is rejected before any SQL is sent" {
  if not live() {
    skipped()
    return
  }
  val conn = appConn()
  defer {
    conn.close()
  }
  match CloudAgents.Pg.beginTenantUnit(conn, TenantScope(tenantId = "", userId = "u")) {
    case Ok(tx) -> {
      CloudAgents.Pg.rollbackUnit(tx)
      assertTrue(false, "empty tenant must be rejected")
    }
    case Err(e) -> assertEqual(CloudAgents.Pg.pgErrorMessage(e), "invalid scope: empty tenant id", "rejected")
  }
  match CloudAgents.Pg.beginUserUnit(conn, UserScope(userId = "")) {
    case Ok(tx) -> {
      CloudAgents.Pg.rollbackUnit(tx)
      assertTrue(false, "empty user must be rejected")
    }
    case Err(e) -> assertEqual(CloudAgents.Pg.pgErrorMessage(e), "invalid scope: empty user id", "rejected")
  }
}

// ── User-owned tables ──────────────────────────────────────────────────────
test "credentials follow their user across tenants and stay private to them" {
  if not live() {
    skipped()
    return
  }
  ensureMigrated()
  val run = uid()
  val u1 = "u1-" + run
  val conn = appConn()
  defer {
    conn.close()
  }
  val w = userUnit(conn, u1)
  exec(
    w,
    "INSERT INTO credentials (id, name, value_encrypted, created_at, updated_at) " +
      "VALUES (@p0, 'GITHUB_TOKEN', 'enc', now(), now())",
    ["c-" + run]
  )
  commit(w)
  val own = userUnit(conn, u1)
  assertEqual(str1(own, "SELECT count(*)::text AS v FROM credentials", []), "1", "owner reads it with no tenant set")
  commit(own)
  val inOrg = tenantUnit(conn, "t-org-" + run, u1)
  assertEqual(str1(inOrg, "SELECT count(*)::text AS v FROM credentials", []), "1", "still visible in any tenant")
  commit(inOrg)
  val other = tenantUnit(conn, "t-org-" + run, "u2-" + run)
  assertEqual(
    str1(other, "SELECT count(*)::text AS v FROM credentials WHERE user_id = @p0", [u1]),
    "0",
    "another member of the same tenant cannot read it"
  )
  commit(other)
}

// ── Claim functions ────────────────────────────────────────────────────────
func insertOutboxSql(): String {
  return "INSERT INTO graph_ingest_outbox (id, session_id, body, body_hash, url, created_at, next_attempt_at, delivered_at) " +
    "VALUES (@p0, 's', '{}', @p0, 'https://graph.example/ingest', now(), now() + (@p1 || ' seconds')::interval, " +
    "CASE WHEN @p2 = 'delivered' THEN now() ELSE NULL END)"
}

func claimOutbox(conn: in DbConnection, leaseSeconds: in String): slice[String] {
  val tx = unscoped(conn)
  val r = rows(
    tx,
    "SELECT tenant_id || '/' || id AS v FROM claim_graph_ingest_outbox(100, @p0::integer)",
    [leaseSeconds]
  )
  commit(tx)
  var acc: slice[String] = []
  for row in r {
    acc = acc.append(Db.dbGetString(row, "v"))
  }
  return acc
}

test "the outbox claim spans tenants, skips undue rows, and leases what it returns" {
  if not live() {
    skipped()
    return
  }
  ensureMigrated()
  val run = uid()
  val ta = "t-a-" + run
  val tb = "t-b-" + run
  val conn = appConn()
  defer {
    conn.close()
  }
  val a = tenantUnit(conn, ta, "u-a")
  exec(a, insertOutboxSql(), ["due-a-" + run, "-60", ""])
  exec(a, insertOutboxSql(), ["future-a-" + run, "3600", ""])
  exec(a, insertOutboxSql(), ["done-a-" + run, "-60", "delivered"])
  commit(a)
  val b = tenantUnit(conn, tb, "u-b")
  exec(b, insertOutboxSql(), ["due-b-" + run, "-60", ""])
  commit(b)

  val first = claimOutbox(conn, "300")
  assertTrue(contains(first, ta + "/due-a-" + run), "claims tenant A's due row")
  assertTrue(contains(first, tb + "/due-b-" + run), "claims tenant B's due row")
  assertTrue(not contains(first, ta + "/future-a-" + run), "does not claim a row not yet due")
  assertTrue(not contains(first, ta + "/done-a-" + run), "does not claim a delivered row")

  val second = claimOutbox(conn, "300")
  assertTrue(not contains(second, ta + "/due-a-" + run), "a live lease is not claimed again")
  assertTrue(not contains(second, tb + "/due-b-" + run), "a live lease is not claimed again (B)")

  val expire = tenantUnit(conn, ta, "u-a")
  exec(
    expire,
    "UPDATE graph_ingest_outbox SET claimed_until = now() - interval '1 second' WHERE id = @p0",
    ["due-a-" + run]
  )
  commit(expire)
  val third = claimOutbox(conn, "300")
  assertTrue(contains(third, ta + "/due-a-" + run), "an expired lease is claimable again")
}

test "concurrent claims never return the same row" {
  if not live() {
    skipped()
    return
  }
  ensureMigrated()
  val run = uid()
  val tenant = "t-c-" + run
  val setup = appConn()
  val w = tenantUnit(setup, tenant, "u")
  exec(w, insertOutboxSql(), ["row-" + run, "-60", ""])
  commit(w)
  setup.close()

  val c1 = appConn()
  val c2 = appConn()
  defer {
    c1.close()
    c2.close()
  }
  // c1 claims but does not commit yet, so it still holds the row lock.
  val t1 = unscoped(c1)
  val got1 = rows(t1, "SELECT tenant_id || '/' || id AS v FROM claim_graph_ingest_outbox(100, 300)", [])
  var ids1: slice[String] = []
  for r in got1 {
    ids1 = ids1.append(Db.dbGetString(r, "v"))
  }
  val ids2 = claimOutbox(c2, "300")
  commit(t1)
  assertTrue(contains(ids1, tenant + "/row-" + run), "the first caller claims the row")
  assertTrue(not contains(ids2, tenant + "/row-" + run), "the concurrent caller skips the locked row")
}

test "membership-sync claim returns only users with GitHub memberships" {
  if not live() {
    skipped()
    return
  }
  ensureMigrated()
  val run = uid()
  val withGh = "gh-u-" + run
  val nativeOnly = "native-u-" + run
  val org = "org-" + run
  val conn = appConn()
  defer {
    conn.close()
  }
  val g = unscoped(conn)
  exec(g, "INSERT INTO users (id) VALUES (@p0), (@p1)", [withGh, nativeOnly])
  exec(g, "INSERT INTO tenants (id, name, kind) VALUES (@p0, 'Org', 'native')", [org])
  exec(
    g,
    "INSERT INTO memberships (tenant_id, user_id, role, source) VALUES (@p0, @p1, 'member', 'github')",
    [org, withGh]
  )
  exec(
    g,
    "INSERT INTO memberships (tenant_id, user_id, role, source) VALUES (@p0, @p1, 'member', 'native')",
    [org, nativeOnly]
  )
  commit(g)
  for u in [withGh, nativeOnly] {
    val w = userUnit(conn, u)
    exec(w, "INSERT INTO user_sync_state (github_synced_at) VALUES (NULL)", [])
    commit(w)
  }
  val c = unscoped(conn)
  val got = rows(c, "SELECT user_id AS v FROM claim_membership_sync(100, 300)", [])
  commit(c)
  var ids: slice[String] = []
  for r in got {
    ids = ids.append(Db.dbGetString(r, "v"))
  }
  assertTrue(contains(ids, withGh), "claims a user with a GitHub membership")
  assertTrue(not contains(ids, nativeOnly), "skips a user with only native memberships")
}

test "claim functions are hardened: definer, fixed search_path, no PUBLIC execute, claimer-owned" {
  if not live() {
    skipped()
    return
  }
  ensureMigrated()
  val conn = appConn()
  defer {
    conn.close()
  }
  val tx = unscoped(conn)
  for fn in ["claim_graph_ingest_outbox", "claim_membership_sync"] {
    assertEqual(
      str1(
        tx,
        "SELECT (prosecdef AND pg_get_userbyid(proowner) = 'cloudagents_claimer' " +
          "AND proconfig @> ARRAY['search_path=pg_catalog, pg_temp'] " +
          "AND NOT EXISTS (SELECT 1 FROM aclexplode(proacl) a WHERE a.grantee = 0) " +
          "AND has_function_privilege('cloudagents_app', p.oid, 'EXECUTE'))::text AS v " +
          "FROM pg_proc p WHERE proname = @p0",
        [fn]
      ),
      "true",
      fn + " is hardened"
    )
  }
  assertEqual(
    str1(tx, "SELECT rolcanlogin::text AS v FROM pg_roles WHERE rolname = 'cloudagents_claimer'", []),
    "false",
    "the claimer role cannot log in"
  )
  assertEqual(
    str1(tx, "SELECT has_table_privilege('cloudagents_claimer', 'public.sessions', 'SELECT')::text AS v", []),
    "false",
    "the claimer cannot read non-claimable tables"
  )
  assertEqual(
    str1(
      tx,
      "SELECT (has_table_privilege('cloudagents_migrator', 'public.sessions', 'INSERT') " +
        "AND NOT has_table_privilege('cloudagents_migrator', 'public.sessions', 'UPDATE'))::text AS v",
      []
    ),
    "true",
    "the migrator may read and insert, nothing else"
  )
  commit(tx)
}

// ── Self-check ─────────────────────────────────────────────────────────────
test "the self-check refuses a service role that is a member of a privileged role" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  ensureMigrated()
  // No test role can create another role (all are NOCREATEROLE), so the
  // negative case uses the owner, which provision.sql makes a member of
  // cloudagents_claimer; the positive case checks the service role holds no
  // such membership.
  val owner = ownerConn()
  defer {
    owner.close()
  }
  match CloudAgents.Pg.SelfCheck.check(owner) {
    case Ok(_) -> assertTrue(false, "the owner role must fail the self-check")
    case Err(m) -> assertTrue(m.contains("owns") or m.contains("privileged"), "refused: " + m)
  }
  val app = appConn()
  defer {
    app.close()
  }
  val tx = unscoped(app)
  assertEqual(
    str1(
      tx,
      "SELECT coalesce(string_agg(r.rolname, ','), '') AS v FROM pg_roles r WHERE r.rolname <> current_user " +
        "AND pg_has_role(current_user, r.oid, 'MEMBER') AND (r.rolsuper OR r.rolbypassrls OR r.rolname IN " +
        "('cloudagents_owner', 'cloudagents_claimer', 'cloudagents_migrator'))",
      []
    ),
    "",
    "the provisioned service role holds no privileged membership"
  )
  commit(tx)
}

test "the self-check passes for the service role and fails for the owner" {
  if not live() {
    skipped()
    return
  }
  ensureMigrated()
  val app = appConn()
  defer {
    app.close()
  }
  match CloudAgents.Pg.SelfCheck.check(app) {
    case Ok(_) -> assertTrue(true, "service role passes")
    case Err(m) -> assertTrue(false, "service role must pass the self-check: " + m)
  }
  val owner = ownerConn()
  defer {
    owner.close()
  }
  match CloudAgents.Pg.SelfCheck.check(owner) {
    case Ok(_) -> assertTrue(false, "the owner role must fail the self-check")
    case Err(m) -> assertTrue(m.contains("owns"), "the owner is refused because it owns tables: " + m)
  }
}
