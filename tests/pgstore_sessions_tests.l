//! Live-Postgres tests for CloudAgents.PgStore.Sessions
//! (docs/phase11-postgres-tenancy.md §4.2, §9 slices B/C): sessions behave
//! like the SQLite store, are isolated by tenant and user, and carry a global
//! route that resolves a session's scope and callback-token hash before any
//! tenant is set. Runs iff the Postgres DSNs are set (see
//! tests/pg_live_tests.l). Per-run unique ids keep it re-runnable.
@test_module
package CloudAgents.PgStoreSessionsTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import Db
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Sessions as Store
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env

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
  println("SKIP: PgStore session tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

/// A tenant row, as sign-in (or the export) will create it: `session_routes`
/// references `tenants`.
func ensureTenant(tenantId: in String): Unit {
  val conn = match CloudAgents.Pg.connectService() {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  match conn.execute("INSERT INTO tenants (id, name, kind) VALUES (@p0, @p0, 'personal') ON CONFLICT (id) DO NOTHING", [tenantId]) {
    case Ok(_) -> ()
    case Err(e) -> panic("tenant insert failed: " + e.message)
  }
}

func fresh(): CloudAgents.Pg.TenantScope {
  val sc = CloudAgents.Pg.personalScope("gh-pgs-" + uid())
  ensureTenant(sc.tenantId)
  return sc
}

/// Run one statement in a scope (fixtures for tables other domains own).
func execScoped(sc: in CloudAgents.Pg.TenantScope, sql: in String, params: in slice[String]): Unit {
  val conn = match CloudAgents.Pg.connectService() {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  val tx = match CloudAgents.Pg.beginTenantUnit(conn, sc) {
    case Ok(t) -> t
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  match CloudAgents.Pg.execIn(tx, sql, params) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  match CloudAgents.Pg.commitUnit(tx) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
}

func mk(id: in String): AgentSession {
  return makeAgentSession(
    sessionId = id,
    repoUrl = "https://github.com/acme/" + id,
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "m1",
    nativeSessionId = id
  )
}

func add(sc: in CloudAgents.Pg.TenantScope, id: in String): Unit {
  match Store.addSession(mk(id), sc) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + dbErrorMessage(e))
  }
}

func opt(r: in Result[Option[AgentSession], DbError]): Option[AgentSession] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func absent(r: in Result[Option[AgentSession], DbError]): Bool {
  return match opt(r) { case Some(_) -> false; case None -> true }
}

func optStr(r: in Result[Option[String], DbError]): String {
  return match r {
    case Ok(Some(v)) -> v
    case Ok(None) -> "<none>"
    case Err(e) -> panic("store call failed: " + dbErrorMessage(e))
  }
}

func claim(r: in Result[Bool, DbError]): Bool {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func unit(r: in Result[Unit, DbError]): Unit {
  match r {
    case Ok(_) -> ()
    case Err(e) -> panic("store call failed: " + dbErrorMessage(e))
  }
}

func ids(sc: in CloudAgents.Pg.TenantScope): String {
  val arr = match Store.getSessions(sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  var acc = ""
  var i = 0
  while i < getSessionArrayLength(arr) {
    acc = acc + getSessionArrayValue(arr, i).sessionId + ","
    i = i + 1
  }
  return acc
}

test "a session round-trips with SQLite's text forms and its route" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val id = "s-" + uid()
  add(sc, id)
  match opt(Store.getSession(id, sc)) {
    case Some(s) -> {
      assertEqual(s.repoUrl, "https://github.com/acme/" + id, "repo")
      assertEqual(s.status, "IDLE", "default status")
      assertEqual(s.isArchived, "0", "not archived")
      assertEqual(s.lastViewedAt, "0", "never viewed reads 0")
      assertEqual(s.groupId, "", "ungrouped")
      assertEqual(s.containerId, "", "no container")
    }
    case None -> assertTrue(false, "session not found")
  }
  assertEqual(optStr(Store.sessionOwnerUserId(id)), sc.userId, "route owner")
  assertEqual(optStr(Store.callbackTokenHashForSession(id)), "", "no token minted yet")
  match Store.sessionRouteScope(id) {
    case Ok(Some(r)) -> {
      assertEqual(r.tenantId, sc.tenantId, "route tenant")
      assertEqual(r.userId, sc.userId, "route user")
    }
    case Ok(None) -> assertTrue(false, "route missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqual(optStr(Store.callbackTokenHashForSession("no-such-" + uid())), "<none>", "unknown session")
}

test "updates, the container compare-and-clear, and viewing" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val id = "s-" + uid()
  add(sc, id)
  unit(Store.updateSessionModel(id, sc, "m2"))
  unit(Store.updateSessionArchived(id, sc, "1"))
  unit(Store.setSessionGroup(id, sc, "g1"))
  unit(Store.setSessionProfile(id, sc, "p1"))
  unit(Store.updateSessionContainerFor(id, sc, "c-new"))
  unit(Store.clearSessionContainerIfMatchesFor(id, sc, "c-old"))
  match opt(Store.getSession(id, sc)) {
    case Some(s) -> {
      assertEqual(s.model, "m2", "model")
      assertEqual(s.isArchived, "1", "archived")
      assertEqual(s.groupId, "g1", "group")
      assertEqual(s.containerId, "c-new", "a stale compare-and-clear leaves the newer container")
    }
    case None -> assertTrue(false, "session not found")
  }
  assertEqual(optStr(Store.sessionProfileId(id, sc)), "p1", "profile")
  unit(Store.clearSessionContainerIfMatchesFor(id, sc, "c-new"))
  unit(Store.updateSessionArchived(id, sc, "0"))
  unit(Store.markSessionViewed(id, sc))
  match opt(Store.getSession(id, sc)) {
    case Some(s) -> {
      assertEqual(s.containerId, "", "a matching compare-and-clear clears")
      assertEqual(s.isArchived, "0", "unarchived")
      assertTrue(s.lastViewedAt != "0" and s.lastViewedAt.length > 10, "viewed stamps epoch millis: " + s.lastViewedAt)
    }
    case None -> assertTrue(false, "session not found")
  }
}

test "a run claim is exclusive until endRun, and a missing session cannot be claimed" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val id = "s-" + uid()
  add(sc, id)
  assertTrue(claim(Store.tryBeginRun(id, sc)), "first claim wins")
  assertEqual(optStr(Store.sessionStatus(id, sc)), "RUNNING", "running")
  assertFalse(claim(Store.tryBeginRun(id, sc)), "second claim refused while running")
  unit(Store.endRun(id, sc))
  assertEqual(optStr(Store.sessionStatus(id, sc)), "IDLE", "idle after endRun")
  assertTrue(claim(Store.tryBeginRun(id, sc)), "claim available again")
  assertFalse(claim(Store.tryBeginRun("missing-" + uid(), sc)), "a missing session cannot be claimed")
}

test "lists are most recently active first and hide observer sessions" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val a = "a-" + uid()
  val b = "b-" + uid()
  add(sc, a)
  add(sc, b)
  // Touch a so it becomes the most recent.
  assertTrue(claim(Store.tryBeginRun(a, sc)), "claim a")
  unit(Store.endRun(a, sc))
  execScoped(
    sc,
    "INSERT INTO sessions (id, user_id, repo_url, harness, status, created_at, last_message_at, observes_session_id) " +
      "VALUES (@p0, @p1, 'r', 'claude', 'IDLE', now(), now() + interval '1 hour', @p2)",
    ["obs-" + uid(), sc.userId, a]
  )
  assertEqual(ids(sc), a + "," + b + ",", "recency order, observer hidden")
}

test "the session list counts pending callbacks and matches the shared JSON shape" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val id = "s-" + uid()
  add(sc, id)
  execScoped(
    sc,
    "INSERT INTO permission_requests (id, session_id, tool_name, input_json, status, created_at) " +
      "VALUES (@p0, @p1, 'Bash', '{}', 'pending', now())",
    [uid(), id]
  )
  execScoped(
    sc,
    "INSERT INTO permission_requests (id, session_id, tool_name, input_json, status, created_at) " +
      "VALUES (@p0, @p1, 'Bash', '{}', 'allowed', now())",
    [uid(), id]
  )
  val json = match Store.sessionSummariesJson(sc) { case Ok(j) -> j; case Err(e) -> panic(dbErrorMessage(e)) }
  assertTrue(json.startsWith("{\"sessions\":[{\"sessionId\":\"" + id + "\""), "one session: " + json)
  assertTrue(json.contains("\"pendingCount\":\"1\""), "only the pending request counts: " + json)
  assertTrue(json.contains("\"ledgerAttention\":\"0\""), "no ledger attention: " + json)
  assertTrue(json.contains("\"isArchived\":\"0\""), "archived text form: " + json)
  assertTrue(json.contains("\"attention\":\""), "derived attention present: " + json)
}

test "remove returns the record and drops the route; delete is a no-op when gone" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val id = "s-" + uid()
  add(sc, id)
  match opt(Store.removeSession(id, sc)) {
    case Some(s) -> assertEqual(s.sessionId, id, "removed record returned")
    case None -> assertTrue(false, "remove found nothing")
  }
  assertTrue(absent(Store.getSession(id, sc)), "gone")
  assertEqual(optStr(Store.sessionOwnerUserId(id)), "<none>", "route dropped")
  assertTrue(absent(Store.removeSession(id, sc)), "second remove finds nothing")
  unit(Store.deleteSessionRecord(id, sc))
}

