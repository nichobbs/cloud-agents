//! CloudAgents.PgStore.Interactive — the Postgres implementation of a
//! session's interactive requests and agent-reported state: permission
//! requests and allow-always rules, user questions, progress, secret
//! requests, artifacts, notifications, and the per-repository memory and
//! task list (docs/phase11-postgres-tenancy.md §9 slices B/C). It mirrors the
//! SQLite-backed functions in `CloudAgents.Repository` with the same
//! signatures and semantics.
//!
//! Container-originated calls arrive with the scope resolved from the
//! session's route (`authorizeCallbackToken`), human calls with the request's
//! scope; either way row-level security confines every statement to that
//! tenant. Within it, these rows are keyed by session (or by the session
//! owner and repository), exactly as on SQLite.
//!
//! Semantics carried over from the SQLite store:
//! - answers and timeouts only move a request out of "pending", once, and
//!   report rows affected so a late answer maps to 409;
//! - a timeout fires only once the request has been pending at least the
//!   given number of milliseconds;
//! - an approved secret is marked delivered at most once;
//! - allow-always rules are idempotent per (session, tool, input);
//! - memory and open tasks are capped per (owner, repository): a write that
//!   would exceed the cap is refused (an update to an existing memory key
//!   always succeeds). A transaction-scoped advisory lock per (tenant,
//!   owner, repository) keeps the cap exact under concurrent writes, which
//!   SQLite got from serialised writes;
//! - "created after" cursors are exclusive, and "" means every row;
//! - timestamps read back as epoch milliseconds, an unset one as "", and a
//!   never-reported progress percent as "".
@runtime_checked
package CloudAgents.PgStore.Interactive

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

func now(): String {
  return CloudAgents.Repository.nowMillis()
}

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

func ms(col: in String): String {
  return CloudAgents.Pg.msOut(col) + " AS " + col
}

/// Rows of `table` for a session created strictly after `after` ("" = all),
/// oldest first.
func createdAfter(
  sc: in CloudAgents.Pg.TenantScope,
  cols: in String,
  table: in String,
  sessionId: in String,
  after: in String,
): Result[slice[DbRow], CloudAgents.Db.DbError] {
  var sql = "SELECT " + cols + " FROM " + table + " WHERE session_id = @p0"
  var params: slice[String] = [sessionId]
  if after.length > 0 {
    sql = sql + " AND created_at > " + CloudAgents.Pg.msIn(1)
    params = [sessionId, after]
  }
  return query(sc, sql + " ORDER BY created_at, id COLLATE \"C\"", params)
}

/// SQL: a pending row by id (`@p0`) that has waited at least `@p2` ms by
/// `@p1` (epoch ms).
func pendingLongEnough(): String {
  return " WHERE id = @p0 AND status = 'pending' AND created_at <= " + CloudAgents.Pg.msIn(1) +
    " - @p2::bigint * interval '1 millisecond'"
}

// ─── Permission requests and rules ──────────────────────────────────────────
func permissionCols(): String {
  return "id, session_id, tool_name, input_json, status, updated_input_json, note, " + ms("created_at") + ", " +
    ms("decided_at")
}

func toPermission(r: in DbRow): CloudAgents.Repository.PermissionRequest {
  return CloudAgents.Repository.PermissionRequest(
    id = CloudAgents.PgStore.col(r, "id"),
    sessionId = CloudAgents.PgStore.col(r, "session_id"),
    toolName = CloudAgents.PgStore.col(r, "tool_name"),
    inputJson = CloudAgents.PgStore.col(r, "input_json"),
    status = CloudAgents.PgStore.col(r, "status"),
    updatedInputJson = CloudAgents.PgStore.col(r, "updated_input_json"),
    note = CloudAgents.PgStore.col(r, "note"),
    createdAt = CloudAgents.PgStore.col(r, "created_at"),
    decidedAt = CloudAgents.PgStore.col(r, "decided_at")
  )
}

