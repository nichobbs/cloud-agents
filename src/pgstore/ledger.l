//! CloudAgents.PgStore.Ledger — the Postgres implementation of the session
//! ledger store (docs/session-ledger.md §4, docs/phase11-postgres-tenancy.md
//! §9 slices B/C). It mirrors the per-session functions of
//! `CloudAgents.Ledger.Store` with the same signatures and semantics, and
//! reuses that package's record types.
//!
//! It also holds the observer bookkeeping (docs/session-ledger.md §10): a
//! profile's observer settings, an observed session's observer state and
//! pending-pass flag, and the observer-session link.
//!
//! Every call runs in one unit scoped by the session's tenant (the route
//! scope in `SessionContext.tenantScope`), so row-level security confines it
//! to that tenant; within it, rows are keyed by session as on SQLite.
//!
//! Semantics carried over from the SQLite store:
//! - `ledger_sessions.seq` is bumped once by every write unit and stamped on
//!   every row the unit touches, so `after=<seq>` reads return exactly the
//!   rows changed since. The bump's row lock serialises a session's writers,
//!   which SQLite got from serialised writes;
//! - an item update is optimistic: it applies only if the item is still at
//!   the version the caller planned against, and its dependent writes
//!   (transition row, blocker resolution, automatic entry) happen only then.
//!   A conflict writes nothing;
//! - claiming feedback marks and reads the claimed rows in one unit, so
//!   feedback is never marked delivered without being returned;
//! - capped lists keep the newest rows, returned oldest first;
//! - timestamps read back as epoch milliseconds and an unset one as "";
//!   booleans as "true"/"false" (or "" when unset); counters and sequence
//!   numbers as decimal text;
//! - a GitHub issue is owned by the newest non-archived session in the
//!   tenant that registered it (ties by session id). Sessions in other
//!   tenants are invisible here, so each tenant manages its own label and
//!   comment on a shared issue.
//!
//! One representational difference: `confidence` is `numeric(4,3)`, so it
//! reads back normalised ("0.8" for "0.80") and rounded to three places.
//! Every consumer parses it as a number, truncated to hundredths.
@runtime_checked
package CloudAgents.PgStore.Ledger

import Std.Core
import Std.Uuid
import Db
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Schema
import CloudAgents.Ledger.Summary
import CloudAgents.Ledger.ObserverPolicy
import CloudAgents.Ledger.Store as LedgerStore

func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func now(): String {
  return CloudAgents.Repository.nowMillis()
}

func c(r: in DbRow, name: in String): String {
  return CloudAgents.PgStore.col(r, name)
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

/// `@pN` as a timestamp, or NULL when it is "".
func msOpt(n: in Int): String {
  return "(timestamptz 'epoch' + NULLIF(@p" + toString(n) + ", '')::bigint * interval '1 millisecond')"
}

func ms(col: in String, alias: in String): String {
  return CloudAgents.Pg.msOut(col) + " AS " + alias
}

/// SQL: `@pN` as a nullable number, NULL for "".
func numOpt(n: in Int, ty: in String): String {
  return "NULLIF(@p" + toString(n) + ", '')::" + ty
}

func firstCount(rows: in slice[DbRow]): Int {
  if rows.length == 0 {
    return 0
  }
  return CloudAgents.Repository.parseNatString(c(rows[0], "n"))
}

// ── Cursor ────────────────────────────────────────────────────────────────────
/// Create the session's ledger row if it has none.
func ensureSession(
  u: in CloudAgents.PgStore.PgUnit, sessionId: in String, ts: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.PgStore.ex(u, "INSERT INTO ledger_sessions (session_id, created_at) VALUES (@p0, " + CloudAgents.Pg.msIn(1) + ") ON CONFLICT (tenant_id, session_id) DO NOTHING", [sessionId, ts])?
  return Ok(value = ())
}

/// Bump the session's cursor for this unit and return the new value. The
/// row lock it takes is held to commit, serialising the session's writers.
func bump(
  u: in CloudAgents.PgStore.PgUnit, sessionId: in String, ts: in String
): Result[String, CloudAgents.Sqlite.DbError] {
  ensureSession(u, sessionId, ts)?
  val rows = CloudAgents.PgStore.q(u, "UPDATE ledger_sessions SET seq = seq + 1 WHERE session_id = @p0 RETURNING seq::text AS seq", [sessionId])?
  if rows.length == 0 {
    return Err(
      error = CloudAgents.Sqlite.ExecFailed(
        sql = "UPDATE ledger_sessions",
        message = "ledger session row missing after insert"
      )
    )
  }
  return Ok(value = c(rows[0], "seq"))
}

/// The session's current change cursor ("0" before the first write).
pub func currentSeq(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[String, CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT seq::text AS seq FROM ledger_sessions WHERE session_id = @p0", [sessionId])?
  if rows.length == 0 {
    return Ok(value = "0")
  }
  return Ok(value = c(rows[0], "seq"))
}

// ── Items ─────────────────────────────────────────────────────────────────────
func itemCols(): String {
  return "session_id, item_id, title, url, state, blocked_by, blocked_reason, prerequisite_proposal, recommendation, " +
    "pr_url, ord::text AS ord, " +
    ms("created_at", "created_at") +
    ", " +
    ms("updated_at", "updated_at") +
    ", updated_seq::text AS updated_seq"
}

// Qualified: the bare names would sort by the text-rendered output columns.
val itemOrder = " ORDER BY ledger_items.ord, ledger_items.item_id COLLATE \"C\""

func toItem(r: in DbRow): WorkItem {
  return WorkItem(
    id = c(r, "item_id"),
    sessionId = c(r, "session_id"),
    title = c(r, "title"),
    url = c(r, "url"),
    state = c(r, "state"),
    blockedBy = decodeStringList(c(r, "blocked_by")),
    blockedReason = c(r, "blocked_reason"),
    prerequisiteProposal = c(r, "prerequisite_proposal"),
    recommendation = c(r, "recommendation"),
    prUrl = c(r, "pr_url"),
    order = c(r, "ord"),
    createdAt = c(r, "created_at"),
    updatedAt = c(r, "updated_at"),
    updatedSeq = c(r, "updated_seq")
  )
}

func toItems(rows: in slice[DbRow]): slice[WorkItem] {
  var acc: slice[WorkItem] = []
  var i = 0
  while i < rows.length.toInt() {
    acc = acc.append(toItem(rows[i]))
    i = i + 1
  }
  return acc
}

/// A session's work items in batch order.
pub func listItems(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[WorkItem], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + itemCols() + " FROM ledger_items WHERE session_id = @p0" + itemOrder + " LIMIT " + toString(LedgerStore.itemRowCap), [sessionId])?
  return Ok(value = toItems(rows))
}

/// Items changed strictly after cursor `after`.
pub func itemsChangedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, after: in String
): Result[slice[WorkItem], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + itemCols() + " FROM ledger_items WHERE session_id = @p0 AND updated_seq > @p1::bigint" + itemOrder + " LIMIT " + toString(LedgerStore.itemRowCap), [sessionId, after])?
  return Ok(value = toItems(rows))
}