test "callback tokens: only the hash is stored, and only the owner can mint" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val id = "s-" + uid()
  add(sc, id)
  val token = match Store.mintCallbackToken(id, sc) { case Ok(t) -> t; case Err(e) -> panic(dbErrorMessage(e)) }
  assertEqual(optStr(Store.callbackTokenHashForSession(id)), hashCallbackToken(token), "hash stored, not the token")
  assertTrue(
    authorizeCallback("Bearer " + token, optStr(Store.callbackTokenHashForSession(id))),
    "the token authorises"
  )
  val intruder = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-intruder-" + uid())
  match Store.mintCallbackToken(id, intruder) {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqual(
    optStr(Store.callbackTokenHashForSession(id)),
    hashCallbackToken(token),
    "another user's mint writes nothing"
  )
}

test "sessions are private to their user and tenant" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val id = "s-" + uid()
  add(sc, id)
  val otherUser = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-other-" + uid())
  val otherTenant = CloudAgents.Pg.TenantScope(tenantId = "org:pgs-" + uid(), userId = sc.userId)
  assertTrue(absent(Store.getSession(id, otherUser)), "another user in the tenant cannot read it")
  assertTrue(absent(Store.getSession(id, otherTenant)), "the same user in another tenant cannot read it")
  assertFalse(claim(Store.tryBeginRun(id, otherUser)), "nor claim it")
  assertTrue(absent(Store.removeSession(id, otherTenant)), "nor remove it")
  unit(Store.deleteSessionRecord(id, otherTenant))
  assertEqual(ids(otherUser), "", "another user's list is empty")
  assertTrue(not absent(Store.getSession(id, sc)), "still there for its owner")
  assertEqual(optStr(Store.sessionOwnerUserId(id)), sc.userId, "route untouched by the foreign delete")
  match Store.getSession(id, CloudAgents.Pg.TenantScope(tenantId = "", userId = sc.userId)) {
    case Ok(_) -> assertTrue(false, "an empty tenant must be rejected")
    case Err(e) -> assertTrue(
      dbErrorMessage(e).contains("invalid scope"),
      "rejected before any SQL: " + dbErrorMessage(e)
    )
  }
}

