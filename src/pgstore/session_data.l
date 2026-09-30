//! CloudAgents.PgStore.SessionData — the Postgres implementation of a
//! session's run history, linked repositories and the user's session groups
//! (`runs`, `session_repos`, `session_groups`), mirroring the SQLite-backed
//! functions in `CloudAgents.Repository` with the same signatures and
//! semantics (docs/phase11-postgres-tenancy.md §9 slices B/C).
//!
//! Semantics carried over from the SQLite store:
//! - runs and groups are filtered by the caller's user; linked repositories
//!   carry no user id, so the handlers' owner-checked session lookup gates
//!   them, as with SQLite (row-level security adds the tenant boundary);
//! - a run's prompt preview is the same bounded prefix, a run only leaves
//!   "running" once, and a still-running run reads back with `endedAt` "";
//! - runs list newest first, repositories oldest first, groups by name in
//!   byte order;
//! - deleting a group reparents its child groups and reassigns its sessions
//!   to its own parent, all in one transaction.
//!
//! One difference: `session_repos` is unique per (session, URL) in Postgres.
//! The handler already refuses a duplicate (`sessionRepoUrlExists`), so the
//! constraint only turns a race between two adds into an error instead of a
//! duplicate row.
@runtime_checked
package CloudAgents.PgStore.SessionData

import Std.Core
import Std.Uuid
import Db
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Repository
import CloudAgents.Sqlite

func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

/// Run statements in one unit and return the affected count of the first.
func exec(
  sc: in CloudAgents.Pg.TenantScope, sql: in String, params: in slice[String]
): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, sql, params)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

func query(
  sc: in CloudAgents.Pg.TenantScope, sql: in String, params: in slice[String]
): Result[slice[DbRow], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, sql, params)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = rows)
}

// ─── Runs ───────────────────────────────────────────────────────────────────
/// Record the start of a run (status "running") and return its id.
pub func recordRunStart(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  prompt: in String,
  harness: in String,
  model: in String,
): Result[String, CloudAgents.Sqlite.DbError] {
  val id = newId()
  exec(sc, "INSERT INTO runs (id, session_id, user_id, prompt_preview, harness, model, status, started_at) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, 'running', " + CloudAgents.Pg.msIn(6) + ")", [id, sessionId, sc.userId, CloudAgents.Repository.promptPreview(prompt), harness, model, CloudAgents.Repository.nowMillis()])?
  return Ok(value = id)
}

/// Move one of the caller's running runs to a terminal status.
pub func recordRunEnd(
  runId: in String, sc: in CloudAgents.Pg.TenantScope, status: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(sc, "UPDATE runs SET status = @p2, ended_at = " + CloudAgents.Pg.msIn(3) + " WHERE id = @p0 AND user_id = @p1 AND status = 'running'", [runId, sc.userId, status, CloudAgents.Repository.nowMillis()])?
  return Ok(value = ())
}

/// Mark every still-running run of a session terminal.
pub func finishSessionRuns(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, status: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(sc, "UPDATE runs SET status = @p2, ended_at = " + CloudAgents.Pg.msIn(3) + " WHERE session_id = @p0 AND user_id = @p1 AND status = 'running'", [sessionId, sc.userId, status, CloudAgents.Repository.nowMillis()])?
  return Ok(value = ())
}

/// A session's run history, newest first.
pub func listRuns(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Run], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT id, session_id, user_id, prompt_preview, harness, model, status, " + CloudAgents.Pg.msOut("started_at") + " AS started_at, " + CloudAgents.Pg.msOut("ended_at") + " AS ended_at FROM runs " + "WHERE session_id = @p0 AND user_id = @p1 ORDER BY started_at DESC, id COLLATE \"C\"", [sessionId, sc.userId])?
  var acc: slice[CloudAgents.Repository.Run] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.Repository.Run(
        id = CloudAgents.PgStore.col(r, "id"),
        sessionId = CloudAgents.PgStore.col(r, "session_id"),
        userId = CloudAgents.PgStore.col(r, "user_id"),
        promptPreview = CloudAgents.PgStore.col(r, "prompt_preview"),
        harness = CloudAgents.PgStore.col(r, "harness"),
        model = CloudAgents.PgStore.col(r, "model"),
        status = CloudAgents.PgStore.col(r, "status"),
        startedAt = CloudAgents.PgStore.col(r, "started_at"),
        endedAt = CloudAgents.PgStore.col(r, "ended_at")
      )
    )
  }
  return Ok(value = acc)
}

// ─── Linked repositories ────────────────────────────────────────────────────
/// A session's linked repositories, oldest first.
pub func listSessionRepos(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.SessionRepo], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT id, session_id, repo_url, branch, " + CloudAgents.Pg.msOut("created_at") + " AS created_at FROM session_repos " + "WHERE session_id = @p0 ORDER BY created_at, id COLLATE \"C\"", [sessionId])?
  var acc: slice[CloudAgents.Repository.SessionRepo] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.Repository.SessionRepo(
        id = CloudAgents.PgStore.col(r, "id"),
        sessionId = CloudAgents.PgStore.col(r, "session_id"),
        repoUrl = CloudAgents.PgStore.col(r, "repo_url"),
        branch = CloudAgents.PgStore.col(r, "branch"),
        createdAt = CloudAgents.PgStore.col(r, "created_at")
      )
    )
  }
  return Ok(value = acc)
}

