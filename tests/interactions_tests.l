@test_module
package CloudAgents.InteractionsTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Interactions
import CloudAgents.Repository
import CloudAgents.Sqlite
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
