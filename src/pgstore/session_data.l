//! CloudAgents.PgStore.SessionData — the Postgres implementation of a
//! session's run history, linked repositories, attachments, highlights and
//! branching, and the user's session groups (`runs`, `session_repos`,
//! `session_attachments`, `session_highlights`, `highlight_scans`,
//! `session_groups`), behind the `CloudAgents.Repository` facade
//! (docs/phase11-postgres-tenancy.md §9 slices B/C).
//!
//! Semantics:
//! - runs and groups are filtered by the caller's user; linked repositories
//!   carry no user id, so the handlers' owner-checked session lookup gates
//!   them (row-level security adds the tenant boundary);
//! - a run's prompt preview is the same bounded prefix, a run only leaves
//!   "running" once, and a still-running run reads back with `endedAt` "";
//! - runs and highlights list newest first, repositories and attachments
//!   oldest first, groups by name in byte order;
//! - the highlight scan cursor reads back in the messages' 12-digit form;
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
import CloudAgents.Db

func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

/// Run statements in one unit and return the affected count of the first.
func exec(
  sc: in CloudAgents.Pg.TenantScope, sql: in String, params: in slice[String]
): Result[Int, CloudAgents.Db.DbError] {
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
): Result[slice[DbRow], CloudAgents.Db.DbError] {
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
): Result[String, CloudAgents.Db.DbError] {
  val id = newId()
  exec(sc, "INSERT INTO runs (id, session_id, user_id, prompt_preview, harness, model, status, started_at) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, 'running', " + CloudAgents.Pg.msIn(6) + ")", [id, sessionId, sc.userId, CloudAgents.Repository.promptPreview(prompt), harness, model, CloudAgents.Repository.nowMillis()])?
  return Ok(value = id)
}

/// Move one of the caller's running runs to a terminal status.
pub func recordRunEnd(
  runId: in String, sc: in CloudAgents.Pg.TenantScope, status: in String
): Result[Unit, CloudAgents.Db.DbError] {
  exec(sc, "UPDATE runs SET status = @p2, ended_at = " + CloudAgents.Pg.msIn(3) + " WHERE id = @p0 AND user_id = @p1 AND status = 'running'", [runId, sc.userId, status, CloudAgents.Repository.nowMillis()])?
  return Ok(value = ())
}

/// Mark every still-running run of a session terminal.
pub func finishSessionRuns(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, status: in String
): Result[Unit, CloudAgents.Db.DbError] {
  exec(sc, "UPDATE runs SET status = @p2, ended_at = " + CloudAgents.Pg.msIn(3) + " WHERE session_id = @p0 AND user_id = @p1 AND status = 'running'", [sessionId, sc.userId, status, CloudAgents.Repository.nowMillis()])?
  return Ok(value = ())
}

/// A session's run history, newest first.
pub func listRuns(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Run], CloudAgents.Db.DbError] {
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
): Result[slice[CloudAgents.Repository.SessionRepo], CloudAgents.Db.DbError] {
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
pub func countSessionRepos(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT count(*)::text AS n FROM session_repos WHERE session_id = @p0", [sessionId])?
  return Ok(value = CloudAgents.Repository.parseNatString(CloudAgents.PgStore.col(rows[0], "n")))
}

/// Whether the session already links a repository at `repoUrl`.
pub func sessionRepoUrlExists(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, repoUrl: in String
): Result[Bool, CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT 1 AS one FROM session_repos WHERE session_id = @p0 AND repo_url = @p1", [sessionId, repoUrl])?
  return Ok(value = rows.length > 0)
}

/// Link a repository to a session and return the stored record.
pub func addSessionRepo(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, repoUrl: in String, branch: in String
): Result[CloudAgents.Repository.SessionRepo, CloudAgents.Db.DbError] {
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
): Result[Int, CloudAgents.Db.DbError] {
  return exec(sc, "DELETE FROM session_repos WHERE id = @p0 AND session_id = @p1", [repoId, sessionId])
}

/// Remove every repository linked to a session.
pub func deleteSessionReposForSession(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Unit, CloudAgents.Db.DbError] {
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
): Result[slice[CloudAgents.Repository.SessionGroup], CloudAgents.Db.DbError] {
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
): Result[Option[CloudAgents.Repository.SessionGroup], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + groupCols() + " FROM session_groups WHERE id = @p0 AND user_id = @p1", [id, sc.userId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toGroup(rows[0])))
}

