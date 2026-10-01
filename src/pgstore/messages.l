//! CloudAgents.PgStore.Messages — the Postgres implementation of a session's
//! transcript and annotations (`messages`, `comments`, `todos`), mirroring
//! the SQLite-backed functions in `CloudAgents.Repository` with the same
//! signatures and semantics (docs/phase11-postgres-tenancy.md §9 slices B/C).
//!
//! These rows carry no user id of their own: ownership is reached through
//! the session, which the handlers check (`requireOwnedSession`) before
//! calling here, exactly as with SQLite. Row-level security adds the tenant
//! boundary underneath.
//!
//! Semantics carried over from the SQLite store:
//! - a message's sequence number is the session's message count at insert
//!   time, rendered as 12-digit zero-padded text; appends to one session are
//!   serialised by a transaction-scoped advisory lock, so concurrent inserts
//!   cannot take the same number (#1170);
//! - messages list in sequence order, comments oldest first, todos newest
//!   first (ties broken by id so the order is deterministic);
//! - `done` renders as "0"/"1" and is kept in step with `status` by the SQL;
//! - the plan-todo replacement is one transaction and never touches rows a
//!   human or tool created (`source = ''`);
//! - the todo-update cursor is exclusive, and "" means "from the start".
//!
//!
//! Full-text search (`searchMessages`) runs against the generated
//! `messages.search_vector` (`to_tsvector('simple', content)`, GIN-indexed)
//! instead of SQLite's FTS5 table, with the same contract: every word of the
//! user's text must match as a case-insensitive prefix, operators in the
//! text are inert, only the caller's own sessions are searched, and results
//! come newest first. Tokenisation differs from FTS5 in the ways listed in
//! docs/phase9-message-search.md, "Postgres".
@runtime_checked
package CloudAgents.PgStore.Messages

import Std.Core
import Std.Uuid
import Db
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Repository
import CloudAgents.Db

func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func messageCols(): String {
  return "id, session_id, role, content, lpad(seq::text, 12, '0') AS seq, " + CloudAgents.Pg.msOut("created_at") +
    " AS created_at"
}

func toMessage(r: in DbRow): CloudAgents.Repository.Message {
  return CloudAgents.Repository.Message(
    id = CloudAgents.PgStore.col(r, "id"),
    sessionId = CloudAgents.PgStore.col(r, "session_id"),
    role = CloudAgents.PgStore.col(r, "role"),
    content = CloudAgents.PgStore.col(r, "content"),
    seq = CloudAgents.PgStore.col(r, "seq"),
    createdAt = CloudAgents.PgStore.col(r, "created_at")
  )
}

/// Append a message and return the stored record, with its fresh id and the
/// session's next sequence number.
pub func addMessage(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, role: in String, content: in String
): Result[CloudAgents.Repository.Message, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  // Serialise appends to one session (#1170): without this, two concurrent
  // inserts would both count the same rows and take the same sequence
  // number. The lock is transaction-scoped, so it is released at commit.
  CloudAgents.PgStore.q(u, "SELECT pg_advisory_xact_lock(hashtextextended(current_setting('app.current_tenant') || ':' || @p0, 0))", [sessionId])?
  val rows = CloudAgents.PgStore.q(u, "INSERT INTO messages (id, session_id, role, content, seq, created_at) " + "VALUES (@p0, @p1, @p2, @p3, (SELECT count(*) FROM messages WHERE session_id = @p1), " + CloudAgents.Pg.msIn(4) + ") RETURNING lpad(seq::text, 12, '0') AS seq", [id, sessionId, role, content, ts])?
  CloudAgents.PgStore.commit(u)?
  return Ok(
    value = CloudAgents.Repository.Message(
      id = id,
      sessionId = sessionId,
      role = role,
      content = content,
      seq = CloudAgents.PgStore.col(rows[0], "seq"),
      createdAt = ts
    )
  )
}

/// All messages in a session, in sequence order.
pub func listMessages(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Message], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + messageCols() + " FROM messages WHERE session_id = @p0 ORDER BY seq, id COLLATE \"C\"", [sessionId])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.Message] = []
  for r in rows {
    acc = acc.append(toMessage(r))
  }
  return Ok(value = acc)
}

/// A session's agent messages with a sequence number above `afterSeq`, in
/// order. `afterSeq` is a stored (zero-padded) seq, or "" for all of them.
pub func agentMessagesAfterSeq(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterSeq: in String
): Result[slice[CloudAgents.Repository.Message], CloudAgents.Db.DbError] {
  val after = if afterSeq.length == 0 { "0" } else { afterSeq }
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + messageCols() + " FROM messages WHERE session_id = @p0 AND role = 'agent' " + "AND seq > @p1::integer ORDER BY seq", [sessionId, after])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.Message] = []
  for r in rows {
    acc = acc.append(toMessage(r))
  }
  return Ok(value = acc)
}