/// How many repositories are linked to a session.
pub func countSessionRepos(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Int, CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT count(*)::text AS n FROM session_repos WHERE session_id = @p0", [sessionId])?
  return Ok(value = CloudAgents.Repository.parseNatString(CloudAgents.PgStore.col(rows[0], "n")))
}

/// Whether the session already links a repository at `repoUrl`.
pub func sessionRepoUrlExists(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, repoUrl: in String
): Result[Bool, CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT 1 AS one FROM session_repos WHERE session_id = @p0 AND repo_url = @p1", [sessionId, repoUrl])?
  return Ok(value = rows.length > 0)
}

/// Link a repository to a session and return the stored record.
pub func addSessionRepo(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, repoUrl: in String, branch: in String
): Result[CloudAgents.Repository.SessionRepo, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  exec(sc, "INSERT INTO session_repos (id, session_id, repo_url, branch, created_at) VALUES (@p0, @p1, @p2, @p3, " + CloudAgents.Pg.msIn(4) + ")", [id, sessionId, repoUrl, branch, ts])?
  return Ok(
    value = CloudAgents.Repository.SessionRepo(
      id = id,
      sessionId = sessionId,
      repoUrl = repoUrl,
      branch = branch,
      createdAt = ts
    )
  )
}

/// Unlink a repository; rows affected (0 = not found).
pub func deleteSessionRepo(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, repoId: in String
): Result[Int, CloudAgents.Sqlite.DbError] {
  return exec(sc, "DELETE FROM session_repos WHERE id = @p0 AND session_id = @p1", [repoId, sessionId])
}

/// Remove every repository linked to a session.
pub func deleteSessionReposForSession(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(sc, "DELETE FROM session_repos WHERE session_id = @p0", [sessionId])?
  return Ok(value = ())
}

// ─── Session groups ─────────────────────────────────────────────────────────
func groupCols(): String {
  return "id, name, parent_id, " + CloudAgents.Pg.msOut("created_at") + " AS created_at"
}

func toGroup(r: in DbRow): CloudAgents.Repository.SessionGroup {
  return CloudAgents.Repository.SessionGroup(
    id = CloudAgents.PgStore.col(r, "id"),
    name = CloudAgents.PgStore.col(r, "name"),
    parentId = CloudAgents.PgStore.col(r, "parent_id"),
    createdAt = CloudAgents.PgStore.col(r, "created_at")
  )
}

/// The caller's groups, by name in byte order.
pub func listSessionGroups(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.SessionGroup], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + groupCols() + " FROM session_groups WHERE user_id = @p0 ORDER BY name COLLATE \"C\", id COLLATE \"C\"", [sc.userId])?
  var acc: slice[CloudAgents.Repository.SessionGroup] = []
  for r in rows {
    acc = acc.append(toGroup(r))
  }
  return Ok(value = acc)
}

/// One of the caller's groups, or None (unknown and foreign look the same).
pub func getSessionGroup(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.SessionGroup], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + groupCols() + " FROM session_groups WHERE id = @p0 AND user_id = @p1", [id, sc.userId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toGroup(rows[0])))
}

/// Create a group and return the stored record.
pub func addSessionGroup(
  sc: in CloudAgents.Pg.TenantScope, name: in String, parentId: in String
): Result[CloudAgents.Repository.SessionGroup, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  exec(sc, "INSERT INTO session_groups (id, user_id, name, parent_id, created_at) VALUES (@p0, @p1, @p2, @p3, " + CloudAgents.Pg.msIn(4) + ")", [id, sc.userId, name, parentId, ts])?
  return Ok(value = CloudAgents.Repository.SessionGroup(id = id, name = name, parentId = parentId, createdAt = ts))
}

/// Update a group's name and parent; rows affected (0 = not found or not
/// the caller's).
pub func updateSessionGroup(
  id: in String, sc: in CloudAgents.Pg.TenantScope, name: in String, parentId: in String
): Result[Int, CloudAgents.Sqlite.DbError] {
  return exec(
    sc,
    "UPDATE session_groups SET name = @p2, parent_id = @p3 WHERE id = @p0 AND user_id = @p1",
    [id, sc.userId, name, parentId]
  )
}

/// Delete a group, moving its child groups and its sessions to `newParentId`
/// ("" when it was a root), in one transaction.
pub func deleteSessionGroupReparenting(
  id: in String, sc: in CloudAgents.Pg.TenantScope, newParentId: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val params = [id, sc.userId, newParentId]
  CloudAgents.PgStore.ex(u, "UPDATE session_groups SET parent_id = @p2 WHERE parent_id = @p0 AND user_id = @p1", params)?
  CloudAgents.PgStore.ex(u, "UPDATE sessions SET group_id = @p2 WHERE group_id = @p0 AND user_id = @p1", params)?
  CloudAgents.PgStore.ex(u, "DELETE FROM session_groups WHERE id = @p0 AND user_id = @p1", [id, sc.userId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}