pub func getItem(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, itemId: in String
): Result[Option[WorkItem], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + itemCols() + " FROM ledger_items WHERE session_id = @p0 AND item_id = @p1", [sessionId, itemId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toItem(rows[0])))
}

/// Register (or refresh) items: a new id is inserted `queued` at the end of
/// the batch; an existing id only has a non-empty title / url updated (its
/// state is untouched). Parallel slices; returns how many were new.
pub func registerItems(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  ids: in slice[String],
  titles: in slice[String],
  urls: in slice[String],
): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ts = now()
  val seq = bump(u, sessionId, ts)?
  var added = 0
  var i = 0
  while i < ids.length.toInt() {
    val id = ids[i]
    val existing = CloudAgents.PgStore.q(u, "SELECT 1 AS one FROM ledger_items WHERE session_id = @p0 AND item_id = @p1", [sessionId, id])?
    if existing.length > 0 {
      if titles[i].length.toInt() > 0 or urls[i].length.toInt() > 0 {
        CloudAgents.PgStore.ex(u, "UPDATE ledger_items SET title = CASE WHEN @p2 = '' THEN title ELSE @p2 END, " + "url = CASE WHEN @p3 = '' THEN url ELSE @p3 END, updated_at = " + CloudAgents.Pg.msIn(4) + ", updated_seq = @p5::bigint WHERE session_id = @p0 AND item_id = @p1", [sessionId, id, titles[i], urls[i], ts, seq])?
      }
    } else {
      // A ref-derived URL is only a default for a new item: re-registering
      // with no url keeps whatever the item already has.
      var url = urls[i]
      if url.length.toInt() == 0 {
        url = urlForItemRef(id)
      }
      CloudAgents.PgStore.ex(u, "INSERT INTO ledger_items (session_id, item_id, title, url, state, ord, created_at, updated_at, updated_seq) " + "VALUES (@p0, @p1, @p2, @p3, 'queued', (SELECT count(*) FROM ledger_items WHERE session_id = @p0), " + CloudAgents.Pg.msIn(4) + ", " + CloudAgents.Pg.msIn(4) + ", @p5::bigint)", [sessionId, id, titles[i], url, ts, seq])?
      added = added + 1
    }
    i = i + 1
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = added)
}

/// Apply a planned item update. `readVersion` is the item's `updatedSeq`
/// the plan was computed against. Returns true when applied, false on a
/// concurrent change (nothing written — re-read and re-plan).
pub func applyItemUpdate(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  updated: in WorkItem,
  readVersion: in String,
  fromState: in String,
  stateChanged: in Bool,
  actor: in String,
  reason: in String,
  auto: in LedgerStore.AutoEntry,
  resolveBlockers: in Bool,
): Result[Bool, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ts = now()
  val seq = bump(u, sessionId, ts)?
  val applied = CloudAgents.PgStore.ex(u, "UPDATE ledger_items SET state = @p2, blocked_by = @p3, blocked_reason = @p4, prerequisite_proposal = @p5, " + "recommendation = @p6, pr_url = @p7, updated_at = " + CloudAgents.Pg.msIn(8) + ", updated_seq = @p9::bigint " + "WHERE session_id = @p0 AND item_id = @p1 AND updated_seq = " + numOpt(10, "bigint"), [sessionId, updated.id, updated.state, encodeStringList(updated.blockedBy), updated.blockedReason, updated.prerequisiteProposal, updated.recommendation, updated.prUrl, ts, seq, readVersion])?
  if applied == 0 {
    // Released without commit: the cursor bump is rolled back too.
    return Ok(value = false)
  }
  if stateChanged {
    CloudAgents.PgStore.ex(u, "INSERT INTO ledger_transitions (id, session_id, item_id, from_state, to_state, actor, reason, at, seq) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6, " + CloudAgents.Pg.msIn(7) + ", @p8::bigint)", [newId(), sessionId, updated.id, fromState, updated.state, actor, reason, ts, seq])?
  }
  if resolveBlockers {
    CloudAgents.PgStore.ex(u, "UPDATE ledger_entries SET review_state = 'resolved', review_at = " + CloudAgents.Pg.msIn(2) + ", updated_seq = @p3::bigint " + "WHERE session_id = @p0 AND item_id = @p1 AND origin = 'transition' AND review_state = 'pending'", [sessionId, updated.id, ts, seq])?
  }
  if auto.summary.length.toInt() > 0 {
    // Every automatic entry is born of this transition, whoever the actor
    // was, so a later leave-blocked transition must be able to resolve it.
    var review = "pending"
    if auto.severity == "info" {
      review = "not_required"
    }
    CloudAgents.PgStore.ex(u, "INSERT INTO ledger_entries (id, session_id, item_id, kind, severity, summary, detail, recommendation, source, " + "undeclared, origin, review_state, created_at, created_seq, updated_seq) VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6, @p7, @p8, " + "false, 'transition', @p9, " + CloudAgents.Pg.msIn(10) + ", @p11::bigint, @p11::bigint)", [newId(), sessionId, updated.id, auto.kind, auto.severity, auto.summary, auto.detail, updated.recommendation, auto.source, review, ts, seq])?
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = true)
}

pub func listTransitions(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, itemId: in String
): Result[slice[WorkItemTransition], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT item_id, from_state, to_state, actor, reason, " + ms("at", "at") + " FROM ledger_transitions " + "WHERE session_id = @p0 AND item_id = @p1 ORDER BY seq, ledger_transitions.at LIMIT 500", [sessionId, itemId])?
  var acc: slice[WorkItemTransition] = []
  var i = 0
  while i < rows.length.toInt() {
    val r = rows[i]
    acc = acc.append(
      WorkItemTransition(
        itemId = c(r, "item_id"),
        fromState = c(r, "from_state"),
        toState = c(r, "to_state"),
        actor = c(r, "actor"),
        reason = c(r, "reason"),
        at = c(r, "at")
      )
    )
    i = i + 1
  }
  return Ok(value = acc)
}