// ── Several instances (spec §5.3a) ─────────────────────────────────────────
func stranded(): slice[StrandedRun] {
  return match Store.claimStrandedRuns(100) {
    case Ok(v) -> v
    case Err(e) -> panic("claimStrandedRuns failed: " + dbErrorMessage(e))
  }
}

func strandedFor(runs: in slice[StrandedRun], id: in String): Option[StrandedRun] {
  for r in runs {
    if r.sessionId == id {
      return Some(value = r)
    }
  }
  return None
}

func warm(): slice[ReapTarget] {
  return match Store.reapableWarmContainers() {
    case Ok(v) -> v
    case Err(e) -> panic("reapableWarmContainers failed: " + dbErrorMessage(e))
  }
}

func warmFor(targets: in slice[ReapTarget], id: in String): Option[ReapTarget] {
  for t in targets {
    if t.sessionId == id {
      return Some(value = t)
    }
  }
  return None
}

func running(sc: in CloudAgents.Pg.TenantScope, container: in String): String {
  val id = "run-" + uid()
  add(sc, id)
  assertTrue(claim(Store.tryBeginRun(id, sc)), "claim " + id)
  execScoped(sc, "UPDATE sessions SET container_id = @p1 WHERE id = @p0", [id, container])
  return id
}

// The oldest possible heartbeat, so these rows lead the sweep's order even
// when earlier runs of this suite have left stale rows behind.
func goStale(sc: in CloudAgents.Pg.TenantScope, id: in String): Unit {
  execScoped(
    sc,
    "UPDATE sessions SET run_heartbeat_at = timestamptz 'epoch' + interval '1 millisecond' WHERE id = @p0",
    [id]
  )
}