/// Create a permission request; `preApproved` creates it already allowed
/// (an allow-always rule matched).
pub func createPermissionRequest(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  toolName: in String,
  inputJson: in String,
  preApproved: in Bool,
): Result[CloudAgents.Repository.PermissionRequest, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = now()
  val status = if preApproved { "allowed" } else { "pending" }
  val note = if preApproved { "allow-always rule matched" } else { "" }
  val decidedAt = if preApproved { ts } else { "" }
  var decided = "NULL"
  if preApproved {
    decided = CloudAgents.Pg.msIn(6)
  }
  exec(sc, "INSERT INTO permission_requests (id, session_id, tool_name, input_json, status, note, created_at, decided_at) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, " + CloudAgents.Pg.msIn(6) + ", " + decided + ")", [id, sessionId, toolName, inputJson, status, note, ts])?
  return Ok(
    value = CloudAgents.Repository.PermissionRequest(
      id = id,
      sessionId = sessionId,
      toolName = toolName,
      inputJson = inputJson,
      status = status,
      updatedInputJson = "",
      note = note,
      createdAt = ts,
      decidedAt = decidedAt
    )
  )
}

pub func getPermissionRequest(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.PermissionRequest], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + permissionCols() + " FROM permission_requests WHERE id = @p0", [id])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toPermission(rows[0])))
}

pub func permissionRequestsCreatedAfter(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  afterCreatedAt: in String,
): Result[slice[CloudAgents.Repository.PermissionRequest], CloudAgents.Db.DbError] {
  val rows = createdAfter(sc, permissionCols(), "permission_requests", sessionId, afterCreatedAt)?
  var acc: slice[CloudAgents.Repository.PermissionRequest] = []
  for r in rows {
    acc = acc.append(toPermission(r))
  }
  return Ok(value = acc)
}

/// Answer a still-pending request; rows affected (0 = no longer pending).
pub func answerPermissionRequest(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  status: in String,
  updatedInputJson: in String,
  note: in String,
): Result[Int, CloudAgents.Db.DbError] {
  return exec(
    sc,
    "UPDATE permission_requests SET status = @p1, updated_input_json = @p2, note = @p3, decided_at = " +
      CloudAgents.Pg.msIn(4) +
      " WHERE id = @p0 AND status = 'pending'",
    [id, status, updatedInputJson, note, now()]
  )
}

/// Deny a request still pending after `timeoutMillis` (write-once).
pub func timeoutPendingPermissionRequest(
  id: in String, sc: in CloudAgents.Pg.TenantScope, timeoutMillis: in Long
): Result[Unit, CloudAgents.Db.DbError] {
  exec(sc, "UPDATE permission_requests SET status = 'denied', note = 'timed out waiting for a human response', decided_at = " + CloudAgents.Pg.msIn(1) + pendingLongEnough(), [id, now(), toString(timeoutMillis)])?
  return Ok(value = ())
}

/// Whether an allow-always rule exists for exactly (session, tool, input).
pub func permissionRuleMatches(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  toolName: in String,
  inputJson: in String,
): Result[Bool, CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT 1 AS one FROM permission_rules WHERE session_id = @p0 AND tool_name = @p1 " + "AND input_digest = md5(@p2) AND input_json = @p2", [sessionId, toolName, inputJson])?
  return Ok(value = rows.length > 0)
}

/// Persist an allow-always rule (idempotent).
pub func addPermissionRule(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  toolName: in String,
  inputJson: in String,
): Result[Unit, CloudAgents.Db.DbError] {
  exec(sc, "INSERT INTO permission_rules (id, session_id, tool_name, input_json, created_at) VALUES (@p0, @p1, @p2, @p3, " + CloudAgents.Pg.msIn(4) + ") ON CONFLICT (tenant_id, session_id, tool_name, input_digest) DO NOTHING", [newId(), sessionId, toolName, inputJson, now()])?
  return Ok(value = ())
}

// ─── User questions ─────────────────────────────────────────────────────────
func questionCols(): String {
  return "id, session_id, question, options_json, status, answer, " + ms("created_at") + ", " + ms("decided_at")
}

