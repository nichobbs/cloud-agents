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
import CloudAgents.Scope
import CloudAgents.Repository
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Schema
import CloudAgents.Ledger.Summary
import CloudAgents.Ledger.ObserverPolicy
import CloudAgents.PgStore.Ledger

/// The session's current change cursor ("0" before the first write).
pub func currentSeq(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[String, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.currentSeq(sessionId, sc)
}

// ── Items ─────────────────────────────────────────────────────────────────────
/// Row caps on the list/delta queries. `snapshot` falls back to a full
/// snapshot when a delta reaches one, so a capped delta never silently
/// skips rows past the client's advancing cursor.
pub val itemRowCap: Int = 1000

pub val entryRowCap: Int = 5000

pub val feedbackRowCap: Int = 2000

val itemCols = "session_id, item_id, title, url, state, blocked_by, blocked_reason, prerequisite_proposal, recommendation, pr_url, ord, created_at, updated_at, updated_seq"

/// A session's work items in batch order.
pub func listItems(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[slice[WorkItem], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.listItems(sessionId, sc)
}

/// Items changed strictly after cursor `after`.
pub func itemsChangedAfter(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, after: in String
): Result[slice[WorkItem], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.itemsChangedAfter(sessionId, sc, after)
}

pub func getItem(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, itemId: in String
): Result[Option[WorkItem], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.getItem(sessionId, sc, itemId)
}

/// Register (or refresh) items: a new id is inserted `queued` at the end of
/// the batch; an existing id only has a non-empty title / url updated (its
/// state is untouched). Parallel slices; returns how many were new.
pub func registerItems(
  sessionId: in String,
  sc: in CloudAgents.Scope.TenantScope,
  ids: in slice[String],
  titles: in slice[String],
  urls: in slice[String],
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.registerItems(sessionId, sc, ids, titles, urls)
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
  sc: in CloudAgents.Scope.TenantScope,
  updated: in WorkItem,
  readVersion: in String,
  fromState: in String,
  stateChanged: in Bool,
  actor: in String,
  reason: in String,
  auto: in AutoEntry,
  resolveBlockers: in Bool,
): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.applyItemUpdate(sessionId, sc, updated, readVersion, fromState, stateChanged, actor, reason, auto, resolveBlockers)
}

pub func listTransitions(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, itemId: in String
): Result[slice[WorkItemTransition], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.listTransitions(sessionId, sc, itemId)
}

// ── Entries ───────────────────────────────────────────────────────────────────
val entryCols = "id, session_id, item_id, kind, severity, declared_severity, summary, detail, options_json, chosen, rationale, recommendation, proceeding_with, reversible, files_json, tags_json, source, undeclared, matched_entry_id, origin, supersedes, transcript_seq, review_state, review_by, review_at, review_comment, created_at, created_seq, updated_seq, observed_from, confidence, evidence, provisional"

val entryOrder = " ORDER BY CAST(created_seq AS INTEGER), created_at, id"

/// Insert a fully decided entry (id / createdAt / seq fields are assigned
/// here) and return it as stored.
pub func insertEntry(
  sc: in CloudAgents.Scope.TenantScope, e: in LedgerEntry
): Result[LedgerEntry, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.insertEntry(sc, e)
}

pub func getEntry(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, entryId: in String
): Result[Option[LedgerEntry], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.getEntry(sessionId, sc, entryId)
}

/// A session's entries in creation order (bounded).
/// Past the cap these are the NEWEST entryRowCap entries (recent activity is
/// never the part dropped); countEntries says whether any were.
pub func listEntries(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[slice[LedgerEntry], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.listEntries(sessionId, sc)
}

/// The entries of this session whose `supersedes` names `entryId`.
pub func supersedingEntryIds(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, entryId: in String
): Result[slice[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.supersedingEntryIds(sessionId, sc, entryId)
}

pub func entriesChangedAfter(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, after: in String
): Result[slice[LedgerEntry], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.entriesChangedAfter(sessionId, sc, after)
}

/// Record a human review on an entry and the matching feedback row, in one
/// transaction. `reviewState` / `kind` are already validated.
pub func reviewEntry(
  sessionId: in String,
  sc: in CloudAgents.Scope.TenantScope,
  entry: in LedgerEntry,
  reviewState: in String,
  kind: in String,
  body: in String,
  by: in String,
): Result[Feedback, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.reviewEntry(sessionId, sc, entry, reviewState, kind, body, by)
}

// ── Feedback ──────────────────────────────────────────────────────────────────
val feedbackCols = "id, session_id, entry_id, item_id, kind, body, created_by, created_at, delivered_at, delivered_via, updated_seq"

/// Add session- or item-level feedback (kind / body already validated).
pub func addFeedback(
  sessionId: in String,
  sc: in CloudAgents.Scope.TenantScope,
  itemId: in String,
  kind: in String,
  body: in String,
  by: in String,
): Result[Feedback, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.addFeedback(sessionId, sc, itemId, kind, body, by)
}

/// A session's feedback, oldest first (bounded).
/// Past the cap these are the NEWEST feedbackRowCap rows, oldest first.
pub func listFeedback(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[slice[Feedback], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.listFeedback(sessionId, sc)
}

/// Feedback on one entry, oldest first.
pub func feedbackForEntry(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, entryId: in String
): Result[slice[Feedback], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.feedbackForEntry(sessionId, sc, entryId)
}

/// Row counts, to tell a capped list from a complete one.
pub func countItems(sessionId: in String, sc: in CloudAgents.Scope.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.countItems(sessionId, sc)
}

pub func countEntries(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.countEntries(sessionId, sc)
}

pub func countFeedback(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.countFeedback(sessionId, sc)
}

/// Progress and attention counts computed in SQL over every row, so the
/// numbers stay right however large the session grows (the lists shipped to
/// the client are capped; these are not).
pub func summaryOf(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, pendingFeedback: in Int
): Result[LedgerSummary, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.summaryOf(sessionId, sc, pendingFeedback)
}

pub func feedbackChangedAfter(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, after: in String
): Result[slice[Feedback], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.feedbackChangedAfter(sessionId, sc, after)
}

/// Undelivered feedback count.
pub func pendingFeedbackCount(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.pendingFeedbackCount(sessionId, sc)
}

/// Claim every undelivered feedback row for delivery via `via`, then return
/// exactly the claimed rows (oldest first).
/// A claimed feedback row with the summary of the entry it answers ("" for
/// session- or item-level feedback, or an entry that no longer exists).
pub record ClaimedFeedback {
  pub feedback: Feedback
  pub entrySummary: String
}

pub func collectFeedback(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, via: in String
): Result[slice[Feedback], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.collectFeedback(sessionId, sc, via)
}

/// Claim every undelivered feedback row and read it back, with the entry
/// summaries the agent sees, in one query: a failure after the claim
/// releases the batch, so nothing is ever marked delivered unseen.
pub func claimFeedback(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, via: in String
): Result[slice[ClaimedFeedback], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.claimFeedback(sessionId, sc, via)
}

/// Undo a claim whose rows never reached the agent (best-effort: a failure
/// here leaves them claimed, which the caller already reports as an error).
pub func releaseFeedbackBatch(sessionId: in String, sc: in CloudAgents.Scope.TenantScope, batch: in String): Unit {
  return CloudAgents.PgStore.Ledger.releaseFeedbackBatch(sessionId, sc, batch)
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
pub func syncRows(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[slice[SyncRow], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.syncRows(sessionId, sc)
}

pub func saveSyncRow(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, row: in SyncRow
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.saveSyncRow(sessionId, sc, row)
}

/// The session's GitHub-backed items it owns for syncing (see ownsIssueSql):
/// empty for an archived session, and without any issue a later session has
/// since taken over.
pub func ownedIssueItems(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[slice[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.ownedIssueItems(sessionId, sc)
}

/// Sessions with owned GitHub-backed items that need a sync pass: an item
/// changed since it was last synced (or never was), or it is waiting on
/// GitHub (blocked, needs_human, pr_open). Least recently attempted first,
/// so a session that keeps failing takes its turn and no more.
pub func sessionsToSync(limit: in Int): Result[slice[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.sessionsToSync(limit)
}

/// Record that a sync pass was attempted for the session (`error` "" when
/// it got as far as the items).
pub func markSyncAttempt(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, error: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.markSyncAttempt(sessionId, sc, error)
}

/// Take the session's sync lease until `now + leaseMillis`. Returns the lease
/// token to release with, or "" when another pass holds an unexpired lease.
/// One conditional UPDATE, so two callers can't both win (SQLite serializes
/// writers). A crashed pass's lease simply expires.
pub func acquireSyncLease(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, leaseMillis: in Long
): Result[String, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.acquireSyncLease(sessionId, sc, leaseMillis)
}

/// Give the lease back, if it is still the one `token` names.
pub func releaseSyncLease(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope, token: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.releaseSyncLease(sessionId, sc, token)
}

// ── Observer (Phase 4) ────────────────────────────────────────────────────────
/// A profile's observer settings, or None when it has none (not observed).
pub func observerSettingsFor(
  profileId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[Option[ObserverSettings], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.observerSettingsFor(profileId, sc)
}

pub func saveObserverSettings(
  profileId: in String, sc: in CloudAgents.Scope.TenantScope, st: in ObserverSettings
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.saveObserverSettings(profileId, sc, st)
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

/// The observer state of an observed session (an empty state when it has
/// never been observed).
pub func observerState(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[ObserverState, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.observerState(sessionId, sc)
}

/// The observed session an observer session works for ("" when `observerSessionId`
/// is not an observer).
pub func observedSessionOf(
  observerSessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[String, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.observedSessionOf(observerSessionId, sc)
}

pub func saveObserverState(
  sc: in CloudAgents.Scope.TenantScope, st: in ObserverState
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.saveObserverState(sc, st)
}

/// What a container needs to know when it is an observer: the session it
/// observes and the repo access its profile grants.
pub record ObserverRunInfo {
  pub observedSessionId: String
  pub repoAccess: String
}

/// The observer facts for a session about to run, or None for any session that
/// isn't an observer.
pub func observerRunInfo(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[Option[ObserverRunInfo], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.observerRunInfo(sessionId, sc)
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

pub func sessionRunFacts(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[Option[SessionRunFacts], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.sessionRunFacts(sessionId, sc)
}

/// Mark a freshly created session as the observer of `observedSessionId`, on
/// the observed session's profile (its credentials and network policy; the
/// container narrows everything else).
pub func linkObserverSession(
  observerSessionId: in String,
  sc: in CloudAgents.Scope.TenantScope,
  observedSessionId: in String,
  profileId: in String,
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.linkObserverSession(observerSessionId, sc, observedSessionId, profileId)
}

/// Remove an observer session's row (a replaced or orphaned observer).
pub func deleteObserverSessionRow(
  observerSessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.deleteObserverSessionRow(observerSessionId, sc)
}

/// Forget an observed session's observer (its session was deleted).
pub func deleteObserverState(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.deleteObserverState(sessionId, sc)
}

/// Ask for a pass. Idempotent: many asks before a pass runs make one pass.
pub func markObserverPending(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.markObserverPending(sessionId, sc)
}

/// Take the pending pass for a session: true for exactly one caller.
pub func claimObserverPass(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.claimObserverPass(sessionId, sc)
}

/// Observed sessions with a pass waiting, the longest-waiting first.
pub func pendingObserverSessions(limit: in Int): Result[slice[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.pendingObserverSessions(limit)
}

/// Mark a provisional observation as covered by a declared entry the agent
/// recorded later: no longer undeclared, and no longer awaiting review unless
/// the owner already reviewed it.
pub func applyRetroMatch(
  sessionId: in String,
  sc: in CloudAgents.Scope.TenantScope,
  observedId: in String,
  declaredId: in String,
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.applyRetroMatch(sessionId, sc, observedId, declaredId)
}

/// A run ended: its mid-run observations are final now.
pub func settleProvisional(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.settleProvisional(sessionId, sc)
}

/// Every entry of a session for reconciliation: declared and observed, newest
/// first up to the cap (the window a candidate can match sits at the end).
pub func entriesForReconcile(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[slice[LedgerEntry], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.entriesForReconcile(sessionId, sc)
}

// ── Repo policy cache ─────────────────────────────────────────────────────────
pub record PolicyCache {
  pub status: String
  pub json: String
  pub error: String
}

pub func getPolicyCache(
  sessionId: in String, sc: in CloudAgents.Scope.TenantScope
): Result[PolicyCache, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.getPolicyCache(sessionId, sc)
}

pub func setPolicyCache(
  sessionId: in String,
  sc: in CloudAgents.Scope.TenantScope,
  status: in String,
  json: in String,
  error: in String,
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.setPolicyCache(sessionId, sc, status, json, error)
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
pub func inboxForUser(sc: in CloudAgents.Scope.TenantScope): Result[slice[InboxEntry], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Ledger.inboxForUser(sc)
}

