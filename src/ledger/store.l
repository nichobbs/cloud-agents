//! CloudAgents.Ledger.Store — SQLite persistence for the session ledger
//! (docs/session-ledger.md §4).
//!
//! Storage and atomicity only: every business rule (validation, transition
//! legality, severity, summaries) lives in the pure CloudAgents.Ledger.*
//! core, and callers pass in already-decided values.
//!
//! Change cursor: `ledger_sessions.seq` is a per-session counter bumped once
//! by every write transaction; every row a transaction touches is stamped
//! with the new value (`updated_seq`). A viewer polling with `after=<seq>`
//! gets exactly the rows changed since. Rows are never deleted.
//!
//! Concurrency: an item transition is optimistic — the UPDATE is guarded on
//! the `updated_seq` the caller planned against, and every dependent write
//! (transition row, automatic blocker entry, blocker resolution) is
//! conditioned on that UPDATE having applied, all in one transaction. The
//! caller re-reads and re-plans on a conflict. Feedback delivery claims rows
//! with a fresh batch id before reading them, so feedback created while an
//! agent is collecting is never marked delivered unseen.
package CloudAgents.Ledger.Store

import Std.Core
import Std.Uuid
import CloudAgents.Db
import CloudAgents.Sqlite
import CloudAgents.Repository
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Schema

func lit(s: in String): String {
  return CloudAgents.Db.sqlLiteral(s)
}

func newLedgerId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func col(r: in CloudAgents.Sqlite.Row, i: in Int): String {
  val len = CloudAgents.Sqlite.getStringArrayLength(r.cols)
  if i < len {
    return CloudAgents.Sqlite.getStringArrayValue(r.cols, i)
  }
  return ""
}

// ── Cursor ────────────────────────────────────────────────────────────────────
func ensureSessionSql(sessionId: in String, now: in String): String {
  return "INSERT OR IGNORE INTO ledger_sessions (session_id, seq, policy_status, policy_json, policy_error, created_at) VALUES (" +
    lit(sessionId) +
    ", '0', '', '', '', " +
    lit(now) +
    ")"
}

func bumpSeqSql(sessionId: in String): String {
  return "UPDATE ledger_sessions SET seq = CAST(CAST(seq AS INTEGER) + 1 AS TEXT) WHERE session_id = " + lit(sessionId)
}

// The session's current cursor, as a SQL scalar subquery usable inside the
// same transaction that bumped it.
func curSeqExpr(sessionId: in String): String {
  return "(SELECT seq FROM ledger_sessions WHERE session_id = " + lit(sessionId) + ")"
}

/// The session's current change cursor ("0" before the first write).
pub func currentSeq(sessionId: in String): Result[String, CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT seq FROM ledger_sessions WHERE session_id = " + lit(sessionId))?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Ok(value = "0")
  }
  return Ok(value = col(CloudAgents.Sqlite.getRowArrayValue(rows, 0), 0))
}

// ── Items ─────────────────────────────────────────────────────────────────────
/// Row caps on the list/delta queries. `snapshot` falls back to a full
/// snapshot when a delta reaches one, so a capped delta never silently
/// skips rows past the client's advancing cursor.
pub val itemRowCap: Int = 1000

pub val entryRowCap: Int = 5000

pub val feedbackRowCap: Int = 2000

val itemCols = "session_id, item_id, title, url, state, blocked_by, blocked_reason, prerequisite_proposal, recommendation, pr_url, ord, created_at, updated_at, updated_seq"

func rowToItem(r: in CloudAgents.Sqlite.Row): WorkItem {
  return WorkItem(
    id = col(r, 1),
    sessionId = col(r, 0),
    title = col(r, 2),
    url = col(r, 3),
    state = col(r, 4),
    blockedBy = decodeStringList(col(r, 5)),
    blockedReason = col(r, 6),
    prerequisiteProposal = col(r, 7),
    recommendation = col(r, 8),
    prUrl = col(r, 9),
    order = col(r, 10),
    createdAt = col(r, 11),
    updatedAt = col(r, 12),
    updatedSeq = col(r, 13)
  )
}

