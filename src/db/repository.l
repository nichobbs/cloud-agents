//! Persistence for the conversation transcript, comments and todos.
//!
//! Builds SQL with the pure CloudAgents.Db builders and runs it through the
//! CloudAgents.Sqlite driver, mapping result rows to domain records. This is
//! the seam the HTTP handlers depend on — they never see SQL or `extern`
//! handles, only records and `Result`.
@runtime_checked
package CloudAgents.Repository

import Std.Core
import Std.Uuid
import Std.Time.{Instant}
import CloudAgents.Db
import CloudAgents.Sqlite

@generate(Json)
pub record Message {
  pub id: String
  pub sessionId: String
  pub role: String
  pub content: String
  pub seq: String
  pub createdAt: String
}

@generate(Json)
pub record Comment {
  pub id: String
  pub messageId: String
  pub sessionId: String
  pub body: String
  pub createdAt: String
}

@generate(Json)
pub record Todo {
  pub id: String
  pub sessionId: String
  pub messageId: String
  pub note: String
  pub done: String
  pub createdAt: String
}

@generate(Json)
pub record MessageList {
  pub messages: slice[Message]
}

@generate(Json)
pub record CommentList {
  pub comments: slice[Comment]
}

@generate(Json)
pub record TodoList {
  pub todos: slice[Todo]
}

// ─── Small helpers ─────────────────────────────────────────────────────────────

func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func nowMillis(): String {
  return toString(Instant.now().toEpochMillis())
}

func digitValue(c: in String): Int {
  if c == "0" { return 0 }
  if c == "1" { return 1 }
  if c == "2" { return 2 }
  if c == "3" { return 3 }
  if c == "4" { return 4 }
  if c == "5" { return 5 }
  if c == "6" { return 6 }
  if c == "7" { return 7 }
  if c == "8" { return 8 }
  if c == "9" { return 9 }
  return -1
}

/// Parse a run of decimal digits into an Int, ignoring non-digit characters.
func parseNatString(s: in String): Int {
  var n = 0
  var i = 0
  while i < s.length {
    val d = digitValue(s.substring(i, 1))
    if d >= 0 {
      n = n * 10 + d
    }
    i = i + 1
  }
  return n
}

func colAt(cols: in slice[String], i: in Int): String {
  if i < cols.length {
    return cols[i]
  }
  return ""
}

// ─── Schema ────────────────────────────────────────────────────────────────────

/// Create every table if it does not already exist. Safe to call at every
/// startup.
pub func initSchema(): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(CloudAgents.Db.messagesSchemaSql())?
  CloudAgents.Sqlite.execute(CloudAgents.Db.commentsSchemaSql())?
  CloudAgents.Sqlite.execute(CloudAgents.Db.todosSchemaSql())?
  return Ok(value = ())
}

// ─── Messages ──────────────────────────────────────────────────────────────────

func rowToMessage(r: in CloudAgents.Sqlite.Row): Message {
  return Message(
    id = colAt(r.cols, 0),
    sessionId = colAt(r.cols, 1),
    role = colAt(r.cols, 2),
    content = colAt(r.cols, 3),
    seq = colAt(r.cols, 4),
    createdAt = colAt(r.cols, 5)
  )
}

/// Next sequence number for a session (its current message count).
func nextSeq(sessionId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.countMessagesSql(sessionId))?
  if rows.length == 0 {
    return Ok(value = 0)
  }
  return Ok(value = parseNatString(colAt(rows[0].cols, 0)))
}

/// Append a message to a session's transcript and return the stored record
/// (with its freshly minted id and sequence number).
pub func addMessage(
  sessionId: in String,
  role: in String,
  content: in String
): Result[Message, CloudAgents.Sqlite.DbError] {
  val seqN = nextSeq(sessionId)?
  val id = newId()
  val ts = nowMillis()
  val seqStr = CloudAgents.Db.padSeq(seqN)
  CloudAgents.Sqlite.execute(CloudAgents.Db.insertMessageSql(id, sessionId, role, content, seqStr, ts))?
  return Ok(value = Message(
    id = id,
    sessionId = sessionId,
    role = role,
    content = content,
    seq = seqStr,
    createdAt = ts
  ))
}

/// All messages in a session, oldest first.
pub func listMessages(sessionId: in String): Result[slice[Message], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectMessagesSql(sessionId))?
  var acc: slice[Message] = []
  var i = 0
  while i < rows.length {
    acc = acc.append(rowToMessage(rows[i]))
    i = i + 1
  }
  return Ok(value = acc)
}

// ─── Comments ──────────────────────────────────────────────────────────────────

func rowToComment(r: in CloudAgents.Sqlite.Row): Comment {
  return Comment(
    id = colAt(r.cols, 0),
    messageId = colAt(r.cols, 1),
    sessionId = colAt(r.cols, 2),
    body = colAt(r.cols, 3),
    createdAt = colAt(r.cols, 4)
  )
}

/// Attach a comment to a message.
pub func addComment(
  messageId: in String,
  sessionId: in String,
  body: in String
): Result[Comment, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = nowMillis()
  CloudAgents.Sqlite.execute(CloudAgents.Db.insertCommentSql(id, messageId, sessionId, body, ts))?
  return Ok(value = Comment(
    id = id,
    messageId = messageId,
    sessionId = sessionId,
    body = body,
    createdAt = ts
  ))
}

/// All comments on a message, oldest first.
pub func listComments(messageId: in String): Result[slice[Comment], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectCommentsSql(messageId))?
  var acc: slice[Comment] = []
  var i = 0
  while i < rows.length {
    acc = acc.append(rowToComment(rows[i]))
    i = i + 1
  }
  return Ok(value = acc)
}

// ─── Todos ─────────────────────────────────────────────────────────────────────

func rowToTodo(r: in CloudAgents.Sqlite.Row): Todo {
  return Todo(
    id = colAt(r.cols, 0),
    sessionId = colAt(r.cols, 1),
    messageId = colAt(r.cols, 2),
    note = colAt(r.cols, 3),
    done = colAt(r.cols, 4),
    createdAt = colAt(r.cols, 5)
  )
}

/// Create a todo / bookmark, optionally anchored to a message (pass "" for a
/// free-standing todo).
pub func addTodo(
  sessionId: in String,
  messageId: in String,
  note: in String
): Result[Todo, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = nowMillis()
  CloudAgents.Sqlite.execute(CloudAgents.Db.insertTodoSql(id, sessionId, messageId, note, ts))?
  return Ok(value = Todo(
    id = id,
    sessionId = sessionId,
    messageId = messageId,
    note = note,
    done = "0",
    createdAt = ts
  ))
}

/// All todos for a session, newest first.
pub func listTodos(sessionId: in String): Result[slice[Todo], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectTodosSql(sessionId))?
  var acc: slice[Todo] = []
  var i = 0
  while i < rows.length {
    acc = acc.append(rowToTodo(rows[i]))
    i = i + 1
  }
  return Ok(value = acc)
}

/// Flip a todo's done flag.
pub func toggleTodo(id: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(CloudAgents.Db.toggleTodoSql(id))?
  return Ok(value = ())
}

/// Delete a todo.
pub func deleteTodo(id: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(CloudAgents.Db.deleteTodoSql(id))?
  return Ok(value = ())
}