/// One column of one row by id, or None.
func columnById(
  sc: in CloudAgents.Pg.TenantScope, table: in String, id: in String, column: in String
): Result[Option[String], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + column + " AS v FROM " + table + " WHERE id = @p0", [id])?
  CloudAgents.PgStore.commit(u)?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = CloudAgents.PgStore.col(rows[0], "v")))
}

/// The session a message belongs to, or None.
pub func getMessageSessionId(
  messageId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[String], CloudAgents.Db.DbError] {
  return columnById(sc, "messages", messageId, "session_id")
}

/// SQL: the user's raw text (`@pN`) as a prefix query. `plainto_tsquery`
/// parses it as plain words (no operator in it is interpreted) and ANDs
/// them; the rewrite then marks every lexeme `:*` so each matches as a
/// prefix. Lexemes from the 'simple' parser never contain a space, so the
/// only quote followed by a space or the end is a lexeme's closing quote.
func prefixQuery(n: in Int): String {
  return "regexp_replace(plainto_tsquery('simple', @p" + toString(n) + ")::text, " +
    r"'''( |$)', ''':*\1', 'g')::tsquery"
}

/// Full-text search across every message in the caller's own sessions,
/// newest first (ties by id). `term` is the user's raw search text; a term
/// with no words matches nothing.
pub func searchMessages(
  sc: in CloudAgents.Pg.TenantScope, term: in String, limit: in Int
): Result[slice[CloudAgents.Repository.Message], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val sql = "SELECT m.id, m.session_id, m.role, m.content, lpad(m.seq::text, 12, '0') AS seq, " +
    CloudAgents.Pg.msOut("m.created_at") +
    " AS created_at FROM messages m JOIN sessions s ON s.id = m.session_id " +
    "WHERE s.user_id = @p0 AND m.search_vector @@ " +
    prefixQuery(1) +
    " ORDER BY m.created_at DESC, m.id COLLATE \"C\" LIMIT " +
    toString(limit)
  val rows = CloudAgents.PgStore.q(u, sql, [sc.userId, term])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.Message] = []
  for r in rows {
    acc = acc.append(toMessage(r))
  }
  return Ok(value = acc)
}

// ─── Comments ───────────────────────────────────────────────────────────────
/// Attach a comment to a message.
pub func addComment(
  messageId: in String, sc: in CloudAgents.Pg.TenantScope, sessionId: in String, body: in String
): Result[CloudAgents.Repository.Comment, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  CloudAgents.PgStore.ex(u, "INSERT INTO comments (id, message_id, session_id, body, created_at) VALUES (@p0, @p1, @p2, @p3, " + CloudAgents.Pg.msIn(4) + ")", [id, messageId, sessionId, body, ts])?
  CloudAgents.PgStore.commit(u)?
  return Ok(
    value = CloudAgents.Repository.Comment(
      id = id,
      messageId = messageId,
      sessionId = sessionId,
      body = body,
      createdAt = ts
    )
  )
}

/// All comments on a message, oldest first.
pub func listComments(
  messageId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Comment], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT id, message_id, session_id, body, " + CloudAgents.Pg.msOut("created_at") + " AS created_at FROM comments " + "WHERE message_id = @p0 ORDER BY created_at, id COLLATE \"C\"", [messageId])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.Comment] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.Repository.Comment(
        id = CloudAgents.PgStore.col(r, "id"),
        messageId = CloudAgents.PgStore.col(r, "message_id"),
        sessionId = CloudAgents.PgStore.col(r, "session_id"),
        body = CloudAgents.PgStore.col(r, "body"),
        createdAt = CloudAgents.PgStore.col(r, "created_at")
      )
    )
  }
  return Ok(value = acc)
}

// ─── Todos ──────────────────────────────────────────────────────────────────
func insertTodoSql(): String {
  return "INSERT INTO todos (id, session_id, message_id, note, done, created_at, status, updated_at, source) " +
    "VALUES (@p0, @p1, @p2, @p3, (@p4 = 'done'), " +
    CloudAgents.Pg.msIn(5) +
    ", @p4, " +
    CloudAgents.Pg.msIn(5) +
    ", @p6)"
}

/// Create a todo, optionally anchored to a message ("" for none). New todos
/// start "pending".
pub func addTodo(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, messageId: in String, note: in String
): Result[CloudAgents.Repository.Todo, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  CloudAgents.PgStore.ex(u, insertTodoSql(), [id, sessionId, messageId, note, "pending", ts, ""])?
  CloudAgents.PgStore.commit(u)?
  return Ok(
    value = CloudAgents.Repository.Todo(
      id = id,
      sessionId = sessionId,
      messageId = messageId,
      note = note,
      done = "0",
      createdAt = ts,
      status = "pending"
    )
  )
}