func itemsFromRows(rows: in CloudAgents.Sqlite.RowArray): slice[WorkItem] {
  var acc: slice[WorkItem] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(rowToItem(CloudAgents.Sqlite.getRowArrayValue(rows, i)))
    i = i + 1
  }
  return acc
}

/// A session's work items in batch order.
pub func listItems(sessionId: in String): Result[slice[WorkItem], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + itemCols + " FROM ledger_items WHERE session_id = " + lit(sessionId) + " ORDER BY CAST(ord AS INTEGER), item_id LIMIT " + toString(itemRowCap))?
  return Ok(value = itemsFromRows(rows))
}

/// Items changed strictly after cursor `after`.
pub func itemsChangedAfter(sessionId: in String, after: in String): Result[slice[WorkItem], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + itemCols + " FROM ledger_items WHERE session_id = " + lit(sessionId) + " AND CAST(updated_seq AS INTEGER) > CAST(" + lit(after) + " AS INTEGER) ORDER BY CAST(ord AS INTEGER), item_id LIMIT " + toString(itemRowCap))?
  return Ok(value = itemsFromRows(rows))
}

pub func getItem(sessionId: in String, itemId: in String): Result[Option[WorkItem], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + itemCols + " FROM ledger_items WHERE session_id = " + lit(sessionId) + " AND item_id = " + lit(itemId))?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = rowToItem(CloudAgents.Sqlite.getRowArrayValue(rows, 0))))
}

/// Register (or refresh) items: a new id is inserted `queued` at the end of
/// the batch; an existing id only has a non-empty title / url updated (its
/// state is untouched). Parallel slices; returns how many were new.
pub func registerItems(
  sessionId: in String, ids: in slice[String], titles: in slice[String], urls: in slice[String]
): Result[Int, CloudAgents.Sqlite.DbError] {
  val existing = listItems(sessionId)?
  val now = CloudAgents.Repository.nowMillis()
  var stmts: slice[String] = [ensureSessionSql(sessionId, now), bumpSeqSql(sessionId)]
  var added = 0
  var i = 0
  while i < ids.length.toInt() {
    val id = ids[i]
    if hasItem(existing, id) {
      var sets = ""
      if titles[i].length.toInt() > 0 {
        sets = sets + "title = " + lit(titles[i]) + ", "
      }
      if urls[i].length.toInt() > 0 {
        sets = sets + "url = " + lit(urls[i]) + ", "
      }
      if sets.length.toInt() > 0 {
        stmts = stmts.append(
          "UPDATE ledger_items SET " + sets + "updated_at = " + lit(now) + ", updated_seq = " + curSeqExpr(sessionId) +
            " WHERE session_id = " +
            lit(sessionId) +
            " AND item_id = " +
            lit(id)
        )
      }
    } else {
      stmts = stmts.append(
        "INSERT OR IGNORE INTO ledger_items (" + itemCols + ") VALUES (" + lit(sessionId) + ", " + lit(id) + ", " +
          lit(titles[i]) +
          ", " +
          lit(urls[i]) +
          ", 'queued', '[]', '', '', '', '', CAST((SELECT COUNT(*) FROM ledger_items WHERE session_id = " +
          lit(sessionId) +
          ") AS TEXT), " +
          lit(now) +
          ", " +
          lit(now) +
          ", " +
          curSeqExpr(sessionId) +
          ")"
      )
      added = added + 1
    }
    i = i + 1
  }
  CloudAgents.Sqlite.executeTransaction(stmts)?
  return Ok(value = added)
}

func hasItem(items: in slice[WorkItem], id: in String): Bool {
  var i = 0
  while i < items.length.toInt() {
    if items[i].id == id {
      return true
    }
    i = i + 1
  }
  return false
}

/// An automatic entry to write alongside a transition ("" summary = none).
pub record AutoEntry {
  pub kind: String
  pub severity: String
  pub source: String
  pub summary: String
  pub detail: String
}