// ── Entries ───────────────────────────────────────────────────────────────────
/// The entry columns in their text forms, read from alias `a`.
func entryCols(a: in String): String {
  val p = a + "."
  return p + "id, " + p + "session_id, " + p + "item_id, " + p + "kind, " + p + "severity, " + p + "declared_severity, " +
    p +
    "summary, " +
    p +
    "detail, " +
    p +
    "options_json, " +
    p +
    "chosen, " +
    p +
    "rationale, " +
    p +
    "recommendation, " +
    p +
    "proceeding_with, " +
    p +
    "reversible::text AS reversible, " +
    p +
    "files_json, " +
    p +
    "tags_json, " +
    p +
    "source, " +
    p +
    "undeclared::text AS undeclared, " +
    p +
    "matched_entry_id, " +
    p +
    "origin, " +
    p +
    "supersedes, " +
    p +
    "transcript_seq::text AS transcript_seq, " +
    p +
    "review_state, " +
    p +
    "review_by, " +
    ms(p + "review_at", "review_at") +
    ", " +
    p +
    "review_comment, " +
    ms(p + "created_at", "created_at") +
    ", " +
    p +
    "created_seq::text AS created_seq, " +
    p +
    "updated_seq::text AS updated_seq, " +
    p +
    "observed_from::text AS observed_from, rtrim(rtrim(" +
    p +
    "confidence::text, '0'), '.') AS confidence, " +
    p +
    "evidence, " +
    p +
    "provisional::text AS provisional"
}

func entryOrder(a: in String): String {
  return " ORDER BY " + a + ".created_seq, " + a + ".created_at, " + a + ".id COLLATE \"C\""
}

func toEntry(r: in DbRow): LedgerEntry {
  return LedgerEntry(
    id = c(r, "id"),
    sessionId = c(r, "session_id"),
    itemId = c(r, "item_id"),
    kind = c(r, "kind"),
    severity = c(r, "severity"),
    declaredSeverity = c(r, "declared_severity"),
    summary = c(r, "summary"),
    detail = c(r, "detail"),
    optionsConsidered = decodeStringList(c(r, "options_json")),
    chosen = c(r, "chosen"),
    rationale = c(r, "rationale"),
    recommendation = c(r, "recommendation"),
    proceedingWith = c(r, "proceeding_with"),
    reversible = c(r, "reversible"),
    files = decodeStringList(c(r, "files_json")),
    tags = decodeStringList(c(r, "tags_json")),
    source = c(r, "source"),
    undeclared = c(r, "undeclared"),
    matchedEntryId = c(r, "matched_entry_id"),
    origin = c(r, "origin"),
    supersedes = c(r, "supersedes"),
    transcriptSeq = c(r, "transcript_seq"),
    reviewState = c(r, "review_state"),
    reviewBy = c(r, "review_by"),
    reviewAt = c(r, "review_at"),
    reviewComment = c(r, "review_comment"),
    createdAt = c(r, "created_at"),
    createdSeq = c(r, "created_seq"),
    updatedSeq = c(r, "updated_seq"),
    observedFrom = c(r, "observed_from"),
    confidence = c(r, "confidence"),
    evidence = c(r, "evidence"),
    provisional = c(r, "provisional")
  )
}

func toEntries(rows: in slice[DbRow]): slice[LedgerEntry] {
  var acc: slice[LedgerEntry] = []
  var i = 0
  while i < rows.length.toInt() {
    acc = acc.append(toEntry(rows[i]))
    i = i + 1
  }
  return acc
}

/// Insert a fully decided entry (id / createdAt / seq fields are assigned
/// here) and return it as stored.
pub func insertEntry(
  sc: in CloudAgents.Pg.TenantScope, e: in LedgerEntry
): Result[LedgerEntry, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val id = newId()
  val ts = now()
  val seq = bump(u, e.sessionId, ts)?
  val cols = "id, session_id, item_id, kind, severity, declared_severity, summary, detail, options_json, chosen, rationale, " +
    "recommendation, proceeding_with, reversible, files_json, tags_json, source, undeclared, matched_entry_id, origin, " +
    "supersedes, transcript_seq, review_state, created_at, created_seq, updated_seq, observed_from, confidence, evidence, provisional"
  val values = "@p0, @p1, @p2, @p3, @p4, @p5, @p6, @p7, @p8, @p9, @p10, @p11, @p12, " + numOpt(13, "boolean") +
    ", @p14, @p15, @p16, COALESCE(" +
    numOpt(17, "boolean") +
    ", false), @p18, @p19, @p20, " +
    numOpt(21, "bigint") +
    ", @p22, " +
    CloudAgents.Pg.msIn(23) +
    ", @p24::bigint, @p24::bigint, " +
    numOpt(25, "bigint") +
    ", " +
    numOpt(26, "numeric") +
    ", @p27, " +
    numOpt(28, "boolean")
  val params: slice[String] = [
    id,
    e.sessionId,
    e.itemId,
    e.kind,
    e.severity,
    e.declaredSeverity,
    e.summary,
    e.detail,
    encodeStringList(e.optionsConsidered),
    e.chosen,
    e.rationale,
    e.recommendation,
    e.proceedingWith,
    e.reversible,
    encodeStringList(e.files),
    encodeStringList(e.tags),
    e.source,
    e.undeclared,
    e.matchedEntryId,
    e.origin,
    e.supersedes,
    e.transcriptSeq,
    e.reviewState,
    ts,
    seq,
    e.observedFrom,
    e.confidence,
    e.evidence,
    e.provisional
  ]
  CloudAgents.PgStore.ex(u, "INSERT INTO ledger_entries (" + cols + ") VALUES (" + values + ")", params)?
  val rows = CloudAgents.PgStore.q(u, "SELECT " + entryCols("e") + " FROM ledger_entries e WHERE e.session_id = @p0 AND e.id = @p1", [e.sessionId, id])?
  if rows.length == 0 {
    return Err(
      error = CloudAgents.Sqlite.ExecFailed(sql = "SELECT ledger entry", message = "entry vanished after insert")
    )
  }
  val stored = toEntry(rows[0])
  CloudAgents.PgStore.commit(u)?
  return Ok(value = stored)
}