/// Replace a session's plan todos with the agent's latest plan in one
/// transaction. `notes` and `statuses` are parallel (the shorter one bounds
/// the count). Timestamps descend with the index so the newest-first listing
/// reads step 1 to step N top to bottom (#826).
pub func replacePlanTodos(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  messageId: in String,
  notes: in slice[String],
  statuses: in slice[String],
): Result[Unit, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val baseMs = CloudAgents.Repository.nowMillisLong()
  var count = notes.length.toInt()
  if statuses.length.toInt() < count {
    count = statuses.length.toInt()
  }
  CloudAgents.PgStore.ex(u, "DELETE FROM todos WHERE session_id = @p0 AND source = 'plan'", [sessionId])?
  var i = 0
  while i < count {
    val ts = toString(baseMs + (count - 1 - i).toLong())
    CloudAgents.PgStore.ex(u, insertTodoSql(), [newId(), sessionId, messageId, notes[i], statuses[i], ts, "plan"])?
    i = i + 1
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

/// Run one statement on a todo by id, `@p0` = id.
func todoWrite(
  sc: in CloudAgents.Pg.TenantScope, sql: in String, params: in slice[String]
): Result[Unit, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, sql, params)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

/// Set a todo's status directly; `done` follows it.
pub func setTodoStatus(
  id: in String, sc: in CloudAgents.Pg.TenantScope, status: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return todoWrite(
    sc,
    "UPDATE todos SET status = @p1, done = (@p1 = 'done'), updated_at = " + CloudAgents.Pg.msIn(2) +
      " WHERE id = @p0",
    [id, status, CloudAgents.Repository.nowMillis()]
  )
}

/// Todos changed strictly after the cursor, oldest change first. "" is the
/// initial cursor and matches every todo.
pub func todosUpdatedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterUpdatedAt: in String
): Result[slice[CloudAgents.Repository.TodoUpdate], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val cols = "SELECT id, note, status, " + CloudAgents.Pg.msOut("updated_at") +
    " AS updated_at FROM todos WHERE session_id = @p0"
  var sql = cols + " ORDER BY updated_at, id COLLATE \"C\""
  var params: slice[String] = [sessionId]
  if afterUpdatedAt.length > 0 {
    sql = cols + " AND updated_at > " + CloudAgents.Pg.msIn(1) + " ORDER BY updated_at, id COLLATE \"C\""
    params = [sessionId, afterUpdatedAt]
  }
  val rows = CloudAgents.PgStore.q(u, sql, params)?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.TodoUpdate] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.Repository.TodoUpdate(
        id = CloudAgents.PgStore.col(r, "id"),
        note = CloudAgents.PgStore.col(r, "note"),
        status = CloudAgents.PgStore.col(r, "status"),
        updatedAt = CloudAgents.PgStore.col(r, "updated_at")
      )
    )
  }
  return Ok(value = acc)
}

/// The session a todo belongs to, or None.
pub func getTodoSessionId(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[String], CloudAgents.Db.DbError] {
  return columnById(sc, "todos", id, "session_id")
}

/// All todos for a session, newest first.
pub func listTodos(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Todo], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT id, session_id, message_id, note, CASE WHEN done THEN '1' ELSE '0' END AS done, " + CloudAgents.Pg.msOut("created_at") + " AS created_at, status FROM todos WHERE session_id = @p0 " + "ORDER BY created_at DESC, id COLLATE \"C\"", [sessionId])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.Todo] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.Repository.Todo(
        id = CloudAgents.PgStore.col(r, "id"),
        sessionId = CloudAgents.PgStore.col(r, "session_id"),
        messageId = CloudAgents.PgStore.col(r, "message_id"),
        note = CloudAgents.PgStore.col(r, "note"),
        done = CloudAgents.PgStore.col(r, "done"),
        createdAt = CloudAgents.PgStore.col(r, "created_at"),
        status = CloudAgents.PgStore.col(r, "status")
      )
    )
  }
  return Ok(value = acc)
}

/// Flip a todo's done flag; the status moves between "pending" and "done".
pub func toggleTodo(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Db.DbError] {
  return todoWrite(
    sc,
    "UPDATE todos SET done = NOT done, status = CASE WHEN done THEN 'pending' ELSE 'done' END, " +
      "updated_at = " +
      CloudAgents.Pg.msIn(1) +
      " WHERE id = @p0",
    [id, CloudAgents.Repository.nowMillis()]
  )
}

/// Delete a todo.
pub func deleteTodo(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Db.DbError] {
  return todoWrite(sc, "DELETE FROM todos WHERE id = @p0", [id])
}