/// Apply a planned item update. `readVersion` is the item's `updatedSeq`
/// the plan was computed against. Returns true when applied, false on a
/// concurrent change (nothing written — re-read and re-plan).
pub func applyItemUpdate(
  sessionId: in String,
  updated: in WorkItem,
  readVersion: in String,
  fromState: in String,
  stateChanged: in Bool,
  actor: in String,
  reason: in String,
  auto: in AutoEntry,
  resolveBlockers: in Bool,
): Result[Bool, CloudAgents.Sqlite.DbError] {
  val now = CloudAgents.Repository.nowMillis()
  val cur = curSeqExpr(sessionId)
  val itemKey = " WHERE session_id = " + lit(sessionId) + " AND item_id = " + lit(updated.id)
  val applied = " EXISTS (SELECT 1 FROM ledger_items" + itemKey + " AND updated_seq = " + cur + ")"
  var stmts: slice[String] = [
    ensureSessionSql(sessionId, now),
    bumpSeqSql(sessionId),
    "UPDATE ledger_items SET state = " + lit(updated.state) + ", blocked_by = " +
      lit(encodeStringList(updated.blockedBy)) +
      ", blocked_reason = " +
      lit(updated.blockedReason) +
      ", prerequisite_proposal = " +
      lit(updated.prerequisiteProposal) +
      ", recommendation = " +
      lit(updated.recommendation) +
      ", pr_url = " +
      lit(updated.prUrl) +
      ", updated_at = " +
      lit(now) +
      ", updated_seq = " +
      cur +
      itemKey +
      " AND updated_seq = " +
      lit(readVersion)
  ]
  if stateChanged {
    stmts = stmts.append(
      "INSERT INTO ledger_transitions (id, session_id, item_id, from_state, to_state, actor, reason, at, seq) SELECT " +
        lit(newLedgerId()) +
        ", " +
        lit(sessionId) +
        ", " +
        lit(updated.id) +
        ", " +
        lit(fromState) +
        ", " +
        lit(updated.state) +
        ", " +
        lit(actor) +
        ", " +
        lit(reason) +
        ", " +
        lit(now) +
        ", " +
        cur +
        " WHERE" +
        applied
    )
  }
  if resolveBlockers {
    stmts = stmts.append(
      "UPDATE ledger_entries SET review_state = 'resolved', review_at = " + lit(now) + ", updated_seq = " + cur +
        " WHERE session_id = " +
        lit(sessionId) +
        " AND item_id = " +
        lit(updated.id) +
        " AND origin = 'transition' AND review_state = 'pending' AND" +
        applied
    )
  }
  if auto.summary.length.toInt() > 0 {
    // Every automatic entry is born of this transition, whoever the actor
    // was, so a later leave-blocked transition must be able to resolve it.
    stmts = stmts.append(
      insertEntrySelectSql(
        newLedgerId(),
        sessionId,
        updated.id,
        auto.kind,
        auto.severity,
        auto.summary,
        auto.detail,
        auto.source,
        "transition",
        updated.recommendation,
        now
      ) +
        " WHERE" +
        applied
    )
  }
  // Last statement: its affected-row count is the "applied" signal.
  stmts = stmts.append("UPDATE ledger_items SET updated_seq = updated_seq" + itemKey + " AND updated_seq = " + cur)
  val n = CloudAgents.Sqlite.executeTransaction(stmts)?
  return Ok(value = n > 0)
}