/// Create a group and return the stored record.
pub func addSessionGroup(
  sc: in CloudAgents.Pg.TenantScope, name: in String, parentId: in String
): Result[CloudAgents.Repository.SessionGroup, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  exec(sc, "INSERT INTO session_groups (id, user_id, name, parent_id, created_at) VALUES (@p0, @p1, @p2, @p3, " + CloudAgents.Pg.msIn(4) + ")", [id, sc.userId, name, parentId, ts])?
  return Ok(value = CloudAgents.Repository.SessionGroup(id = id, name = name, parentId = parentId, createdAt = ts))
}

/// Update a group's name and parent; rows affected (0 = not found or not
/// the caller's).
pub func updateSessionGroup(
  id: in String, sc: in CloudAgents.Pg.TenantScope, name: in String, parentId: in String
): Result[Int, CloudAgents.Db.DbError] {
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
): Result[Unit, CloudAgents.Db.DbError] {
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

// ─── Attachments ────────────────────────────────────────────────────────────
func attachmentCols(): String {
  return "id, session_id, message_id, file_name, stored_name, mime_type, kind, size_bytes::text AS size_bytes, " +
    CloudAgents.Pg.msOut("created_at") +
    " AS created_at"
}

func toAttachment(r: in DbRow): CloudAgents.Repository.Attachment {
  return CloudAgents.Repository.Attachment(
    id = CloudAgents.PgStore.col(r, "id"),
    sessionId = CloudAgents.PgStore.col(r, "session_id"),
    messageId = CloudAgents.PgStore.col(r, "message_id"),
    fileName = CloudAgents.PgStore.col(r, "file_name"),
    storedName = CloudAgents.PgStore.col(r, "stored_name"),
    mimeType = CloudAgents.PgStore.col(r, "mime_type"),
    kind = CloudAgents.PgStore.col(r, "kind"),
    sizeBytes = CloudAgents.PgStore.col(r, "size_bytes"),
    createdAt = CloudAgents.PgStore.col(r, "created_at")
  )
}

func insertAttachmentSql(): String {
  return "INSERT INTO session_attachments (id, session_id, message_id, file_name, stored_name, mime_type, kind, size_bytes, created_at) " +
    "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6, @p7::bigint, " +
    CloudAgents.Pg.msIn(8) +
    ")"
}

/// Record an uploaded attachment's metadata (the bytes are already on disk);
/// it is linked to its message later.
pub func createAttachment(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  fileName: in String,
  storedName: in String,
  mimeType: in String,
  kind: in String,
  sizeBytes: in String,
): Result[CloudAgents.Repository.Attachment, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  exec(sc, insertAttachmentSql(), [id, sessionId, "", fileName, storedName, mimeType, kind, sizeBytes, ts])?
  return Ok(
    value = CloudAgents.Repository.Attachment(
      id = id,
      sessionId = sessionId,
      messageId = "",
      fileName = fileName,
      storedName = storedName,
      mimeType = mimeType,
      kind = kind,
      sizeBytes = sizeBytes,
      createdAt = ts
    )
  )
}

/// Link an attachment to the user message it was sent with.
pub func linkAttachmentToMessage(
  id: in String, sc: in CloudAgents.Pg.TenantScope, messageId: in String
): Result[Unit, CloudAgents.Db.DbError] {
  exec(sc, "UPDATE session_attachments SET message_id = @p1 WHERE id = @p0", [id, messageId])?
  return Ok(value = ())
}

/// An attachment by id, or None.
pub func getAttachment(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.Attachment], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + attachmentCols() + " FROM session_attachments WHERE id = @p0", [id])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toAttachment(rows[0])))
}