test "a sweep takes stranded runs over in every tenant, once, and frees them" {
  if not live() {
    return
  }
  migrate()
  val a = fresh()
  val b = fresh()
  val staleA = running(a, "c-a")
  val staleB = running(b, "c-b")
  val live = running(a, "c-live")
  goStale(a, staleA)
  goStale(b, staleB)
  assertTrue(claim(Store.heartbeatRun(live, a)), "the live run heartbeats")

  val first = stranded()
  match strandedFor(first, staleA) {
    case Some(r) -> {
      assertEqual(r.tenantScope.tenantId, a.tenantId, "tenant A's run carries tenant A")
      assertEqual(r.tenantScope.userId, a.userId, "and its owner")
      assertEqual(r.containerId, "c-a", "and its container")
      assertEqual(r.previousInstance, CloudAgents.SessionStore.instanceId(), "and the instance that went quiet")
    }
    case None -> assertTrue(false, "tenant A's stranded run is taken over")
  }
  val rb = match strandedFor(first, staleB) {
    case Some(r) -> r
    case None -> panic("tenant B's stranded run is taken over")
  }
  match strandedFor(first, live) {
    case Some(_) -> assertTrue(false, "a run with a live heartbeat is not taken over")
    case None -> ()
  }
  match strandedFor(stranded(), staleA) {
    case Some(_) -> assertTrue(false, "an overlapping sweep does not take the same run")
    case None -> ()
  }
  assertFalse(claim(Store.heartbeatRun(staleA, a)), "a late heartbeat from the original instance changes nothing")
  unit(Store.endRun(staleA, a))
  assertEqual(optStr(Store.sessionStatus(staleA, a)), "RUNNING", "nor does its late endRun")

  assertTrue(claim(Store.releaseStrandedRun(rb)), "the sweep frees B's session")
  assertFalse(claim(Store.releaseStrandedRun(rb)), "freeing it twice is a no-op")
  match opt(Store.getSession(staleB, b)) {
    case Some(s) -> {
      assertEqual(s.status, "IDLE", "B is idle again")
      assertEqual(s.containerId, "", "with no container")
    }
    case None -> assertTrue(false, "B's session exists")
  }
  assertTrue(claim(Store.tryBeginRun(staleB, b)), "and can run again")
}

test "a RUNNING session with no heartbeat is stranded" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val id = running(sc, "c-none")
  execScoped(sc, "UPDATE sessions SET run_heartbeat_at = NULL WHERE id = @p0", [id])
  val r = match strandedFor(stranded(), id) {
    case Some(v) -> v
    case None -> panic("a heartbeat-less RUNNING session is taken over")
  }
  assertTrue(claim(Store.releaseStrandedRun(r)), "and freed")
}

