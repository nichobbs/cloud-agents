//! Live-Postgres tests for CloudAgents.PgStore.Interactive
//! (docs/phase11-postgres-tenancy.md §9 slices B/C): permission requests and
//! rules, user questions, progress, secret requests, artifacts,
//! notifications, and the capped repository memory and task list behave like
//! the SQLite store and stay inside their tenant. Runs iff the Postgres DSNs
//! are set (see tests/pg_live_tests.l). Per-run unique ids keep it
//! re-runnable.
@test_module
package CloudAgents.PgStoreInteractiveTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Interactive as Store
import CloudAgents.PgStore.Sessions as Sessions
import CloudAgents.Repository
import CloudAgents.SessionStore
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
  println("SKIP: PgStore interactive tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

func fresh(): CloudAgents.Pg.TenantScope {
  return CloudAgents.Pg.personalScope("gh-pgi-" + uid())
}

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

func int(r: in Result[Int, DbError]): Int {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func bool(r: in Result[Bool, DbError]): Bool {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func unit(r: in Result[Unit, DbError]): Unit {
  match r {
    case Ok(_) -> ()
    case Err(e) -> panic("store call failed: " + dbErrorMessage(e))
  }
}

func permStatus(id: in String, sc: in CloudAgents.Pg.TenantScope): String {
  return match Store.getPermissionRequest(id, sc) {
    case Ok(Some(p)) -> p.status + "|" + p.note
    case Ok(None) -> "<none>"
    case Err(e) -> panic(dbErrorMessage(e))
  }
}

test "permission requests: pending and pre-approved, answer once, timeout, cursor" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  val p1 = match Store.createPermissionRequest(sid, sc, "Bash", "{\"cmd\":\"ls\"}", false) {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val p2 = match Store.createPermissionRequest(sid, sc, "Bash", "{}", true) {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqual(permStatus(p1.id, sc), "pending|", "pending")
  assertEqual(permStatus(p2.id, sc), "allowed|allow-always rule matched", "pre-approved")
  match Store.getPermissionRequest(p2.id, sc) {
    case Ok(Some(p)) -> assertEqual(p.decidedAt, p2.createdAt, "pre-approved decided at creation")
    case Ok(None) -> assertTrue(false, "missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val all = match Store.permissionRequestsCreatedAfter(sid, sc, "") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(all.length.toInt(), 2, "empty cursor sees both")
  val after = match Store.permissionRequestsCreatedAfter(sid, sc, p2.createdAt) {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(after.length.toInt(), 0, "cursor is exclusive")
  unit(Store.timeoutPendingPermissionRequest(p1.id, sc, (3600000).toLong()))
  assertEqual(permStatus(p1.id, sc), "pending|", "not timed out before the timeout")
  assertEqualInt(int(Store.answerPermissionRequest(p1.id, sc, "allowed", "{}", "ok")), 1, "answered")
  assertEqualInt(int(Store.answerPermissionRequest(p1.id, sc, "denied", "", "")), 0, "a second answer is refused")
  val p3 = match Store.createPermissionRequest(sid, sc, "Edit", "{}", false) {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Store.timeoutPendingPermissionRequest(p3.id, sc, (0).toLong()))
  assertEqual(permStatus(p3.id, sc), "denied|timed out waiting for a human response", "timed out")
}

test "allow-always rules are exact and idempotent" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  unit(Store.addPermissionRule(sid, sc, "Bash", "{\"cmd\":\"ls\"}"))
  unit(Store.addPermissionRule(sid, sc, "Bash", "{\"cmd\":\"ls\"}"))
  assertTrue(bool(Store.permissionRuleMatches(sid, sc, "Bash", "{\"cmd\":\"ls\"}")), "matches")
  assertFalse(bool(Store.permissionRuleMatches(sid, sc, "Bash", "{\"cmd\":\"ls -la\"}")), "different input")
  assertFalse(bool(Store.permissionRuleMatches(sid, sc, "Edit", "{\"cmd\":\"ls\"}")), "different tool")
  assertFalse(bool(Store.permissionRuleMatches("s-" + uid(), sc, "Bash", "{\"cmd\":\"ls\"}")), "different session")
}

test "user questions and secret requests" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  val q = match Store.createUserQuestion(sid, sc, "Which?", "[\"a\",\"b\"]") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(int(Store.answerUserQuestion(q.id, sc, "a")), 1, "answered")
  assertEqualInt(int(Store.answerUserQuestion(q.id, sc, "b")), 0, "only once")
  match Store.getUserQuestion(q.id, sc) {
    case Ok(Some(x)) -> {
      assertEqual(x.status + ":" + x.answer, "answered:a", "stored answer")
      assertTrue(x.decidedAt.length > 10, "decided time set")
    }
    case Ok(None) -> assertTrue(false, "missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val q2 = match Store.createUserQuestion(sid, sc, "Free text?", "") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Store.timeoutPendingUserQuestion(q2.id, sc, (0).toLong()))
  match Store.getUserQuestion(q2.id, sc) {
    case Ok(Some(x)) -> assertEqual(x.status, "timed_out", "question timed out")
    case Ok(None) -> assertTrue(false, "missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val s1 = match Store.createSecretRequest(sid, sc, "API_KEY", "to call the API") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertFalse(bool(Store.markSecretRequestDelivered(s1.id, sc)), "not deliverable before approval")
  assertEqualInt(int(Store.answerSecretRequest(s1.id, sc, "approved")), 1, "approved")
  assertTrue(bool(Store.markSecretRequestDelivered(s1.id, sc)), "first delivery")
  assertFalse(bool(Store.markSecretRequestDelivered(s1.id, sc)), "delivered at most once")
  val secrets = match Store.secretRequestsCreatedAfter(sid, sc, "") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(secrets.length.toInt(), 1, "one secret request")
  assertEqual(secrets[0].status, "approved", "status")
}

test "progress reads back as SQLite text forms" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  ensureTenant(sc.tenantId)
  val sid = "s-" + uid()
  match Sessions.addSession(makeAgentSession(sessionId = sid, repoUrl = "r", branch = "", containerId = "", harness = "claude", model = "", nativeSessionId = sid), sc) {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.sessionProgress(sid, sc) {
    case Ok(p) -> assertEqual(p.summary + "|" + p.percent, "|", "never reported")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Store.updateSessionProgress(sid, sc, "halfway", "50"))
  match Store.sessionProgress(sid, sc) {
    case Ok(p) -> assertEqual(p.summary + "|" + p.percent, "halfway|50", "reported")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Store.updateSessionProgress(sid, sc, "no number", ""))
  match Store.sessionProgress(sid, sc) {
    case Ok(p) -> assertEqual(p.summary + "|" + p.percent, "no number|", "percent cleared")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.sessionProgress("missing-" + uid(), sc) {
    case Ok(p) -> assertEqual(p.summary + "|" + p.percent, "|", "unknown session")
    case Err(e) -> panic(dbErrorMessage(e))
  }
}

test "artifacts: session and repository scoped, owner-only repository reads" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  val a1 = match Store.createArtifact(sid, sc, "out.txt", "id1_out.txt", "text/plain", "", "12", "", "") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val a2 = match Store.createArtifact(sid, sc, "report.md", "id2_report.md", "text/markdown", "notes", "34", "github.com/acme/app", sc.userId) {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val listed = match Store.listArtifacts(sid, sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  assertEqualInt(listed.length.toInt(), 2, "both listed under the session")
  assertEqual(listed[0].sizeBytes, "12", "size text form")
  val repo = match Store.listRepoArtifacts(sc, "github.com/acme/app") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(repo.length.toInt(), 1, "only the repository-scoped one")
  assertEqual(repo[0].id, a2.id, "which one")
  val other = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-pgi-other-" + uid())
  match Store.getRepoArtifactById(a2.id, other) {
    case Ok(Some(_)) -> assertTrue(false, "another user must not read it")
    case Ok(None) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.getArtifact(a1.id, sc) {
    case Ok(Some(x)) -> assertEqual(x.createdAt, a1.createdAt, "exact created_at")
    case Ok(None) -> assertTrue(false, "missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val since = match Store.artifactsCreatedAfter(sid, sc, "") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(since.length.toInt(), 2, "cursor from the start")
}

test "memory is capped per owner and repository, and updates always succeed" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val repo = "github.com/acme/" + uid()
  assertTrue(bool(Store.upsertMemoryCapped(sc, repo, "b", "1", 2)), "first")
  assertTrue(bool(Store.upsertMemoryCapped(sc, repo, "A", "2", 2)), "second")
  assertFalse(bool(Store.upsertMemoryCapped(sc, repo, "c", "3", 2)), "a third key is refused at the cap")
  assertTrue(bool(Store.upsertMemoryCapped(sc, repo, "b", "updated", 2)), "an existing key updates at the cap")
  val mem = match Store.listMemory(sc, repo) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  assertEqualInt(mem.length.toInt(), 2, "two entries")
  assertEqual(mem[0].memKey + "," + mem[1].memKey + "=" + mem[1].value, "A,b=updated", "byte order, updated value")
  assertTrue(bool(Store.deleteMemory(sc, repo, "A")), "deleted")
  assertFalse(bool(Store.deleteMemory(sc, repo, "A")), "already gone")
  match Store.getMemory(sc, repo, "b") {
    case Ok(Some(m)) -> assertEqual(m.value, "updated", "get")
    case Ok(None) -> assertTrue(false, "missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val other = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-pgi-other-" + uid())
  val otherMem = match Store.listMemory(other, repo) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  assertEqualInt(otherMem.length.toInt(), 0, "memory is per owner")
}

test "open tasks are capped; completion is once" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val repo = "github.com/acme/" + uid()
  val t1 = match Store.addTaskCapped(sc, repo, "first", 1) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  assertTrue(t1.created, "first task")
  match Store.addTaskCapped(sc, repo, "second", 1) {
    case Ok(v) -> assertFalse(v.created, "refused at the open-task cap")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.completeTask(sc, repo, t1.id) {
    case Ok(TaskCompleted) -> ()
    case Ok(_) -> assertTrue(false, "expected completed")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.completeTask(sc, repo, t1.id) {
    case Ok(TaskAlreadyDone) -> ()
    case Ok(_) -> assertTrue(false, "expected already done")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.completeTask(sc, repo, "missing-" + uid()) {
    case Ok(TaskNotFound) -> ()
    case Ok(_) -> assertTrue(false, "expected not found")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.addTaskCapped(sc, repo, "second", 1) {
    case Ok(v) -> assertTrue(v.created, "room again once the first is done")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val open = match Store.listTasks(sc, repo, Some(value = "open")) {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(open.length.toInt(), 1, "one open")
  val every = match Store.listTasks(sc, repo, None) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  assertEqualInt(every.length.toInt(), 2, "two in all")
}

test "notifications, and nothing crosses tenants" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  val n1 = match Store.createNotification(sid, sc, "info", "one") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.createNotification(sid, sc, "done", "two") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val all = match Store.listNotifications(sid, sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  assertEqualInt(all.length.toInt(), 2, "two notifications")
  assertEqual(all[0].readAt, "", "unread reads as empty")
  val since = match Store.notificationsCreatedAfter(sid, sc, "") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqual(since[0].id, n1.id, "oldest first after a cursor")
  val otherTenant = fresh()
  val theirs = match Store.listNotifications(sid, otherTenant) {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(theirs.length.toInt(), 0, "another tenant sees no notifications for the same session id")
  val theirPerms = match Store.permissionRequestsCreatedAfter(sid, otherTenant, "") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(theirPerms.length.toInt(), 0, "nor permission requests")
}