/// Remove one attachment row.
pub func deleteAttachment(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Db.DbError] {
  exec(sc, "DELETE FROM session_attachments WHERE id = @p0", [id])?
  return Ok(value = ())
}

/// A session's attachments, oldest first.
pub func listAttachments(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Attachment], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + attachmentCols() + " FROM session_attachments WHERE session_id = @p0 " + "ORDER BY created_at, id COLLATE \"C\"", [sessionId])?
  var acc: slice[CloudAgents.Repository.Attachment] = []
  for r in rows {
    acc = acc.append(toAttachment(r))
  }
  return Ok(value = acc)
}

// ─── Highlights ─────────────────────────────────────────────────────────────
func insertHighlightSql(): String {
  return "INSERT INTO session_highlights (id, session_id, message_id, kind, title, detail, created_at) " +
    "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, " +
    CloudAgents.Pg.msIn(6) +
    ")"
}

/// Store one extracted highlight, anchored to the agent message it came
/// from.
pub func addHighlight(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  messageId: in String,
  kind: in String,
  title: in String,
  detail: in String,
): Result[CloudAgents.Repository.Highlight, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  exec(sc, insertHighlightSql(), [id, sessionId, messageId, kind, title, detail, ts])?
  return Ok(
    value = CloudAgents.Repository.Highlight(
      id = id,
      sessionId = sessionId,
      messageId = messageId,
      kind = kind,
      title = title,
      detail = detail,
      createdAt = ts
    )
  )
}

/// A session's highlights, newest first.
pub func listHighlights(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Highlight], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT id, session_id, message_id, kind, title, detail, " + CloudAgents.Pg.msOut("created_at") + " AS created_at " + "FROM session_highlights WHERE session_id = @p0 ORDER BY created_at DESC, id COLLATE \"C\"", [sessionId])?
  var acc: slice[CloudAgents.Repository.Highlight] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.Repository.Highlight(
        id = CloudAgents.PgStore.col(r, "id"),
        sessionId = CloudAgents.PgStore.col(r, "session_id"),
        messageId = CloudAgents.PgStore.col(r, "message_id"),
        kind = CloudAgents.PgStore.col(r, "kind"),
        title = CloudAgents.PgStore.col(r, "title"),
        detail = CloudAgents.PgStore.col(r, "detail"),
        createdAt = CloudAgents.PgStore.col(r, "created_at")
      )
    )
  }
  return Ok(value = acc)
}

