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
import CloudAgents.Ledger.Summary
import CloudAgents.Ledger.ObserverPolicy

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
      // A ref-derived URL is only a default for a new item: re-registering
      // with no url keeps whatever the item already has.
      var url = urls[i]
      if url.length.toInt() == 0 {
        url = urlForItemRef(id)
      }
      stmts = stmts.append(
        "INSERT OR IGNORE INTO ledger_items (" + itemCols + ") VALUES (" + lit(sessionId) + ", " + lit(id) + ", " +
          lit(titles[i]) +
          ", " +
          lit(url) +
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
    cur +
    ", '', '', '', ''"
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
val entryCols = "id, session_id, item_id, kind, severity, declared_severity, summary, detail, options_json, chosen, rationale, recommendation, proceeding_with, reversible, files_json, tags_json, source, undeclared, matched_entry_id, origin, supersedes, transcript_seq, review_state, review_by, review_at, review_comment, created_at, created_seq, updated_seq, observed_from, confidence, evidence, provisional"

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
    updatedSeq = col(r, 28),
    observedFrom = col(r, 29),
    confidence = col(r, 30),
    evidence = col(r, 31),
    provisional = col(r, 32)
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
    ", " +
    lit(e.observedFrom) +
    ", " +
    lit(e.confidence) +
    ", " +
    lit(e.evidence) +
    ", " +
    lit(e.provisional) +
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
/// Past the cap these are the NEWEST entryRowCap entries (recent activity is
/// never the part dropped); countEntries says whether any were.
pub func listEntries(sessionId: in String): Result[slice[LedgerEntry], CloudAgents.Sqlite.DbError] {
  val newest = "SELECT " + entryCols + " FROM ledger_entries WHERE session_id = " + lit(sessionId) +
    " ORDER BY CAST(created_seq AS INTEGER) DESC, created_at DESC, id DESC LIMIT " +
    toString(entryRowCap)
  val rows = CloudAgents.Sqlite.query("SELECT " + entryCols + " FROM (" + newest + ")" + entryOrder)?
  return Ok(value = entriesFromRows(rows))
}

/// The entries of this session whose `supersedes` names `entryId`.
pub func supersedingEntryIds(
  sessionId: in String, entryId: in String
): Result[slice[String], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT id FROM ledger_entries WHERE session_id = " + lit(sessionId) + " AND supersedes = " + lit(entryId) + entryOrder)?
  var acc: slice[String] = []
  var i = 0
  while i < CloudAgents.Sqlite.getRowArrayLength(rows) {
    acc = acc.append(col(CloudAgents.Sqlite.getRowArrayValue(rows, i), 0))
    i = i + 1
  }
  return Ok(value = acc)
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
/// Past the cap these are the NEWEST feedbackRowCap rows, oldest first.
pub func listFeedback(sessionId: in String): Result[slice[Feedback], CloudAgents.Sqlite.DbError] {
  val newest = "SELECT " + feedbackCols + " FROM ledger_feedback WHERE session_id = " + lit(sessionId) +
    " ORDER BY created_at DESC, id DESC LIMIT " +
    toString(feedbackRowCap)
  val rows = CloudAgents.Sqlite.query("SELECT " + feedbackCols + " FROM (" + newest + ") ORDER BY created_at, id")?
  return Ok(value = feedbackFromRows(rows))
}

/// Feedback on one entry, oldest first.
pub func feedbackForEntry(sessionId: in String, entryId: in String): Result[slice[Feedback], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + feedbackCols + " FROM ledger_feedback WHERE session_id = " + lit(sessionId) + " AND entry_id = " + lit(entryId) + " ORDER BY created_at, id")?
  return Ok(value = feedbackFromRows(rows))
}

/// Row counts, to tell a capped list from a complete one.
pub func countItems(sessionId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  return countWhere("ledger_items", sessionId)
}

pub func countEntries(sessionId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  return countWhere("ledger_entries", sessionId)
}

pub func countFeedback(sessionId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  return countWhere("ledger_feedback", sessionId)
}

func countWhere(table: in String, sessionId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT COUNT(*) FROM " + table + " WHERE session_id = " + lit(sessionId))?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Ok(value = 0)
  }
  return Ok(value = decimalToInt(col(CloudAgents.Sqlite.getRowArrayValue(rows, 0), 0)))
}

