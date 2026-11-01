//! CloudAgents.PgStore.Imports — storage for importing findings about Claude
//! Code cloud sessions cloud-agents did not run
//! (docs/claude-session-import.md §5, §7.1).
//!
//! `import_tokens` is a global table, like `invitations`: a token is resolved
//! before any tenant is set, so those units are unscoped and every query here
//! checks the caller's active membership itself. Only a token's hash is
//! stored. `claude_session_imports` (the per-session cursor and tombstone)
//! and the imported `sessions` row are tenant-owned and go through the
//! caller's tenant scope.
@runtime_checked
package CloudAgents.PgStore.Imports

import Std.Core
import Std.Uuid
import Db
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Db
import CloudAgents.Crypto
import CloudAgents.Ledger.Model
import CloudAgents.PgStore.Ledger

/// Import tokens are shown once, prefixed so they are recognisable (and
/// redactable, `CloudAgents.Ledger.Redact`) wherever they turn up.
pub val importTokenPrefix = "cai_"

pub val maxLabelLen = 100

/// An import token as listed. Times are epoch-millisecond text ("" for none).
pub record ImportTokenInfo {
  pub id: String
  pub label: String
  pub createdAt: String
  pub lastUsedAt: String
  pub revoked: Bool
}

/// A newly created token. The raw token exists only here.
pub record CreatedImportToken {
  pub info: ImportTokenInfo
  pub token: String
}

/// Who an import token acts for.
pub record ImportPrincipal {
  pub tokenId: String
  pub tenantId: String
  pub userId: String
}

/// One imported session's cursor (§6.1). `throughOrdinal` is -1 before the
/// first chunk; `restartUntilOrdinal` is the old cursor while a re-import
/// (§4.3) is catching up, else -1. `lastRestartAt` is epoch-millisecond text.
pub record ImportCursor {
  pub ccrSessionId: String
  pub sessionId: String
  pub throughEventId: String
  pub throughOrdinal: Long
  pub lastEventAt: String
  pub lastCounts: String
  pub restartUntilOrdinal: Long
  pub lastRestartAt: String
  pub deleted: Bool
}

/// What the importer says about a session (§6.3 `session`).
pub record ImportedSessionInfo {
  pub title: String
  pub repoUrl: String
  pub branch: String
  pub createdAt: String
  pub updatedAt: String
}

/// An existing finding, listed so a re-import does not report it again.
pub record KnownFinding {
  pub kind: String
  pub summary: String
}

pub func hashImportToken(token: in String): String {
  return CloudAgents.Crypto.sha256Base64("import:" + token)
}

func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func col(r: in DbRow, name: in String): String {
  return CloudAgents.PgStore.col(r, name)
}

func longOf(s: in String): Long {
  return match tryParseLong(s) {
    case Ok(v) -> v
    case Err(_) -> -1.toLong()
  }
}

func tokenCols(): String {
  return "id, label, " + CloudAgents.Pg.msOut("created_at") + " AS created_at, " +
    "COALESCE(" + CloudAgents.Pg.msOut("last_used_at") + ", '') AS last_used_at, " +
    "CASE WHEN revoked_at IS NULL THEN '0' ELSE '1' END AS revoked"
}

func toTokenInfo(r: in DbRow): ImportTokenInfo {
  return ImportTokenInfo(
    id = col(r, "id"),
    label = col(r, "label"),
    createdAt = col(r, "created_at"),
    lastUsedAt = col(r, "last_used_at"),
    revoked = col(r, "revoked") == "1"
  )
}

func activeMemberSql(): String {
  return "EXISTS (SELECT 1 FROM memberships m WHERE m.tenant_id = @p0 AND m.user_id = @p1 AND NOT m.suspended)"
}

