//! Repo-scoped task tests (phase 7 §8): the add_task / list_tasks / complete_task
//! callbacks over the Postgres store.
@test_module
package CloudAgents.RepoTasksTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Callbacks
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite

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
    return true
  }
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: repo task tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

func uniq(prefix: in String): String {
  return prefix + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

/// A repo URL unique to this test's user, so tasks never leak across tests.
func repoOf(me: in String): String {
  return "https://github.com/t/" + me
}

func mkSessionRepo(id: in String, repoUrl: in String): Unit {
  val s = makeAgentSession(
    sessionId = id,
    repoUrl = repoUrl,
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = id
  )
  match addSession(s, CloudAgents.Auth.requestScope()) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mkSession(id: in String, me: in String): Unit {
  mkSessionRepo(id, repoOf(me))
}

func mintToken(id: in String, ownerUserId: in String): String {
  return match CloudAgents.SessionStore.mintCallbackToken(id, CloudAgents.Pg.personalScope(ownerUserId)) {
    case Ok(t) -> t
    case Err(e) -> panic("mintCallbackToken failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func bearer(token: in String): String {
  return "Bearer " + token
}

// ── add_task / list_tasks / complete_task (phase 7 §8) ───────────────────────
test "add_task then list_tasks: appears in the open list" {
  if not live() {
    return
  }
  val me = freshUser("tasks-roundtrip")
  val sid = uniq("sess-tasks-1")
  mkSession(sid, me)
  val token = mintToken(sid, me)

  val created = match createTaskHandler(sid, bearer(token), CreateTaskRequest(description = "migrate the auth module")) {
    case Ok(r) -> r
    case Err(e) -> panic("createTask failed: " + toString(e.status))
  }
  assertTrue(created.id.length > 0, "add_task returns a minted id")

  match listTasksHandler(sid, bearer(token), None) {
    case Ok(l) -> {
      assertEqualInt(l.tasks.length.toInt(), 1, "the new task shows up unfiltered")
      assertEqual(l.tasks[0].id, created.id, "same id round-trips")
      assertEqual(l.tasks[0].description, "migrate the auth module", "description round-trips")
      assertEqual(l.tasks[0].status, "open", "a freshly created task is open")
    }
    case Err(e) -> assertTrue(false, "listTasks failed: " + toString(e.status))
  }

  match listTasksHandler(sid, bearer(token), Some(value = "open")) {
    case Ok(l) -> assertEqualInt(l.tasks.length.toInt(), 1, "status=open includes the new task")
    case Err(e) -> assertTrue(false, "listTasks(open) failed: " + toString(e.status))
  }
  match listTasksHandler(sid, bearer(token), Some(value = "done")) {
    case Ok(l) -> assertEqualInt(l.tasks.length.toInt(), 0, "status=done excludes an open task")
    case Err(e) -> assertTrue(false, "listTasks(done) failed: " + toString(e.status))
  }
}

test "complete_task moves a task from open to done, and re-completing is a no-op success" {
  if not live() {
    return
  }
  val me = freshUser("tasks-complete")
  val sid = uniq("sess-tasks-2")
  mkSession(sid, me)
  val token = mintToken(sid, me)

  val created = match createTaskHandler(sid, bearer(token), CreateTaskRequest(description = "write the release notes")) {
    case Ok(r) -> r
    case Err(e) -> panic("createTask failed: " + toString(e.status))
  }

  match completeTaskHandler(sid, bearer(token), created.id) {
    case Ok(r) -> {
      assertEqual(r.id, created.id, "completion echoes the task id")
      assertEqual(r.status, "done", "completion reports done")
    }
    case Err(e) -> assertTrue(false, "completeTask failed: " + toString(e.status))
  }

  match listTasksHandler(sid, bearer(token), Some(value = "open")) {
    case Ok(l) -> assertEqualInt(l.tasks.length.toInt(), 0, "the task is gone from the open list")
    case Err(e) -> assertTrue(false, "listTasks(open) failed: " + toString(e.status))
  }
  match listTasksHandler(sid, bearer(token), Some(value = "done")) {
    case Ok(l) -> {
      assertEqualInt(l.tasks.length.toInt(), 1, "the task appears in the done list")
      assertEqual(l.tasks[0].id, created.id, "it's the same task")
    }
    case Err(e) -> assertTrue(false, "listTasks(done) failed: " + toString(e.status))
  }

  // complete_task is idempotent: completing an already-done task succeeds
  // (no-op), it is not an error.
  match completeTaskHandler(sid, bearer(token), created.id) {
    case Ok(r) -> assertEqual(r.status, "done", "re-completing an already-done task is a success no-op")
    case Err(e) -> assertTrue(false, "idempotent complete_task must not error: " + toString(e.status))
  }
}

test "complete_task 404s for an unknown or cross-scope task id" {
  if not live() {
    return
  }
  val me = freshUser("tasks-scope")

  val sidA = uniq("sess-tasks-scope-A")
  mkSessionRepo(sidA, repoOf(me) + "-a")
  val tokenA = mintToken(sidA, me)
  val created = match createTaskHandler(sidA, bearer(tokenA), CreateTaskRequest(description = "repo-a task")) {
    case Ok(r) -> r
    case Err(e) -> panic("createTask failed: " + toString(e.status))
  }

  // A session on a DIFFERENT repo cannot complete repo-a's task — 404, not a
  // leak of "it exists elsewhere".
  val sidB = uniq("sess-tasks-scope-B")
  mkSessionRepo(sidB, repoOf(me) + "-b")
  val tokenB = mintToken(sidB, me)
  match completeTaskHandler(sidB, bearer(tokenB), created.id) {
    case Ok(_) -> assertTrue(false, "a cross-repo task id must not be completable")
    case Err(e) -> assertEqualInt(e.status, 404, "cross-repo task id -> 404")
  }

  // A genuinely unknown id also 404s.
  match completeTaskHandler(sidA, bearer(tokenA), "no-such-task-id") {
    case Ok(_) -> assertTrue(false, "an unknown task id must not be completable")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown task id -> 404")
  }
}

test "tasks carry across sessions on the same repo, isolated from other repos" {
  if not live() {
    return
  }
  val me = freshUser("tasks-cross-session")

  val sidA = uniq("sess-tasks-cross-A")
  mkSession(sidA, me)
  val tokenA = mintToken(sidA, me)
  match createTaskHandler(sidA, bearer(tokenA), CreateTaskRequest(description = "left for the next session")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "createTask A failed: " + toString(e.status))
  }

  // A brand-new session on the SAME repo sees the earlier session's task.
  val sidB = uniq("sess-tasks-cross-B")
  mkSession(sidB, me)
  val tokenB = mintToken(sidB, me)
  match listTasksHandler(sidB, bearer(tokenB), None) {
    case Ok(l) -> {
      assertEqualInt(l.tasks.length.toInt(), 1, "a new session on the same repo inherits the task")
      assertEqual(l.tasks[0].description, "left for the next session", "the earlier session's task is readable")
    }
    case Err(e) -> assertTrue(false, "listTasks B failed: " + toString(e.status))
  }

  // A session on a DIFFERENT repo sees none of it.
  val sidC = uniq("sess-tasks-cross-C")
  mkSessionRepo(sidC, repoOf(me) + "-other")
  val tokenC = mintToken(sidC, me)
  match listTasksHandler(sidC, bearer(tokenC), None) {
    case Ok(l) -> assertEqualInt(l.tasks.length.toInt(), 0, "a different repo shares no tasks")
    case Err(e) -> assertTrue(false, "listTasks C failed: " + toString(e.status))
  }
}

test "add_task validates description and rejects a session with no repo to scope to" {
  if not live() {
    return
  }
  val me = freshUser("tasks-validation")
  val sid = uniq("sess-tasks-val")
  mkSession(sid, me)
  val token = mintToken(sid, me)

  match createTaskHandler(sid, bearer(token), CreateTaskRequest(description = "")) {
    case Ok(_) -> assertTrue(false, "empty description must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty description -> 400")
  }

  val sidNoRepo = uniq("sess-tasks-norepo")
  mkSessionRepo(sidNoRepo, "")
  val tokenNoRepo = mintToken(sidNoRepo, me)
  match createTaskHandler(sidNoRepo, bearer(tokenNoRepo), CreateTaskRequest(description = "x")) {
    case Ok(_) -> assertTrue(false, "a session with no repo must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "no repo -> 400")
  }
}

test "list_tasks requires a valid callback token; the owner can list via the user route" {
  if not live() {
    return
  }
  val me = freshUser("tasks-auth")
  val sid = uniq("sess-tasks-auth")
  mkSession(sid, me)
  val token = mintToken(sid, me)

  match listTasksHandler(sid, bearer("wrong-token"), None) {
    case Ok(_) -> assertTrue(false, "a wrong callback token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 401, "bad token -> 401")
  }
  match createTaskHandler(sid, bearer(token), CreateTaskRequest(description = "x")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "createTask failed: " + toString(e.status))
  }
  match listSessionTasksHandler(sid) {
    case Ok(l) -> assertEqualInt(l.tasks.length.toInt(), 1, "the owner can list the repo's tasks via the user route")
    case Err(e) -> assertTrue(false, "listSessionTasks failed: " + toString(e.status))
  }
}

test "list_tasks rejects an invalid status filter" {
  if not live() {
    return
  }
  val me = freshUser("tasks-status-filter")
  val sid = uniq("sess-tasks-filter")
  mkSession(sid, me)
  val token = mintToken(sid, me)

  match listTasksHandler(sid, bearer(token), Some(value = "bogus")) {
    case Ok(_) -> assertTrue(false, "an invalid status filter must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "invalid status -> 400")
  }
}

// The single most important test for this slice: the cap counts OPEN tasks
// specifically, not lifetime total. Filling to the cap with open tasks
// blocks the next add_task; completing ONE existing task frees exactly one
// slot for a new task (docs/phase7-autonomy.md §8's headline design
// decision).
test "add_task caps the number of OPEN tasks per repo; completing one frees a slot" {
  if not live() {
    return
  }
  val me = freshUser("tasks-cap")
  val sid = uniq("sess-tasks-cap")
  mkSession(sid, me)
  val token = mintToken(sid, me)

  // Fill the repo to exactly the cap (256 open tasks).
  var i = 0
  var firstId = ""
  while i < 256 {
    match createTaskHandler(sid, bearer(token), CreateTaskRequest(description = "task " + toString(i))) {
      case Ok(r) -> {
        if i == 0 {
          firstId = r.id
        }
      }
      case Err(e) -> assertTrue(false, "createTask " + toString(i) + " failed: " + toString(e.status))
    }
    i = i + 1
  }

  // A 257th open task is rejected.
  match createTaskHandler(sid, bearer(token), CreateTaskRequest(description = "one too many")) {
    case Ok(_) -> assertTrue(false, "a new open task past the cap must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "over-cap add_task -> 400")
  }

  // Complete ONE existing task, freeing exactly one slot — proving the cap
  // counts OPEN tasks, not lifetime total (a done task must not still count
  // against the cap).
  match completeTaskHandler(sid, bearer(token), firstId) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "completing the first task failed: " + toString(e.status))
  }

  match createTaskHandler(sid, bearer(token), CreateTaskRequest(description = "now there's room")) {
    case Ok(r) -> assertTrue(r.id.length > 0, "add_task succeeds once a slot is freed by completion")
    case Err(e) -> assertTrue(false, "add_task should succeed after freeing a slot: " + toString(e.status))
  }

  // The repo is back at the cap (255 open from the original fill minus the
  // one completed, plus the one just added = 256 open again); one more must
  // be rejected.
  match createTaskHandler(sid, bearer(token), CreateTaskRequest(description = "over the refilled cap")) {
    case Ok(_) -> assertTrue(false, "the repo should be back at the open-task cap")
    case Err(e) -> assertEqualInt(e.status, 400, "over the refilled cap -> 400")
  }
}