func decimalToInt(s: in String): Int {
  val digits = "0123456789"
  var n = 0
  var i = 0
  while i < s.length.toInt() {
    var d = 0
    while d < 10 and digits.substring(d, 1) != s.substring(i, 1) {
      d = d + 1
    }
    if d == 10 {
      return n
    }
    n = n * 10 + d
    i = i + 1
  }
  return n
}

/// Progress and attention counts computed in SQL over every row, so the
/// numbers stay right however large the session grows (the lists shipped to
/// the client are capped; these are not).
pub func summaryOf(sessionId: in String, pendingFeedback: in Int): Result[LedgerSummary, CloudAgents.Sqlite.DbError] {
  val sid = lit(sessionId)
  val items = "FROM ledger_items WHERE session_id = " + sid
  val entries = "FROM ledger_entries WHERE session_id = " + sid
  val pending = " AND review_state = 'pending' AND severity IN ('review', 'blocking')"
  val sql = "SELECT (SELECT COUNT(*) " + items + "), " + stateCount(items, "queued") + ", " +
    stateCount(items, "in_progress") +
    ", " +
    stateCount(items, "pr_open") +
    ", " +
    stateCount(items, "done") +
    ", " +
    stateCount(items, "blocked") +
    ", " +
    stateCount(items, "needs_human") +
    ", " +
    stateCount(items, "skipped") +
    ", (SELECT COUNT(*) " +
    entries +
    pending +
    "), (SELECT COUNT(*) " +
    entries +
    pending +
    " AND severity = 'blocking'), (SELECT COUNT(*) " +
    entries +
    " AND undeclared = 'true'), MAX(COALESCE((SELECT MAX(CAST(created_at AS INTEGER)) " +
    entries +
    "), 0), COALESCE((SELECT MAX(CAST(updated_at AS INTEGER)) " +
    items +
    "), 0))"
  val rows = CloudAgents.Sqlite.query(sql)?
  val r = CloudAgents.Sqlite.getRowArrayValue(rows, 0)
  var last = col(r, 11)
  if last == "0" {
    last = ""
  }
  return Ok(
    value = LedgerSummary(
      sessionId = sessionId,
      total = col(r, 0),
      queued = col(r, 1),
      inProgress = col(r, 2),
      prOpen = col(r, 3),
      done = col(r, 4),
      blocked = col(r, 5),
      needsHuman = col(r, 6),
      skipped = col(r, 7),
      pendingReview = col(r, 8),
      blockingCount = col(r, 9),
      undeclaredCount = col(r, 10),
      pendingFeedback = toString(pendingFeedback),
      lastActivityAt = last
    )
  )
}

