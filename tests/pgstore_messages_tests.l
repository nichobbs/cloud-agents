//! Live-Postgres tests for CloudAgents.PgStore.Messages
//! (docs/phase11-postgres-tenancy.md §9 slices B/C): a session's messages,
//! comments and todos behave like the SQLite store and are isolated by
//! tenant. Runs iff the Postgres DSNs are set (see tests/pg_live_tests.l).
//! Per-run unique ids keep it re-runnable.
@test_module
package CloudAgents.PgStoreMessagesTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore
import CloudAgents.PgStore.Messages as Store
import CloudAgents.PgStore.Sessions as Sessions
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite

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
  println("SKIP: PgStore message tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
  return CloudAgents.Pg.personalScope("gh-pgm-" + uid())
}

func msg(r: in Result[Message, DbError]): Message {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func msgs(r: in Result[slice[Message], DbError]): slice[Message] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func todoList(r: in Result[slice[Todo], DbError]): slice[Todo] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func updates(r: in Result[slice[TodoUpdate], DbError]): slice[TodoUpdate] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func optStr(r: in Result[Option[String], DbError]): String {
  return match r {
    case Ok(Some(v)) -> v
    case Ok(None) -> "<none>"
    case Err(e) -> panic("store call failed: " + dbErrorMessage(e))
  }
}

func unit(r: in Result[Unit, DbError]): Unit {
  match r {
    case Ok(_) -> ()
    case Err(e) -> panic("store call failed: " + dbErrorMessage(e))
  }
}

func todoSummary(sid: in String, sc: in CloudAgents.Pg.TenantScope): String {
  var acc = ""
  for t in todoList(Store.listTodos(sid, sc)) {
    acc = acc + t.note + ":" + t.status + ":" + t.done + ","
  }
  return acc
}

test "messages get padded sequence numbers in order and round-trip exactly" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  val a = msg(Store.addMessage(sid, sc, "user", "hello"))
  val b = msg(Store.addMessage(sid, sc, "agent", "hi there"))
  assertEqual(a.seq, "000000000000", "first seq")
  assertEqual(b.seq, "000000000001", "second seq")
  val listed = msgs(Store.listMessages(sid, sc))
  assertEqualInt(listed.length.toInt(), 2, "two messages")
  assertEqual(listed[0].id, a.id, "sequence order")
  assertEqual(listed[1].content, "hi there", "content")
  assertEqual(listed[1].seq, "000000000001", "listed seq padded")
  assertEqual(listed[0].createdAt, a.createdAt, "exact created_at round-trip")
  assertEqual(optStr(Store.getMessageSessionId(b.id, sc)), sid, "message to session")
  assertEqual(optStr(Store.getMessageSessionId("missing-" + uid(), sc)), "<none>", "unknown message")
  var i = 0
  while i < 10 {
    msg(Store.addMessage(sid, sc, "user", "more"))
    i = i + 1
  }
  val all = msgs(Store.listMessages(sid, sc))
  var distinct = true
  var j = 1
  while j < all.length {
    if all[j].seq == all[j - 1].seq {
      distinct = false
    }
    j = j + 1
  }
  assertTrue(distinct, "sequence numbers stay distinct")
  assertEqual(all[all.length - 1].seq, "000000000011", "twelve messages, last seq 11")
}

test "comments list oldest first under their message" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  val m = msg(Store.addMessage(sid, sc, "agent", "text"))
  match Store.addComment(m.id, sc, sid, "first") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.addComment(m.id, sc, sid, "second") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val cs = match Store.listComments(m.id, sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  assertEqualInt(cs.length.toInt(), 2, "two comments")
  assertEqual(cs[0].body, "first", "oldest first")
  assertEqual(cs[1].sessionId, sid, "bound to its session")
}