func toQuestion(r: in DbRow): CloudAgents.Repository.UserQuestion {
  return CloudAgents.Repository.UserQuestion(
    id = CloudAgents.PgStore.col(r, "id"),
    sessionId = CloudAgents.PgStore.col(r, "session_id"),
    question = CloudAgents.PgStore.col(r, "question"),
    optionsJson = CloudAgents.PgStore.col(r, "options_json"),
    status = CloudAgents.PgStore.col(r, "status"),
    answer = CloudAgents.PgStore.col(r, "answer"),
    createdAt = CloudAgents.PgStore.col(r, "created_at"),
    decidedAt = CloudAgents.PgStore.col(r, "decided_at")
  )
}

pub func createUserQuestion(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  question: in String,
  optionsJson: in String,
): Result[CloudAgents.Repository.UserQuestion, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = now()
  exec(sc, "INSERT INTO user_questions (id, session_id, question, options_json, status, created_at) " + "VALUES (@p0, @p1, @p2, @p3, 'pending', " + CloudAgents.Pg.msIn(4) + ")", [id, sessionId, question, optionsJson, ts])?
  return Ok(
    value = CloudAgents.Repository.UserQuestion(
      id = id,
      sessionId = sessionId,
      question = question,
      optionsJson = optionsJson,
      status = "pending",
      answer = "",
      createdAt = ts,
      decidedAt = ""
    )
  )
}

pub func getUserQuestion(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.UserQuestion], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + questionCols() + " FROM user_questions WHERE id = @p0", [id])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toQuestion(rows[0])))
}

pub func userQuestionsCreatedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterCreatedAt: in String
): Result[slice[CloudAgents.Repository.UserQuestion], CloudAgents.Db.DbError] {
  val rows = createdAfter(sc, questionCols(), "user_questions", sessionId, afterCreatedAt)?
  var acc: slice[CloudAgents.Repository.UserQuestion] = []
  for r in rows {
    acc = acc.append(toQuestion(r))
  }
  return Ok(value = acc)
}

pub func answerUserQuestion(
  id: in String, sc: in CloudAgents.Pg.TenantScope, answer: in String
): Result[Int, CloudAgents.Db.DbError] {
  return exec(
    sc,
    "UPDATE user_questions SET status = 'answered', answer = @p1, decided_at = " + CloudAgents.Pg.msIn(2) +
      " WHERE id = @p0 AND status = 'pending'",
    [id, answer, now()]
  )
}

pub func timeoutPendingUserQuestion(
  id: in String, sc: in CloudAgents.Pg.TenantScope, timeoutMillis: in Long
): Result[Unit, CloudAgents.Db.DbError] {
  exec(sc, "UPDATE user_questions SET status = 'timed_out', decided_at = " + CloudAgents.Pg.msIn(1) + pendingLongEnough(), [id, now(), toString(timeoutMillis)])?
  return Ok(value = ())
}

// ─── Progress ───────────────────────────────────────────────────────────────
/// Set a session's latest reported progress ("" percent clears it).
pub func updateSessionProgress(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  summary: in String,
  percent: in String,
): Result[Unit, CloudAgents.Db.DbError] {
  exec(sc, "UPDATE sessions SET progress_summary = @p1, progress_percent = NULLIF(@p2, '')::smallint WHERE id = @p0", [sessionId, summary, percent])?
  return Ok(value = ())
}