test "the warm reaper leases idle WARM sessions in every tenant and never frees a running one" {
  if not live() {
    return
  }
  migrate()
  val a = fresh()
  val b = fresh()
  val oldA = "warm-" + uid()
  val oldB = "warm-" + uid()
  val recent = "warm-" + uid()
  val raced = "warm-" + uid()
  add(a, oldA)
  add(b, oldB)
  add(a, recent)
  add(a, raced)
  val idleWarm = "status = 'WARM', last_message_at = now() - interval '1 hour'"
  execScoped(a, "UPDATE sessions SET " + idleWarm + ", container_id = 'c-old-a' WHERE id = @p0", [oldA])
  execScoped(b, "UPDATE sessions SET " + idleWarm + ", container_id = 'c-old-b' WHERE id = @p0", [oldB])
  execScoped(a, "UPDATE sessions SET " + idleWarm + ", container_id = 'c-raced' WHERE id = @p0", [raced])
  execScoped(
    a,
    "UPDATE sessions SET status = 'WARM', container_id = 'c-recent', last_message_at = now() WHERE id = @p0",
    [recent]
  )

  val first = warm()
  val ta = match warmFor(first, oldA) { case Some(t) -> t; case None -> panic("tenant A's idle WARM session is found") }
  assertEqual(ta.containerId, "c-old-a", "with its container")
  assertEqual(ta.tenantScope.tenantId, a.tenantId, "under its tenant")
  match warmFor(first, oldB) {
    case Some(t) -> assertEqual(t.tenantScope.tenantId, b.tenantId, "tenant B's is found under tenant B")
    case None -> assertTrue(false, "tenant B's idle WARM session is found")
  }
  match warmFor(first, recent) {
    case Some(_) -> assertTrue(false, "a session inside the warm window is not reaped")
    case None -> ()
  }
  match warmFor(warm(), oldA) {
    case Some(_) -> assertTrue(false, "a leased session is not found by an overlapping reaper")
    case None -> ()
  }

  assertTrue(claim(Store.reapWarmSession(ta)), "the reaper frees A's session")
  assertFalse(claim(Store.reapWarmSession(ta)), "a second reap is a no-op")
  match warmFor(first, raced) {
    case Some(t) -> {
      assertTrue(claim(Store.tryBeginRun(raced, a)), "a run starts on the session after the scan")
      assertFalse(claim(Store.reapWarmSession(t)), "the reaper leaves the running session alone")
    }
    case None -> assertTrue(false, "the raced session is found")
  }
}

test "resetting a session's container is refused while it runs" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val id = running(sc, "c-reset")
  unit(Store.resetSessionContainer(id, sc))
  assertEqual(optStr(Store.sessionStatus(id, sc)), "RUNNING", "still running")
  unit(Store.endRun(id, sc))
  unit(Store.resetSessionContainer(id, sc))
  match opt(Store.getSession(id, sc)) {
    case Some(s) -> assertEqual(s.containerId, "", "an idle session's container is dropped")
    case None -> assertTrue(false, "session exists")
  }
}

// #1206: the sweep's name is stored whole, so its release still matches when
// the instance name is long.
test "a stranded run taken over under a long instance name is released" {
  if not live() {
    return
  }
  migrate()
  val original = Env.GetEnvironmentVariable("CLOUDAGENTS_INSTANCE_ID")
  defer {
    Env.SetEnvironmentVariable("CLOUDAGENTS_INSTANCE_ID", original)
  }
  var long = ""
  var i = 0
  while i < 250 {
    long = long + "x"
    i = i + 1
  }
  Env.SetEnvironmentVariable("CLOUDAGENTS_INSTANCE_ID", long)
  val sc = fresh()
  val id = running(sc, "c-long")
  goStale(sc, id)
  val r = match strandedFor(stranded(), id) { case Some(v) -> v; case None -> panic("the stale run is taken over") }
  assertTrue(r.sweeper.length.toInt() > 250, "the sweeper name is long")
  assertTrue(claim(Store.releaseStrandedRun(r)), "and the release still matches it")
}
