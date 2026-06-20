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