// A minimal INSERT ... SELECT for automatic entries (no options/files/tags).
func insertEntrySelectSql(
  id: in String,
  sessionId: in String,
  itemId: in String,
  kind: in String,
  severity: in String,
  summary: in String,
  detail: in String,
  source: in String,
  origin: in String,
  recommendation: in String,
  now: in String,
): String {
  var review = "pending"
  if severity == "info" {
    review = "not_required"
  }
  val cur = curSeqExpr(sessionId)
  return "INSERT INTO ledger_entries (" + entryCols + ") SELECT " + lit(id) + ", " + lit(sessionId) + ", " + lit(itemId) +
    ", " +
    lit(kind) +
    ", " +
    lit(severity) +
    ", '', " +
    lit(summary) +
    ", " +
    lit(detail) +
    ", '[]', '', '', " +
    lit(recommendation) +
    ", '', '', '[]', '[]', " +
    lit(source) +
    ", 'false', '', " +
    lit(origin) +
    ", '', '', " +
    lit(review) +
    ", '', '', '', " +
    lit(now) +
    ", " +
    cur +
    ", " +
    cur
}

pub func listTransitions(
  sessionId: in String, itemId: in String
): Result[slice[WorkItemTransition], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT item_id, from_state, to_state, actor, reason, at FROM ledger_transitions WHERE session_id = " + lit(sessionId) + " AND item_id = " + lit(itemId) + " ORDER BY CAST(seq AS INTEGER), at LIMIT 500")?
  var acc: slice[WorkItemTransition] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(rowToTransition(CloudAgents.Sqlite.getRowArrayValue(rows, i)))
    i = i + 1
  }
  return Ok(value = acc)
}

func rowToTransition(r: in CloudAgents.Sqlite.Row): WorkItemTransition {
  return WorkItemTransition(
    itemId = col(r, 0),
    fromState = col(r, 1),
    toState = col(r, 2),
    actor = col(r, 3),
    reason = col(r, 4),
    at = col(r, 5)
  )
}

// ── Entries ───────────────────────────────────────────────────────────────────
val entryCols = "id, session_id, item_id, kind, severity, declared_severity, summary, detail, options_json, chosen, rationale, recommendation, proceeding_with, reversible, files_json, tags_json, source, undeclared, matched_entry_id, origin, supersedes, transcript_seq, review_state, review_by, review_at, review_comment, created_at, created_seq, updated_seq"

func rowToEntry(r: in CloudAgents.Sqlite.Row): LedgerEntry {
  return LedgerEntry(
    id = col(r, 0),
    sessionId = col(r, 1),
    itemId = col(r, 2),
    kind = col(r, 3),
    severity = col(r, 4),
    declaredSeverity = col(r, 5),
    summary = col(r, 6),
    detail = col(r, 7),
    optionsConsidered = decodeStringList(col(r, 8)),
    chosen = col(r, 9),
    rationale = col(r, 10),
    recommendation = col(r, 11),
    proceedingWith = col(r, 12),
    reversible = col(r, 13),
    files = decodeStringList(col(r, 14)),
    tags = decodeStringList(col(r, 15)),
    source = col(r, 16),
    undeclared = col(r, 17),
    matchedEntryId = col(r, 18),
    origin = col(r, 19),
    supersedes = col(r, 20),
    transcriptSeq = col(r, 21),
    reviewState = col(r, 22),
    reviewBy = col(r, 23),
    reviewAt = col(r, 24),
    reviewComment = col(r, 25),
    createdAt = col(r, 26),
    createdSeq = col(r, 27),
    updatedSeq = col(r, 28)
  )
}

func entriesFromRows(rows: in CloudAgents.Sqlite.RowArray): slice[LedgerEntry] {
  var acc: slice[LedgerEntry] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(rowToEntry(CloudAgents.Sqlite.getRowArrayValue(rows, i)))
    i = i + 1
  }
  return acc
}

val entryOrder = " ORDER BY CAST(created_seq AS INTEGER), created_at, id"

