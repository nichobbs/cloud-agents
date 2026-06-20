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