test "todos: add, status, toggle, delete, and the update cursor" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  val t = match Store.addTodo(sid, sc, "", "write docs") { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  assertEqual(t.status, "pending", "new todo pending")
  assertEqual(todoSummary(sid, sc), "write docs:pending:0,", "listed")
  assertEqualInt(updates(Store.todosUpdatedAfter(sid, sc, "")).length.toInt(), 1, "empty cursor sees everything")
  val cursor = updates(Store.todosUpdatedAfter(sid, sc, ""))[0].updatedAt
  assertEqualInt(updates(Store.todosUpdatedAfter(sid, sc, cursor)).length.toInt(), 0, "the cursor is exclusive")
  unit(Store.setTodoStatus(t.id, sc, "in_progress"))
  assertEqual(todoSummary(sid, sc), "write docs:in_progress:0,", "status set")
  unit(Store.setTodoStatus(t.id, sc, "done"))
  assertEqual(todoSummary(sid, sc), "write docs:done:1,", "done follows status")
  unit(Store.toggleTodo(t.id, sc))
  assertEqual(todoSummary(sid, sc), "write docs:pending:0,", "toggle back to pending")
  unit(Store.toggleTodo(t.id, sc))
  assertEqual(todoSummary(sid, sc), "write docs:done:1,", "toggle to done")
  assertEqual(optStr(Store.getTodoSessionId(t.id, sc)), sid, "todo to session")
  unit(Store.deleteTodo(t.id, sc))
  assertEqual(todoSummary(sid, sc), "", "deleted")
}

test "plan replacement keeps human todos and lists steps in plan order" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  match Store.addTodo(sid, sc, "", "human note") {
    case Ok(_) -> ()
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Store.replacePlanTodos(sid, sc, "m1", ["old one", "old two"], ["pending", "pending"]))
  unit(
    Store.replacePlanTodos(
      sid,
      sc,
      "m2",
      ["step one", "step two", "step three"],
      ["done", "in_progress", "pending", "extra"]
    )
  )
  val all = todoList(Store.listTodos(sid, sc))
  var plan = ""
  var human = 0
  for td in all {
    if td.note == "human note" {
      human = human + 1
    } else {
      plan = plan + td.note + ":" + td.status + ":" + td.done + ","
    }
  }
  assertEqualInt(human, 1, "the human todo survives")
  assertEqual(
    plan,
    "step one:done:1,step two:in_progress:0,step three:pending:0,",
    "latest plan only, step order, parallel slices bounded"
  )
}

test "a session's transcript is invisible to another tenant" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  val m = msg(Store.addMessage(sid, sc, "user", "secret"))
  val other = CloudAgents.Pg.personalScope("gh-pgm-other-" + uid())
  assertEqualInt(msgs(Store.listMessages(sid, other)).length.toInt(), 0, "no messages across tenants")
  assertEqual(optStr(Store.getMessageSessionId(m.id, other)), "<none>", "no message lookup across tenants")
  // The next sequence number counts only this tenant's rows.
  val n = msg(Store.addMessage(sid, other, "user", "same session id, other tenant"))
  assertEqual(n.seq, "000000000000", "sequence is per tenant")
  assertEqualInt(
    msgs(Store.listMessages(sid, sc)).length.toInt(),
    1,
    "the original tenant still sees only its own message"
  )
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

func newSession(sc: in CloudAgents.Pg.TenantScope): String {
  ensureTenant(sc.tenantId)
  val sid = "s-" + uid()
  unit(
    Sessions.addSession(
      makeAgentSession(
        sessionId = sid,
        repoUrl = "r",
        branch = "",
        containerId = "",
        harness = "claude",
        model = "",
        nativeSessionId = sid
      ),
      sc
    )
  )
  return sid
}