// ─── Tokens ─────────────────────────────────────────────────────────────────
/// Create a token acting for `userId` in `tenantId`; None when the user is
/// not an active member there.
pub func createImportToken(
  userId: in String, tenantId: in String, label: in String
): Result[Option[CreatedImportToken], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val member = CloudAgents.PgStore.q(u, "SELECT 1 AS ok WHERE " + activeMemberSql(), [tenantId, userId])?
  if member.length.toInt() == 0 {
    return Ok(value = None)
  }
  val raw = importTokenPrefix + newId().replace("-", "") + newId().replace("-", "")
  val id = newId()
  CloudAgents.PgStore.ex(u, "INSERT INTO import_tokens (id, tenant_id, user_id, token_hash, label) VALUES (@p0, @p1, @p2, @p3, @p4)", [id, tenantId, userId, hashImportToken(raw), label])?
  val rows = CloudAgents.PgStore.q(u, "SELECT " + tokenCols() + " FROM import_tokens WHERE id = @p0", [id])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = Some(value = CreatedImportToken(info = toTokenInfo(rows[0]), token = raw)))
}

/// The caller's tokens in `tenantId`, newest first.
pub func listImportTokens(userId: in String, tenantId: in String): Result[slice[ImportTokenInfo], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + tokenCols() + " FROM import_tokens WHERE tenant_id = @p0 AND user_id = @p1 " + "ORDER BY created_at DESC, id", [tenantId, userId])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[ImportTokenInfo] = []
  for r in rows {
    acc = acc.append(toTokenInfo(r))
  }
  return Ok(value = acc)
}

/// Revoke one of the caller's tokens; false when there is no such token.
pub func revokeImportToken(userId: in String, tenantId: in String, id: in String): Result[Bool, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "UPDATE import_tokens SET revoked_at = COALESCE(revoked_at, now()) " + "WHERE tenant_id = @p0 AND user_id = @p1 AND id = @p2", [tenantId, userId, id])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n > 0)
}

/// The principal a raw token acts for: None when it is unknown, revoked, or
/// its user is no longer an active member of its tenant. Records the use.
pub func resolveImportToken(raw: in String): Result[Option[ImportPrincipal], CloudAgents.Db.DbError] {
  if not raw.startsWith(importTokenPrefix) {
    return Ok(value = None)
  }
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "UPDATE import_tokens t SET last_used_at = now() WHERE t.token_hash = @p0 AND t.revoked_at IS NULL " + "AND EXISTS (SELECT 1 FROM memberships m WHERE m.tenant_id = t.tenant_id AND m.user_id = t.user_id AND NOT m.suspended) " + "RETURNING t.id, t.tenant_id, t.user_id", [hashImportToken(raw)])?
  CloudAgents.PgStore.commit(u)?
  if rows.length.toInt() == 0 {
    return Ok(value = None)
  }
  val r = rows[0]
  return Ok(value = Some(value = ImportPrincipal(tokenId = col(r, "id"), tenantId = col(r, "tenant_id"), userId = col(r, "user_id"))))
}

/// Count one findings POST against the token's hourly cap; false (and
/// nothing counted) once the cap is reached in the current window.
pub func takeChunkSlot(tokenId: in String, maxPerHour: in Int): Result[Bool, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val expired = "(window_start IS NULL OR window_start < now() - interval '1 hour')"
  val n = CloudAgents.PgStore.ex(u, "UPDATE import_tokens SET " + "window_count = CASE WHEN " + expired + " THEN 1 ELSE window_count + 1 END, " + "window_start = CASE WHEN " + expired + " THEN now() ELSE window_start END " + "WHERE id = @p0 AND (" + expired + " OR window_count < @p1::integer)", [tokenId, toString(maxPerHour)])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n > 0)
}

// ─── Cursors ────────────────────────────────────────────────────────────────
func cursorCols(): String {
  return "ccr_session_id, session_id, through_event_id, through_ordinal::text AS through_ordinal, last_event_at, last_counts, " +
    "restart_until_ordinal::text AS restart_until_ordinal, " +
    "COALESCE(" + CloudAgents.Pg.msOut("last_restart_at") + ", '') AS last_restart_at, " +
    "CASE WHEN deleted_at IS NULL THEN '0' ELSE '1' END AS deleted"
}

func toCursor(r: in DbRow): ImportCursor {
  return ImportCursor(
    ccrSessionId = col(r, "ccr_session_id"),
    sessionId = col(r, "session_id"),
    throughEventId = col(r, "through_event_id"),
    throughOrdinal = longOf(col(r, "through_ordinal")),
    lastEventAt = col(r, "last_event_at"),
    lastCounts = col(r, "last_counts"),
    restartUntilOrdinal = longOf(col(r, "restart_until_ordinal")),
    lastRestartAt = col(r, "last_restart_at"),
    deleted = col(r, "deleted") == "1"
  )
}

