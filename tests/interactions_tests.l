@test_module
package CloudAgents.InteractionsTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Interactions
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.Streaming
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/prompt_tests.l) ───────────────────

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return path
}

func cleanupTestDb(path: in String): Unit {
  try {
    fileDelete(path)
  } catch Bug as b {
    // locked or already gone — fine for a temp file
  }
}

// A message id created in `sessionId`, panicking on failure.
func addTestMessage(sessionId: in String): String {
  return match CloudAgents.Repository.addMessage(sessionId, "agent", "hello") {
    case Ok(m) -> m.id
    case Err(e) -> panic("addMessage failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
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
  val dbPath = useFreshTestDb("interactions-todo-ownership")
  defer {
    cleanupTestDb(dbPath)
  }
  val mid = addTestMessage("session-A")

  // 1. Anchoring a todo to a message from its own session succeeds, and the
  // todo is bound to the session the *message* belongs to (derived, not trusted
  // from the client).
  match addTodoHandler("session-A", AddTodoRequest(messageId = mid, note = "follow up")) {
    case Ok(t) -> assertEqual(t.sessionId, "session-A", "todo bound to the owning session")
    case Err(err) -> assertTrue(false, "same-session anchor should succeed, got status " + toString(err.status))
  }

  // 2. Anchoring the same message from a different session is rejected — a todo
  // must not point at another session's transcript.
  match addTodoHandler("session-B", AddTodoRequest(messageId = mid, note = "cross-session")) {
    case Ok(_) -> assertTrue(false, "a message from another session must not anchor a todo here")
    case Err(err) -> assertEqualInt(err.status, 400, "cross-session anchor returns 400")
  }

  // 3. A nonexistent anchor message is a 404.
  match addTodoHandler("session-A", AddTodoRequest(messageId = "no-such-message", note = "dangling")) {
    case Ok(_) -> assertTrue(false, "a missing anchor message must not create a todo")
    case Err(err) -> assertEqualInt(err.status, 404, "missing anchor returns 404")
  }

  // 4. An unanchored todo (empty messageId) skips the ownership check entirely.
  match addTodoHandler("session-A", AddTodoRequest(messageId = "", note = "standalone")) {
    case Ok(t) -> assertEqual(t.messageId, "", "unanchored todo has no message")
    case Err(err) -> assertTrue(false, "unanchored todo should succeed, got status " + toString(err.status))
  }
}

test "addTodoHandler validates note presence and length (#35)" {
  val dbPath = useFreshTestDb("interactions-todo-validation")
  defer {
    cleanupTestDb(dbPath)
  }
  // Empty session id.
  match addTodoHandler("", AddTodoRequest(messageId = "", note = "x")) {
    case Ok(_) -> assertTrue(false, "empty session id must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty id returns 400")
  }
  // Empty note.
  match addTodoHandler("session-A", AddTodoRequest(messageId = "", note = "")) {
    case Ok(_) -> assertTrue(false, "empty note must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "empty note returns 400")
  }
  // Over-length note (> 32768 chars).
  match addTodoHandler("session-A", AddTodoRequest(messageId = "", note = overLongText())) {
    case Ok(_) -> assertTrue(false, "an over-length note must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "over-length note returns 400")
  }
}

test "addCommentHandler derives the session from the message and validates input (#57/#35)" {
  val dbPath = useFreshTestDb("interactions-comment")
  defer {
    cleanupTestDb(dbPath)
  }
  val mid = addTestMessage("session-C")

  // The comment's sessionId is derived from the stored message, not supplied
  // by the client (#57).
  match addCommentHandler(mid, AddCommentRequest(body = "nice")) {
    case Ok(c) -> assertEqual(c.sessionId, "session-C", "comment bound to the message's session")
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
  val dbPath = useFreshTestDb("interactions-reads")
  defer {
    cleanupTestDb(dbPath)
  }
  val mid = addTestMessage("session-R")
  // Anchor a comment and a todo to the message.
  match addCommentHandler(mid, AddCommentRequest(body = "c1")) {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, "comment setup failed: " + toString(err.status))
  }
  match addTodoHandler("session-R", AddTodoRequest(messageId = mid, note = "t1")) {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, "todo setup failed: " + toString(err.status))
  }

  match getMessages("session-R") {
    case Ok(ml) -> assertEqualInt(ml.messages.length, 1, "one message listed")
    case Err(err) -> assertTrue(false, "getMessages failed: " + toString(err.status))
  }
  match getComments(mid) {
    case Ok(cl) -> assertEqualInt(cl.comments.length, 1, "one comment listed")
    case Err(err) -> assertTrue(false, "getComments failed: " + toString(err.status))
  }
  match getTodos("session-R") {
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
  val dbPath = useFreshTestDb("interactions-todo-mutate")
  defer {
    cleanupTestDb(dbPath)
  }
  val tid = match addTodoHandler("session-T", AddTodoRequest(messageId = "", note = "task")) {
    case Ok(t) -> t.id
    case Err(err) -> panic("addTodo setup failed: " + toString(err.status))
  }

  // A new todo starts not done.
  match getTodos("session-T") {
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
  match getTodos("session-T") {
    case Ok(tl) -> assertEqual(tl.todos[0].done, "1", "todo is done after toggle")
    case Err(err) -> assertTrue(false, "getTodos after toggle failed: " + toString(err.status))
  }

  // Delete removes it.
  match deleteTodoHandler(tid) {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, "delete failed: " + toString(err.status))
  }
  match getTodos("session-T") {
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
  val dbPath = useFreshTestDb("todo-status")
  defer {
    cleanupTestDb(dbPath)
  }

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

  val created = match addTodoHandler("session-S", AddTodoRequest(messageId = "", note = "step")) {
    case Ok(t) -> t
    case Err(err) -> panic("addTodoHandler failed: " + toString(err.status))
  }
  assertEqual(created.status, "pending", "a new todo starts pending")
  match setTodoStatusHandler(created.id, SetTodoStatusRequest(status = "in_progress")) {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, "valid status update failed: " + toString(err.status))
  }
  match CloudAgents.Repository.listTodos("session-S") {
    case Ok(todos) -> {
      assertEqual(todos[0].status, "in_progress", "status persisted")
      assertEqual(todos[0].done, "0", "done stays in lockstep")
    }
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
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
  val dbPath = useFreshTestDb("plan-ingest")
  defer {
    cleanupTestDb(dbPath)
  }
  val mid = addTestMessage("session-P")
  // A human todo that must survive every re-ingest.
  val human = match addTodoHandler("session-P", AddTodoRequest(messageId = "", note = "human note")) {
    case Ok(t) -> t
    case Err(err) -> panic("addTodoHandler failed: " + toString(err.status))
  }

  match ingestAgentPlan("session-P", mid, "- [x] step one\n- [~] step two\n- [ ] step three") {
    case Ok(n) -> assertEqualInt(n, 3, "three items ingested")
    case Err(e) -> assertTrue(false, "ingest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos("session-P") {
    case Ok(todos) -> assertEqualInt(todos.length.toInt(), 4, "3 plan rows + 1 human row")
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // The agent restates its plan — the old plan rows are replaced, not stacked.
  match ingestAgentPlan("session-P", mid, "- [x] step one\n- [x] step two\n- [~] step three") {
    case Ok(n) -> assertEqualInt(n, 3, "restated plan re-ingested")
    case Err(e) -> assertTrue(false, "re-ingest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos("session-P") {
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
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // A reply with no plan (or a lone checkbox) leaves everything untouched.
  match ingestAgentPlan("session-P", mid, "all done, no list here\n- [x] just one") {
    case Ok(n) -> assertEqualInt(n, 0, "no >=2-item list -> nothing ingested")
    case Err(e) -> assertTrue(false, "no-op ingest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos("session-P") {
    case Ok(todos) -> assertEqualInt(todos.length.toInt(), 4, "no-op ingest left rows alone")
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
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
  val dbPath = useFreshTestDb("todo-cursor-isolation")
  defer {
    cleanupTestDb(dbPath)
  }
  val midA = addTestMessage("session-CU-A")
  val midB = addTestMessage("session-CU-B")

  // Ingest a plan in A and a different one in B.
  match ingestAgentPlan("session-CU-A", midA, "- [ ] a-one\n- [x] a-two") {
    case Ok(n) -> assertEqualInt(n, 2, "A's plan ingested")
    case Err(e) -> assertTrue(false, "A ingest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match ingestAgentPlan("session-CU-B", midB, "- [ ] b-one\n- [ ] b-two") {
    case Ok(n) -> assertEqualInt(n, 2, "B's plan ingested")
    case Err(e) -> assertTrue(false, "B ingest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Cross-session isolation: A's cursor query never sees B's rows.
  val updatesA = match CloudAgents.Repository.todosUpdatedAfter("session-CU-A", "0") {
    case Ok(us) -> us
    case Err(e) -> panic("todosUpdatedAfter failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertEqualInt(updatesA.length.toInt(), 2, "only A's two rows")
  for u in updatesA {
    assertTrue(u.note == "a-one" or u.note == "a-two", "no cross-session leak: " + u.note)
  }

  // Cursor semantics: advancing past the last updated_at yields nothing...
  val lastCursor = updatesA[updatesA.length - 1].updatedAt
  match CloudAgents.Repository.todosUpdatedAfter("session-CU-A", lastCursor) {
    case Ok(us) -> assertEqualInt(us.length.toInt(), 0, "caught up -> empty")
    case Err(e) -> assertTrue(false, "cursor query failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // ...and a later status change surfaces past that same cursor.
  match CloudAgents.Repository.listTodos("session-CU-A") {
    case Ok(todos) -> {
      match CloudAgents.Interactions.setTodoStatusHandler(todos[0].id, SetTodoStatusRequest(status = "in_progress")) {
        case Ok(_) -> ()
        case Err(err) -> assertTrue(false, "status update failed: " + toString(err.status))
      }
    }
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.todosUpdatedAfter("session-CU-A", lastCursor) {
    case Ok(us) -> {
      assertEqualInt(us.length.toInt(), 1, "the status change surfaces past the cursor")
      assertEqual(us[0].status, "in_progress", "with its new status")
    }
    case Err(e) -> assertTrue(false, "cursor query failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "ingested plan lists first step first (#826) and enforces storage caps (#825)" {
  val dbPath = useFreshTestDb("plan-order-caps")
  defer {
    cleanupTestDb(dbPath)
  }
  val mid = addTestMessage("session-PO")
  match ingestAgentPlan("session-PO", mid, "- [x] first step\n- [~] second step\n- [ ] third step") {
    case Ok(n) -> assertEqualInt(n, 3, "three steps ingested")
    case Err(e) -> assertTrue(false, "ingest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos("session-PO") {
    case Ok(todos) -> {
      assertEqual(todos[0].note, "first step", "plan reads top-to-bottom, not reversed")
      assertEqual(todos[1].note, "second step", "middle step in place")
      assertEqual(todos[2].note, "third step", "last step last")
    }
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // An over-long NOTE is dropped at the ingestion boundary (the display
  // parser is uncapped by design); the remaining valid items still ingest.
  // The note limit is 32768 BYTES while the scan cap is 32768 CHARS, so the
  // only way a parsed note can exceed the byte limit is multi-byte text:
  // 16384 '✓' chars = 49152 UTF-8 bytes, and the whole message stays inside
  // the scan tail so all three lines reach the parser.
  match ingestAgentPlan("session-PO", mid, "- [ ] ok one\n- [ ] " + overWideText() + "\n- [ ] ok two") {
    case Ok(n) -> assertEqualInt(n, 2, "over-long note dropped, two kept")
    case Err(e) -> assertTrue(false, "capped ingest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos("session-PO") {
    case Ok(todos) -> {
      assertEqualInt(todos.length.toInt(), 2, "only the two kept rows stored")
      assertEqual(todos[0].note, "ok one", "first kept item first")
      assertEqual(todos[1].note, "ok two", "second kept item second")
    }
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // A "plan" longer than maxPlanIngestItems is truncated to the cap.
  var big = ""
  var s = 0
  while s < 60 {
    big = big + "- [ ] step " + toString(s) + "\n"
    s = s + 1
  }
  match ingestAgentPlan("session-PO", mid, big) {
    case Ok(n) -> assertEqualInt(n, 50, "60-step plan capped at 50")
    case Err(e) -> assertTrue(false, "count-capped ingest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // An over-long ITEM near the end of a huge message pushes earlier lines
  // out of the scan tail: only "ok two" survives, which is < 2 items, so
  // nothing is ingested and the prior plan rows stay. This is also the
  // regression guard for lyric-lang#6322 — the ~32k-char scan loop runs
  // past the .NET OSR promotion threshold, which used to crash the process
  // when parseAgentPlan appended records inside that loop.
  match ingestAgentPlan("session-PO", mid, "- [ ] ok one\n- [ ] " + overLongText() + "\n- [ ] ok two") {
    case Ok(n) -> assertEqualInt(n, 0, "tail-capped scan leaves <2 items -> no-op")
    case Err(e) -> assertTrue(false, "tail-capped ingest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.listTodos("session-PO") {
    case Ok(todos) -> assertEqualInt(todos.length.toInt(), 50, "no-op ingest left the capped plan alone")
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}
