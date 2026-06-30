package CloudAgents.Db

import Std.Core

/// Phase 2 groundwork: session lifecycle state and the SQLite schema.
///
/// The session state machine (docs/phase2-session-management.md):
///
///   CREATED -> CLONING -> IDLE -> RUNNING -> WARM -> IDLE ...
///   (any state) -> DESTROYED
///
/// The actual SQL execution is performed through the `lyric-db` library once
/// it is wired in; this module owns the pure, host-independent pieces — the
/// status vocabulary and the schema text — so they can be unit-tested without
/// a database.

/// Lifecycle state of a session.
pub enum SessionStatus {
  case Created
  case Cloning
  case Idle
  case Running
  case Warm
  case Destroyed
}

/// Canonical uppercase string stored in the `status` column.
pub func statusToString(s: in SessionStatus): String {
  return match s {
    case Created -> "CREATED"
    case Cloning -> "CLONING"
    case Idle -> "IDLE"
    case Running -> "RUNNING"
    case Warm -> "WARM"
    case Destroyed -> "DESTROYED"
  }
}

/// Parse a status string from the database back into the enum.
/// Returns `None` for an unrecognised value.
pub func statusFromString(s: in String): Option[SessionStatus] {
  if s == "CREATED" {
    return Some(value = Created)
  }
  if s == "CLONING" {
    return Some(value = Cloning)
  }
  if s == "IDLE" {
    return Some(value = Idle)
  }
  if s == "RUNNING" {
    return Some(value = Running)
  }
  if s == "WARM" {
    return Some(value = Warm)
  }
  if s == "DESTROYED" {
    return Some(value = Destroyed)
  }
  return None
}

/// Whether a session in this state currently holds (or expects) a live
/// container. Used by the idle-recycling sweep to decide what to stop.
pub func hasLiveContainer(s: in SessionStatus): Bool {
  return match s {
    case Created -> false
    case Cloning -> true
    case Idle -> false
    case Running -> true
    case Warm -> true
    case Destroyed -> false
  }
}

// ─── State machine ────────────────────────────────────────────────────────────
//
// Drives the transitions in docs/phase2-session-management.md. Modelled as a
// total function so the compiler's exhaustiveness check guarantees every
// (state, event) pair is considered — illegal pairs return `Invalid` rather
// than silently doing the wrong thing.

/// Events that can drive a session between states.
pub enum SessionEvent {
  case CloneStarted
  case CloneFinished
  case MessageReceived
  case ProcessExited
  case IdleTimeout
  case Deleted
}

/// Result of attempting a transition: a new status, or `Invalid` when the
/// event is not legal in the current state.
pub union Transition {
  case To(status: SessionStatus)
  case Invalid
}

/// Compute the next state for a (current state, event) pair.
pub func nextStatus(current: in SessionStatus, event: in SessionEvent): Transition {
  return match current {
    case Created -> match event {
      case CloneStarted -> To(status = Cloning)
      case Deleted -> To(status = Destroyed)
      case CloneFinished -> Invalid
      case MessageReceived -> Invalid
      case ProcessExited -> Invalid
      case IdleTimeout -> Invalid
    }
    case Cloning -> match event {
      case CloneFinished -> To(status = Idle)
      case Deleted -> To(status = Destroyed)
      case CloneStarted -> Invalid
      case MessageReceived -> Invalid
      case ProcessExited -> Invalid
      case IdleTimeout -> Invalid
    }
    case Idle -> match event {
      case MessageReceived -> To(status = Running)
      case Deleted -> To(status = Destroyed)
      case CloneStarted -> Invalid
      case CloneFinished -> Invalid
      case ProcessExited -> Invalid
      case IdleTimeout -> Invalid
    }
    case Running -> match event {
      case ProcessExited -> To(status = Warm)
      case Deleted -> To(status = Destroyed)
      case CloneStarted -> Invalid
      case CloneFinished -> Invalid
      case MessageReceived -> Invalid
      case IdleTimeout -> Invalid
    }
    case Warm -> match event {
      case MessageReceived -> To(status = Running)
      case IdleTimeout -> To(status = Idle)
      case Deleted -> To(status = Destroyed)
      case CloneStarted -> Invalid
      case CloneFinished -> Invalid
      case ProcessExited -> Invalid
    }
    case Destroyed -> Invalid
  }
}

// ─── Idle recycling ───────────────────────────────────────────────────────────
//
// A background sweep stops warm containers after a short grace window and
// evicts the container metadata of long-idle sessions (docs/phase2 §2).

/// Grace period a container stays warm after a run before being stopped (5 min).
pub func warmWindowMillis(): Long {
  return 300000.toLong()
}

/// How long an idle session is kept before its container metadata is dropped
/// and it is treated as fully cold (1 hour).
pub func coldWindowMillis(): Long {
  return 3600000.toLong()
}

/// Action the idle sweep should take for a session.
pub enum RecycleAction {
  case StopAndIdle
  case EvictCold
  case NoAction
}