func stateCount(fromItems: in String, state: in String): String {
  return "(SELECT COUNT(*) " + fromItems + " AND state = " + lit(state) + ")"
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
/// A claimed feedback row with the summary of the entry it answers ("" for
/// session- or item-level feedback, or an entry that no longer exists).
pub record ClaimedFeedback {
  pub feedback: Feedback
  pub entrySummary: String
}

pub func collectFeedback(sessionId: in String, via: in String): Result[slice[Feedback], CloudAgents.Sqlite.DbError] {
  val claimed = claimFeedback(sessionId, via)?
  var acc: slice[Feedback] = []
  var i = 0
  while i < claimed.length.toInt() {
    acc = acc.append(claimed[i].feedback)
    i = i + 1
  }
  return Ok(value = acc)
}

/// Claim every undelivered feedback row and read it back, with the entry
/// summaries the agent sees, in one query: a failure after the claim
/// releases the batch, so nothing is ever marked delivered unseen.
pub func claimFeedback(sessionId: in String, via: in String): Result[slice[ClaimedFeedback], CloudAgents.Sqlite.DbError] {
  val now = CloudAgents.Repository.nowMillis()
  val batch = newLedgerId()
  CloudAgents.Sqlite.executeTransaction([ensureSessionSql(sessionId, now), bumpSeqSql(sessionId), "UPDATE ledger_feedback SET delivered_at = " + lit(now) + ", delivered_via = " + lit(via) + ", delivery_batch = " + lit(batch) + ", updated_seq = " + curSeqExpr(sessionId) + " WHERE session_id = " + lit(sessionId) + " AND delivered_at = ''"])?
  val sql = "SELECT " + prefixedCols(feedbackCols, "f") +
    ", COALESCE(e.summary, '') FROM ledger_feedback f LEFT JOIN ledger_entries e ON e.session_id = f.session_id AND e.id = f.entry_id WHERE f.session_id = " +
    lit(sessionId) +
    " AND f.delivery_batch = " +
    lit(batch) +
    " ORDER BY f.created_at, f.id"
  match CloudAgents.Sqlite.query(sql) {
    case Ok(rows) -> return Ok(value = claimedFromRows(rows))
    case Err(e) -> {
      // The claim committed but the agent will get an error, not the rows:
      // release them so the next check delivers them.
      releaseFeedbackBatch(sessionId, batch)
      return Err(error = e)
    }
  }
}

func claimedFromRows(rows: in CloudAgents.Sqlite.RowArray): slice[ClaimedFeedback] {
  var acc: slice[ClaimedFeedback] = []
  var i = 0
  while i < CloudAgents.Sqlite.getRowArrayLength(rows) {
    val r = CloudAgents.Sqlite.getRowArrayValue(rows, i)
    acc = acc.append(ClaimedFeedback(feedback = rowToFeedback(r), entrySummary = col(r, 11)))
    i = i + 1
  }
  return acc
}

// "a, b" -> "f.a, f.b"
func prefixedCols(cols: in String, alias: in String): String {
  val names = splitOn(cols, ",")
  var acc = ""
  var i = 0
  while i < names.length.toInt() {
    if i > 0 {
      acc = acc + ", "
    }
    acc = acc + alias + "." + names[i].trim()
    i = i + 1
  }
  return acc
}

/// Undo a claim whose rows never reached the agent (best-effort: a failure
/// here leaves them claimed, which the caller already reports as an error).
pub func releaseFeedbackBatch(sessionId: in String, batch: in String): Unit {
  val sql = "UPDATE ledger_feedback SET delivered_at = '', delivered_via = '', delivery_batch = '', updated_seq = " +
    curSeqExpr(sessionId) +
    " WHERE session_id = " +
    lit(sessionId) +
    " AND delivery_batch = " +
    lit(batch)
  match CloudAgents.Sqlite.executeTransaction([bumpSeqSql(sessionId), sql]) {
    case Ok(_) -> ()
    case Err(e) -> println(
      "WARNING: releasing ledger feedback batch " + batch + " failed: " +
        CloudAgents.Sqlite.dbErrorMessage(e)
    )
  }
}

// ── GitHub sync state (Phase 3) ───────────────────────────────────────────────
pub record SyncRow {
  pub itemId: String
  pub syncedLabel: String
  pub commentId: String
  pub commentHash: String
  pub lastError: String
  pub syncedAt: String
  pub attemptedAt: String
}

pub func emptySyncRow(itemId: in String): SyncRow {
  return SyncRow(
    itemId = itemId,
    syncedLabel = "",
    commentId = "",
    commentHash = "",
    lastError = "",
    syncedAt = "",
    attemptedAt = ""
  )
}

/// Every item's sync row for a session (items never synced have none).
pub func syncRows(sessionId: in String): Result[slice[SyncRow], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT item_id, synced_label, comment_id, comment_hash, last_error, synced_at, attempted_at FROM ledger_github_sync WHERE session_id = " + lit(sessionId))?
  var acc: slice[SyncRow] = []
  var i = 0
  while i < CloudAgents.Sqlite.getRowArrayLength(rows) {
    val r = CloudAgents.Sqlite.getRowArrayValue(rows, i)
    acc = acc.append(
      SyncRow(
        itemId = col(r, 0),
        syncedLabel = col(r, 1),
        commentId = col(r, 2),
        commentHash = col(r, 3),
        lastError = col(r, 4),
        syncedAt = col(r, 5),
        attemptedAt = col(r, 6)
      )
    )
    i = i + 1
  }
  return Ok(value = acc)
}

pub func saveSyncRow(sessionId: in String, row: in SyncRow): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute("INSERT INTO ledger_github_sync (session_id, item_id, synced_label, comment_id, comment_hash, last_error, synced_at, attempted_at) VALUES (" + lit(sessionId) + ", " + lit(row.itemId) + ", " + lit(row.syncedLabel) + ", " + lit(row.commentId) + ", " + lit(row.commentHash) + ", " + lit(row.lastError) + ", " + lit(row.syncedAt) + ", " + lit(row.attemptedAt) + ") ON CONFLICT(session_id, item_id) DO UPDATE SET synced_label = excluded.synced_label, comment_id = excluded.comment_id, comment_hash = excluded.comment_hash, last_error = excluded.last_error, synced_at = excluded.synced_at, attempted_at = excluded.attempted_at")?
  return Ok(())
}