pub func getEntry(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, entryId: in String
): Result[Option[LedgerEntry], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + entryCols("e") + " FROM ledger_entries e WHERE e.session_id = @p0 AND e.id = @p1", [sessionId, entryId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toEntry(rows[0])))
}

/// A session's entries in creation order (bounded).
/// Past the cap these are the NEWEST entryRowCap entries (recent activity is
/// never the part dropped); countEntries says whether any were.
pub func listEntries(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[LedgerEntry], CloudAgents.Sqlite.DbError] {
  val newest = "SELECT * FROM ledger_entries WHERE session_id = @p0 " +
    "ORDER BY created_seq DESC, created_at DESC, id COLLATE \"C\" DESC LIMIT " +
    toString(LedgerStore.entryRowCap)
  val rows = query(sc, "SELECT " + entryCols("e") + " FROM (" + newest + ") e" + entryOrder("e"), [sessionId])?
  return Ok(value = toEntries(rows))
}

/// The entries of this session whose `supersedes` names `entryId`.
pub func supersedingEntryIds(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, entryId: in String
): Result[slice[String], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT e.id FROM ledger_entries e WHERE e.session_id = @p0 AND e.supersedes = @p1" + entryOrder("e"), [sessionId, entryId])?
  var acc: slice[String] = []
  var i = 0
  while i < rows.length.toInt() {
    acc = acc.append(c(rows[i], "id"))
    i = i + 1
  }
  return Ok(value = acc)
}

pub func entriesChangedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, after: in String
): Result[slice[LedgerEntry], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + entryCols("e") + " FROM ledger_entries e WHERE e.session_id = @p0 AND e.updated_seq > @p1::bigint" + entryOrder("e") + " LIMIT " + toString(LedgerStore.entryRowCap), [sessionId, after])?
  return Ok(value = toEntries(rows))
}

/// Record a human review on an entry and the matching feedback row, in one
/// unit. `reviewState` / `kind` are already validated.
pub func reviewEntry(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  entry: in LedgerEntry,
  reviewState: in String,
  kind: in String,
  body: in String,
  by: in String,
): Result[Feedback, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ts = now()
  val seq = bump(u, sessionId, ts)?
  CloudAgents.PgStore.ex(u, "UPDATE ledger_entries SET review_state = @p2, review_by = @p3, review_at = " + CloudAgents.Pg.msIn(4) + ", review_comment = @p5, updated_seq = @p6::bigint WHERE session_id = @p0 AND id = @p1", [sessionId, entry.id, reviewState, by, ts, body, seq])?
  val fb = insertFeedback(u, sessionId, entry.id, entry.itemId, kind, body, by, ts, seq)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = fb)
}

// ── Feedback ──────────────────────────────────────────────────────────────────
func feedbackCols(a: in String): String {
  val p = a + "."
  return p + "id, " + p + "session_id, " + p + "entry_id, " + p + "item_id, " + p + "kind, " + p + "body, " + p +
    "created_by, " +
    ms(p + "created_at", "created_at") +
    ", " +
    ms(p + "delivered_at", "delivered_at") +
    ", " +
    p +
    "delivered_via, " +
    p +
    "updated_seq::text AS updated_seq"
}

func feedbackOrder(a: in String): String {
  return " ORDER BY " + a + ".created_at, " + a + ".id COLLATE \"C\""
}

func toFeedback(r: in DbRow): Feedback {
  return Feedback(
    id = c(r, "id"),
    sessionId = c(r, "session_id"),
    entryId = c(r, "entry_id"),
    itemId = c(r, "item_id"),
    kind = c(r, "kind"),
    body = c(r, "body"),
    createdBy = c(r, "created_by"),
    createdAt = c(r, "created_at"),
    deliveredAt = c(r, "delivered_at"),
    deliveredVia = c(r, "delivered_via"),
    updatedSeq = c(r, "updated_seq")
  )
}

func toFeedbackList(rows: in slice[DbRow]): slice[Feedback] {
  var acc: slice[Feedback] = []
  var i = 0
  while i < rows.length.toInt() {
    acc = acc.append(toFeedback(rows[i]))
    i = i + 1
  }
  return acc
}

func insertFeedback(
  u: in CloudAgents.PgStore.PgUnit,
  sessionId: in String,
  entryId: in String,
  itemId: in String,
  kind: in String,
  body: in String,
  by: in String,
  ts: in String,
  seq: in String,
): Result[Feedback, CloudAgents.Sqlite.DbError] {
  val id = newId()
  CloudAgents.PgStore.ex(u, "INSERT INTO ledger_feedback (id, session_id, entry_id, item_id, kind, body, created_by, created_at, updated_seq) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6, " + CloudAgents.Pg.msIn(7) + ", @p8::bigint)", [id, sessionId, entryId, itemId, kind, body, by, ts, seq])?
  val rows = CloudAgents.PgStore.q(u, "SELECT " + feedbackCols("f") + " FROM ledger_feedback f WHERE f.session_id = @p0 AND f.id = @p1", [sessionId, id])?
  if rows.length == 0 {
    return Err(
      error = CloudAgents.Sqlite.ExecFailed(
        sql = "SELECT ledger feedback",
        message = "feedback vanished after insert"
      )
    )
  }
  return Ok(value = toFeedback(rows[0]))
}

/// Add session- or item-level feedback (kind / body already validated).
pub func addFeedback(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  itemId: in String,
  kind: in String,
  body: in String,
  by: in String,
): Result[Feedback, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ts = now()
  val seq = bump(u, sessionId, ts)?
  val fb = insertFeedback(u, sessionId, "", itemId, kind, body, by, ts, seq)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = fb)
}

/// A session's feedback, oldest first (bounded).
/// Past the cap these are the NEWEST feedbackRowCap rows, oldest first.
pub func listFeedback(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[Feedback], CloudAgents.Sqlite.DbError] {
  val newest = "SELECT * FROM ledger_feedback WHERE session_id = @p0 ORDER BY created_at DESC, id COLLATE \"C\" DESC LIMIT " +
    toString(LedgerStore.feedbackRowCap)
  val rows = query(sc, "SELECT " + feedbackCols("f") + " FROM (" + newest + ") f" + feedbackOrder("f"), [sessionId])?
  return Ok(value = toFeedbackList(rows))
}

