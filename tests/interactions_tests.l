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