/// A session's latest reported progress (both "" when never reported, or
/// when there is no such session).
pub func sessionProgress(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[CloudAgents.Repository.SessionProgress, CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT progress_summary, coalesce(progress_percent::text, '') AS progress_percent FROM sessions WHERE id = @p0", [sessionId])?
  if rows.length == 0 {
    return Ok(value = CloudAgents.Repository.SessionProgress(summary = "", percent = ""))
  }
  return Ok(
    value = CloudAgents.Repository.SessionProgress(
      summary = CloudAgents.PgStore.col(rows[0], "progress_summary"),
      percent = CloudAgents.PgStore.col(rows[0], "progress_percent")
    )
  )
}

// ─── Secret requests ────────────────────────────────────────────────────────
func secretCols(): String {
  return "id, session_id, name, reason, status, " + ms("created_at") + ", " + ms("decided_at")
}

func toSecret(r: in DbRow): CloudAgents.Repository.SecretRequest {
  return CloudAgents.Repository.SecretRequest(
    id = CloudAgents.PgStore.col(r, "id"),
    sessionId = CloudAgents.PgStore.col(r, "session_id"),
    name = CloudAgents.PgStore.col(r, "name"),
    reason = CloudAgents.PgStore.col(r, "reason"),
    status = CloudAgents.PgStore.col(r, "status"),
    createdAt = CloudAgents.PgStore.col(r, "created_at"),
    decidedAt = CloudAgents.PgStore.col(r, "decided_at")
  )
}

pub func createSecretRequest(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, name: in String, reason: in String
): Result[CloudAgents.Repository.SecretRequest, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = now()
  exec(sc, "INSERT INTO secret_requests (id, session_id, name, reason, status, created_at) VALUES (@p0, @p1, @p2, @p3, 'pending', " + CloudAgents.Pg.msIn(4) + ")", [id, sessionId, name, reason, ts])?
  return Ok(
    value = CloudAgents.Repository.SecretRequest(
      id = id,
      sessionId = sessionId,
      name = name,
      reason = reason,
      status = "pending",
      createdAt = ts,
      decidedAt = ""
    )
  )
}

pub func getSecretRequest(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.SecretRequest], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + secretCols() + " FROM secret_requests WHERE id = @p0", [id])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toSecret(rows[0])))
}

pub func secretRequestsCreatedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterCreatedAt: in String
): Result[slice[CloudAgents.Repository.SecretRequest], CloudAgents.Db.DbError] {
  val rows = createdAfter(sc, secretCols(), "secret_requests", sessionId, afterCreatedAt)?
  var acc: slice[CloudAgents.Repository.SecretRequest] = []
  for r in rows {
    acc = acc.append(toSecret(r))
  }
  return Ok(value = acc)
}

pub func answerSecretRequest(
  id: in String, sc: in CloudAgents.Pg.TenantScope, status: in String
): Result[Int, CloudAgents.Db.DbError] {
  return exec(
    sc,
    "UPDATE secret_requests SET status = @p1, decided_at = " + CloudAgents.Pg.msIn(2) +
      " WHERE id = @p0 AND status = 'pending'",
    [id, status, now()]
  )
}

pub func timeoutPendingSecretRequest(
  id: in String, sc: in CloudAgents.Pg.TenantScope, timeoutMillis: in Long
): Result[Unit, CloudAgents.Db.DbError] {
  exec(sc, "UPDATE secret_requests SET status = 'timed_out', decided_at = " + CloudAgents.Pg.msIn(1) + pendingLongEnough(), [id, now(), toString(timeoutMillis)])?
  return Ok(value = ())
}

/// Mark an approved secret delivered; true only for the first delivery.
pub func markSecretRequestDelivered(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Bool, CloudAgents.Db.DbError] {
  val n = exec(sc, "UPDATE secret_requests SET delivered_at = " + CloudAgents.Pg.msIn(1) + " WHERE id = @p0 AND status = 'approved' AND delivered_at IS NULL", [id, now()])?
  return Ok(value = n > 0)
}

// ─── Artifacts ──────────────────────────────────────────────────────────────
func artifactCols(): String {
  return "id, session_id, file_name, stored_name, mime_type, description, size_bytes::text AS size_bytes, " +
    ms("created_at") +
    ", repo_key, owner_user_id"
}

func toArtifact(r: in DbRow): CloudAgents.Repository.Artifact {
  return CloudAgents.Repository.Artifact(
    id = CloudAgents.PgStore.col(r, "id"),
    sessionId = CloudAgents.PgStore.col(r, "session_id"),
    fileName = CloudAgents.PgStore.col(r, "file_name"),
    storedName = CloudAgents.PgStore.col(r, "stored_name"),
    mimeType = CloudAgents.PgStore.col(r, "mime_type"),
    description = CloudAgents.PgStore.col(r, "description"),
    sizeBytes = CloudAgents.PgStore.col(r, "size_bytes"),
    createdAt = CloudAgents.PgStore.col(r, "created_at"),
    repoKey = CloudAgents.PgStore.col(r, "repo_key"),
    ownerUserId = CloudAgents.PgStore.col(r, "owner_user_id")
  )
}