/// Feedback on one entry, oldest first.
pub func feedbackForEntry(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, entryId: in String
): Result[slice[Feedback], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + feedbackCols("f") + " FROM ledger_feedback f WHERE f.session_id = @p0 AND f.entry_id = @p1" + feedbackOrder("f"), [sessionId, entryId])?
  return Ok(value = toFeedbackList(rows))
}

pub func feedbackChangedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, after: in String
): Result[slice[Feedback], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + feedbackCols("f") + " FROM ledger_feedback f WHERE f.session_id = @p0 AND f.updated_seq > @p1::bigint" + feedbackOrder("f") + " LIMIT " + toString(LedgerStore.feedbackRowCap), [sessionId, after])?
  return Ok(value = toFeedbackList(rows))
}

/// Row counts, to tell a capped list from a complete one.
pub func countItems(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Sqlite.DbError] {
  return countWhere(sc, "ledger_items", sessionId, "")
}

pub func countEntries(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Sqlite.DbError] {
  return countWhere(sc, "ledger_entries", sessionId, "")
}

pub func countFeedback(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Sqlite.DbError] {
  return countWhere(sc, "ledger_feedback", sessionId, "")
}

/// Undelivered feedback count.
pub func pendingFeedbackCount(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Int, CloudAgents.Sqlite.DbError] {
  return countWhere(sc, "ledger_feedback", sessionId, " AND delivered_at IS NULL")
}

func countWhere(
  sc: in CloudAgents.Pg.TenantScope, table: in String, sessionId: in String, extra: in String
): Result[Int, CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT count(*)::text AS n FROM " + table + " WHERE session_id = @p0" + extra, [sessionId])?
  return Ok(value = firstCount(rows))
}

/// Progress and attention counts computed in SQL over every row, so the
/// numbers stay right however large the session grows.
pub func summaryOf(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, pendingFeedback: in Int
): Result[LedgerSummary, CloudAgents.Sqlite.DbError] {
  val pending = "review_state = 'pending' AND severity IN ('review', 'blocking')"
  val sql = "SELECT " + "(SELECT count(*) FROM ledger_items WHERE session_id = @p0)::text AS total, " +
    stateCount("queued") +
    stateCount("in_progress") +
    stateCount("pr_open") +
    stateCount("done") +
    stateCount("blocked") +
    stateCount("needs_human") +
    stateCount("skipped") +
    "(SELECT count(*) FROM ledger_entries WHERE session_id = @p0 AND " +
    pending +
    ")::text AS pending_review, " +
    "(SELECT count(*) FROM ledger_entries WHERE session_id = @p0 AND " +
    pending +
    " AND severity = 'blocking')::text AS blocking, " +
    "(SELECT count(*) FROM ledger_entries WHERE session_id = @p0 AND undeclared)::text AS undeclared, " +
    CloudAgents.Pg.msOut(
      "GREATEST((SELECT max(created_at) FROM ledger_entries WHERE session_id = @p0), " +
        "(SELECT max(updated_at) FROM ledger_items WHERE session_id = @p0))"
    ) +
    " AS last_activity"
  val rows = query(sc, sql, [sessionId])?
  val r = rows[0]
  return Ok(
    value = LedgerSummary(
      sessionId = sessionId,
      total = c(r, "total"),
      queued = c(r, "queued"),
      inProgress = c(r, "in_progress"),
      prOpen = c(r, "pr_open"),
      done = c(r, "done"),
      blocked = c(r, "blocked"),
      needsHuman = c(r, "needs_human"),
      skipped = c(r, "skipped"),
      pendingReview = c(r, "pending_review"),
      blockingCount = c(r, "blocking"),
      undeclaredCount = c(r, "undeclared"),
      pendingFeedback = toString(pendingFeedback),
      lastActivityAt = c(r, "last_activity")
    )
  )
}

// A literal state name, never user input.
func stateCount(state: in String): String {
  return "(SELECT count(*) FROM ledger_items WHERE session_id = @p0 AND state = '" + state + "')::text AS " + state +
    ", "
}

/// Claim every undelivered feedback row for delivery via `via`, then return
/// exactly the claimed rows (oldest first).
pub func collectFeedback(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, via: in String
): Result[slice[Feedback], CloudAgents.Sqlite.DbError] {
  val claimed = claimFeedback(sessionId, sc, via)?
  var acc: slice[Feedback] = []
  var i = 0
  while i < claimed.length.toInt() {
    acc = acc.append(claimed[i].feedback)
    i = i + 1
  }
  return Ok(value = acc)
}

/// Claim every undelivered feedback row and read it back, with the summary
/// of the entry each answers, in one unit: if the read fails the claim is
/// rolled back, so nothing is ever marked delivered unseen.
pub func claimFeedback(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, via: in String
): Result[slice[LedgerStore.ClaimedFeedback], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ts = now()
  val batch = newId()
  val seq = bump(u, sessionId, ts)?
  CloudAgents.PgStore.ex(u, "UPDATE ledger_feedback SET delivered_at = " + CloudAgents.Pg.msIn(1) + ", delivered_via = @p2, delivery_batch = @p3, " + "updated_seq = @p4::bigint WHERE session_id = @p0 AND delivered_at IS NULL", [sessionId, ts, via, batch, seq])?
  val rows = CloudAgents.PgStore.q(u, "SELECT " + feedbackCols("f") + ", COALESCE(e.summary, '') AS entry_summary FROM ledger_feedback f " + "LEFT JOIN ledger_entries e ON e.session_id = f.session_id AND e.id = f.entry_id " + "WHERE f.session_id = @p0 AND f.delivery_batch = @p1" + feedbackOrder("f"), [sessionId, batch])?
  var acc: slice[LedgerStore.ClaimedFeedback] = []
  var i = 0
  while i < rows.length.toInt() {
    acc = acc.append(
      LedgerStore.ClaimedFeedback(feedback = toFeedback(rows[i]), entrySummary = c(rows[i], "entry_summary"))
    )
    i = i + 1
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = acc)
}

/// Undo a claim whose rows never reached the agent (best-effort: a failure
/// here leaves them claimed, which the caller already reports as an error).
pub func releaseFeedbackBatch(sessionId: in String, sc: in CloudAgents.Pg.TenantScope, batch: in String): Unit {
  match releaseBatch(sessionId, sc, batch) {
    case Ok(_) -> ()
    case Err(e) -> println(
      "WARNING: releasing ledger feedback batch " + batch + " failed: " +
        CloudAgents.Sqlite.dbErrorMessage(e)
    )
  }
}