// SQL: item `i` (of ledger_items) is the one that owns its GitHub issue. A
// label and a comment live on the issue, so exactly one session may manage
// them: the most recent non-archived session to register the issue (ties by
// session id). An archived session owns nothing.
func ownsIssueSql(): String {
  return "i.item_id LIKE 'gh:%' AND s.is_archived = '0' AND NOT EXISTS (SELECT 1 FROM ledger_items o JOIN sessions os ON os.id = o.session_id " +
    "WHERE o.item_id = i.item_id AND o.session_id != i.session_id AND os.is_archived = '0' AND (CAST(o.created_at AS INTEGER) > CAST(i.created_at AS INTEGER) " +
    "OR (CAST(o.created_at AS INTEGER) = CAST(i.created_at AS INTEGER) AND o.session_id > i.session_id)))"
}

/// The session's GitHub-backed items it owns for syncing (see ownsIssueSql):
/// empty for an archived session, and without any issue a later session has
/// since taken over.
pub func ownedIssueItems(sessionId: in String): Result[slice[String], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT i.item_id FROM ledger_items i JOIN sessions s ON s.id = i.session_id WHERE i.session_id = " + lit(sessionId) + " AND " + ownsIssueSql())?
  var acc: slice[String] = []
  var i = 0
  while i < CloudAgents.Sqlite.getRowArrayLength(rows) {
    acc = acc.append(col(CloudAgents.Sqlite.getRowArrayValue(rows, i), 0))
    i = i + 1
  }
  return Ok(value = acc)
}

/// Sessions with owned GitHub-backed items that need a sync pass: an item
/// changed since it was last synced (or never was), or it is waiting on
/// GitHub (blocked, needs_human, pr_open). Least recently attempted first,
/// so a session that keeps failing takes its turn and no more.
pub func sessionsToSync(limit: in Int): Result[slice[String], CloudAgents.Sqlite.DbError] {
  val sql = "SELECT i.session_id, MAX(COALESCE(CAST(r.attempted_at AS INTEGER), 0)) AS attempted FROM ledger_items i " +
    "JOIN sessions s ON s.id = i.session_id " +
    "LEFT JOIN ledger_github_sync g ON g.session_id = i.session_id AND g.item_id = i.item_id " +
    "LEFT JOIN ledger_github_sync_runs r ON r.session_id = i.session_id " +
    "WHERE " +
    ownsIssueSql() +
    " AND (g.item_id IS NULL OR CAST(g.synced_at AS INTEGER) < CAST(i.updated_at AS INTEGER) OR i.state IN ('blocked', 'needs_human', 'pr_open')) " +
    "GROUP BY i.session_id ORDER BY attempted, i.session_id LIMIT " +
    toString(limit)
  val rows = CloudAgents.Sqlite.query(sql)?
  var acc: slice[String] = []
  var i = 0
  while i < CloudAgents.Sqlite.getRowArrayLength(rows) {
    acc = acc.append(col(CloudAgents.Sqlite.getRowArrayValue(rows, i), 0))
    i = i + 1
  }
  return Ok(value = acc)
}