/// Every imported session in the tenant, tombstones included.
pub func listImportCursors(sc: in CloudAgents.Pg.TenantScope): Result[slice[ImportCursor], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + cursorCols() + " FROM claude_session_imports ORDER BY imported_at, ccr_session_id", [])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[ImportCursor] = []
  for r in rows {
    acc = acc.append(toCursor(r))
  }
  return Ok(value = acc)
}

pub func getImportCursor(sc: in CloudAgents.Pg.TenantScope, ccrSessionId: in String): Result[Option[ImportCursor], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + cursorCols() + " FROM claude_session_imports WHERE ccr_session_id = @p0", [ccrSessionId])?
  CloudAgents.PgStore.commit(u)?
  if rows.length.toInt() == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toCursor(rows[0])))
}

/// The imported session for `ccrSessionId`, created on first sight with its
/// cursor (§7.1): a read-only `sessions` row with no container, owned by the
/// caller. Later calls refresh its title and last activity. Returns the
/// cloud-agents session id, or "" when the session's import was deleted
/// (a tombstone), which is never recreated.
pub func ensureImportedSession(
  sc: in CloudAgents.Pg.TenantScope, ccrSessionId: in String, info: in ImportedSessionInfo
): Result[String, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  // Claim the cursor row first, then lock it: two first chunks for the same
  // session serialise here instead of each creating a session row.
  CloudAgents.PgStore.ex(u, "INSERT INTO claude_session_imports (ccr_session_id) VALUES (@p0) ON CONFLICT (tenant_id, ccr_session_id) DO NOTHING", [ccrSessionId])?
  val existing = CloudAgents.PgStore.q(u, "SELECT session_id, CASE WHEN deleted_at IS NULL THEN '0' ELSE '1' END AS deleted " + "FROM claude_session_imports WHERE ccr_session_id = @p0 FOR UPDATE", [ccrSessionId])?
  if existing.length.toInt() > 0 and col(existing[0], "deleted") == "1" {
    // A tombstone: never recreate the session ("" tells the caller).
    CloudAgents.PgStore.commit(u)?
    return Ok(value = "")
  }
  if existing.length.toInt() > 0 and col(existing[0], "session_id").length.toInt() > 0 {
    val sid = col(existing[0], "session_id")
    CloudAgents.PgStore.ex(u, "UPDATE sessions SET progress_summary = @p1, last_message_at = GREATEST(last_message_at, " + "COALESCE(NULLIF(@p2, '')::timestamptz, last_message_at)) WHERE id = @p0 AND imported_from <> ''", [sid, info.title, info.updatedAt])?
    CloudAgents.PgStore.commit(u)?
    return Ok(value = sid)
  }
  val sid = newId()
  CloudAgents.PgStore.ex(u, "INSERT INTO sessions (id, user_id, repo_url, branch, harness, native_session_id, status, created_at, last_message_at, " + "progress_summary, imported_from) VALUES (@p0, @p1, @p2, @p3, 'claude', @p4, 'DESTROYED', " + "COALESCE(NULLIF(@p5, '')::timestamptz, now()), COALESCE(NULLIF(@p6, '')::timestamptz, NULLIF(@p5, '')::timestamptz, now()), " + "@p7, 'claude-cloud')", [sid, sc.userId, info.repoUrl, info.branch, ccrSessionId, info.createdAt, info.updatedAt, info.title])?
  CloudAgents.PgStore.ex(u, "INSERT INTO session_routes (session_id, tenant_id, user_id) VALUES (@p0, @p1, @p2)", [sid, sc.tenantId, sc.userId])?
  CloudAgents.PgStore.ex(u, "UPDATE claude_session_imports SET session_id = @p1, updated_at = now() WHERE ccr_session_id = @p0", [ccrSessionId, sid])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = sid)
}

/// Where a chunk moves a session's cursor. `restartUntilOrdinal` is the old
/// cursor when the chunk starts a re-import, -1 to end one, or -2 to keep
/// whatever is stored; `startedRestart` stamps the cooldown.
pub record CursorAdvance {
  pub throughEventId: String
  pub throughOrdinal: Long
  pub lastEventAt: String
  pub countsJson: String
  pub restartUntilOrdinal: Long
  pub startedRestart: Bool
}