/// Insert a fully decided entry (id / createdAt / seq fields are assigned
/// here) and return it as stored.
pub func insertEntry(e: in LedgerEntry): Result[LedgerEntry, CloudAgents.Sqlite.DbError] {
  val id = newLedgerId()
  val now = CloudAgents.Repository.nowMillis()
  val cur = curSeqExpr(e.sessionId)
  val insert = "INSERT INTO ledger_entries (" + entryCols + ") VALUES (" + lit(id) + ", " + lit(e.sessionId) + ", " +
    lit(e.itemId) +
    ", " +
    lit(e.kind) +
    ", " +
    lit(e.severity) +
    ", " +
    lit(e.declaredSeverity) +
    ", " +
    lit(e.summary) +
    ", " +
    lit(e.detail) +
    ", " +
    lit(encodeStringList(e.optionsConsidered)) +
    ", " +
    lit(e.chosen) +
    ", " +
    lit(e.rationale) +
    ", " +
    lit(e.recommendation) +
    ", " +
    lit(e.proceedingWith) +
    ", " +
    lit(e.reversible) +
    ", " +
    lit(encodeStringList(e.files)) +
    ", " +
    lit(encodeStringList(e.tags)) +
    ", " +
    lit(e.source) +
    ", " +
    lit(e.undeclared) +
    ", " +
    lit(e.matchedEntryId) +
    ", " +
    lit(e.origin) +
    ", " +
    lit(e.supersedes) +
    ", " +
    lit(e.transcriptSeq) +
    ", " +
    lit(e.reviewState) +
    ", '', '', '', " +
    lit(now) +
    ", " +
    cur +
    ", " +
    cur +
    ")"
  CloudAgents.Sqlite.executeTransaction([ensureSessionSql(e.sessionId, now), bumpSeqSql(e.sessionId), insert])?
  match getEntry(e.sessionId, id)? {
    case Some(stored) -> return Ok(value = stored)
    case None -> return Err(error = ExecFailed(sql = "SELECT ledger entry", message = "entry vanished after insert"))
  }
}

pub func getEntry(sessionId: in String, entryId: in String): Result[Option[LedgerEntry], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + entryCols + " FROM ledger_entries WHERE session_id = " + lit(sessionId) + " AND id = " + lit(entryId))?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = rowToEntry(CloudAgents.Sqlite.getRowArrayValue(rows, 0))))
}

/// A session's entries in creation order (bounded).
pub func listEntries(sessionId: in String): Result[slice[LedgerEntry], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + entryCols + " FROM ledger_entries WHERE session_id = " + lit(sessionId) + entryOrder + " LIMIT " + toString(entryRowCap))?
  return Ok(value = entriesFromRows(rows))
}

pub func entriesChangedAfter(
  sessionId: in String, after: in String
): Result[slice[LedgerEntry], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + entryCols + " FROM ledger_entries WHERE session_id = " + lit(sessionId) + " AND CAST(updated_seq AS INTEGER) > CAST(" + lit(after) + " AS INTEGER)" + entryOrder + " LIMIT " + toString(entryRowCap))?
  return Ok(value = entriesFromRows(rows))
}

/// Record a human review on an entry and the matching feedback row, in one
/// transaction. `reviewState` / `kind` are already validated.
pub func reviewEntry(
  sessionId: in String,
  entry: in LedgerEntry,
  reviewState: in String,
  kind: in String,
  body: in String,
  by: in String,
): Result[Feedback, CloudAgents.Sqlite.DbError] {
  val now = CloudAgents.Repository.nowMillis()
  val cur = curSeqExpr(sessionId)
  val fid = newLedgerId()
  CloudAgents.Sqlite.executeTransaction([ensureSessionSql(sessionId, now), bumpSeqSql(sessionId), "UPDATE ledger_entries SET review_state = " + lit(reviewState) + ", review_by = " + lit(by) + ", review_at = " + lit(now) + ", review_comment = " + lit(body) + ", updated_seq = " + cur + " WHERE session_id = " + lit(sessionId) + " AND id = " + lit(entry.id), insertFeedbackSql(fid, sessionId, entry.id, entry.itemId, kind, body, by, now)])?
  return getFeedbackOrFail(sessionId, fid)
}

// ── Feedback ──────────────────────────────────────────────────────────────────
val feedbackCols = "id, session_id, entry_id, item_id, kind, body, created_by, created_at, delivered_at, delivered_via, updated_seq"