func artifactList(rows: in slice[DbRow]): slice[CloudAgents.Repository.Artifact] {
  var acc: slice[CloudAgents.Repository.Artifact] = []
  for r in rows {
    acc = acc.append(toArtifact(r))
  }
  return acc
}

/// Record an artifact's metadata (the bytes are already on disk). A
/// repository-scoped artifact carries its repo key and owner; a
/// session-scoped one leaves both "".
pub func createArtifact(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  fileName: in String,
  storedName: in String,
  mimeType: in String,
  description: in String,
  sizeBytes: in String,
  repoKey: in String,
  ownerUserId: in String,
): Result[CloudAgents.Repository.Artifact, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = now()
  exec(sc, "INSERT INTO artifacts (id, session_id, file_name, stored_name, mime_type, description, size_bytes, created_at, repo_key, owner_user_id) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6::bigint, " + CloudAgents.Pg.msIn(7) + ", @p8, @p9)", [id, sessionId, fileName, storedName, mimeType, description, sizeBytes, ts, repoKey, ownerUserId])?
  return Ok(
    value = CloudAgents.Repository.Artifact(
      id = id,
      sessionId = sessionId,
      fileName = fileName,
      storedName = storedName,
      mimeType = mimeType,
      description = description,
      sizeBytes = sizeBytes,
      createdAt = ts,
      repoKey = repoKey,
      ownerUserId = ownerUserId
    )
  )
}

pub func getArtifact(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.Artifact], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + artifactCols() + " FROM artifacts WHERE id = @p0", [id])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toArtifact(rows[0])))
}

/// A session's artifacts, oldest first.
pub func listArtifacts(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Artifact], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + artifactCols() + " FROM artifacts WHERE session_id = @p0 ORDER BY created_at, id COLLATE \"C\"", [sessionId])?
  return Ok(value = artifactList(rows))
}

/// The caller's repository-scoped artifacts for `repoKey`, oldest first.
pub func listRepoArtifacts(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String
): Result[slice[CloudAgents.Repository.Artifact], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + artifactCols() + " FROM artifacts WHERE owner_user_id = @p0 AND repo_key = @p1 " + "ORDER BY created_at, id COLLATE \"C\"", [sc.userId, repoKey])?
  return Ok(value = artifactList(rows))
}

/// One of the caller's repository-scoped artifacts by id, or None.
pub func getRepoArtifactById(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.Artifact], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + artifactCols() + " FROM artifacts WHERE id = @p0 AND owner_user_id = @p1", [id, sc.userId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toArtifact(rows[0])))
}

pub func artifactsCreatedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterCreatedAt: in String
): Result[slice[CloudAgents.Repository.Artifact], CloudAgents.Db.DbError] {
  val rows = createdAfter(sc, artifactCols(), "artifacts", sessionId, afterCreatedAt)?
  return Ok(value = artifactList(rows))
}

// ─── Session owner and repository ───────────────────────────────────────────
/// A session's owner and repository URL, or None.
pub func sessionOwnerAndRepo(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.SessionOwnerRepo], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT user_id, repo_url FROM sessions WHERE id = @p0", [id])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(
    value = Some(
      value = CloudAgents.Repository.SessionOwnerRepo(
        userId = CloudAgents.PgStore.col(rows[0], "user_id"),
        repoUrl = CloudAgents.PgStore.col(rows[0], "repo_url")
      )
    )
  )
}

// ─── Repository memory ──────────────────────────────────────────────────────
/// SQL: serialise capped writes for one (tenant, owner, repository), `@p0` =
/// owner, `@p1` = repo key.
func capLock(): String {
  return "SELECT pg_advisory_xact_lock(hashtextextended(current_setting('app.current_tenant') || ':' || @p0 || ':' || @p1, 0))"
}