func ensureSyncRunRow(sessionId: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute("INSERT INTO ledger_github_sync_runs (session_id, attempted_at, last_error, lease_until) VALUES (" + lit(sessionId) + ", '0', '', '0') ON CONFLICT(session_id) DO NOTHING")?
  return Ok(())
}

/// Record that a sync pass was attempted for the session (`error` "" when
/// it got as far as the items).
pub func markSyncAttempt(sessionId: in String, error: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  ensureSyncRunRow(sessionId)?
  CloudAgents.Sqlite.execute("UPDATE ledger_github_sync_runs SET attempted_at = " + lit(CloudAgents.Repository.nowMillis()) + ", last_error = " + lit(error) + " WHERE session_id = " + lit(sessionId))?
  return Ok(())
}

/// Take the session's sync lease until `now + leaseMillis`. Returns the lease
/// token to release with, or "" when another pass holds an unexpired lease.
/// One conditional UPDATE, so two callers can't both win (SQLite serializes
/// writers). A crashed pass's lease simply expires.
pub func acquireSyncLease(sessionId: in String, leaseMillis: in Long): Result[String, CloudAgents.Sqlite.DbError] {
  ensureSyncRunRow(sessionId)?
  val now = CloudAgents.Repository.nowMillisLong()
  val until = toString(now + leaseMillis)
  val changed = CloudAgents.Sqlite.execute("UPDATE ledger_github_sync_runs SET lease_until = " + lit(until) + " WHERE session_id = " + lit(sessionId) + " AND CAST(lease_until AS INTEGER) <= " + toString(now))?
  if changed == 1 {
    return Ok(value = until)
  }
  return Ok(value = "")
}

/// Give the lease back, if it is still the one `token` names.
pub func releaseSyncLease(sessionId: in String, token: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute("UPDATE ledger_github_sync_runs SET lease_until = '0' WHERE session_id = " + lit(sessionId) + " AND lease_until = " + lit(token))?
  return Ok(())
}

// ── Observer (Phase 4) ────────────────────────────────────────────────────────
/// A profile's observer settings, or None when it has none (not observed).
pub func observerSettingsFor(profileId: in String): Result[Option[ObserverSettings], CloudAgents.Sqlite.DbError] {
  if profileId.length.toInt() == 0 {
    return Ok(value = None)
  }
  // Joined to profiles: settings outlive a deleted profile's row, and a session
  // left pointing at a deleted profile must not stay observed.
  val rows = CloudAgents.Sqlite.query("SELECT s.enabled, s.harness, s.model, s.repo_access, s.mid_run_minutes, s.max_passes_per_day FROM ledger_observer_settings s JOIN profiles p ON p.id = s.profile_id WHERE s.profile_id = " + lit(profileId))?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Ok(value = None)
  }
  val r = CloudAgents.Sqlite.getRowArrayValue(rows, 0)
  return Ok(
    value = Some(
      value = ObserverSettings(
        enabled = col(r, 0),
        harness = col(r, 1),
        model = col(r, 2),
        repoAccess = col(r, 3),
        midRunMinutes = col(r, 4),
        maxPassesPerDay = col(r, 5)
      )
    )
  )
}