func insertFeedbackSql(
  id: in String,
  sessionId: in String,
  entryId: in String,
  itemId: in String,
  kind: in String,
  body: in String,
  by: in String,
  now: in String,
): String {
  return "INSERT INTO ledger_feedback (" + feedbackCols + ", delivery_batch) VALUES (" + lit(id) + ", " + lit(sessionId) +
    ", " +
    lit(entryId) +
    ", " +
    lit(itemId) +
    ", " +
    lit(kind) +
    ", " +
    lit(body) +
    ", " +
    lit(by) +
    ", " +
    lit(now) +
    ", '', '', " +
    curSeqExpr(sessionId) +
    ", '')"
}

func rowToFeedback(r: in CloudAgents.Sqlite.Row): Feedback {
  return Feedback(
    id = col(r, 0),
    sessionId = col(r, 1),
    entryId = col(r, 2),
    itemId = col(r, 3),
    kind = col(r, 4),
    body = col(r, 5),
    createdBy = col(r, 6),
    createdAt = col(r, 7),
    deliveredAt = col(r, 8),
    deliveredVia = col(r, 9),
    updatedSeq = col(r, 10)
  )
}

func feedbackFromRows(rows: in CloudAgents.Sqlite.RowArray): slice[Feedback] {
  var acc: slice[Feedback] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(rowToFeedback(CloudAgents.Sqlite.getRowArrayValue(rows, i)))
    i = i + 1
  }
  return acc
}

func getFeedbackOrFail(sessionId: in String, id: in String): Result[Feedback, CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + feedbackCols + " FROM ledger_feedback WHERE session_id = " + lit(sessionId) + " AND id = " + lit(id))?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Err(error = ExecFailed(sql = "SELECT ledger feedback", message = "feedback vanished after insert"))
  }
  return Ok(value = rowToFeedback(CloudAgents.Sqlite.getRowArrayValue(rows, 0)))
}

/// Add session- or item-level feedback (kind / body already validated).
pub func addFeedback(
  sessionId: in String, itemId: in String, kind: in String, body: in String, by: in String
): Result[Feedback, CloudAgents.Sqlite.DbError] {
  val now = CloudAgents.Repository.nowMillis()
  val fid = newLedgerId()
  CloudAgents.Sqlite.executeTransaction([ensureSessionSql(sessionId, now), bumpSeqSql(sessionId), insertFeedbackSql(fid, sessionId, "", itemId, kind, body, by, now)])?
  return getFeedbackOrFail(sessionId, fid)
}

/// A session's feedback, oldest first (bounded).
pub func listFeedback(sessionId: in String): Result[slice[Feedback], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + feedbackCols + " FROM ledger_feedback WHERE session_id = " + lit(sessionId) + " ORDER BY created_at, id LIMIT " + toString(feedbackRowCap))?
  return Ok(value = feedbackFromRows(rows))
}

pub func feedbackChangedAfter(
  sessionId: in String, after: in String
): Result[slice[Feedback], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + feedbackCols + " FROM ledger_feedback WHERE session_id = " + lit(sessionId) + " AND CAST(updated_seq AS INTEGER) > CAST(" + lit(after) + " AS INTEGER) ORDER BY created_at, id LIMIT " + toString(feedbackRowCap))?
  return Ok(value = feedbackFromRows(rows))
}

/// Undelivered feedback count.
pub func pendingFeedbackCount(sessionId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT CAST(COUNT(*) AS TEXT) FROM ledger_feedback WHERE session_id = " + lit(sessionId) + " AND delivered_at = ''")?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Ok(value = 0)
  }
  return Ok(value = parseCount(col(CloudAgents.Sqlite.getRowArrayValue(rows, 0), 0)))
}

func parseCount(s: in String): Int {
  var n = 0
  var i = 0
  val len = s.length.toInt()
  while i < len {
    val d = digitOf(s.substring(i, 1))
    if d < 0 {
      return n
    }
    n = n * 10 + d
    i = i + 1
  }
  return n
}