func advanceIn(u: in CloudAgents.PgStore.PgUnit, ccrSessionId: in String, a: in CursorAdvance): Result[Unit, CloudAgents.Db.DbError] {
  val restart = if a.restartUntilOrdinal < -1.toLong() then "restart_until_ordinal" else "@p5::bigint"
  val stamp = if a.startedRestart then "now()" else "last_restart_at"
  CloudAgents.PgStore.ex(u, "UPDATE claude_session_imports SET through_event_id = @p1, through_ordinal = @p2::bigint, " + "last_event_at = CASE WHEN @p3 = '' THEN last_event_at ELSE @p3 END, last_counts = @p4, " + "restart_until_ordinal = " + restart + ", last_restart_at = " + stamp + ", updated_at = now() " + "WHERE ccr_session_id = @p0", [ccrSessionId, a.throughEventId, toString(a.throughOrdinal), a.lastEventAt, a.countsJson, toString(a.restartUntilOrdinal)])?
  return Ok(value = ())
}

/// Move a session's cursor unconditionally (tests and repairs; the import
/// endpoint uses `commitImportChunk`).
pub func advanceImportCursor(sc: in CloudAgents.Pg.TenantScope, ccrSessionId: in String, a: in CursorAdvance): Result[Unit, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  advanceIn(u, ccrSessionId, a)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

/// Store a chunk's findings and move its cursor in one transaction, but only
/// if the cursor is still where the caller read it (`expectedOrdinal`,
/// `expectedEventId`): the cursor row is locked first, so two concurrent
/// POSTs for one session cannot both pass the ordinal check
/// (docs/claude-session-import.md §7.2). False, with nothing written, when
/// the cursor moved in between or the session was deleted.
pub func commitImportChunk(
  sc: in CloudAgents.Pg.TenantScope,
  ccrSessionId: in String,
  expectedOrdinal: in Long,
  expectedEventId: in String,
  entries: in slice[CloudAgents.Ledger.Model.LedgerEntry],
  a: in CursorAdvance,
): Result[Bool, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT through_ordinal::text AS through_ordinal, through_event_id, " + "CASE WHEN deleted_at IS NULL THEN '0' ELSE '1' END AS deleted FROM claude_session_imports " + "WHERE ccr_session_id = @p0 FOR UPDATE", [ccrSessionId])?
  if rows.length.toInt() == 0 {
    return Ok(value = false)
  }
  val r = rows[0]
  if col(r, "deleted") == "1" or longOf(col(r, "through_ordinal")) != expectedOrdinal or col(r, "through_event_id") != expectedEventId {
    return Ok(value = false)
  }
  for e in entries {
    CloudAgents.PgStore.Ledger.insertEntryIn(u, e)?
  }
  advanceIn(u, ccrSessionId, a)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = true)
}

/// Clear a tombstone so a deleted imported session may be imported again.
pub func clearImportTombstone(sc: in CloudAgents.Pg.TenantScope, ccrSessionId: in String): Result[Bool, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "DELETE FROM claude_session_imports WHERE ccr_session_id = @p0 AND deleted_at IS NOT NULL", [ccrSessionId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n > 0)
}

/// Up to `limit` of a session's observed findings, oldest first.
pub func knownFindings(
  sc: in CloudAgents.Pg.TenantScope, sessionId: in String, limit: in Int
): Result[slice[KnownFinding], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT kind, summary FROM ledger_entries WHERE session_id = @p0 AND source = 'observed' " + "ORDER BY created_seq LIMIT @p1::integer", [sessionId, toString(limit)])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[KnownFinding] = []
  for r in rows {
    acc = acc.append(KnownFinding(kind = col(r, "kind"), summary = col(r, "summary")))
  }
  return Ok(value = acc)
}

/// Whether `sessionId` is an imported (read-only) session of the caller's.
pub func isImportedSession(sc: in CloudAgents.Pg.TenantScope, sessionId: in String): Result[Bool, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT 1 AS ok FROM sessions WHERE id = @p0 AND imported_from <> ''", [sessionId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = rows.length.toInt() > 0)
}
