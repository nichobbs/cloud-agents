//! CloudAgents.PgStore.Sessions — the Postgres implementation of the session
//! store (`sessions`, plus the global `session_routes`), mirroring the
//! SQLite-backed functions in `CloudAgents.SessionStore` with the same
//! signatures and semantics (docs/phase11-postgres-tenancy.md §4.2, §9 slices
//! B/C).
//!
//! Semantics carried over from the SQLite store:
//! - every read and write is filtered by the caller's user within the tenant
//!   (creator-only visibility, spec §5.4); observer sessions never appear in
//!   the lists;
//! - lists are most recently active first;
//! - `tryBeginRun` is a single guarded UPDATE, so two concurrent sends cannot
//!   both win;
//! - the container compare-and-clear only clears a still-matching id (#45);
//! - text forms match SQLite exactly: timestamps as epoch milliseconds,
//!   `is_archived` as "0"/"1", and "0" for a session never viewed.
//!
//! `session_routes` is the one global table here (spec §4.2). It maps a
//! session id to its tenant and owner so the container callback path, which
//! has no user identity, can find the session's scope before any tenant is
//! set. It is written in the same unit as the session row it routes, holds
//! the callback-token hash (moved out of `sessions`), and is removed with
//! the session.
@runtime_checked
package CloudAgents.PgStore.Sessions

import Std.Core
import Std.Uuid
import Db
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite

func sessionCols(): String {
  return "id, user_id, repo_url, branch, container_id, harness, model, native_session_id, status, " +
    CloudAgents.Pg.msOut("created_at") +
    " AS created_at, " +
    CloudAgents.Pg.msOut("last_message_at") +
    " AS last_message_at, CASE WHEN is_archived THEN '1' ELSE '0' END AS is_archived, group_id, " +
    "coalesce(" +
    CloudAgents.Pg.msOut("last_viewed_at") +
    ", '0') AS last_viewed_at, parent_session_id, forked_from_message_id"
}

func toSession(r: in DbRow): CloudAgents.SessionStore.AgentSession {
  return CloudAgents.SessionStore.AgentSession(
    sessionId = CloudAgents.PgStore.col(r, "id"),
    repoUrl = CloudAgents.PgStore.col(r, "repo_url"),
    branch = CloudAgents.PgStore.col(r, "branch"),
    containerId = CloudAgents.PgStore.col(r, "container_id"),
    harness = CloudAgents.PgStore.col(r, "harness"),
    model = CloudAgents.PgStore.col(r, "model"),
    nativeSessionId = CloudAgents.PgStore.col(r, "native_session_id"),
    status = CloudAgents.PgStore.col(r, "status"),
    isArchived = CloudAgents.PgStore.col(r, "is_archived"),
    groupId = CloudAgents.PgStore.col(r, "group_id"),
    lastViewedAt = CloudAgents.PgStore.col(r, "last_viewed_at"),
    parentSessionId = CloudAgents.PgStore.col(r, "parent_session_id"),
    forkedFromMessageId = CloudAgents.PgStore.col(r, "forked_from_message_id")
  )
}

func ownedWhere(): String {
  return " WHERE id = @p0 AND user_id = @p1"
}

/// Run one owner-scoped UPDATE on a session, `@p0` = id, `@p1` = user.
func updateOwned(
  sc: in CloudAgents.Pg.TenantScope, set: in String, params: in slice[String]
): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "UPDATE sessions SET " + set + ownedWhere(), params)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

/// The session-list projection as `{"sessions":[...]}`, most recently active
/// first, observer sessions excluded.
pub func sessionSummariesJson(sc: in CloudAgents.Pg.TenantScope): Result[String, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val sql = "SELECT " + sessionCols() +
    ", ((SELECT count(*) FROM permission_requests p WHERE p.session_id = s.id AND p.status = 'pending')" +
    " + (SELECT count(*) FROM user_questions q WHERE q.session_id = s.id AND q.status = 'pending')" +
    " + (SELECT count(*) FROM secret_requests r WHERE r.session_id = s.id AND r.status = 'pending'))::text AS pending_count" +
    ", (SELECT count(*) FROM ledger_entries l WHERE l.session_id = s.id AND l.review_state = 'pending' " +
    "AND l.severity IN ('review', 'blocking'))::text AS ledger_attention" +
    " FROM sessions s WHERE s.user_id = @p0 AND s.observes_session_id = '' ORDER BY s.last_message_at DESC"
  val rows = CloudAgents.PgStore.q(u, sql, [sc.userId])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.SessionStore.SessionSummaryRow] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.SessionStore.SessionSummaryRow(
        sessionId = CloudAgents.PgStore.col(r, "id"),
        repoUrl = CloudAgents.PgStore.col(r, "repo_url"),
        branch = CloudAgents.PgStore.col(r, "branch"),
        harness = CloudAgents.PgStore.col(r, "harness"),
        model = CloudAgents.PgStore.col(r, "model"),
        status = CloudAgents.PgStore.col(r, "status"),
        createdAt = CloudAgents.PgStore.col(r, "created_at"),
        lastMessageAt = CloudAgents.PgStore.col(r, "last_message_at"),
        isArchived = CloudAgents.PgStore.col(r, "is_archived"),
        groupId = CloudAgents.PgStore.col(r, "group_id"),
        lastViewedAt = CloudAgents.PgStore.col(r, "last_viewed_at"),
        parentSessionId = CloudAgents.PgStore.col(r, "parent_session_id"),
        forkedFromMessageId = CloudAgents.PgStore.col(r, "forked_from_message_id"),
        pendingCount = CloudAgents.PgStore.col(r, "pending_count"),
        ledgerAttention = CloudAgents.PgStore.col(r, "ledger_attention")
      )
    )
  }
  return Ok(value = CloudAgents.SessionStore.sessionSummariesToJson(acc))
}