func releaseBatch(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, batch: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val seq = bump(u, sessionId, now())?
  CloudAgents.PgStore.ex(u, "UPDATE ledger_feedback SET delivered_at = NULL, delivered_via = '', delivery_batch = '', updated_seq = @p2::bigint " + "WHERE session_id = @p0 AND delivery_batch = @p1", [sessionId, batch, seq])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

// ── GitHub sync state ─────────────────────────────────────────────────────────
/// Every item's sync row for a session (items never synced have none).
pub func syncRows(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[LedgerStore.SyncRow], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT item_id, synced_label, comment_id, comment_hash, last_error, " + ms("synced_at", "synced_at") + ", " + ms("attempted_at", "attempted_at") + " FROM ledger_github_sync WHERE session_id = @p0 ORDER BY item_id COLLATE \"C\"", [sessionId])?
  var acc: slice[LedgerStore.SyncRow] = []
  var i = 0
  while i < rows.length.toInt() {
    val r = rows[i]
    acc = acc.append(
      LedgerStore.SyncRow(
        itemId = c(r, "item_id"),
        syncedLabel = c(r, "synced_label"),
        commentId = c(r, "comment_id"),
        commentHash = c(r, "comment_hash"),
        lastError = c(r, "last_error"),
        syncedAt = c(r, "synced_at"),
        attemptedAt = c(r, "attempted_at")
      )
    )
    i = i + 1
  }
  return Ok(value = acc)
}

pub func saveSyncRow(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, row: in LedgerStore.SyncRow
): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(sc, "INSERT INTO ledger_github_sync (session_id, item_id, synced_label, comment_id, comment_hash, last_error, synced_at, attempted_at) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, " + msOpt(6) + ", " + msOpt(7) + ") ON CONFLICT (tenant_id, session_id, item_id) DO UPDATE SET " + "synced_label = excluded.synced_label, comment_id = excluded.comment_id, comment_hash = excluded.comment_hash, " + "last_error = excluded.last_error, synced_at = excluded.synced_at, attempted_at = excluded.attempted_at", [sessionId, row.itemId, row.syncedLabel, row.commentId, row.commentHash, row.lastError, row.syncedAt, row.attemptedAt])?
  return Ok(value = ())
}

/// The session's GitHub-backed items it owns for syncing: the newest
/// non-archived session in the tenant to register an issue owns it (ties by
/// session id). Empty for an archived session.
pub func ownedIssueItems(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[String], CloudAgents.Sqlite.DbError] {
  val sql = "SELECT i.item_id FROM ledger_items i JOIN sessions s ON s.id = i.session_id " +
    "WHERE i.session_id = @p0 AND i.item_id LIKE 'gh:%' AND NOT s.is_archived AND NOT EXISTS (" +
    "SELECT 1 FROM ledger_items o JOIN sessions os ON os.id = o.session_id " +
    "WHERE o.item_id = i.item_id AND o.session_id <> i.session_id AND NOT os.is_archived AND " +
    "(o.created_at > i.created_at OR (o.created_at = i.created_at AND o.session_id COLLATE \"C\" > i.session_id COLLATE \"C\"))) " +
    "ORDER BY i.ord, i.item_id COLLATE \"C\""
  val rows = query(sc, sql, [sessionId])?
  var acc: slice[String] = []
  var i = 0
  while i < rows.length.toInt() {
    acc = acc.append(c(rows[i], "item_id"))
    i = i + 1
  }
  return Ok(value = acc)
}

/// Record that a sync pass was attempted for the session (`error` "" when
/// it got as far as the items).
pub func markSyncAttempt(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, error: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(sc, "INSERT INTO ledger_github_sync_runs (session_id, attempted_at, last_error) VALUES (@p0, " + CloudAgents.Pg.msIn(1) + ", @p2) " + "ON CONFLICT (tenant_id, session_id) DO UPDATE SET attempted_at = excluded.attempted_at, last_error = excluded.last_error", [sessionId, now(), error])?
  return Ok(value = ())
}

/// Take the session's sync lease until `now + leaseMillis`. Returns the lease
/// token to release with, or "" when another pass holds an unexpired lease.
/// One conditional UPDATE under the row lock, so two callers can't both win.
/// A crashed pass's lease simply expires.
pub func acquireSyncLease(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, leaseMillis: in Long
): Result[String, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val t = CloudAgents.Repository.nowMillisLong()
  val until = toString(t + leaseMillis)
  CloudAgents.PgStore.ex(u, "INSERT INTO ledger_github_sync_runs (session_id) VALUES (@p0) ON CONFLICT (tenant_id, session_id) DO NOTHING", [sessionId])?
  val changed = CloudAgents.PgStore.ex(u, "UPDATE ledger_github_sync_runs SET lease_until = " + CloudAgents.Pg.msIn(1) + " WHERE session_id = @p0 AND (lease_until IS NULL OR lease_until <= " + CloudAgents.Pg.msIn(2) + ")", [sessionId, until, toString(t)])?
  CloudAgents.PgStore.commit(u)?
  if changed == 1 {
    return Ok(value = until)
  }
  return Ok(value = "")
}

/// Give the lease back, if it is still the one `token` names.
pub func releaseSyncLease(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, token: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  if token.length.toInt() == 0 {
    return Ok(value = ())
  }
  exec(sc, "UPDATE ledger_github_sync_runs SET lease_until = NULL WHERE session_id = @p0 AND lease_until = " + CloudAgents.Pg.msIn(1), [sessionId, token])?
  return Ok(value = ())
}