func toMemory(r: in DbRow): CloudAgents.Repository.MemoryRecord {
  return CloudAgents.Repository.MemoryRecord(
    memKey = CloudAgents.PgStore.col(r, "mem_key"),
    value = CloudAgents.PgStore.col(r, "value"),
    updatedAt = CloudAgents.PgStore.col(r, "updated_at")
  )
}

/// Insert or update a memory entry for (owner, repo). A new key is refused
/// (false) once the scope holds `maxEntries`; an existing key is always
/// updated.
pub func upsertMemoryCapped(
  sc: in CloudAgents.Pg.TenantScope,
  repoKey: in String,
  memKey: in String,
  value: in String,
  maxEntries: in Int,
): Result[Bool, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.q(u, capLock(), [sc.userId, repoKey])?
  val inScope = "user_id = @p0 AND repo_key = @p1"
  val n = CloudAgents.PgStore.ex(u, "INSERT INTO memories (id, user_id, repo_key, mem_key, value, created_at, updated_at) " + "SELECT @p4, @p0, @p1, @p2, @p3, " + CloudAgents.Pg.msIn(5) + ", " + CloudAgents.Pg.msIn(5) + " WHERE (SELECT count(*) FROM memories WHERE " + inScope + ") < @p6::int " + "OR EXISTS (SELECT 1 FROM memories WHERE " + inScope + " AND mem_key = @p2) " + "ON CONFLICT (tenant_id, user_id, repo_key, mem_key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at", [sc.userId, repoKey, memKey, value, newId(), now(), toString(maxEntries)])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n > 0)
}

/// The owner's memory for a repository, by key in byte order.
pub func listMemory(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String
): Result[slice[CloudAgents.Repository.MemoryRecord], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT mem_key, value, " + ms("updated_at") + " FROM memories WHERE user_id = @p0 AND repo_key = @p1 " + "ORDER BY mem_key COLLATE \"C\"", [sc.userId, repoKey])?
  var acc: slice[CloudAgents.Repository.MemoryRecord] = []
  for r in rows {
    acc = acc.append(toMemory(r))
  }
  return Ok(value = acc)
}

pub func getMemory(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String, memKey: in String
): Result[Option[CloudAgents.Repository.MemoryRecord], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT mem_key, value, " + ms("updated_at") + " FROM memories WHERE user_id = @p0 AND repo_key = @p1 AND mem_key = @p2", [sc.userId, repoKey, memKey])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toMemory(rows[0])))
}

/// Delete a memory entry; true when one was deleted.
pub func deleteMemory(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String, memKey: in String
): Result[Bool, CloudAgents.Db.DbError] {
  val n = exec(sc, "DELETE FROM memories WHERE user_id = @p0 AND repo_key = @p1 AND mem_key = @p2", [sc.userId, repoKey, memKey])?
  return Ok(value = n > 0)
}

// ─── Repository task list ───────────────────────────────────────────────────
/// Add an open task for (owner, repo), refused once `maxOpenTasks` are open.
pub func addTaskCapped(
  sc: in CloudAgents.Pg.TenantScope,
  repoKey: in String,
  description: in String,
  maxOpenTasks: in Int,
): Result[CloudAgents.Repository.AddTaskResult, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.q(u, capLock(), [sc.userId, repoKey])?
  val id = newId()
  val n = CloudAgents.PgStore.ex(u, "INSERT INTO repo_tasks (id, user_id, repo_key, description, status, created_at, updated_at) " + "SELECT @p2, @p0, @p1, @p3, 'open', " + CloudAgents.Pg.msIn(4) + ", " + CloudAgents.Pg.msIn(4) + " WHERE (SELECT count(*) FROM repo_tasks WHERE user_id = @p0 AND repo_key = @p1 AND status = 'open') < @p5::int", [sc.userId, repoKey, id, description, now(), toString(maxOpenTasks)])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = CloudAgents.Repository.AddTaskResult(created = n > 0, id = id))
}