/// Decide what the idle sweep should do given a session's state and how long
/// it has been since its last message.
pub func recycleDecision(status: in SessionStatus, idleMillis: in Long): RecycleAction {
  return match status {
    case Warm -> if idleMillis >= warmWindowMillis() then StopAndIdle else NoAction
    case Idle -> if idleMillis >= coldWindowMillis() then EvictCold else NoAction
    case Created -> NoAction
    case Cloning -> NoAction
    case Running -> NoAction
    case Destroyed -> NoAction
  }
}

/// DDL for the `sessions` table (Phase 2). Mirrors the schema in
/// docs/phase2-session-management.md. Applied at startup with
/// `CREATE TABLE IF NOT EXISTS`, so it is safe to run repeatedly.
pub func sessionsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS sessions (" +
    "id TEXT PRIMARY KEY, " +
    "github_user_id INTEGER NOT NULL, " +
    "repo_url TEXT, " +
    "branch TEXT DEFAULT 'main', " +
    "status TEXT, " +
    "container_id TEXT, " +
    "volume_name TEXT, " +
    "created_at TIMESTAMP, " +
    "last_message_at TIMESTAMP)"
}

/// Name of the per-session workspace volume (Phase 3 keys by GitHub user).
pub func workspaceVolumeName(githubUserId: in String, sessionId: in String): String {
  return "session-" + githubUserId + "-" + sessionId
}

/// Name of the per-user home volume holding the `.claude` credentials.
pub func homeVolumeName(githubUserId: in String): String {
  return "user-" + githubUserId + "-home"
}

// ─── Parameterised SQL ────────────────────────────────────────────────────────
//
// Statements use `?` placeholders bound by the lyric-db layer. Every read and
// mutation is scoped by `github_user_id` so a user can only ever touch their
// own sessions (Phase 3 ownership enforcement, docs/phase3 §4).

/// INSERT a new session row.
/// Params: id, github_user_id, repo_url, branch, status, container_id,
/// volume_name, created_at, last_message_at.
pub func insertSessionSql(): String {
  return "INSERT INTO sessions " +
    "(id, github_user_id, repo_url, branch, status, container_id, volume_name, created_at, last_message_at) " +
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
}

/// SELECT a single session owned by a user. Params: id, github_user_id.
pub func selectSessionByIdSql(): String {
  return "SELECT id, github_user_id, repo_url, branch, status, container_id, volume_name, created_at, last_message_at " +
    "FROM sessions WHERE id = ? AND github_user_id = ?"
}

/// SELECT all sessions owned by a user, newest first. Param: github_user_id.
pub func listSessionsByUserSql(): String {
  return "SELECT id, github_user_id, repo_url, branch, status, container_id, volume_name, created_at, last_message_at " +
    "FROM sessions WHERE github_user_id = ? ORDER BY last_message_at DESC"
}

/// UPDATE a session's status and container id.
/// Params: status, container_id, id, github_user_id.
pub func updateSessionStatusSql(): String {
  return "UPDATE sessions SET status = ?, container_id = ? WHERE id = ? AND github_user_id = ?"
}

/// Record that a message was received. Params: last_message_at, id, github_user_id.
pub func touchLastMessageSql(): String {
  return "UPDATE sessions SET last_message_at = ? WHERE id = ? AND github_user_id = ?"
}

/// DELETE a session. Params: id, github_user_id.
pub func deleteSessionSql(): String {
  return "DELETE FROM sessions WHERE id = ? AND github_user_id = ?"
}

/// Reset any sessions still marked RUNNING or WARM back to IDLE. Used by the
/// startup recovery routine after a Docker daemon or VM restart (docs/phase2
/// §Constraints). No params.
pub func recoverDanglingSessionsSql(): String {
  return "UPDATE sessions SET status = 'IDLE', container_id = '' " +
    "WHERE status = 'RUNNING' OR status = 'WARM'"
}

// ─── Conversation transcript, comments and todos ───────────────────────────────
//
// These tables back the "addressable agent responses" feature: each user
// prompt and each agent reply is stored as a `messages` row with a stable id,
// so comments and todo items can link back to a specific point in the run.
//
// The lyric-db parameter binding used for `sessions` above is not available
// through the minimal CloudAgents.Sqlite driver, so statements that take values
// are assembled here with `sqlLiteral` escaping. Every column is declared with
// TEXT affinity so the driver can read each one with `GetString`.

/// Quote and escape a value as a SQLite single-quoted string literal. The only
/// metacharacter inside a single-quoted SQLite string is `'`, which is escaped
/// by doubling it — this is injection-safe for any text interpolated into a
/// quoted literal position.
pub func sqlLiteral(s: in String): String {
  var acc = "'"
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    if c == "'" {
      acc = acc + "''"
    } else {
      acc = acc + c
    }
    i = i + 1
  }
  return acc + "'"
}