// ── Observer reconciliation ───────────────────────────────────────────────────
/// Mark a provisional observation as covered by a declared entry the agent
/// recorded later: no longer undeclared, and no longer awaiting review unless
/// the owner already reviewed it.
pub func applyRetroMatch(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  observedId: in String,
  declaredId: in String,
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val seq = bump(u, sessionId, now())?
  CloudAgents.PgStore.ex(u, "UPDATE ledger_entries SET matched_entry_id = @p2, undeclared = false, provisional = false, severity = 'info', " + "review_state = CASE WHEN review_state = 'pending' THEN 'not_required' ELSE review_state END, updated_seq = @p3::bigint " + "WHERE session_id = @p0 AND id = @p1", [sessionId, observedId, declaredId, seq])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

/// A run ended: its mid-run observations are final now.
pub func settleProvisional(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT count(*)::text AS n FROM ledger_entries WHERE session_id = @p0 AND provisional", [sessionId])?
  if firstCount(rows) == 0 {
    return Ok(value = ())
  }
  val seq = bump(u, sessionId, now())?
  CloudAgents.PgStore.ex(u, "UPDATE ledger_entries SET provisional = false, updated_seq = @p1::bigint WHERE session_id = @p0 AND provisional", [sessionId, seq])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

/// Every entry of a session for reconciliation (see listEntries).
pub func entriesForReconcile(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[LedgerEntry], CloudAgents.Sqlite.DbError] {
  return listEntries(sessionId, sc)
}

// ── Repo policy cache ─────────────────────────────────────────────────────────
pub func getPolicyCache(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[LedgerStore.PolicyCache, CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT policy_status, policy_json, policy_error FROM ledger_sessions WHERE session_id = @p0", [sessionId])?
  if rows.length == 0 {
    return Ok(value = LedgerStore.PolicyCache(status = "", json = "", error = ""))
  }
  val r = rows[0]
  return Ok(
    value = LedgerStore.PolicyCache(
      status = c(r, "policy_status"),
      json = c(r, "policy_json"),
      error = c(r, "policy_error")
    )
  )
}

pub func setPolicyCache(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  status: in String,
  json: in String,
  error: in String,
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  ensureSession(u, sessionId, now())?
  CloudAgents.PgStore.ex(u, "UPDATE ledger_sessions SET policy_status = @p1, policy_json = @p2, policy_error = @p3 WHERE session_id = @p0", [sessionId, status, json, error])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

// ── Cross-session inbox ───────────────────────────────────────────────────────
/// Every pending review / blocking entry across the caller's sessions in the
/// tenant, blocking first, then oldest first (bounded).
pub func inboxForUser(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[LedgerStore.InboxEntry], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + entryCols("e") + ", s.repo_url AS repo_url, s.branch AS branch FROM ledger_entries e " + "JOIN sessions s ON s.id = e.session_id WHERE s.user_id = @p0 AND e.review_state = 'pending' " + "AND e.severity IN ('review', 'blocking') ORDER BY CASE e.severity WHEN 'blocking' THEN 0 ELSE 1 END, e.created_at, e.id COLLATE \"C\" LIMIT 500", [sc.userId])?
  var acc: slice[LedgerStore.InboxEntry] = []
  var i = 0
  while i < rows.length.toInt() {
    acc = acc.append(
      LedgerStore.InboxEntry(
        ledgerEntry = toEntry(rows[i]),
        repoUrl = c(rows[i], "repo_url"),
        branch = c(rows[i], "branch")
      )
    )
    i = i + 1
  }
  return Ok(value = acc)
}

// ── Observer bookkeeping ─────────────────────────────────────────────────────
/// A profile's observer settings, or None when it has none (not observed).
/// Joined to profiles: settings outlive a deleted profile's row, and a
/// session left pointing at a deleted profile must not stay observed.
pub func observerSettingsFor(
  profileId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[ObserverSettings], CloudAgents.Sqlite.DbError] {
  if profileId.length.toInt() == 0 {
    return Ok(value = None)
  }
  val rows = query(sc, "SELECT s.enabled::text AS enabled, s.harness, s.model, s.repo_access, s.mid_run_minutes::text AS mid_run_minutes, " + "s.max_passes_per_day::text AS max_passes_per_day FROM ledger_observer_settings s JOIN profiles p ON p.id = s.profile_id " + "WHERE s.profile_id = @p0", [profileId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  val r = rows[0]
  return Ok(
    value = Some(
      value = ObserverSettings(
        enabled = c(r, "enabled"),
        harness = c(r, "harness"),
        model = c(r, "model"),
        repoAccess = c(r, "repo_access"),
        midRunMinutes = c(r, "mid_run_minutes"),
        maxPassesPerDay = c(r, "max_passes_per_day")
      )
    )
  )
}

/// Save a profile's observer settings (already validated).
pub func saveObserverSettings(
  profileId: in String, sc: in CloudAgents.Pg.TenantScope, st: in ObserverSettings
): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(sc, "INSERT INTO ledger_observer_settings (profile_id, enabled, harness, model, repo_access, mid_run_minutes, max_passes_per_day, updated_at) " + "VALUES (@p0, @p1::boolean, @p2, @p3, @p4, @p5::integer, @p6::integer, " + CloudAgents.Pg.msIn(7) + ") ON CONFLICT (tenant_id, profile_id) DO UPDATE SET " + "enabled = excluded.enabled, harness = excluded.harness, model = excluded.model, repo_access = excluded.repo_access, " + "mid_run_minutes = excluded.mid_run_minutes, max_passes_per_day = excluded.max_passes_per_day, updated_at = excluded.updated_at", [profileId, st.enabled, st.harness, st.model, st.repoAccess, st.midRunMinutes, st.maxPassesPerDay, now()])?
  return Ok(value = ())
}

func observerCols(): String {
  return "session_id, observer_session_id, cursor_seq::text AS cursor_seq, window_end::text AS window_end, " +
    "CASE WHEN pending THEN '1' ELSE '0' END AS pending, pass_day::text AS pass_day, passes_today::text AS passes_today, " +
    ms("last_pass_at", "last_pass_at") +
    ", config_key, last_error"
}

func toObserverState(r: in DbRow): LedgerStore.ObserverState {
  return LedgerStore.ObserverState(
    sessionId = c(r, "session_id"),
    observerSessionId = c(r, "observer_session_id"),
    cursorSeq = c(r, "cursor_seq"),
    windowEnd = c(r, "window_end"),
    pending = c(r, "pending"),
    passDay = c(r, "pass_day"),
    passesToday = c(r, "passes_today"),
    lastPassAt = c(r, "last_pass_at"),
    configHash = c(r, "config_key"),
    lastError = c(r, "last_error")
  )
}

/// The observer state of an observed session (an empty state when it has
/// never been observed).
pub func observerState(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[LedgerStore.ObserverState, CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + observerCols() + " FROM ledger_observer WHERE session_id = @p0", [sessionId])?
  if rows.length == 0 {
    return Ok(value = LedgerStore.emptyObserverState(sessionId))
  }
  return Ok(value = toObserverState(rows[0]))
}

/// The observed session an observer session works for ("" when
/// `observerSessionId` is not an observer).
pub func observedSessionOf(
  observerSessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[String, CloudAgents.Sqlite.DbError] {
  if observerSessionId.length.toInt() == 0 {
    return Ok(value = "")
  }
  val rows = query(sc, "SELECT session_id FROM ledger_observer WHERE observer_session_id = @p0", [observerSessionId])?
  if rows.length == 0 {
    return Ok(value = "")
  }
  return Ok(value = c(rows[0], "session_id"))
}

pub func saveObserverState(
  sc: in CloudAgents.Pg.TenantScope, st: in LedgerStore.ObserverState
): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(sc, "INSERT INTO ledger_observer (session_id, observer_session_id, cursor_seq, window_end, pending, pass_day, passes_today, last_pass_at, config_key, last_error) " + "VALUES (@p0, @p1, " + numOpt(2, "bigint") + ", " + numOpt(3, "bigint") + ", @p4 = '1', " + numOpt(5, "integer") + ", COALESCE(" + numOpt(6, "integer") + ", 0), " + msOpt(7) + ", @p8, @p9) " + "ON CONFLICT (tenant_id, session_id) DO UPDATE SET observer_session_id = excluded.observer_session_id, cursor_seq = excluded.cursor_seq, " + "window_end = excluded.window_end, pending = excluded.pending, pass_day = excluded.pass_day, passes_today = excluded.passes_today, " + "last_pass_at = excluded.last_pass_at, config_key = excluded.config_key, last_error = excluded.last_error", [st.sessionId, st.observerSessionId, st.cursorSeq, st.windowEnd, st.pending, st.passDay, st.passesToday, st.lastPassAt, st.configHash, st.lastError])?
  return Ok(value = ())
}

/// The observer facts for a session about to run, or None for any session
/// that isn't an observer.
pub func observerRunInfo(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[LedgerStore.ObserverRunInfo], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT o.session_id, COALESCE(st.repo_access, 'none') AS repo_access FROM ledger_observer o " + "JOIN sessions t ON t.id = o.session_id LEFT JOIN ledger_observer_settings st ON st.profile_id = t.profile_id " + "AND st.profile_id IN (SELECT id FROM profiles) WHERE o.observer_session_id = @p0 AND o.observer_session_id <> ''", [sessionId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(
    value = Some(
      value = LedgerStore.ObserverRunInfo(
        observedSessionId = c(rows[0], "session_id"),
        repoAccess = c(rows[0], "repo_access")
      )
    )
  )
}

/// The facts about a session the observer machinery needs, in the given
/// tenant, without an owner check (callers are an authenticated container
/// callback, a run hook on the session's own request, or a maintenance pass).
pub func sessionRunFacts(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[LedgerStore.SessionRunFacts], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT id, user_id, repo_url, branch, harness, status, profile_id, CASE WHEN is_archived THEN '1' ELSE '0' END AS is_archived, " + "observes_session_id, container_id FROM sessions WHERE id = @p0", [sessionId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  val r = rows[0]
  return Ok(
    value = Some(
      value = LedgerStore.SessionRunFacts(
        sessionId = c(r, "id"),
        userId = c(r, "user_id"),
        repoUrl = c(r, "repo_url"),
        branch = c(r, "branch"),
        harness = c(r, "harness"),
        status = c(r, "status"),
        profileId = c(r, "profile_id"),
        isArchived = c(r, "is_archived"),
        observesSessionId = c(r, "observes_session_id"),
        containerId = c(r, "container_id")
      )
    )
  )
}

/// Mark a freshly created session as the observer of `observedSessionId`, on
/// the observed session's profile.
pub func linkObserverSession(
  observerSessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  observedSessionId: in String,
  profileId: in String,
): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(sc, "UPDATE sessions SET observes_session_id = @p1, profile_id = @p2 WHERE id = @p0", [observerSessionId, observedSessionId, profileId])?
  return Ok(value = ())
}

/// Remove an observer session's row and its route (a replaced or orphaned
/// observer). Only ever an observer: an ordinary session is left alone.
pub func deleteObserverSessionRow(
  observerSessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Unit, CloudAgents.Sqlite.DbError] {
  if observerSessionId.length.toInt() == 0 {
    return Ok(value = ())
  }
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "DELETE FROM sessions WHERE id = @p0 AND observes_session_id <> ''", [observerSessionId])?
  if n > 0 {
    CloudAgents.PgStore.ex(u, "DELETE FROM session_routes WHERE session_id = @p0 AND tenant_id = @p1", [observerSessionId, sc.tenantId])?
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

/// Forget an observed session's observer (its session was deleted).
pub func deleteObserverState(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(sc, "DELETE FROM ledger_observer WHERE session_id = @p0", [sessionId])?
  return Ok(value = ())
}

/// Ask for a pass. Idempotent: many asks before a pass runs make one pass.
pub func markObserverPending(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(sc, "INSERT INTO ledger_observer (session_id, pending) VALUES (@p0, true) ON CONFLICT (tenant_id, session_id) DO UPDATE SET pending = true", [sessionId])?
  return Ok(value = ())
}

/// Take the pending pass for a session: true for exactly one caller.
pub func claimObserverPass(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Bool, CloudAgents.Sqlite.DbError] {
  val n = exec(sc, "UPDATE ledger_observer SET pending = false WHERE session_id = @p0 AND pending", [sessionId])?
  return Ok(value = n == 1)
}

// ─── Cross-tenant listings (docs/phase11-postgres-tenancy.md §5.3a) ─────────
func listSessionIds(fn: in String, limit: in Int): Result[slice[String], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT session_id FROM public." + fn + "(@p0::integer)", [toString(limit)])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[String] = []
  for r in rows {
    acc = acc.append(c(r, "session_id"))
  }
  return Ok(value = acc)
}

/// Sessions with owned GitHub-backed items that need a sync pass, in every
/// tenant, least recently attempted first (`list_sessions_to_sync`). Each
/// session's pass then takes its sync lease under the session's route scope.
pub func sessionsToSync(limit: in Int): Result[slice[String], CloudAgents.Sqlite.DbError] {
  return listSessionIds("list_sessions_to_sync", limit)
}

/// Observed sessions with a pass waiting, in every tenant, the
/// longest-waiting first (`list_observer_passes`). Each pass is then claimed
/// by `claimObserverPass` under the session's route scope.
pub func pendingObserverSessions(limit: in Int): Result[slice[String], CloudAgents.Sqlite.DbError] {
  return listSessionIds("list_observer_passes", limit)
}