/// The highest transcript seq already scanned for highlights, in the
/// messages' 12-digit form, or "" when the session was never scanned.
pub func highlightScanSeq(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[String, CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT lpad(last_seq::text, 12, '0') AS last_seq FROM highlight_scans WHERE session_id = @p0", [sessionId])?
  if rows.length == 0 {
    return Ok(value = "")
  }
  return Ok(value = CloudAgents.PgStore.col(rows[0], "last_seq"))
}

/// Record the highest transcript seq scanned for highlights.
pub func setHighlightScanSeq(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, lastSeq: in String
): Result[Unit, CloudAgents.Db.DbError] {
  exec(sc, "INSERT INTO highlight_scans (session_id, last_seq) VALUES (@p0, @p1::bigint) " + "ON CONFLICT (tenant_id, session_id) DO UPDATE SET last_seq = EXCLUDED.last_seq", [sessionId, lastSeq])?
  return Ok(value = ())
}

// ─── Branching ──────────────────────────────────────────────────────────────
func mappedId(pairs: in slice[String], oldId: in String): String {
  var i = 0
  while i + 1 < pairs.length {
    if pairs[i] == oldId {
      return pairs[i + 1]
    }
    i = i + 2
  }
  return ""
}

/// Branch one of the caller's sessions from a message into a new child
/// session: the transcript up to and including that message (all of it when
/// `forkedMessageId` is ""), with fresh message ids and the original sequence
/// numbers and timestamps; the comments on copied messages; attachments that
/// are free-standing or on a copied message (and their files on disk);
/// todos and highlights likewise (copied todos become ordinary todos); the linked
/// repositories; and the profile. The new session keeps the parent's group and
/// gets its own route. Unlike the old SQLite store, the database side is one
/// transaction, so a failure leaves no partial branch; attachment
/// files are copied only after it commits (#1172).
pub func branchSession(
  parentSessionId: in String,
  forkedMessageId: in String,
  newSessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  newBranch: in String,
): Result[Unit, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val parents = CloudAgents.PgStore.q(u, "SELECT repo_url, branch, harness, model, group_id, profile_id FROM sessions WHERE id = @p0 AND user_id = @p1", [parentSessionId, sc.userId])?
  if parents.length == 0 {
    return Err(error = CloudAgents.Db.ValidationFailed(message = "parent session not found or not owned by user"))
  }
  val parent = parents[0]
  var maxSeq = "999999999"
  if forkedMessageId.length > 0 {
    val forked = CloudAgents.PgStore.q(u, "SELECT session_id, seq::text AS seq FROM messages WHERE id = @p0", [forkedMessageId])?
    if forked.length == 0 {
      return Err(error = CloudAgents.Db.ValidationFailed(message = "forked message not found"))
    }
    if CloudAgents.PgStore.col(forked[0], "session_id") != parentSessionId {
      return Err(error = CloudAgents.Db.ValidationFailed(message = "forked message does not belong to parent session"))
    }
    maxSeq = CloudAgents.PgStore.col(forked[0], "seq")
  }
  var branch = CloudAgents.PgStore.col(parent, "branch")
  if newBranch.length > 0 {
    branch = newBranch
  }
  val ts = CloudAgents.Repository.nowMillis()
  CloudAgents.PgStore.ex(u, "INSERT INTO sessions (id, user_id, repo_url, branch, container_id, harness, model, native_session_id, status, " + "created_at, last_message_at, group_id, profile_id, parent_session_id, forked_from_message_id) " + "VALUES (@p0, @p1, @p2, @p3, '', @p4, @p5, @p0, 'IDLE', " + CloudAgents.Pg.msIn(6) + ", " + CloudAgents.Pg.msIn(6) + ", @p7, @p8, @p9, @p10)", [newSessionId, sc.userId, CloudAgents.PgStore.col(parent, "repo_url"), branch, CloudAgents.PgStore.col(parent, "harness"), CloudAgents.PgStore.col(parent, "model"), ts, CloudAgents.PgStore.col(parent, "group_id"), CloudAgents.PgStore.col(parent, "profile_id"), parentSessionId, forkedMessageId])?
  CloudAgents.PgStore.ex(u, "INSERT INTO session_routes (session_id, tenant_id, user_id) VALUES (@p0, @p1, @p2)", [newSessionId, sc.tenantId, sc.userId])?
  CloudAgents.PgStore.ex(u, "INSERT INTO session_repos (id, session_id, repo_url, branch, created_at) " + "SELECT gen_random_uuid()::text, @p1, repo_url, branch, " + CloudAgents.Pg.msIn(2) + " FROM session_repos WHERE session_id = @p0", [parentSessionId, newSessionId, ts])?

  // Messages, recording old id -> new id pairs.
  val msgs = CloudAgents.PgStore.q(u, "SELECT id FROM messages WHERE session_id = @p0 AND seq <= @p1::bigint ORDER BY seq, id COLLATE \"C\"", [parentSessionId, maxSeq])?
  var idPairs: slice[String] = []
  for m in msgs {
    val oldId = CloudAgents.PgStore.col(m, "id")
    val nid = newId()
    idPairs = idPairs.append(oldId)
    idPairs = idPairs.append(nid)
    CloudAgents.PgStore.ex(u, "INSERT INTO messages (id, session_id, role, content, seq, created_at) " + "SELECT @p2, @p1, role, content, seq, created_at FROM messages WHERE id = @p0", [oldId, newSessionId, nid])?
    CloudAgents.PgStore.ex(u, "INSERT INTO comments (id, message_id, session_id, body, created_at) " + "SELECT gen_random_uuid()::text, @p2, @p1, body, created_at FROM comments WHERE message_id = @p0", [oldId, newSessionId, nid])?
  }

  // Attachment rows now; their files are copied only after the commit, so a
  // rolled-back branch leaves no orphaned copies on disk (#1172).
  var filesToCopy: slice[String] = []
  val atts = CloudAgents.PgStore.q(u, "SELECT id, message_id, stored_name FROM session_attachments WHERE session_id = @p0 ORDER BY created_at, id COLLATE \"C\"", [parentSessionId])?
  for a in atts {
    val oldMsg = CloudAgents.PgStore.col(a, "message_id")
    val newMsg = mappedId(idPairs, oldMsg)
    if oldMsg.length == 0 or newMsg.length > 0 {
      CloudAgents.PgStore.ex(u, "INSERT INTO session_attachments (id, session_id, message_id, file_name, stored_name, mime_type, kind, size_bytes, created_at) " + "SELECT gen_random_uuid()::text, @p1, @p2, file_name, stored_name, mime_type, kind, size_bytes, created_at " + "FROM session_attachments WHERE id = @p0", [CloudAgents.PgStore.col(a, "id"), newSessionId, newMsg])?
      filesToCopy = filesToCopy.append(CloudAgents.PgStore.col(a, "stored_name"))
    }
  }

  // Todos and highlights: free-standing ones, and those on a copied message.
  val todos = CloudAgents.PgStore.q(u, "SELECT id, message_id FROM todos WHERE session_id = @p0", [parentSessionId])?
  for t in todos {
    val oldMsg = CloudAgents.PgStore.col(t, "message_id")
    val newMsg = mappedId(idPairs, oldMsg)
    if oldMsg.length == 0 or newMsg.length > 0 {
      CloudAgents.PgStore.ex(u, "INSERT INTO todos (id, session_id, message_id, note, done, created_at, status, updated_at, source) " + "SELECT gen_random_uuid()::text, @p1, @p2, note, (status = 'done'), created_at, status, created_at, '' " + "FROM todos WHERE id = @p0", [CloudAgents.PgStore.col(t, "id"), newSessionId, newMsg])?
    }
  }
  val highlights = CloudAgents.PgStore.q(u, "SELECT id, message_id FROM session_highlights WHERE session_id = @p0", [parentSessionId])?
  for h in highlights {
    val oldMsg = CloudAgents.PgStore.col(h, "message_id")
    val newMsg = mappedId(idPairs, oldMsg)
    if oldMsg.length == 0 or newMsg.length > 0 {
      CloudAgents.PgStore.ex(u, "INSERT INTO session_highlights (id, session_id, message_id, kind, title, detail, created_at) " + "SELECT gen_random_uuid()::text, @p1, @p2, kind, title, detail, created_at FROM session_highlights WHERE id = @p0", [CloudAgents.PgStore.col(h, "id"), newSessionId, newMsg])?
    }
  }
  CloudAgents.PgStore.commit(u)?
  val sourceDir = CloudAgents.Repository.attachmentsBaseDir() + "/" + parentSessionId
  val targetDir = CloudAgents.Repository.attachmentsBaseDir() + "/" + newSessionId
  for storedName in filesToCopy {
    CloudAgents.Repository.copyFileIfExists(sourceDir + "/" + storedName, targetDir, targetDir + "/" + storedName)
  }
  return Ok(value = ())
}