/// Left-pad a sequence number to a fixed width so lexical ordering on the TEXT
/// `seq` column matches numeric ordering.
pub func padSeq(n: in Int): String {
  var s = toString(n)
  while s.length < 12 {
    s = "0" + s
  }
  return s
}

/// DDL for the conversation transcript. `role` is 'user' or 'agent'; `seq` is a
/// zero-padded monotonic counter within a session.
pub func messagesSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS messages (" +
    "id TEXT PRIMARY KEY, " +
    "session_id TEXT NOT NULL, " +
    "role TEXT NOT NULL, " +
    "content TEXT NOT NULL, " +
    "seq TEXT NOT NULL, " +
    "created_at TEXT NOT NULL)"
}

/// DDL for comments attached to a specific message.
pub func commentsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS comments (" +
    "id TEXT PRIMARY KEY, " +
    "message_id TEXT NOT NULL, " +
    "session_id TEXT NOT NULL, " +
    "body TEXT NOT NULL, " +
    "created_at TEXT NOT NULL)"
}

/// DDL for todo / bookmark items. `message_id` links back to the source message
/// (empty string when a todo is not anchored to a message). `done` is '0'/'1'.
pub func todosSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS todos (" +
    "id TEXT PRIMARY KEY, " +
    "session_id TEXT NOT NULL, " +
    "message_id TEXT NOT NULL, " +
    "note TEXT NOT NULL, " +
    "done TEXT NOT NULL, " +
    "created_at TEXT NOT NULL)"
}

/// INSERT one transcript message with all values inlined as escaped literals.
pub func insertMessageSql(
  id: in String,
  sessionId: in String,
  role: in String,
  content: in String,
  seq: in String,
  createdAt: in String
): String {
  return "INSERT INTO messages (id, session_id, role, content, seq, created_at) VALUES (" +
    sqlLiteral(id) + ", " + sqlLiteral(sessionId) + ", " + sqlLiteral(role) + ", " +
    sqlLiteral(content) + ", " + sqlLiteral(seq) + ", " + sqlLiteral(createdAt) + ")"
}

/// SELECT the session_id that owns a given message. Used by the comments
/// handler to derive ownership without trusting the client.
pub func selectMessageSessionIdSql(messageId: in String): String {
  return "SELECT session_id FROM messages WHERE id = " + sqlLiteral(messageId)
}

/// SELECT a session's transcript, oldest first. Column order matches the
/// mapping in CloudAgents.Repository.
pub func selectMessagesSql(sessionId: in String): String {
  return "SELECT id, session_id, role, content, seq, created_at FROM messages " +
    "WHERE session_id = " + sqlLiteral(sessionId) + " ORDER BY seq ASC"
}

/// COUNT messages in a session, cast to TEXT so the driver can read it with
/// GetString. Used to compute the next `seq`.
pub func countMessagesSql(sessionId: in String): String {
  return "SELECT CAST(COUNT(*) AS TEXT) FROM messages WHERE session_id = " +
    sqlLiteral(sessionId)
}

/// INSERT a comment on a message.
pub func insertCommentSql(
  id: in String,
  messageId: in String,
  sessionId: in String,
  body: in String,
  createdAt: in String
): String {
  return "INSERT INTO comments (id, message_id, session_id, body, created_at) VALUES (" +
    sqlLiteral(id) + ", " + sqlLiteral(messageId) + ", " + sqlLiteral(sessionId) + ", " +
    sqlLiteral(body) + ", " + sqlLiteral(createdAt) + ")"
}

/// SELECT comments on a message, oldest first.
pub func selectCommentsSql(messageId: in String): String {
  return "SELECT id, message_id, session_id, body, created_at FROM comments " +
    "WHERE message_id = " + sqlLiteral(messageId) + " ORDER BY created_at ASC"
}

/// INSERT a todo / bookmark.
pub func insertTodoSql(
  id: in String,
  sessionId: in String,
  messageId: in String,
  note: in String,
  createdAt: in String
): String {
  return "INSERT INTO todos (id, session_id, message_id, note, done, created_at) VALUES (" +
    sqlLiteral(id) + ", " + sqlLiteral(sessionId) + ", " + sqlLiteral(messageId) + ", " +
    sqlLiteral(note) + ", '0', " + sqlLiteral(createdAt) + ")"
}

/// SELECT all todos for a session, newest first.
pub func selectTodosSql(sessionId: in String): String {
  return "SELECT id, session_id, message_id, note, done, created_at FROM todos " +
    "WHERE session_id = " + sqlLiteral(sessionId) + " ORDER BY created_at DESC"
}

/// Toggle a todo's done flag by id.
pub func toggleTodoSql(id: in String): String {
  return "UPDATE todos SET done = CASE done WHEN '1' THEN '0' ELSE '1' END WHERE id = " +
    sqlLiteral(id)
}

/// DELETE a todo by id.
pub func deleteTodoSql(id: in String): String {
  return "DELETE FROM todos WHERE id = " + sqlLiteral(id)
}