/// All of the caller's sessions, most recently active first, observer
/// sessions excluded.
pub func getSessions(
  sc: in CloudAgents.Pg.TenantScope
): Result[CloudAgents.SessionStore.AgentSessionArray, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + sessionCols() + " FROM sessions WHERE user_id = @p0 AND observes_session_id = '' " + "ORDER BY last_message_at DESC", [sc.userId])?
  CloudAgents.PgStore.commit(u)?
  var list = CloudAgents.SessionStore.createEmptySessionArray()
  for r in rows {
    list = CloudAgents.SessionStore.appendSession(list, toSession(r))
  }
  return Ok(value = list)
}

/// Persist a new session owned by the caller, and its route, in one unit.
/// `last_message_at` starts at `created_at`.
pub func addSession(
  session: in CloudAgents.SessionStore.AgentSession, sc: in CloudAgents.Pg.TenantScope
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ts = CloudAgents.Repository.nowMillis()
  CloudAgents.PgStore.ex(u, "INSERT INTO sessions (id, user_id, repo_url, branch, container_id, harness, model, native_session_id, status, " + "created_at, last_message_at) VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6, @p7, @p8, " + CloudAgents.Pg.msIn(9) + ", " + CloudAgents.Pg.msIn(9) + ")", [session.sessionId, sc.userId, session.repoUrl, session.branch, session.containerId, session.harness, session.model, session.nativeSessionId, session.status, ts])?
  CloudAgents.PgStore.ex(u, "INSERT INTO session_routes (session_id, tenant_id, user_id) VALUES (@p0, @p1, @p2)", [session.sessionId, sc.tenantId, sc.userId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

/// One column of one of the caller's sessions, or None.
func ownedColumn(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, column: in String
): Result[Option[String], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + column + " AS v FROM sessions" + ownedWhere(), [sessionId, sc.userId])?
  CloudAgents.PgStore.commit(u)?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = CloudAgents.PgStore.col(rows[0], "v")))
}

/// A session's status, or None when it does not exist or is not the caller's.
pub func sessionStatus(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[String], CloudAgents.Sqlite.DbError] {
  return ownedColumn(sessionId, sc, "status")
}

/// Associate a session with a profile ("" clears it).
pub func setSessionProfile(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  updateOwned(sc, "profile_id = @p2", [sessionId, sc.userId, profileId])?
  return Ok(value = ())
}

/// A session's profile id ("" when none), or None.
pub func sessionProfileId(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[String], CloudAgents.Sqlite.DbError] {
  return ownedColumn(sessionId, sc, "profile_id")
}

/// One of the caller's sessions, or None.
pub func getSession(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.SessionStore.AgentSession], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + sessionCols() + " FROM sessions" + ownedWhere(), [sessionId, sc.userId])?
  CloudAgents.PgStore.commit(u)?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toSession(rows[0])))
}

pub func updateSessionContainerFor(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, containerId: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  updateOwned(sc, "container_id = @p2", [sessionId, sc.userId, containerId])?
  return Ok(value = ())
}