pub func saveObserverSettings(profileId: in String, st: in ObserverSettings): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute("INSERT INTO ledger_observer_settings (profile_id, enabled, harness, model, repo_access, mid_run_minutes, max_passes_per_day, updated_at) VALUES (" + lit(profileId) + ", " + lit(st.enabled) + ", " + lit(st.harness) + ", " + lit(st.model) + ", " + lit(st.repoAccess) + ", " + lit(st.midRunMinutes) + ", " + lit(st.maxPassesPerDay) + ", " + lit(CloudAgents.Repository.nowMillis()) + ") ON CONFLICT(profile_id) DO UPDATE SET enabled = excluded.enabled, harness = excluded.harness, model = excluded.model, repo_access = excluded.repo_access, mid_run_minutes = excluded.mid_run_minutes, max_passes_per_day = excluded.max_passes_per_day, updated_at = excluded.updated_at")?
  return Ok(())
}

/// An observed session's observer bookkeeping (see ledgerObserverSchemaSql).
pub record ObserverState {
  pub sessionId: String
  pub observerSessionId: String
  pub cursorSeq: String
  pub windowEnd: String
  pub pending: String
  pub passDay: String
  pub passesToday: String
  pub lastPassAt: String
  pub configHash: String
  pub lastError: String
}

pub func emptyObserverState(sessionId: in String): ObserverState {
  return ObserverState(
    sessionId = sessionId,
    observerSessionId = "",
    cursorSeq = "",
    windowEnd = "",
    pending = "0",
    passDay = "",
    passesToday = "0",
    lastPassAt = "",
    configHash = "",
    lastError = ""
  )
}

val observerCols = "session_id, observer_session_id, cursor_seq, window_end, pending, pass_day, passes_today, last_pass_at, config_hash, last_error"

func rowToObserverState(r: in CloudAgents.Sqlite.Row): ObserverState {
  return ObserverState(
    sessionId = col(r, 0),
    observerSessionId = col(r, 1),
    cursorSeq = col(r, 2),
    windowEnd = col(r, 3),
    pending = col(r, 4),
    passDay = col(r, 5),
    passesToday = col(r, 6),
    lastPassAt = col(r, 7),
    configHash = col(r, 8),
    lastError = col(r, 9)
  )
}

/// The observer state of an observed session (an empty state when it has
/// never been observed).
pub func observerState(sessionId: in String): Result[ObserverState, CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + observerCols + " FROM ledger_observer WHERE session_id = " + lit(sessionId))?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Ok(value = emptyObserverState(sessionId))
  }
  return Ok(value = rowToObserverState(CloudAgents.Sqlite.getRowArrayValue(rows, 0)))
}

/// The observed session an observer session works for ("" when `observerSessionId`
/// is not an observer).
pub func observedSessionOf(observerSessionId: in String): Result[String, CloudAgents.Sqlite.DbError] {
  if observerSessionId.length.toInt() == 0 {
    return Ok(value = "")
  }
  val rows = CloudAgents.Sqlite.query("SELECT session_id FROM ledger_observer WHERE observer_session_id = " + lit(observerSessionId))?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Ok(value = "")
  }
  return Ok(value = col(CloudAgents.Sqlite.getRowArrayValue(rows, 0), 0))
}

pub func saveObserverState(st: in ObserverState): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute("INSERT INTO ledger_observer (" + observerCols + ") VALUES (" + lit(st.sessionId) + ", " + lit(st.observerSessionId) + ", " + lit(st.cursorSeq) + ", " + lit(st.windowEnd) + ", " + lit(st.pending) + ", " + lit(st.passDay) + ", " + lit(st.passesToday) + ", " + lit(st.lastPassAt) + ", " + lit(st.configHash) + ", " + lit(st.lastError) + ") ON CONFLICT(session_id) DO UPDATE SET observer_session_id = excluded.observer_session_id, cursor_seq = excluded.cursor_seq, window_end = excluded.window_end, pending = excluded.pending, pass_day = excluded.pass_day, passes_today = excluded.passes_today, last_pass_at = excluded.last_pass_at, config_hash = excluded.config_hash, last_error = excluded.last_error")?
  return Ok(())
}

