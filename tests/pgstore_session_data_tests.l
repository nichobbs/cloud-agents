//! Live-Postgres tests for CloudAgents.PgStore.SessionData
//! (docs/phase11-postgres-tenancy.md §9 slices B/C): run history, linked
//! repositories and session groups behave like the SQLite store and are
//! isolated by user and tenant. Runs iff the Postgres DSNs are set (see
//! tests/pg_live_tests.l). Per-run unique ids keep it re-runnable.
@test_module
package CloudAgents.PgStoreSessionDataTests

import Std.Core
import Std.Environment
import Std.File
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.SessionData as Store
import CloudAgents.PgStore.Sessions as Sessions
import CloudAgents.PgStore.Messages
import CloudAgents.Repository
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
  println("SKIP: PgStore session-data tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
  return CloudAgents.Pg.personalScope("gh-pgd-" + uid())
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

func runs(r: in Result[slice[Run], DbError]): slice[Run] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func repos(r: in Result[slice[SessionRepo], DbError]): slice[SessionRepo] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func groups(r: in Result[slice[SessionGroup], DbError]): slice[SessionGroup] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func group(r: in Result[SessionGroup, DbError]): SessionGroup {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func int(r: in Result[Int, DbError]): Int {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func unit(r: in Result[Unit, DbError]): Unit {
  match r {
    case Ok(_) -> ()
    case Err(e) -> panic("store call failed: " + dbErrorMessage(e))
  }
}

func groupNames(sc: in CloudAgents.Pg.TenantScope): String {
  var acc = ""
  for g in groups(Store.listSessionGroups(sc)) {
    acc = acc + g.name + "<" + g.parentId + ">,"
  }
  return acc
}

test "a run is recorded with a bounded preview and ends only once" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  var long = ""
  var i = 0
  while i < 60 {
    long = long + "0123456789"
    i = i + 1
  }
  val runId = match Store.recordRunStart(sid, sc, long, "claude", "opus") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val running = runs(Store.listRuns(sid, sc))
  assertEqualInt(running.length.toInt(), 1, "one run")
  assertEqual(running[0].status, "running", "running")
  assertEqual(running[0].endedAt, "", "no end time yet")
  assertEqualInt(running[0].promptPreview.length.toInt(), 500, "preview bounded like SQLite")
  unit(Store.recordRunEnd(runId, sc, "succeeded"))
  unit(Store.recordRunEnd(runId, sc, "failed"))
  val ended = runs(Store.listRuns(sid, sc))
  assertEqual(ended[0].status, "succeeded", "a finished run does not change again")
  assertTrue(ended[0].endedAt.length > 10, "end time set: " + ended[0].endedAt)
  match Store.recordRunStart(sid, sc, "again", "claude", "opus") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Store.finishSessionRuns(sid, sc, "cancelled"))
  val all = runs(Store.listRuns(sid, sc))
  assertEqualInt(all.length.toInt(), 2, "two runs")
  assertEqual(all[0].status, "cancelled", "newest first, and finishSessionRuns closed it")
  val other = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-pgd-other-" + uid())
  assertEqualInt(runs(Store.listRuns(sid, other)).length.toInt(), 0, "another user sees no runs")
}

test "linked repositories: add, count, duplicate guard, delete" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  match Store.addSessionRepo(sid, sc, "https://github.com/a/one", "main") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val two = match Store.addSessionRepo(sid, sc, "https://github.com/a/two", "") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(int(Store.countSessionRepos(sid, sc)), 2, "count")
  val listed = repos(Store.listSessionRepos(sid, sc))
  assertEqual(listed[0].repoUrl, "https://github.com/a/one", "oldest first")
  match Store.sessionRepoUrlExists(sid, sc, "https://github.com/a/two") {
    case Ok(b) -> assertTrue(b, "exists")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.sessionRepoUrlExists(sid, sc, "https://github.com/a/three") {
    case Ok(b) -> assertFalse(b, "absent")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(int(Store.deleteSessionRepo(sid, sc, two.id)), 1, "deleted")
  assertEqualInt(int(Store.deleteSessionRepo(sid, sc, two.id)), 0, "already gone")
  unit(Store.deleteSessionReposForSession(sid, sc))
  assertEqualInt(int(Store.countSessionRepos(sid, sc)), 0, "all removed")
  val otherTenant = CloudAgents.Pg.personalScope("gh-pgd-other-" + uid())
  match Store.addSessionRepo(sid, sc, "https://github.com/a/one", "main") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(int(Store.countSessionRepos(sid, otherTenant)), 0, "invisible across tenants")
}

test "groups sort by byte order and deleting one reparents children and sessions" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  ensureTenant(sc.tenantId)
  val root = group(Store.addSessionGroup(sc, "Root", ""))
  val child = group(Store.addSessionGroup(sc, "alpha", root.id))
  val grandchild = group(Store.addSessionGroup(sc, "Beta", child.id))
  assertEqual(
    groupNames(sc),
    "Beta<" + child.id + ">,Root<>,alpha<" + root.id + ">,",
    "byte order: uppercase before lowercase"
  )
  val sid = "s-" + uid()
  match Sessions.addSession(makeAgentSession(sessionId = sid, repoUrl = "r", branch = "", containerId = "", harness = "claude", model = "", nativeSessionId = sid), sc) {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Sessions.setSessionGroup(sid, sc, child.id) {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Store.deleteSessionGroupReparenting(child.id, sc, child.parentId))
  assertEqual(groupNames(sc), "Beta<" + root.id + ">,Root<>,", "grandchild moved up to the deleted group's parent")
  match Sessions.getSession(sid, sc) {
    case Ok(Some(s)) -> assertEqual(s.groupId, root.id, "session reassigned to the parent")
    case Ok(None) -> assertTrue(false, "session missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(int(Store.updateSessionGroup(grandchild.id, sc, "Gamma", "")), 1, "update")
  val other = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-pgd-other-" + uid())
  assertEqualInt(int(Store.updateSessionGroup(grandchild.id, other, "Hijack", "")), 0, "another user cannot update it")
  match Store.getSessionGroup(grandchild.id, other) {
    case Ok(Some(_)) -> assertTrue(false, "another user must not see the group")
    case Ok(None) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqual(groupNames(other), "", "another user's list is empty")
  assertEqual(groupNames(sc), "Gamma<>,Root<>,", "owner sees the update")
}

test "attachments link to their message and list oldest first" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  val a = match Store.createAttachment(sid, sc, "a.png", "stored-a", "image/png", "image", "1234") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.createAttachment(sid, sc, "b.pdf", "stored-b", "application/pdf", "document", "99") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Store.linkAttachmentToMessage(a.id, sc, "msg-1"))
  match Store.getAttachment(a.id, sc) {
    case Ok(Some(x)) -> {
      assertEqual(x.messageId, "msg-1", "linked")
      assertEqual(x.sizeBytes, "1234", "size text form")
      assertEqual(x.createdAt, a.createdAt, "exact created_at")
    }
    case Ok(None) -> assertTrue(false, "attachment missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val listed = match Store.listAttachments(sid, sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  assertEqualInt(listed.length.toInt(), 2, "two attachments")
  assertEqual(listed[0].fileName, "a.png", "oldest first")
  unit(Store.deleteAttachment(a.id, sc))
  match Store.getAttachment(a.id, sc) {
    case Ok(Some(_)) -> assertTrue(false, "deleted attachment still present")
    case Ok(None) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
}

test "highlights and the scan cursor round-trip" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  match Store.highlightScanSeq(sid, sc) {
    case Ok(v) -> assertEqual(v, "", "never scanned")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.addHighlight(sid, sc, "m1", "discovery", "Found it", "details") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Store.setHighlightScanSeq(sid, sc, "000000000005"))
  unit(Store.setHighlightScanSeq(sid, sc, "000000000007"))
  match Store.highlightScanSeq(sid, sc) {
    case Ok(v) -> assertEqual(v, "000000000007", "latest cursor in 12-digit form")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val hs = match Store.listHighlights(sid, sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  assertEqualInt(hs.length.toInt(), 1, "one highlight")
  assertEqual(hs[0].title, "Found it", "title")
}

test "branching copies the transcript prefix and what hangs off it, with its own route" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  ensureTenant(sc.tenantId)
  val parent = "p-" + uid()
  match Sessions.addSession(makeAgentSession(sessionId = parent, repoUrl = "https://github.com/acme/app", branch = "main", containerId = "", harness = "claude", model = "m", nativeSessionId = parent), sc) {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Sessions.setSessionProfile(parent, sc, "prof-1") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.addSessionRepo(parent, sc, "https://github.com/acme/lib", "dev") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val m0 = match CloudAgents.PgStore.Messages.addMessage(parent, sc, "user", "one") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val m1 = match CloudAgents.PgStore.Messages.addMessage(parent, sc, "agent", "two") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val m2 = match CloudAgents.PgStore.Messages.addMessage(parent, sc, "user", "three") {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match CloudAgents.PgStore.Messages.addComment(m1.id, sc, parent, "note on two") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match CloudAgents.PgStore.Messages.addTodo(parent, sc, m2.id, "after the fork") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match CloudAgents.PgStore.Messages.addTodo(parent, sc, "", "free-standing") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.addHighlight(parent, sc, m0.id, "discovery", "early", "d") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.createAttachment(parent, sc, "pic.png", "stored-pic", "image/png", "image", "3") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ATTACHMENTS_DIR", "/tmp/cloud-agents-tests-att-" + uid())
  val attDir = CloudAgents.Repository.attachmentsBaseDir()
  match Std.File.createDir(attDir + "/" + parent) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  match Std.File.writeText(attDir + "/" + parent + "/stored-pic", "png") {
    case Ok(_) -> ()
    case Err(_) -> panic("could not write the fixture file")
  }
  val child = "c-" + uid()
  unit(Store.branchSession(parent, m1.id, child, sc, "feature"))
  match Std.File.readText(attDir + "/" + child + "/stored-pic") {
    case Ok(t) -> assertEqual(t, "png", "free-standing attachment's file copied after commit")
    case Err(_) -> assertTrue(false, "attachment file was not copied to the branch")
  }
  match Sessions.getSession(child, sc) {
    case Ok(Some(s)) -> {
      assertEqual(s.branch, "feature", "new branch")
      assertEqual(s.parentSessionId, parent, "parent recorded")
      assertEqual(s.forkedFromMessageId, m1.id, "fork point recorded")
    }
    case Ok(None) -> assertTrue(false, "child missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Sessions.sessionProfileId(child, sc) {
    case Ok(Some(p)) -> assertEqual(p, "prof-1", "profile copied")
    case Ok(None) -> assertTrue(false, "child missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Sessions.sessionOwnerUserId(child) {
    case Ok(Some(o)) -> assertEqual(o, sc.userId, "child has its own route")
    case Ok(None) -> assertTrue(false, "child route missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val copied = match CloudAgents.PgStore.Messages.listMessages(child, sc) {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(copied.length.toInt(), 2, "prefix up to and including the fork message")
  assertEqual(copied[1].seq, m1.seq, "sequence numbers kept")
  assertEqual(copied[1].createdAt, m1.createdAt, "timestamps kept")
  assertTrue(copied[1].id != m1.id, "fresh message ids")
  val comments = match CloudAgents.PgStore.Messages.listComments(copied[1].id, sc) {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(comments.length.toInt(), 1, "comment follows its message")
  val todos = match CloudAgents.PgStore.Messages.listTodos(child, sc) {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(todos.length.toInt(), 1, "only the free-standing todo (the other hangs off a message after the fork)")
  assertEqual(todos[0].note, "free-standing", "which todo")
  val hs = match Store.listHighlights(child, sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  assertEqualInt(hs.length.toInt(), 1, "highlight on a copied message follows")
  assertEqualInt(int(Store.countSessionRepos(child, sc)), 1, "linked repos copied")
  match Store.branchSession(parent, "no-such-message", "c-" + uid(), sc, "") {
    case Ok(_) -> assertTrue(false, "an unknown fork point must fail")
    case Err(e) -> assertTrue(dbErrorMessage(e).contains("forked message not found"), dbErrorMessage(e))
  }
  val other = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-pgd-other-" + uid())
  match Store.branchSession(parent, "", "c-" + uid(), other, "") {
    case Ok(_) -> assertTrue(false, "another user must not branch the session")
    case Err(e) -> assertTrue(dbErrorMessage(e).contains("parent session not found"), dbErrorMessage(e))
  }
}