/// Clear the container id only if it still equals `containerId` (#45).
pub func clearSessionContainerIfMatchesFor(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  containerId: in String,
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, "UPDATE sessions SET container_id = ''" + ownedWhere() + " AND container_id = @p2", [sessionId, sc.userId, containerId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

pub func updateSessionModel(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, model: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  updateOwned(sc, "model = @p2", [sessionId, sc.userId, model])?
  return Ok(value = ())
}

/// Set the archived flag from its text form ("1" archives, anything else
/// unarchives; callers pass "1" or "0").
pub func updateSessionArchived(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, isArchived: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  updateOwned(sc, "is_archived = (@p2 = '1')", [sessionId, sc.userId, isArchived])?
  return Ok(value = ())
}

pub func setSessionGroup(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, groupId: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  updateOwned(sc, "group_id = @p2", [sessionId, sc.userId, groupId])?
  return Ok(value = ())
}

/// Stamp "the user looked at this session just now".
pub func markSessionViewed(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Unit, CloudAgents.Sqlite.DbError] {
  updateOwned(sc, "last_viewed_at = " + CloudAgents.Pg.msIn(2), [sessionId, sc.userId, CloudAgents.Repository.nowMillis()])?
  return Ok(value = ())
}

/// Delete one of the caller's sessions and its route; rows deleted.
func deleteOwned(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "DELETE FROM sessions" + ownedWhere(), [sessionId, sc.userId])?
  if n > 0 {
    CloudAgents.PgStore.ex(u, "DELETE FROM session_routes WHERE session_id = @p0 AND tenant_id = @p1", [sessionId, sc.tenantId])?
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

/// Remove a session, returning the record removed (None when it did not
/// exist or is not the caller's).
pub func removeSession(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.SessionStore.AgentSession], CloudAgents.Sqlite.DbError] {
  val existing = getSession(sessionId, sc)?
  match existing {
    case None -> return Ok(value = None)
    case Some(_) -> ()
  }
  deleteOwned(sessionId, sc)?
  return Ok(value = existing)
}

/// Delete a session row without re-reading it; a no-op if already gone.
pub func deleteSessionRecord(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Unit, CloudAgents.Sqlite.DbError] {
  deleteOwned(sessionId, sc)?
  return Ok(value = ())
}

/// Atomically claim a session for a run: false when a run is already in
/// progress (or the session is not the caller's).
pub func tryBeginRun(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Bool, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "UPDATE sessions SET status = 'RUNNING', last_message_at = " + CloudAgents.Pg.msIn(2) + ownedWhere() + " AND status <> 'RUNNING'", [sessionId, sc.userId, CloudAgents.Repository.nowMillis()])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n > 0)
}

/// Return a session to IDLE after a run and record the activity time.
pub func endRun(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Sqlite.DbError] {
  updateOwned(sc, "status = 'IDLE', last_message_at = " + CloudAgents.Pg.msIn(2), [sessionId, sc.userId, CloudAgents.Repository.nowMillis()])?
  return Ok(value = ())
}

// ─── Session routes (global) ────────────────────────────────────────────────
/// Mint a fresh callback token for one of the caller's sessions, store only
/// its hash on the session's route, and return the raw token. A session
/// that is not the caller's gets no hash written (the token is still
/// returned, as on SQLite, and authorises nothing).
pub func mintCallbackToken(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[String, CloudAgents.Sqlite.DbError] {
  val token = Std.Uuid.uuidToString(Std.Uuid.newUuid()) + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  val tokenHash = CloudAgents.Auth.hashCallbackToken(token)
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, "UPDATE session_routes SET callback_token_hash = @p2 WHERE session_id = @p0 AND tenant_id = @p3 " + "AND user_id = @p1 AND EXISTS (SELECT 1 FROM sessions s WHERE s.id = @p0 AND s.user_id = @p1)", [sessionId, sc.userId, tokenHash, sc.tenantId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = token)
}

/// One column of a session's route by id only, or None when there is no
/// such session. Deliberately unscoped: it is read before any tenant is
/// known.
func routeColumn(sessionId: in String, column: in String): Result[Option[String], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + column + " AS v FROM session_routes WHERE session_id = @p0", [sessionId])?
  CloudAgents.PgStore.commit(u)?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = CloudAgents.PgStore.col(rows[0], "v")))
}

/// A session's stored callback-token hash by id only: None for an unknown
/// session, "" for one that never minted a token. Comparing a presented
/// token's hash against it (CloudAgents.Auth.authorizeCallback) is the
/// authentication.
pub func callbackTokenHashForSession(sessionId: in String): Result[Option[String], CloudAgents.Sqlite.DbError] {
  return routeColumn(sessionId, "callback_token_hash")
}

/// A session's owning user id by id only, or None.
pub func sessionOwnerUserId(sessionId: in String): Result[Option[String], CloudAgents.Sqlite.DbError] {
  return routeColumn(sessionId, "user_id")
}

/// The scope a session's container callbacks run under: its tenant and
/// owner, from the route (spec §5.2's callback-token resolver). None for an
/// unknown session. Callers authenticate the presented token against
/// `callbackTokenHashForSession` before acting in this scope.
pub func sessionRouteScope(sessionId: in String): Result[Option[CloudAgents.Pg.TenantScope], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT tenant_id, user_id FROM session_routes WHERE session_id = @p0", [sessionId])?
  CloudAgents.PgStore.commit(u)?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(
    value = Some(
      value = CloudAgents.Pg.TenantScope(
        tenantId = CloudAgents.PgStore.col(rows[0], "tenant_id"),
        userId = CloudAgents.PgStore.col(rows[0], "user_id")
      )
    )
  )
}
