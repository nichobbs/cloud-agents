//! Interactions tests: messages, comments, todos, agent-plan ingest and the
//! capture-event audit endpoint over the Postgres store, plus tenant isolation.
@test_module
package CloudAgents.InteractionsTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Interactions
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Db
import CloudAgents.Streaming
import CloudAgents.Capture
import extern System.Environment as Env

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
  println("SKIP: interactions tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Db.dbErrorMessage(e))
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

// Every Interactions handler is owner-gated on the session row, so a test
// session must exist and be owned by the CURRENT user. Idempotent.
func ensureSession(id: in String): Unit {
  match CloudAgents.SessionStore.getSession(id, CloudAgents.Auth.requestScope()) {
    case Ok(Some(_)) -> return ()
    case Ok(None) -> ()
    case Err(e) -> panic("getSession failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  val s = makeAgentSession(
    sessionId = id,
    repoUrl = "https://github.com/t/interactions",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = id
  )
  match addSession(s, CloudAgents.Auth.requestScope()) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

// A message id created in `sessionId` (owned by the current user), panicking
// on failure.
func addTestMessage(sessionId: in String): String {
  ensureSession(sessionId)
  return match CloudAgents.Repository.addMessage(sessionId, CloudAgents.Auth.requestScope(), "agent", "hello") {
    case Ok(m) -> m.id
    case Err(e) -> panic("addMessage failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

// A string longer than the 32768-char body/note cap (2^16 = 65536).
func overLongText(): String {
  var s = "x"
  var k = 0
  while k < 16 {
    s = s + s
    k = k + 1
  }
  return s
}

// A string UNDER the 32768-char scan/body caps but OVER 32768 UTF-8 BYTES:
// 2^14 = 16384 '✓' (U+2713, 3 bytes each) = 49152 bytes. Exercises the
// byte-measured note limit without the message being tail-capped away.
func overWideText(): String {
  var s = "✓"
  var k = 0
  while k < 14 {
    s = s + s
    k = k + 1
  }
  return s
}

test "addTodoHandler enforces message ownership (#173)" {
  if not live() {
    return
  }
  val me = freshUser("interactions-todo-ownership")
  val mid = addTestMessage(("session-A-" + me))
  ensureSession(("session-B-" + me))

  // 1. Anchoring a todo to a message from its own session succeeds, and the
  // todo is bound to the session the *message* belongs to (derived, not trusted
  // from the client).
  match addTodoHandler(("session-A-" + me), AddTodoRequest(messageId = mid, note = "follow up")) {
    case Ok(t) -> assertEqual(t.sessionId, ("session-A-" + me), "todo bound to the owning session")
    case Err(err) -> assertTrue(false, "same-session anchor should succeed, got status " + toString(err.status))
  }

  // 2. Anchoring the same message from a different session is rejected — a todo
  // must not point at another session's transcript.
  match addTodoHandler(("session-B-" + me), AddTodoRequest(messageId = mid, note = "cross-session")) {
    case Ok(_) -> assertTrue(false, "a message from another session must not anchor a todo here")
    case Err(err) -> assertEqualInt(err.status, 400, "cross-session anchor returns 400")
  }

  // 3. A nonexistent anchor message is a 404.
  match addTodoHandler(("session-A-" + me), AddTodoRequest(messageId = "no-such-message", note = "dangling")) {
    case Ok(_) -> assertTrue(false, "a missing anchor message must not create a todo")
    case Err(err) -> assertEqualInt(err.status, 404, "missing anchor returns 404")
  }

  // 4. An unanchored todo (empty messageId) skips the ownership check entirely.
  match addTodoHandler(("session-A-" + me), AddTodoRequest(messageId = "", note = "standalone")) {
    case Ok(t) -> assertEqual(t.messageId, "", "unanchored todo has no message")
    case Err(err) -> assertTrue(false, "unanchored todo should succeed, got status " + toString(err.status))
  }
}

test "addTodoHandler validates note presence and length (#35)" {
  if not live() {
    return
  }
  val me = freshUser("interactions-todo-validation")
  // Empty session id.
  match addTodoHandler("", AddTodoRequest(messageId = "", note = "x")) {
    case Ok(_) -> assertTrue(false, "empty session id must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty id returns 400")
  }
  // Empty note.
  match addTodoHandler(("session-A-" + me), AddTodoRequest(messageId = "", note = "")) {
    case Ok(_) -> assertTrue(false, "empty note must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty note returns 400")
  }
  // Over-length note (> 32768 chars).
  match addTodoHandler(("session-A-" + me), AddTodoRequest(messageId = "", note = overLongText())) {
    case Ok(_) -> assertTrue(false, "an over-length note must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "over-length note returns 400")
  }
}

test "addCommentHandler derives the session from the message and validates input (#57/#35)" {
  if not live() {
    return
  }
  val me = freshUser("interactions-comment")
  val mid = addTestMessage(("session-C-" + me))

  // The comment's sessionId is derived from the stored message, not supplied
  // by the client (#57).
  match addCommentHandler(mid, AddCommentRequest(body = "nice")) {
    case Ok(c) -> assertEqual(c.sessionId, ("session-C-" + me), "comment bound to the message's session")
    case Err(err) -> assertTrue(false, "valid comment should succeed, got status " + toString(err.status))
  }

  // A comment on a nonexistent message is a 404.
  match addCommentHandler("no-such-message", AddCommentRequest(body = "orphan")) {
    case Ok(_) -> assertTrue(false, "a comment on a missing message must be rejected")
    case Err(err) -> assertEqualInt(err.status, 404, "missing message returns 404")
  }

  // Empty and over-length bodies are rejected (#35).
  match addCommentHandler(mid, AddCommentRequest(body = "")) {
    case Ok(_) -> assertTrue(false, "empty body must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty body returns 400")
  }
  match addCommentHandler(mid, AddCommentRequest(body = overLongText())) {
    case Ok(_) -> assertTrue(false, "an over-length body must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "over-length body returns 400")
  }
}

test "getMessages/getComments/getTodos list stored rows and reject an empty id (#335)" {
  if not live() {
    return
  }
  val me = freshUser("interactions-reads")
  val mid = addTestMessage(("session-R-" + me))
  // Anchor a comment and a todo to the message.
  match addCommentHandler(mid, AddCommentRequest(body = "c1")) {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, "comment setup failed: " + toString(err.status))
  }
  match addTodoHandler(("session-R-" + me), AddTodoRequest(messageId = mid, note = "t1")) {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, "todo setup failed: " + toString(err.status))
  }

  match getMessages(("session-R-" + me)) {
    case Ok(ml) -> assertEqualInt(ml.messages.length, 1, "one message listed")
    case Err(err) -> assertTrue(false, "getMessages failed: " + toString(err.status))
  }
  match getComments(mid) {
    case Ok(cl) -> assertEqualInt(cl.comments.length, 1, "one comment listed")
    case Err(err) -> assertTrue(false, "getComments failed: " + toString(err.status))
  }
  match getTodos(("session-R-" + me)) {
    case Ok(tl) -> assertEqualInt(tl.todos.length, 1, "one todo listed")
    case Err(err) -> assertTrue(false, "getTodos failed: " + toString(err.status))
  }

  // Each read handler rejects an empty id up front.
  match getMessages("") {
    case Ok(_) -> assertTrue(false, "getMessages must reject an empty id")
    case Err(err) -> assertEqualInt(err.status, 400, "getMessages empty id returns 400")
  }
  match getComments("") {
    case Ok(_) -> assertTrue(false, "getComments must reject an empty id")
    case Err(err) -> assertEqualInt(err.status, 400, "getComments empty id returns 400")
  }
  match getTodos("") {
    case Ok(_) -> assertTrue(false, "getTodos must reject an empty id")
    case Err(err) -> assertEqualInt(err.status, 400, "getTodos empty id returns 400")
  }
}

test "toggleTodoHandler flips done and deleteTodoHandler removes the row (#335)" {
  if not live() {
    return
  }
  val me = freshUser("interactions-todo-mutate")
  ensureSession(("session-T-" + me))
  val tid = match addTodoHandler(("session-T-" + me), AddTodoRequest(messageId = "", note = "task")) {
    case Ok(t) -> t.id
    case Err(err) -> panic("addTodo setup failed: " + toString(err.status))
  }

  // A new todo starts not done.
  match getTodos(("session-T-" + me)) {
    case Ok(tl) -> {
      assertEqualInt(tl.todos.length, 1, "one todo before toggle")
      assertEqual(tl.todos[0].done, "0", "todo starts not done")
    }
    case Err(err) -> assertTrue(false, "getTodos failed: " + toString(err.status))
  }

  // Toggle flips done to "1".
  match toggleTodoHandler(tid) {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, "toggle failed: " + toString(err.status))
  }
  match getTodos(("session-T-" + me)) {
    case Ok(tl) -> assertEqual(tl.todos[0].done, "1", "todo is done after toggle")
    case Err(err) -> assertTrue(false, "getTodos after toggle failed: " + toString(err.status))
  }

  // Delete removes it.
  match deleteTodoHandler(tid) {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, "delete failed: " + toString(err.status))
  }
  match getTodos(("session-T-" + me)) {
    case Ok(tl) -> assertEqualInt(tl.todos.length, 0, "no todos after delete")
    case Err(err) -> assertTrue(false, "getTodos after delete failed: " + toString(err.status))
  }

  // Empty ids are rejected 400.
  match toggleTodoHandler("") {
    case Ok(_) -> assertTrue(false, "toggle must reject an empty id")
    case Err(err) -> assertEqualInt(err.status, 400, "toggle empty id returns 400")
  }
  match deleteTodoHandler("") {
    case Ok(_) -> assertTrue(false, "delete must reject an empty id")
    case Err(err) -> assertEqualInt(err.status, 400, "delete empty id returns 400")
  }
}

test "setTodoStatusHandler validates its inputs and persists a valid status" {
  if not live() {
    return
  }
  val me = freshUser("todo-status")

  assertTrue(isValidTodoStatus("pending"), "pending is valid")
  assertTrue(isValidTodoStatus("in_progress"), "in_progress is valid")
  assertTrue(isValidTodoStatus("done"), "done is valid")
  assertTrue(not isValidTodoStatus("open"), "repo-task statuses are not todo statuses")

  match setTodoStatusHandler("", SetTodoStatusRequest(status = "done")) {
    case Ok(_) -> assertTrue(false, "empty id must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty id returns 400")
  }
  match setTodoStatusHandler("t1", SetTodoStatusRequest(status = "bogus")) {
    case Ok(_) -> assertTrue(false, "bogus status must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "bogus status returns 400")
  }

  ensureSession(("session-S-" + me))
  val created = match addTodoHandler(("session-S-" + me), AddTodoRequest(messageId = "", note = "step")) {
    case Ok(t) -> t
    case Err(err) -> panic("addTodoHandler failed: " + toString(err.status))
  }
  assertEqual(created.status, "pending", "a new todo starts pending")
  match setTodoStatusHandler(created.id, SetTodoStatusRequest(status = "in_progress")) {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, "valid status update failed: " + toString(err.status))
  }
  match CloudAgents.Repository.listTodos(("session-S-" + me), CloudAgents.Auth.requestScope()) {
    case Ok(todos) -> {
      assertEqual(todos[0].status, "in_progress", "status persisted")
      assertEqual(todos[0].done, "0", "done stays in lockstep")
    }
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

test "parseAgentPlan takes the LAST >=2-item checkbox list and maps all three markers" {
  val plan = parseAgentPlan(
    "- [ ] old one\n- [ ] old two\n\nprose in between\n\n1. [x] clone the repo\n2) [~] fix the bug\n* [ ] run tests\nDone."
  )
  assertEqualInt(plan.length.toInt(), 3, "the last list wins")
  assertEqual(plan[0].status, "done", "x maps to done")
  assertEqual(plan[0].note, "clone the repo", "note text extracted")
  assertEqual(plan[1].status, "in_progress", "~ maps to in_progress")
  assertEqual(plan[2].status, "pending", "space maps to pending")
}

test "parseAgentPlan ignores lone checkboxes and plain prose" {
  assertEqualInt(parseAgentPlan("note:\n- [ ] lonely item\nmore prose").length.toInt(), 0, "single-item list dropped")
  assertEqualInt(parseAgentPlan("just prose\nno boxes at all").length.toInt(), 0, "no checkboxes -> no plan")
  assertEqualInt(parseAgentPlan("- [q] bogus marker\n- [w] another").length.toInt(), 0, "unknown markers dropped")
}

test "parseAgentPlan tolerates blank lines inside a list" {
  val plan = parseAgentPlan("- [ ] a\n\n- [x] b")
  assertEqualInt(plan.length.toInt(), 2, "blank line does not split the list")
}

test "ingestAgentPlan replaces prior plan rows and never touches human todos" {
  if not live() {
    return
  }
  val me = freshUser("plan-ingest")
  val mid = addTestMessage(("session-P-" + me))
  // A human todo that must survive every re-ingest.
  val human = match addTodoHandler(("session-P-" + me), AddTodoRequest(messageId = "", note = "human note")) {
    case Ok(t) -> t
    case Err(err) -> panic("addTodoHandler failed: " + toString(err.status))
  }

  match ingestAgentPlan(("session-P-" + me), CloudAgents.Auth.requestScope(), mid, "- [x] step one\n- [~] step two\n- [ ] step three") {
    case Ok(n) -> assertEqualInt(n, 3, "three items ingested")
    case Err(e) -> assertTrue(false, "ingest failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos(("session-P-" + me), CloudAgents.Auth.requestScope()) {
    case Ok(todos) -> assertEqualInt(todos.length.toInt(), 4, "3 plan rows + 1 human row")
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // The agent restates its plan — the old plan rows are replaced, not stacked.
  match ingestAgentPlan(("session-P-" + me), CloudAgents.Auth.requestScope(), mid, "- [x] step one\n- [x] step two\n- [~] step three") {
    case Ok(n) -> assertEqualInt(n, 3, "restated plan re-ingested")
    case Err(e) -> assertTrue(false, "re-ingest failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos(("session-P-" + me), CloudAgents.Auth.requestScope()) {
    case Ok(todos) -> {
      assertEqualInt(todos.length.toInt(), 4, "still 3 plan rows + 1 human row")
      var humanSeen = false
      for t in todos {
        if t.id == human.id {
          humanSeen = true
        }
      }
      assertTrue(humanSeen, "the human todo survived both ingests")
    }
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // A reply with no plan (or a lone checkbox) leaves everything untouched.
  match ingestAgentPlan(("session-P-" + me), CloudAgents.Auth.requestScope(), mid, "all done, no list here\n- [x] just one") {
    case Ok(n) -> assertEqualInt(n, 0, "no >=2-item list -> nothing ingested")
    case Err(e) -> assertTrue(false, "no-op ingest failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos(("session-P-" + me), CloudAgents.Auth.requestScope()) {
    case Ok(todos) -> assertEqualInt(todos.length.toInt(), 4, "no-op ingest left rows alone")
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

test "planIngestEnabled is off by default and on only for exactly '1'" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_INGEST_AGENT_PLAN", "")
  assertTrue(not planIngestEnabled(), "unset/empty -> off")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_INGEST_AGENT_PLAN", "true")
  assertTrue(not planIngestEnabled(), "'true' is not the documented switch")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_INGEST_AGENT_PLAN", "1")
  assertTrue(planIngestEnabled(), "'1' -> on")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_INGEST_AGENT_PLAN", "")
}

test "parsePlanLine alignment with the frontend parser (#784): bullet-space and bracket-space edges" {
  // Bullet without a trailing space parses (frontend `\s*` after the bullet).
  val tight = parseAgentPlan("-[ ] first\n-[x] second")
  assertEqualInt(tight.length.toInt(), 2, "bullet without trailing space parses")
  // No whitespace after "]" is rejected (frontend `\s+` before the text).
  assertEqualInt(parseAgentPlan("- [x]crammed\n- [x]also").length.toInt(), 0, "no space after ] -> rejected")
  // A checkbox with nothing after it is rejected on both sides.
  assertEqualInt(parseAgentPlan("- [ ] \n- [x] ").length.toInt(), 0, "empty text -> rejected")
  // A bullet is REQUIRED (#790) — the frontend regex's bullet group is
  // mandatory, so a bare bullet-less checkbox must not ingest server-side
  // either.
  assertEqualInt(parseAgentPlan("[ ] bare one\n[x] bare two").length.toInt(), 0, "bullet-less checkbox -> rejected")
  // Tab between bullet and checkbox parses, matching the frontend's \s* (#807).
  assertEqualInt(parseAgentPlan("-\t[ ] tabbed one\n-\t[x] tabbed two").length.toInt(), 2, "tab after bullet parses")
  // CRLF line endings parse identically to LF, with clean note text (#830).
  val crlf = parseAgentPlan("- [x] one\r\n- [ ] two\r\n")
  assertEqualInt(crlf.length.toInt(), 2, "CRLF plan parses")
  assertEqual(crlf[0].note, "one", "no stray \r in the note")
}

test "parseAgentPlan strips ANSI SGR codes before parsing (#794)" {
  // Real harness output is stored WITH its color codes — build a colorized
  // plan the way streaming's own tests build control characters.
  val esc = CloudAgents.Streaming.charFromCode(27)
  val green = esc + "[32m"
  val boldYellow = esc + "[1;33m"
  val off = esc + "[0m"
  val colored = green + "- [x] clone the repo" + off + "\n" + boldYellow + "- [~] fix the bug" + off
  val plan = parseAgentPlan(colored)
  assertEqualInt(plan.length.toInt(), 2, "colorized checkbox lines parse")
  assertEqual(plan[0].note, "clone the repo", "SGR codes stripped from the note")
  assertEqual(plan[1].status, "in_progress", "marker parsed through the coloring")
  // A non-SGR escape sequence (no terminating 'm') is kept literally, exactly
  // like the frontend regex — the line then fails the bullet check.
  val weird = esc + "[Z- [x] one\n" + esc + "[Z- [x] two"
  assertEqualInt(parseAgentPlan(weird).length.toInt(), 0, "non-SGR escapes are not stripped")
}

test "todosUpdatedAfter is session-scoped and cursor-correct; plan ingest is isolated (#831)" {
  if not live() {
    return
  }
  val me = freshUser("todo-cursor-isolation")
  val midA = addTestMessage(("session-CU-A-" + me))
  val midB = addTestMessage(("session-CU-B-" + me))

  // Ingest a plan in A and a different one in B.
  match ingestAgentPlan(("session-CU-A-" + me), CloudAgents.Auth.requestScope(), midA, "- [ ] a-one\n- [x] a-two") {
    case Ok(n) -> assertEqualInt(n, 2, "A's plan ingested")
    case Err(e) -> assertTrue(false, "A ingest failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match ingestAgentPlan(("session-CU-B-" + me), CloudAgents.Auth.requestScope(), midB, "- [ ] b-one\n- [ ] b-two") {
    case Ok(n) -> assertEqualInt(n, 2, "B's plan ingested")
    case Err(e) -> assertTrue(false, "B ingest failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // Cross-session isolation: A's cursor query never sees B's rows.
  val updatesA = match CloudAgents.Repository.todosUpdatedAfter(("session-CU-A-" + me), CloudAgents.Auth.requestScope(), "0") {
    case Ok(us) -> us
    case Err(e) -> panic("todosUpdatedAfter failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  assertEqualInt(updatesA.length.toInt(), 2, "only A's two rows")
  for u in updatesA {
    assertTrue(u.note == "a-one" or u.note == "a-two", "no cross-session leak: " + u.note)
  }

  // Cursor semantics: advancing past the last updated_at yields nothing...
  val lastCursor = updatesA[updatesA.length - 1].updatedAt
  match CloudAgents.Repository.todosUpdatedAfter(("session-CU-A-" + me), CloudAgents.Auth.requestScope(), lastCursor) {
    case Ok(us) -> assertEqualInt(us.length.toInt(), 0, "caught up -> empty")
    case Err(e) -> assertTrue(false, "cursor query failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  // ...and a later status change surfaces past that same cursor. The bump
  // lands at nowMillis(); in the SAME millisecond as lastCursor the
  // strictly-greater cursor query rightly skips it — that's #803's benign
  // same-ms window, not a bug. Spin past the boundary so the test asserts
  // cursor semantics rather than scheduler luck (flaked on CI). Both sides
  // are 13-digit epoch-ms strings, so string order == numeric order.
  var spin = 0
  while CloudAgents.Repository.nowMillis() <= lastCursor {
    spin = spin + 1
  }
  match CloudAgents.Repository.listTodos(("session-CU-A-" + me), CloudAgents.Auth.requestScope()) {
    case Ok(todos) -> {
      match CloudAgents.Interactions.setTodoStatusHandler(todos[0].id, SetTodoStatusRequest(status = "in_progress")) {
        case Ok(_) -> ()
        case Err(err) -> assertTrue(false, "status update failed: " + toString(err.status))
      }
    }
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.Repository.todosUpdatedAfter(("session-CU-A-" + me), CloudAgents.Auth.requestScope(), lastCursor) {
    case Ok(us) -> {
      assertEqualInt(us.length.toInt(), 1, "the status change surfaces past the cursor")
      assertEqual(us[0].status, "in_progress", "with its new status")
    }
    case Err(e) -> assertTrue(false, "cursor query failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

test "ingested plan lists first step first (#826) and enforces storage caps (#825)" {
  if not live() {
    return
  }
  val me = freshUser("plan-order-caps")
  val mid = addTestMessage(("session-PO-" + me))
  match ingestAgentPlan(("session-PO-" + me), CloudAgents.Auth.requestScope(), mid, "- [x] first step\n- [~] second step\n- [ ] third step") {
    case Ok(n) -> assertEqualInt(n, 3, "three steps ingested")
    case Err(e) -> assertTrue(false, "ingest failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos(("session-PO-" + me), CloudAgents.Auth.requestScope()) {
    case Ok(todos) -> {
      assertEqual(todos[0].note, "first step", "plan reads top-to-bottom, not reversed")
      assertEqual(todos[1].note, "second step", "middle step in place")
      assertEqual(todos[2].note, "third step", "last step last")
    }
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // An over-long NOTE is dropped at the ingestion boundary (the display
  // parser is uncapped by design); the remaining valid items still ingest.
  // The note limit is 32768 BYTES while the scan cap is 32768 CHARS, so the
  // only way a parsed note can exceed the byte limit is multi-byte text:
  // 16384 '✓' chars = 49152 UTF-8 bytes, and the whole message stays inside
  // the scan tail so all three lines reach the parser.
  match ingestAgentPlan(("session-PO-" + me), CloudAgents.Auth.requestScope(), mid, "- [ ] ok one\n- [ ] " + overWideText() + "\n- [ ] ok two") {
    case Ok(n) -> assertEqualInt(n, 2, "over-long note dropped, two kept")
    case Err(e) -> assertTrue(false, "capped ingest failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos(("session-PO-" + me), CloudAgents.Auth.requestScope()) {
    case Ok(todos) -> {
      assertEqualInt(todos.length.toInt(), 2, "only the two kept rows stored")
      assertEqual(todos[0].note, "ok one", "first kept item first")
      assertEqual(todos[1].note, "ok two", "second kept item second")
    }
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // A "plan" longer than maxPlanIngestItems is truncated to the cap.
  var big = ""
  var s = 0
  while s < 60 {
    big = big + "- [ ] step " + toString(s) + "\n"
    s = s + 1
  }
  match ingestAgentPlan(("session-PO-" + me), CloudAgents.Auth.requestScope(), mid, big) {
    case Ok(n) -> assertEqualInt(n, 50, "60-step plan capped at 50")
    case Err(e) -> assertTrue(false, "count-capped ingest failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // An over-long ITEM near the end of a huge message pushes earlier lines
  // out of the scan tail: only "ok two" survives, which is < 2 items, so
  // nothing is ingested and the prior plan rows stay. This is also the
  // regression guard for lyric-lang#6322 — the ~32k-char scan loop runs
  // past the .NET OSR promotion threshold, which used to crash the process
  // when parseAgentPlan appended records inside that loop.
  match ingestAgentPlan(("session-PO-" + me), CloudAgents.Auth.requestScope(), mid, "- [ ] ok one\n- [ ] " + overLongText() + "\n- [ ] ok two") {
    case Ok(n) -> assertEqualInt(n, 0, "tail-capped scan leaves <2 items -> no-op")
    case Err(e) -> assertTrue(false, "tail-capped ingest failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos(("session-PO-" + me), CloudAgents.Auth.requestScope()) {
    case Ok(todos) -> assertEqualInt(todos.length.toInt(), 50, "no-op ingest left the capped plan alone")
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

// ── GET /api/sessions/{id}/events (docs/session-events-endpoint.md) ───────────
// Three non-blank stream-json lines -> seq 0,1,2, one payload carrying an
// apostrophe so escaping/round-tripping is exercised.
func fixtureEventsNdjson(): String {
  val l0 = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
  val l1 = "{\"type\":\"user\",\"message\":{\"content\":\"it's a test\"}}"
  val l2 = "{\"type\":\"result\",\"subtype\":\"success\"}"
  return l0 + "\n" + l1 + "\n" + l2 + "\n"
}

// Pure encoder — no DB. Envelope shape, string seq, escaped payloads, empty case.
test "sessionEventsToJson encodes the audit envelope with escaped payloads" {
  val acc: List[CaptureEvent] = newList()
  // A normal event whose payload contains a double quote (must be escaped), and
  // a malformed event whose payload is not valid JSON (carried as a string).
  acc.add(CaptureEvent(seq = 0.toLong(), eventType = "system", payload = "x\"y", prevHash = "", hash = "h0"))
  acc.add(
    CaptureEvent(seq = 1.toLong(), eventType = "malformed", payload = "not json <<", prevHash = "h0", hash = "h1")
  )
  val json = CloudAgents.Interactions.sessionEventsToJson(acc.toArray())

  assertTrue(json.startsWith("{\"events\":["), "envelope opens with the events array")
  assertTrue(json.endsWith("]}"), "envelope closes the array and object")
  assertTrue(json.contains("\"seq\":\"0\""), "seq is rendered as a string")
  assertTrue(json.contains("\"type\":\"malformed\""), "malformed event type is preserved")
  // The embedded double quote is escaped, so the envelope stays valid JSON:
  // payload value x"y -> ...x\"y... inside the JSON string.
  assertTrue(json.contains("x\\\"y"), "payload double quote is escaped")
  assertTrue(json.contains("not json <<"), "malformed payload carried verbatim in the string")

  val empty: List[CaptureEvent] = newList()
  assertEqual(
    CloudAgents.Interactions.sessionEventsToJson(empty.toArray()),
    "{\"events\":[]}",
    "empty session -> empty array"
  )
}

// Pure validation — both error paths return before any DB access.
test "getSessionEvents rejects an empty id and a non-numeric cursor" {
  match CloudAgents.Interactions.getSessionEvents("", "") {
    case Ok(_) -> assertTrue(false, "empty id must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty id -> 400")
  }
  match CloudAgents.Interactions.getSessionEvents("s1", "abc") {
    case Ok(_) -> assertTrue(false, "non-numeric after must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "non-numeric after -> 400")
  }
}

// Live round-trip through the handler over the real store (the HTTP dispatch
// layer itself still needs the running Lyric.Web server, per the spec §5).
test "getSessionEvents returns the stored chain as the audit envelope" {
  if not live() {
    return
  }
  val me = freshUser("sessevents-endpoint")
  ensureSession(("sess-E-" + me))
  val batch = parseStreamJson(fixtureEventsNdjson(), 0.toLong(), "")
  match CloudAgents.Repository.appendSessionEvents(("sess-E-" + me), CloudAgents.Auth.requestScope(), batch.events) {
    case Ok(n) -> assertEqualInt(n, 3, "three events appended")
    case Err(e) -> assertTrue(false, "append failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  val json = match CloudAgents.Interactions.getSessionEvents(("sess-E-" + me), "") {
    case Ok(s) -> s
    case Err(e) -> panic("getSessionEvents from start returned an unexpected error")
  }
  assertTrue(json.startsWith("{\"events\":["), "envelope shape")
  assertTrue(json.contains("\"seq\":\"0\""), "from-start includes event 0")
  assertTrue(json.contains("\"seq\":\"2\""), "from-start includes the last event")
  assertTrue(json.contains("it's a test"), "apostrophe payload round-trips verbatim")

  // Cursor: after=0 excludes event 0, includes the tail.
  val tail = match CloudAgents.Interactions.getSessionEvents(("sess-E-" + me), "0") {
    case Ok(s) -> s
    case Err(e) -> panic("cursor fetch returned an unexpected error")
  }
  assertTrue(not tail.contains("\"seq\":\"0\""), "after=0 excludes event 0")
  assertTrue(tail.contains("\"seq\":\"1\""), "after=0 includes event 1")

  // Unknown session -> 404, the same answer as a session owned by someone else.
  match CloudAgents.Interactions.getSessionEvents(("sess-does-not-exist-" + me), "") {
    case Ok(_) -> assertTrue(false, "unknown session must not return events")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown session -> 404")
  }

  // An owned session with no captured events yet -> empty envelope.
  ensureSession(("sess-E-empty-" + me))
  val none = match CloudAgents.Interactions.getSessionEvents(("sess-E-empty-" + me), "") {
    case Ok(s) -> s
    case Err(e) -> panic("owned event-less session should be empty, not an error")
  }
  assertEqual(none, "{\"events\":[]}", "owned event-less session -> empty envelope")
}

// ── Tenant isolation ──────────────────────────────────────────────────────────
// Every Interactions handler is owner-scoped through the session row: a
// session, message, or todo belonging to another user answers 404 exactly like
// one that doesn't exist (no existence leak), and its data is never returned
// or mutated. User A owns the session; user B is a different authenticated
// caller who knows every id.
test "user B cannot read user A's messages or capture events" {
  if not live() {
    return
  }
  val me = freshUser("interactions-tenant-reads")
  val userB = newUser("b")
  CloudAgents.Auth.setCurrentUserId(me)
  val sid = ("sess-tenant-a-" + me)
  val mid = addTestMessage(sid)
  val batch = parseStreamJson(fixtureEventsNdjson(), 0.toLong(), "")
  match CloudAgents.Repository.appendSessionEvents(sid, CloudAgents.Auth.requestScope(), batch.events) {
    case Ok(n) -> assertEqualInt(n, 3, "three events appended")
    case Err(e) -> assertTrue(false, "append failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // The owner sees both.
  match getMessages(sid) {
    case Ok(ml) -> assertEqualInt(ml.messages.length, 1, "owner reads the transcript")
    case Err(err) -> assertTrue(false, "owner getMessages failed: " + toString(err.status))
  }
  match getSessionEvents(sid, "") {
    case Ok(json) -> assertTrue(json.contains("\"seq\":\"2\""), "owner reads the capture chain")
    case Err(err) -> assertTrue(false, "owner getSessionEvents failed: " + toString(err.status))
  }

  CloudAgents.Auth.setCurrentUserId(userB)
  match getMessages(sid) {
    case Ok(_) -> assertTrue(false, "user B must not read user A's transcript")
    case Err(err) -> assertEqualInt(err.status, 404, "foreign transcript -> 404")
  }
  match getSessionEvents(sid, "") {
    case Ok(_) -> assertTrue(false, "user B must not read user A's capture events")
    case Err(err) -> assertEqualInt(err.status, 404, "foreign capture events -> 404")
  }
  // The cursor form is gated too, not just the from-start read.
  match getSessionEvents(sid, "0") {
    case Ok(_) -> assertTrue(false, "user B must not page user A's capture events")
    case Err(err) -> assertEqualInt(err.status, 404, "foreign capture events with cursor -> 404")
  }
  // A foreign session and a nonexistent one are indistinguishable.
  match getMessages(("sess-never-existed-" + me)) {
    case Ok(_) -> assertTrue(false, "nonexistent session must not list messages")
    case Err(err) -> assertEqualInt(err.status, 404, "nonexistent transcript -> 404")
  }
  match getComments(mid) {
    case Ok(_) -> assertTrue(false, "user B must not list comments on user A's message")
    case Err(err) -> assertEqualInt(err.status, 404, "foreign message comments -> 404")
  }
}

test "user B cannot read or mutate user A's todos and comments" {
  if not live() {
    return
  }
  val me = freshUser("interactions-tenant-writes")
  val userB = newUser("b")
  CloudAgents.Auth.setCurrentUserId(me)
  val sid = ("sess-tenant-a2-" + me)
  val mid = addTestMessage(sid)
  val tid = match addTodoHandler(sid, AddTodoRequest(messageId = mid, note = "owner todo")) {
    case Ok(t) -> t.id
    case Err(err) -> panic("owner addTodo failed: " + toString(err.status))
  }

  CloudAgents.Auth.setCurrentUserId(userB)
  match getTodos(sid) {
    case Ok(_) -> assertTrue(false, "user B must not list user A's todos")
    case Err(err) -> assertEqualInt(err.status, 404, "foreign todos -> 404")
  }
  match addTodoHandler(sid, AddTodoRequest(messageId = "", note = "intruder")) {
    case Ok(_) -> assertTrue(false, "user B must not add a todo to user A's session")
    case Err(err) -> assertEqualInt(err.status, 404, "foreign addTodo -> 404")
  }
  match addCommentHandler(mid, AddCommentRequest(body = "intruder")) {
    case Ok(_) -> assertTrue(false, "user B must not comment on user A's message")
    case Err(err) -> assertEqualInt(err.status, 404, "foreign addComment -> 404")
  }
  match toggleTodoHandler(tid) {
    case Ok(_) -> assertTrue(false, "user B must not toggle user A's todo")
    case Err(err) -> assertEqualInt(err.status, 404, "foreign toggle -> 404")
  }
  match setTodoStatusHandler(tid, SetTodoStatusRequest(status = "done")) {
    case Ok(_) -> assertTrue(false, "user B must not set user A's todo status")
    case Err(err) -> assertEqualInt(err.status, 404, "foreign setTodoStatus -> 404")
  }
  match deleteTodoHandler(tid) {
    case Ok(_) -> assertTrue(false, "user B must not delete user A's todo")
    case Err(err) -> assertEqualInt(err.status, 404, "foreign deleteTodo -> 404")
  }

  // Nothing user B attempted reached the store. Read back as the owner: under
  // Postgres RLS user B's own scope cannot see user A's rows at all.
  CloudAgents.Auth.setCurrentUserId(me)
  match CloudAgents.Repository.listTodos(sid, CloudAgents.Auth.requestScope()) {
    case Ok(todos) -> {
      assertEqualInt(todos.length.toInt(), 1, "no intruder todo was added and the owner's survived")
      assertEqual(todos[0].status, "pending", "owner todo status untouched")
      assertEqual(todos[0].done, "0", "owner todo done flag untouched")
    }
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listComments(mid, CloudAgents.Auth.requestScope()) {
    case Ok(cs) -> assertEqualInt(cs.length.toInt(), 0, "no intruder comment was added")
    case Err(e) -> assertTrue(false, "listComments failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // The owner still has full access.
  match getTodos(sid) {
    case Ok(tl) -> assertEqualInt(tl.todos.length, 1, "owner still lists its todo")
    case Err(err) -> assertTrue(false, "owner getTodos failed: " + toString(err.status))
  }
}

// The Testamur CaptureFetch client authenticates with the static operator
// token (CLOUD_AGENTS_API_TOKEN), which resolves to operatorUserId()
// ("default"). It can read the capture chain of every session the operator
// identity owns, and nothing else.
test "operator identity reads its own sessions' events but not an OAuth user's" {
  if not live() {
    return
  }
  val me = freshUser("interactions-operator-events")
  val oauthUser = newUser("oauth")
  // The operator identity is the one fixed user the static API token resolves to.
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(CloudAgents.Auth.operatorUserId()) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning the operator failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  val batch = parseStreamJson(fixtureEventsNdjson(), 0.toLong(), "")

  CloudAgents.Auth.setCurrentUserId(CloudAgents.Auth.operatorUserId())
  ensureSession(("sess-operator-" + me))
  match CloudAgents.Repository.appendSessionEvents(("sess-operator-" + me), CloudAgents.Auth.requestScope(), batch.events) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "append failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  CloudAgents.Auth.setCurrentUserId(oauthUser)
  ensureSession(("sess-oauth-user-" + me))
  match CloudAgents.Repository.appendSessionEvents(("sess-oauth-user-" + me), CloudAgents.Auth.requestScope(), batch.events) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "append failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  CloudAgents.Auth.setCurrentUserId(CloudAgents.Auth.operatorUserId())
  match getSessionEvents(("sess-operator-" + me), "") {
    case Ok(json) -> assertTrue(json.contains("\"seq\":\"2\""), "operator reads its own session's chain")
    case Err(err) -> assertTrue(false, "operator getSessionEvents failed: " + toString(err.status))
  }
  match getSessionEvents(("sess-oauth-user-" + me), "") {
    case Ok(_) -> assertTrue(false, "operator token must not read an OAuth user's capture events")
    case Err(err) -> assertEqualInt(err.status, 404, "operator on a foreign session -> 404")
  }
}