func digitOf(c: in String): Int {
  val digits = "0123456789"
  var i = 0
  while i < 10 {
    if digits.substring(i, 1) == c {
      return i
    }
    i = i + 1
  }
  return -1
}

/// Claim every undelivered feedback row for delivery via `via`, then return
/// exactly the claimed rows (oldest first).
pub func collectFeedback(sessionId: in String, via: in String): Result[slice[Feedback], CloudAgents.Sqlite.DbError] {
  val now = CloudAgents.Repository.nowMillis()
  val batch = newLedgerId()
  CloudAgents.Sqlite.executeTransaction([ensureSessionSql(sessionId, now), bumpSeqSql(sessionId), "UPDATE ledger_feedback SET delivered_at = " + lit(now) + ", delivered_via = " + lit(via) + ", delivery_batch = " + lit(batch) + ", updated_seq = " + curSeqExpr(sessionId) + " WHERE session_id = " + lit(sessionId) + " AND delivered_at = ''"])?
  val rows = CloudAgents.Sqlite.query("SELECT " + feedbackCols + " FROM ledger_feedback WHERE session_id = " + lit(sessionId) + " AND delivery_batch = " + lit(batch) + " ORDER BY created_at, id")?
  return Ok(value = feedbackFromRows(rows))
}

// ── Repo policy cache ─────────────────────────────────────────────────────────
pub record PolicyCache {
  pub status: String
  pub json: String
  pub error: String
}

pub func getPolicyCache(sessionId: in String): Result[PolicyCache, CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT policy_status, policy_json, policy_error FROM ledger_sessions WHERE session_id = " + lit(sessionId))?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Ok(value = PolicyCache(status = "", json = "", error = ""))
  }
  val r = CloudAgents.Sqlite.getRowArrayValue(rows, 0)
  return Ok(value = PolicyCache(status = col(r, 0), json = col(r, 1), error = col(r, 2)))
}

pub func setPolicyCache(
  sessionId: in String, status: in String, json: in String, error: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val now = CloudAgents.Repository.nowMillis()
  CloudAgents.Sqlite.executeTransaction([ensureSessionSql(sessionId, now), "UPDATE ledger_sessions SET policy_status = " + lit(status) + ", policy_json = " + lit(json) + ", policy_error = " + lit(error) + " WHERE session_id = " + lit(sessionId)])?
  return Ok(())
}

// ── Cross-session inbox ───────────────────────────────────────────────────────
/// One attention-queue entry with the session context the inbox shows.
@generate(Json)
pub record InboxEntry {
  pub ledgerEntry: LedgerEntry
  pub repoUrl: String
  pub branch: String
}

func prefixedEntryCols(): String {
  var acc = ""
  val names = splitOn(entryCols, ",")
  var i = 0
  while i < names.length.toInt() {
    if i > 0 {
      acc = acc + ", "
    }
    acc = acc + "e." + names[i].trim()
    i = i + 1
  }
  return acc
}

/// Every pending review / blocking entry across `userId`'s sessions,
/// blocking first, then oldest first (bounded).
pub func inboxForUser(userId: in String): Result[slice[InboxEntry], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + prefixedEntryCols() + ", s.repo_url, s.branch FROM ledger_entries e JOIN sessions s ON s.id = e.session_id" + " WHERE s.user_id = " + lit(userId) + " AND e.review_state = 'pending' AND e.severity IN ('review', 'blocking')" + " ORDER BY CASE e.severity WHEN 'blocking' THEN 0 ELSE 1 END, e.created_at, e.id LIMIT 500")?
  var acc: slice[InboxEntry] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(rowToInboxEntry(CloudAgents.Sqlite.getRowArrayValue(rows, i)))
    i = i + 1
  }
  return Ok(value = acc)
}

func rowToInboxEntry(r: in CloudAgents.Sqlite.Row): InboxEntry {
  return InboxEntry(ledgerEntry = rowToEntry(r), repoUrl = col(r, 29), branch = col(r, 30))
}