/// The owner's tasks for a repository, newest first, optionally filtered by
/// status.
pub func listTasks(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String, statusFilter: in Option[String]
): Result[slice[CloudAgents.Repository.RepoTask], CloudAgents.Db.DbError] {
  val filter = match statusFilter { case Some(s) -> s; case None -> "" }
  var sql = "SELECT id, description, status, " + ms("created_at") + ", " + ms("updated_at") +
    " FROM repo_tasks WHERE user_id = @p0 AND repo_key = @p1"
  var params: slice[String] = [sc.userId, repoKey]
  if filter.length > 0 {
    sql = sql + " AND status = @p2"
    params = [sc.userId, repoKey, filter]
  }
  val rows = query(sc, sql + " ORDER BY created_at DESC, id COLLATE \"C\"", params)?
  var acc: slice[CloudAgents.Repository.RepoTask] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.Repository.RepoTask(
        id = CloudAgents.PgStore.col(r, "id"),
        description = CloudAgents.PgStore.col(r, "description"),
        status = CloudAgents.PgStore.col(r, "status"),
        createdAt = CloudAgents.PgStore.col(r, "created_at"),
        updatedAt = CloudAgents.PgStore.col(r, "updated_at")
      )
    )
  }
  return Ok(value = acc)
}

/// Complete one of the owner's tasks for a repository.
pub func completeTask(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String, taskId: in String
): Result[CloudAgents.Repository.CompleteTaskOutcome, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT status FROM repo_tasks WHERE id = @p0 AND user_id = @p1 AND repo_key = @p2 FOR UPDATE", [taskId, sc.userId, repoKey])?
  if rows.length == 0 {
    CloudAgents.PgStore.commit(u)?
    return Ok(value = TaskNotFound)
  }
  if CloudAgents.PgStore.col(rows[0], "status") == "done" {
    CloudAgents.PgStore.commit(u)?
    return Ok(value = TaskAlreadyDone)
  }
  CloudAgents.PgStore.ex(u, "UPDATE repo_tasks SET status = 'done', updated_at = " + CloudAgents.Pg.msIn(3) + " WHERE id = @p0 AND user_id = @p1 AND repo_key = @p2 AND status = 'open'", [taskId, sc.userId, repoKey, now()])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = TaskCompleted)
}

// ─── Notifications ──────────────────────────────────────────────────────────
func notificationCols(): String {
  return "id, session_id, level, summary, " + ms("created_at") + ", " + ms("read_at")
}

func notificationList(rows: in slice[DbRow]): slice[CloudAgents.Repository.Notification] {
  var acc: slice[CloudAgents.Repository.Notification] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.Repository.Notification(
        id = CloudAgents.PgStore.col(r, "id"),
        sessionId = CloudAgents.PgStore.col(r, "session_id"),
        level = CloudAgents.PgStore.col(r, "level"),
        summary = CloudAgents.PgStore.col(r, "summary"),
        createdAt = CloudAgents.PgStore.col(r, "created_at"),
        readAt = CloudAgents.PgStore.col(r, "read_at")
      )
    )
  }
  return acc
}

pub func createNotification(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  level: in String,
  summary: in String,
): Result[CloudAgents.Repository.Notification, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = now()
  exec(sc, "INSERT INTO notifications (id, session_id, level, summary, created_at) VALUES (@p0, @p1, @p2, @p3, " + CloudAgents.Pg.msIn(4) + ")", [id, sessionId, level, summary, ts])?
  return Ok(
    value = CloudAgents.Repository.Notification(
      id = id,
      sessionId = sessionId,
      level = level,
      summary = summary,
      createdAt = ts,
      readAt = ""
    )
  )
}

/// A session's notifications, newest first.
pub func listNotifications(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Notification], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + notificationCols() + " FROM notifications WHERE session_id = @p0 ORDER BY created_at DESC, id COLLATE \"C\"", [sessionId])?
  return Ok(value = notificationList(rows))
}

pub func notificationsCreatedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterCreatedAt: in String
): Result[slice[CloudAgents.Repository.Notification], CloudAgents.Db.DbError] {
  val rows = createdAfter(sc, notificationCols(), "notifications", sessionId, afterCreatedAt)?
  return Ok(value = notificationList(rows))
}