// Pin a message's created_at so newest-first assertions never depend on two
// inserts landing in different milliseconds.
func pinCreated(sc: in CloudAgents.Pg.TenantScope, id: in String, ms: in String): Unit {
  val u = match CloudAgents.PgStore.open(sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, "UPDATE messages SET created_at = " + CloudAgents.Pg.msIn(1) + " WHERE id = @p0", [id, ms]) {
    case Ok(n) -> assertEqualInt(n, 1, "pinned " + id)
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(CloudAgents.PgStore.commit(u))
}

func found(sc: in CloudAgents.Pg.TenantScope, term: in String): String {
  val rows = msgs(Store.searchMessages(sc, term, 50))
  var acc = ""
  for m in rows {
    acc = if acc.length == 0 { m.content } else { acc + "|" + m.content }
  }
  return acc
}

test "search: every word must match as a case-insensitive prefix, newest first" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = newSession(sc)
  val a = msg(Store.addMessage(sid, sc, "user", "Please reschedule the deploy"))
  val b = msg(Store.addMessage(sid, sc, "agent", "The deploy is SCHEDULED for Friday"))
  val c = msg(Store.addMessage(sid, sc, "agent", "Unrelated chatter"))
  pinCreated(sc, a.id, "1700000001000")
  pinCreated(sc, b.id, "1700000002000")
  pinCreated(sc, c.id, "1700000003000")
  assertEqual(
    found(sc, "sched"),
    "The deploy is SCHEDULED for Friday",
    "prefix, case-insensitive; not a mid-word match"
  )
  assertEqual(found(sc, "deploy"), "The deploy is SCHEDULED for Friday|Please reschedule the deploy", "newest first")
  assertEqual(found(sc, "deploy fri"), "The deploy is SCHEDULED for Friday", "every word must match")
  assertEqual(found(sc, "  DEPLOY   please  "), "Please reschedule the deploy", "extra whitespace and case are ignored")
  assertEqual(found(sc, "nothing-like-this"), "", "no match is an empty result")
  assertEqual(found(sc, "!!!"), "", "a term with no words matches nothing")
  match Store.searchMessages(sc, "deploy", 1) {
    case Ok(rows) -> assertEqualInt(rows.length.toInt(), 1, "the limit applies")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val hit = msgs(Store.searchMessages(sc, "friday", 50))
  assertEqual(
    hit[0].id + "|" + hit[0].sessionId + "|" + hit[0].role + "|" + hit[0].createdAt,
    b.id + "|" + sid + "|agent|1700000002000",
    "the full row"
  )
  assertEqual(hit[0].seq, "000000000001", "padded sequence number")
}

test "search: query syntax in the text is inert" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = newSession(sc)
  msg(Store.addMessage(sid, sc, "user", "alpha beta"))
  msg(Store.addMessage(sid, sc, "user", "gamma"))
  assertEqual(found(sc, "alpha | gamma"), "", "a pipe is not OR")
  assertEqual(found(sc, "alpha OR gamma"), "", "OR is just a word")
  assertEqual(found(sc, "!gamma"), "gamma", "a bang is not NOT")
  assertEqual(found(sc, "alpha & beta"), "alpha beta", "an ampersand is not an operator either")
  assertEqual(found(sc, "'); DROP TABLE messages; --"), "", "SQL in the text is only text")
  assertEqual(found(sc, "a\" OR content MATCH \"x"), "", "the FTS5 injection attempt matches nothing")
  assertEqual(found(sc, "gamma:*"), "gamma", "tsquery prefix syntax is just punctuation")
}

test "search covers only the caller's own sessions in the tenant" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val mine = newSession(sc)
  msg(Store.addMessage(mine, sc, "user", "needle mine"))
  val other = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-pgm-other-" + uid())
  val theirs = newSession(other)
  msg(Store.addMessage(theirs, other, "user", "needle theirs"))
  assertEqual(found(sc, "needle"), "needle mine", "another user's session in the same tenant is not searched")
  assertEqual(found(other, "needle"), "needle theirs", "and the other way round")
  assertEqual(found(fresh(), "needle"), "", "another tenant finds nothing")
}