/// What a container needs to know when it is an observer: the session it
/// observes and the repo access its profile grants.
pub record ObserverRunInfo {
  pub observedSessionId: String
  pub repoAccess: String
}

/// The observer facts for a session about to run, or None for any session that
/// isn't an observer.
pub func observerRunInfo(sessionId: in String): Result[Option[ObserverRunInfo], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT o.session_id, COALESCE(st.repo_access, 'none') FROM ledger_observer o JOIN sessions t ON t.id = o.session_id LEFT JOIN ledger_observer_settings st ON st.profile_id = t.profile_id AND st.profile_id IN (SELECT id FROM profiles) WHERE o.observer_session_id = " + lit(sessionId) + " AND o.observer_session_id != ''")?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Ok(value = None)
  }
  val r = CloudAgents.Sqlite.getRowArrayValue(rows, 0)
  return Ok(value = Some(value = ObserverRunInfo(observedSessionId = col(r, 0), repoAccess = col(r, 1))))
}

/// The facts about a session the observer machinery needs, read without an
/// owner scope (callers are an authenticated container callback, a run hook
/// on the session's own request, or the operator's maintenance run).
pub record SessionRunFacts {
  pub sessionId: String
  pub userId: String
  pub repoUrl: String
  pub branch: String
  pub harness: String
  pub status: String
  pub profileId: String
  pub isArchived: String
  pub observesSessionId: String
  pub containerId: String
}

pub func sessionRunFacts(sessionId: in String): Result[Option[SessionRunFacts], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT id, user_id, repo_url, branch, harness, status, COALESCE(profile_id, ''), is_archived, observes_session_id, container_id FROM sessions WHERE id = " + lit(sessionId))?
  if CloudAgents.Sqlite.getRowArrayLength(rows) == 0 {
    return Ok(value = None)
  }
  val r = CloudAgents.Sqlite.getRowArrayValue(rows, 0)
  return Ok(
    value = Some(
      value = SessionRunFacts(
        sessionId = col(r, 0),
        userId = col(r, 1),
        repoUrl = col(r, 2),
        branch = col(r, 3),
        harness = col(r, 4),
        status = col(r, 5),
        profileId = col(r, 6),
        isArchived = col(r, 7),
        observesSessionId = col(r, 8),
        containerId = col(r, 9)
      )
    )
  )
}

/// Mark a freshly created session as the observer of `observedSessionId`, on
/// the observed session's profile (its credentials and network policy; the
/// container narrows everything else).
pub func linkObserverSession(
  observerSessionId: in String, observedSessionId: in String, profileId: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute("UPDATE sessions SET observes_session_id = " + lit(observedSessionId) + ", profile_id = " + lit(profileId) + " WHERE id = " + lit(observerSessionId))?
  return Ok(())
}

/// Remove an observer session's row (a replaced or orphaned observer).
pub func deleteObserverSessionRow(observerSessionId: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  if observerSessionId.length.toInt() == 0 {
    return Ok(())
  }
  CloudAgents.Sqlite.execute("DELETE FROM sessions WHERE id = " + lit(observerSessionId) + " AND observes_session_id != ''")?
  return Ok(())
}

/// Forget an observed session's observer (its session was deleted).
pub func deleteObserverState(sessionId: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute("DELETE FROM ledger_observer WHERE session_id = " + lit(sessionId))?
  return Ok(())
}

/// Ask for a pass. Idempotent: many asks before a pass runs make one pass.
pub func markObserverPending(sessionId: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute("INSERT INTO ledger_observer (" + observerCols + ") VALUES (" + lit(sessionId) + ", '', '', '', '1', '', '0', '', '', '') ON CONFLICT(session_id) DO UPDATE SET pending = '1'")?
  return Ok(())
}

/// Take the pending pass for a session: true for exactly one caller.
pub func claimObserverPass(sessionId: in String): Result[Bool, CloudAgents.Sqlite.DbError] {
  val changed = CloudAgents.Sqlite.execute("UPDATE ledger_observer SET pending = '0' WHERE session_id = " + lit(sessionId) + " AND pending = '1'")?
  return Ok(value = changed == 1)
}

/// Observed sessions with a pass waiting, the longest-waiting first.
pub func pendingObserverSessions(limit: in Int): Result[slice[String], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT o.session_id FROM ledger_observer o JOIN sessions s ON s.id = o.session_id WHERE o.pending = '1' AND s.is_archived = '0' ORDER BY CAST(COALESCE(NULLIF(o.last_pass_at, ''), '0') AS INTEGER), o.session_id LIMIT " + toString(limit))?
  var acc: slice[String] = []
  var i = 0
  while i < CloudAgents.Sqlite.getRowArrayLength(rows) {
    acc = acc.append(col(CloudAgents.Sqlite.getRowArrayValue(rows, i), 0))
    i = i + 1
  }
  return Ok(value = acc)
}

/// Mark a provisional observation as covered by a declared entry the agent
/// recorded later: no longer undeclared, and no longer awaiting review unless
/// the owner already reviewed it.
pub func applyRetroMatch(
  sessionId: in String, observedId: in String, declaredId: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val now = CloudAgents.Repository.nowMillis()
  CloudAgents.Sqlite.executeTransaction([ensureSessionSql(sessionId, now), bumpSeqSql(sessionId), "UPDATE ledger_entries SET matched_entry_id = " + lit(declaredId) + ", undeclared = 'false', provisional = 'false', severity = 'info', review_state = CASE WHEN review_state = 'pending' THEN 'not_required' ELSE review_state END, updated_seq = " + curSeqExpr(sessionId) + " WHERE session_id = " + lit(sessionId) + " AND id = " + lit(observedId)])?
  return Ok(())
}

/// A run ended: its mid-run observations are final now.
pub func settleProvisional(sessionId: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT COUNT(*) FROM ledger_entries WHERE session_id = " + lit(sessionId) + " AND provisional = 'true'")?
  if decimalToInt(col(CloudAgents.Sqlite.getRowArrayValue(rows, 0), 0)) == 0 {
    return Ok(())
  }
  val now = CloudAgents.Repository.nowMillis()
  CloudAgents.Sqlite.executeTransaction([ensureSessionSql(sessionId, now), bumpSeqSql(sessionId), "UPDATE ledger_entries SET provisional = 'false', updated_seq = " + curSeqExpr(sessionId) + " WHERE session_id = " + lit(sessionId) + " AND provisional = 'true'"])?
  return Ok(())
}

/// Every entry of a session for reconciliation: declared and observed, newest
/// first up to the cap (the window a candidate can match sits at the end).
pub func entriesForReconcile(sessionId: in String): Result[slice[LedgerEntry], CloudAgents.Sqlite.DbError] {
  return listEntries(sessionId)
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

/// Every pending review / blocking entry across `userId`'s sessions,
/// blocking first, then oldest first (bounded).
pub func inboxForUser(userId: in String): Result[slice[InboxEntry], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query("SELECT " + prefixedCols(entryCols, "e") + ", s.repo_url, s.branch FROM ledger_entries e JOIN sessions s ON s.id = e.session_id" + " WHERE s.user_id = " + lit(userId) + " AND e.review_state = 'pending' AND e.severity IN ('review', 'blocking')" + " ORDER BY CASE e.severity WHEN 'blocking' THEN 0 ELSE 1 END, e.created_at, e.id LIMIT 500")?
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
  return InboxEntry(ledgerEntry = rowToEntry(r), repoUrl = col(r, 33), branch = col(r, 34))
}
