//! Live-Postgres tests for CloudAgents.PgStore.Ledger
//! (docs/phase11-postgres-tenancy.md §9 slices B/C): work items, entries,
//! feedback, GitHub sync state and the policy cache behave like the SQLite
//! ledger store and stay inside their tenant. Runs iff the Postgres DSNs are
//! set (see tests/pg_live_tests.l). Per-run unique ids keep it re-runnable.
@test_module
package CloudAgents.PgStoreLedgerTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore
import CloudAgents.PgStore.Ledger as Store
import CloudAgents.PgStore.Sessions as Sessions
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Store as SqliteLedger
import CloudAgents.SessionStore
import CloudAgents.Sqlite

func live(): Bool {
  val ok = CloudAgents.Pg.serviceConfigured() and
    Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "").length.toInt() > 0
  if ok {
    return true
  }
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: PgStore ledger tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
  return false
}

func migrate(): Unit {
  val conn = match CloudAgents.Pg.connectDsn(Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "")) {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(_) -> ()
    case Err(e) -> panic("migrate failed: " + CloudAgents.Pg.pgErrorMessage(e))
  }
}

func uid(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func fresh(): CloudAgents.Pg.TenantScope {
  return CloudAgents.Pg.personalScope("gh-pgl-" + uid())
}

func unit(r: in Result[Unit, DbError]): Unit {
  match r {
    case Ok(_) -> ()
    case Err(e) -> panic("store call failed: " + dbErrorMessage(e))
  }
}

func int(r: in Result[Int, DbError]): Int {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func str(r: in Result[String, DbError]): String {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func items(sid: in String, sc: in CloudAgents.Pg.TenantScope): slice[WorkItem] {
  return match Store.listItems(sid, sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
}

func entries(sid: in String, sc: in CloudAgents.Pg.TenantScope): slice[LedgerEntry] {
  return match Store.listEntries(sid, sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
}

func item(sid: in String, sc: in CloudAgents.Pg.TenantScope, id: in String): WorkItem {
  return match Store.getItem(sid, sc, id) {
    case Ok(Some(w)) -> w
    case Ok(None) -> panic("item " + id + " missing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
}

func ensureTenant(tenantId: in String): Unit {
  val conn = match CloudAgents.Pg.connectService() {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  match conn.execute("INSERT INTO tenants (id, name, kind) VALUES (@p0, @p0, 'personal') ON CONFLICT (id) DO NOTHING", [tenantId]) {
    case Ok(_) -> ()
    case Err(e) -> panic("tenant insert failed: " + e.message)
  }
}

func addSession(sid: in String, sc: in CloudAgents.Pg.TenantScope): Unit {
  ensureTenant(sc.tenantId)
  unit(
    Sessions.addSession(
      makeAgentSession(
        sessionId = sid,
        repoUrl = "https://github.com/acme/shop",
        branch = "main",
        containerId = "",
        harness = "claude",
        model = "",
        nativeSessionId = sid
      ),
      sc
    )
  )
}

func draft(
  sid: in String,
  itemId: in String,
  kind: in String,
  severity: in String,
  summary: in String,
  review: in String,
): LedgerEntry {
  return LedgerEntry(
    id = "",
    sessionId = sid,
    itemId = itemId,
    kind = kind,
    severity = severity,
    declaredSeverity = "",
    summary = summary,
    detail = "",
    optionsConsidered = [],
    chosen = "",
    rationale = "",
    recommendation = "",
    proceedingWith = "",
    reversible = "",
    files = [],
    tags = [],
    source = "declared",
    undeclared = "false",
    matchedEntryId = "",
    origin = "",
    supersedes = "",
    transcriptSeq = "",
    reviewState = review,
    reviewBy = "",
    reviewAt = "",
    reviewComment = "",
    createdAt = "",
    createdSeq = "",
    updatedSeq = "",
    observedFrom = "",
    confidence = "",
    evidence = "",
    provisional = ""
  )
}

func insert(sc: in CloudAgents.Pg.TenantScope, e: in LedgerEntry): LedgerEntry {
  return match Store.insertEntry(sc, e) { case Ok(v) -> v; case Err(err) -> panic(dbErrorMessage(err)) }
}

func noAuto(): SqliteLedger.AutoEntry {
  return SqliteLedger.AutoEntry(kind = "", severity = "", source = "", summary = "", detail = "")
}

func moved(w: in WorkItem, state: in String): WorkItem {
  return WorkItem(
    id = w.id,
    sessionId = w.sessionId,
    title = w.title,
    url = w.url,
    state = state,
    blockedBy = w.blockedBy,
    blockedReason = w.blockedReason,
    prerequisiteProposal = w.prerequisiteProposal,
    recommendation = "ask the owner",
    prUrl = w.prUrl,
    order = w.order,
    createdAt = w.createdAt,
    updatedAt = w.updatedAt,
    updatedSeq = w.updatedSeq
  )
}

test "items: register, refresh, batch order, cursor deltas" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  assertEqual(str(Store.currentSeq(sid, sc)), "0", "cursor before any write")
  assertEqualInt(
    int(
      Store.registerItems(
        sid,
        sc,
        ["gh:acme/shop#1", "local:docs", "gh:acme/shop#2"],
        ["One", "Docs", "Two"],
        ["", "", "https://example.test/2"]
      )
    ),
    3,
    "three new"
  )
  val first = items(sid, sc)
  assertEqualInt(first.length.toInt(), 3, "three items")
  assertEqual(
    first[0].id + "|" + first[1].id + "|" + first[2].id,
    "gh:acme/shop#1|local:docs|gh:acme/shop#2",
    "batch order"
  )
  assertEqual(first[0].order + first[1].order + first[2].order, "012", "ord as text")
  assertEqual(first[0].state, "queued", "new items are queued")
  assertEqual(first[0].url, "https://github.com/acme/shop/issues/1", "ref-derived url")
  assertEqual(first[2].url, "https://example.test/2", "explicit url")
  assertEqual(first[0].updatedSeq, "1", "stamped with the first cursor")
  assertEqual(first[0].createdAt, first[0].updatedAt, "created = updated")
  val cursor = str(Store.currentSeq(sid, sc))
  assertEqual(cursor, "1", "one write")
  // Refresh: a title change only; an empty url keeps the existing one.
  assertEqualInt(
    int(Store.registerItems(sid, sc, ["gh:acme/shop#1", "local:new"], ["One renamed", "New"], ["", ""])),
    1,
    "one new"
  )
  val one = item(sid, sc, "gh:acme/shop#1")
  assertEqual(one.title, "One renamed", "title refreshed")
  assertEqual(one.url, "https://github.com/acme/shop/issues/1", "url kept")
  assertEqual(item(sid, sc, "local:new").order, "3", "appended at the end")
  match Store.itemsChangedAfter(sid, sc, cursor) {
    case Ok(xs) -> assertEqualInt(xs.length.toInt(), 2, "only the refreshed and the new item")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqualInt(int(Store.countItems(sid, sc)), 4, "count")
  match Store.getItem(sid, sc, "gh:acme/shop#99") {
    case Ok(None) -> ()
    case _ -> assertTrue(false, "unknown item is None")
  }
  match Store.listItems(sid, fresh()) {
    case Ok(xs) -> assertEqualInt(xs.length.toInt(), 0, "another tenant sees no items")
    case Err(e) -> panic(dbErrorMessage(e))
  }
}

test "item updates are optimistic and write their transition, blocker and resolution together" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  int(Store.registerItems(sid, sc, ["gh:acme/shop#1"], ["One"], [""]))
  val w = item(sid, sc, "gh:acme/shop#1")
  val auto = SqliteLedger.AutoEntry(
    kind = "blocker",
    severity = "blocking",
    source = "system",
    summary = "Blocked: needs a schema",
    detail = "d"
  )
  val ok = match Store.applyItemUpdate(sid, sc, moved(w, "blocked"), w.updatedSeq, "queued", true, "agent", "needs a schema", auto, false) {
    case Ok(b) -> b
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertTrue(ok, "applied")
  val blocked = item(sid, sc, "gh:acme/shop#1")
  assertEqual(blocked.state, "blocked", "state written")
  assertEqual(blocked.recommendation, "ask the owner", "fields written")
  match Store.listTransitions(sid, sc, "gh:acme/shop#1") {
    case Ok(ts) -> {
      assertEqualInt(ts.length.toInt(), 1, "one transition")
      assertEqual(
        ts[0].fromState + ">" + ts[0].toState + "|" + ts[0].actor + "|" + ts[0].reason,
        "queued>blocked|agent|needs a schema",
        "transition row"
      )
      assertEqual(ts[0].at, blocked.updatedAt, "transition time")
    }
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val es = entries(sid, sc)
  assertEqualInt(es.length.toInt(), 1, "automatic entry")
  assertEqual(
    es[0].origin + "|" + es[0].reviewState + "|" + es[0].undeclared + "|" + es[0].reversible,
    "transition|pending|false|",
    "automatic entry fields"
  )
  assertEqual(es[0].recommendation, "ask the owner", "carries the item's recommendation")
  // A stale version writes nothing, not even the cursor.
  val before = str(Store.currentSeq(sid, sc))
  val stale = match Store.applyItemUpdate(sid, sc, moved(w, "in_progress"), w.updatedSeq, "queued", true, "agent", "", noAuto(), true) {
    case Ok(b) -> b
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertFalse(stale, "stale version not applied")
  assertEqual(str(Store.currentSeq(sid, sc)), before, "cursor unchanged")
  assertEqual(item(sid, sc, "gh:acme/shop#1").state, "blocked", "state unchanged")
  // Leaving blocked resolves the automatic blocker entry.
  val resumed = match Store.applyItemUpdate(sid, sc, moved(blocked, "in_progress"), blocked.updatedSeq, "blocked", true, "human", "unblocked", noAuto(), true) {
    case Ok(b) -> b
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertTrue(resumed, "resume applied")
  val after = entries(sid, sc)
  assertEqual(after[0].reviewState, "resolved", "blocker resolved")
  assertTrue(after[0].reviewAt.length.toInt() > 0, "resolution time")
}

test "entries round-trip their text forms and list, supersede, review and summarise like SQLite" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  int(Store.registerItems(sid, sc, ["local:a"], ["A"], [""]))
  val d0 = draft(sid, "local:a", "decision", "review", "Use Postgres", "pending")
  val d = LedgerEntry(
    id = d0.id,
    sessionId = d0.sessionId,
    itemId = d0.itemId,
    kind = d0.kind,
    severity = d0.severity,
    declaredSeverity = "info",
    summary = d0.summary,
    detail = "because",
    optionsConsidered = ["sqlite", "postgres"],
    chosen = "postgres",
    rationale = "tenancy",
    recommendation = "",
    proceedingWith = "yes",
    reversible = "true",
    files = ["a.l"],
    tags = ["db"],
    source = "observed",
    undeclared = "true",
    matchedEntryId = "",
    origin = "",
    supersedes = "",
    transcriptSeq = "42",
    reviewState = d0.reviewState,
    reviewBy = "",
    reviewAt = "",
    reviewComment = "",
    createdAt = "",
    createdSeq = "",
    updatedSeq = "",
    observedFrom = "40",
    confidence = "0.80",
    evidence = "quote",
    provisional = "true"
  )
  val stored = insert(sc, d)
  assertTrue(stored.id.length.toInt() > 0, "id assigned")
  assertEqual(stored.createdSeq, "2", "created at the second cursor")
  assertEqual(stored.createdSeq, stored.updatedSeq, "created = updated seq")
  assertEqual(stored.reversible + "|" + stored.undeclared + "|" + stored.provisional, "true|true|true", "booleans")
  assertEqual(stored.transcriptSeq + "|" + stored.observedFrom, "42|40", "event range")
  assertEqual(stored.confidence, "0.8", "confidence normalised")
  assertEqual(stored.optionsConsidered[1] + "|" + stored.files[0] + "|" + stored.tags[0], "postgres|a.l|db", "lists")
  assertEqual(stored.reviewAt, "", "never reviewed")
  val plain = insert(sc, draft(sid, "local:a", "note", "info", "Plain", "not_required"))
  assertEqual(
    plain.reversible + "|" + plain.provisional + "|" + plain.transcriptSeq + "|" + plain.confidence,
    "|||",
    "unset stays empty"
  )
  val sup0 = draft(sid, "local:a", "decision", "review", "Use Postgres 16", "pending")
  val sup = insert(
    sc,
    LedgerEntry(
      id = sup0.id,
      sessionId = sid,
      itemId = sup0.itemId,
      kind = sup0.kind,
      severity = sup0.severity,
      declaredSeverity = "",
      summary = sup0.summary,
      detail = "",
      optionsConsidered = [],
      chosen = "",
      rationale = "",
      recommendation = "",
      proceedingWith = "",
      reversible = "",
      files = [],
      tags = [],
      source = "declared",
      undeclared = "false",
      matchedEntryId = "",
      origin = "",
      supersedes = stored.id,
      transcriptSeq = "",
      reviewState = "pending",
      reviewBy = "",
      reviewAt = "",
      reviewComment = "",
      createdAt = "",
      createdSeq = "",
      updatedSeq = "",
      observedFrom = "",
      confidence = "",
      evidence = "",
      provisional = ""
    )
  )
  match Store.supersedingEntryIds(sid, sc, stored.id) {
    case Ok(ids) -> assertEqualInt(ids.length.toInt(), 1, "one superseding entry")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val es = entries(sid, sc)
  assertEqual(es[0].id + es[1].id + es[2].id, stored.id + plain.id + sup.id, "creation order")
  val cursor = str(Store.currentSeq(sid, sc))
  val fb = match Store.reviewEntry(sid, sc, stored, "rejected", "reject", "No.", "owner") {
    case Ok(f) -> f
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqual(
    fb.entryId + "|" + fb.kind + "|" + fb.body + "|" + fb.deliveredAt,
    stored.id + "|reject|No.|",
    "feedback row"
  )
  match Store.entriesChangedAfter(sid, sc, cursor) {
    case Ok(xs) -> {
      assertEqualInt(xs.length.toInt(), 1, "only the reviewed entry changed")
      assertEqual(
        xs[0].reviewState + "|" + xs[0].reviewBy + "|" + xs[0].reviewComment,
        "rejected|owner|No.",
        "review written"
      )
      assertTrue(xs[0].reviewAt.length.toInt() > 0, "review time")
    }
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.getEntry(sid, sc, "nope") {
    case Ok(None) -> ()
    case _ -> assertTrue(false, "unknown entry is None")
  }
  assertEqualInt(int(Store.countEntries(sid, sc)), 3, "count")
  match Store.summaryOf(sid, sc, 5) {
    case Ok(s) -> {
      assertEqual(s.total + "|" + s.queued + "|" + s.blocked, "1|1|0", "item counts")
      assertEqual(
        s.pendingReview + "|" + s.blockingCount + "|" + s.undeclaredCount + "|" + s.pendingFeedback,
        "1|0|1|5",
        "attention counts"
      )
      assertEqual(s.lastActivityAt, sup.createdAt, "last activity is the newest entry")
    }
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.summaryOf("s-empty-" + uid(), sc, 0) {
    case Ok(s) -> assertEqual(s.total + "|" + s.lastActivityAt, "0|", "an empty session")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  // Retro-match and settling provisional observations.
  unit(Store.applyRetroMatch(sid, sc, stored.id, sup.id))
  match Store.getEntry(sid, sc, stored.id) {
    case Ok(Some(e)) -> assertEqual(
      e.matchedEntryId + "|" + e.undeclared + "|" + e.provisional + "|" + e.severity + "|" +
        e.reviewState,
      sup.id + "|false|false|info|rejected",
      "retro match keeps a human review"
    )
    case _ -> assertTrue(false, "entry missing")
  }
  val obs0 = draft(sid, "", "deviation", "review", "Mid-run", "pending")
  val obs = insert(
    sc,
    LedgerEntry(
      id = "",
      sessionId = sid,
      itemId = "",
      kind = obs0.kind,
      severity = obs0.severity,
      declaredSeverity = "",
      summary = obs0.summary,
      detail = "",
      optionsConsidered = [],
      chosen = "",
      rationale = "",
      recommendation = "",
      proceedingWith = "",
      reversible = "",
      files = [],
      tags = [],
      source = "observed",
      undeclared = "true",
      matchedEntryId = "",
      origin = "",
      supersedes = "",
      transcriptSeq = "",
      reviewState = "pending",
      reviewBy = "",
      reviewAt = "",
      reviewComment = "",
      createdAt = "",
      createdSeq = "",
      updatedSeq = "",
      observedFrom = "",
      confidence = "1",
      evidence = "",
      provisional = "true"
    )
  )
  assertEqual(obs.confidence, "1", "whole confidence")
  val c1 = str(Store.currentSeq(sid, sc))
  unit(Store.settleProvisional(sid, sc))
  match Store.getEntry(sid, sc, obs.id) {
    case Ok(Some(e)) -> assertEqual(e.provisional, "false", "settled")
    case _ -> assertTrue(false, "entry missing")
  }
  val c2 = str(Store.currentSeq(sid, sc))
  assertTrue(c1 != c2, "settling bumps the cursor")
  unit(Store.settleProvisional(sid, sc))
  assertEqual(str(Store.currentSeq(sid, sc)), c2, "nothing to settle writes nothing")
}

func pinFeedbackCreated(sid: in String, sc: in CloudAgents.Pg.TenantScope, body: in String, ms: in String): Unit {
  val u = match CloudAgents.PgStore.open(sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, "UPDATE ledger_feedback SET created_at = " + CloudAgents.Pg.msIn(2) + " WHERE session_id = @p0 AND body = @p1", [sid, body, ms]) {
    case Ok(n) -> assertEqualInt(n, 1, "pinned " + body)
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(CloudAgents.PgStore.commit(u))
}

func batchOf(sid: in String, sc: in CloudAgents.Pg.TenantScope): String {
  val u = match CloudAgents.PgStore.open(sc) { case Ok(v) -> v; case Err(e) -> panic(dbErrorMessage(e)) }
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = match CloudAgents.PgStore.q(u, "SELECT delivery_batch FROM ledger_feedback WHERE session_id = @p0 AND delivery_batch <> '' LIMIT 1", [sid]) {
    case Ok(v) -> v
    case Err(e) -> panic(dbErrorMessage(e))
  }
  return CloudAgents.PgStore.col(rows[0], "delivery_batch")
}

test "feedback is claimed once with its entry summary, and a released batch is delivered again" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  val e = insert(sc, draft(sid, "", "question", "review", "Which API?", "pending"))
  match Store.reviewEntry(sid, sc, e, "commented", "comment", "Use v2.", "owner") {
    case Ok(_) -> ()
    case Err(err) -> panic(dbErrorMessage(err))
  }
  match Store.addFeedback(sid, sc, "", "directive", "Update the changelog.", "owner") {
    case Ok(f) -> assertEqual(f.entryId + "|" + f.createdBy, "|owner", "session-level feedback")
    case Err(err) -> panic(dbErrorMessage(err))
  }
  // Pin the order: the two inserts may land in the same millisecond.
  pinFeedbackCreated(sid, sc, "Use v2.", "1700000001000")
  pinFeedbackCreated(sid, sc, "Update the changelog.", "1700000002000")
  assertEqualInt(int(Store.pendingFeedbackCount(sid, sc)), 2, "two pending")
  assertEqualInt(int(Store.countFeedback(sid, sc)), 2, "two in all")
  val cursor = str(Store.currentSeq(sid, sc))
  match Store.claimFeedback(sid, sc, "mcp_poll") {
    case Ok(cs) -> {
      assertEqualInt(cs.length.toInt(), 2, "both claimed")
      assertEqual(cs[0].entrySummary + "|" + cs[1].entrySummary, "Which API?|", "entry summaries")
      assertEqual(cs[0].feedback.deliveredVia, "mcp_poll", "delivered via")
      assertTrue(cs[0].feedback.deliveredAt.length.toInt() > 0, "delivered at")
    }
    case Err(err) -> panic(dbErrorMessage(err))
  }
  assertEqualInt(int(Store.pendingFeedbackCount(sid, sc)), 0, "none pending")
  match Store.collectFeedback(sid, sc, "mcp_poll") {
    case Ok(fs) -> assertEqualInt(fs.length.toInt(), 0, "a second claim gets nothing")
    case Err(err) -> panic(dbErrorMessage(err))
  }
  match Store.feedbackChangedAfter(sid, sc, cursor) {
    case Ok(fs) -> assertEqualInt(fs.length.toInt(), 2, "the claim stamped both rows")
    case Err(err) -> panic(dbErrorMessage(err))
  }
  Store.releaseFeedbackBatch(sid, sc, batchOf(sid, sc))
  assertEqualInt(int(Store.pendingFeedbackCount(sid, sc)), 2, "released rows are pending again")
  match Store.listFeedback(sid, sc) {
    case Ok(fs) -> assertEqual(
      fs[0].body + "|" + fs[1].body + "|" + fs[0].deliveredAt,
      "Use v2.|Update the changelog.|",
      "oldest first, undelivered"
    )
    case Err(err) -> panic(dbErrorMessage(err))
  }
  match Store.feedbackForEntry(sid, sc, e.id) {
    case Ok(fs) -> assertEqualInt(fs.length.toInt(), 1, "one on the entry")
    case Err(err) -> panic(dbErrorMessage(err))
  }
  assertEqualInt(int(Store.pendingFeedbackCount(sid, fresh())), 0, "another tenant sees none")
}

test "GitHub sync rows, issue ownership and the sync lease" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val older = "s-" + uid()
  val newer = "s-" + uid()
  addSession(older, sc)
  int(Store.registerItems(older, sc, ["gh:acme/shop#7", "local:x"], ["Seven", "X"], ["", ""]))
  addSession(newer, sc)
  int(Store.registerItems(newer, sc, ["gh:acme/shop#7"], ["Seven"], [""]))
  match Store.ownedIssueItems(older, sc) {
    case Ok(xs) -> assertEqualInt(xs.length.toInt(), 0, "the newer session took the issue over")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.ownedIssueItems(newer, sc) {
    case Ok(xs) -> assertEqualInt(xs.length.toInt(), 1, "the newer session owns it")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Sessions.updateSessionArchived(newer, sc, "1"))
  match Store.ownedIssueItems(older, sc) {
    case Ok(xs) -> assertEqualInt(xs.length.toInt(), 1, "an archived session owns nothing, so the older one does")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.ownedIssueItems(newer, sc) {
    case Ok(xs) -> assertEqualInt(xs.length.toInt(), 0, "archived")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  // Sync rows upsert and read back.
  val row = SqliteLedger.SyncRow(
    itemId = "gh:acme/shop#7",
    syncedLabel = "agent:blocked",
    commentId = "",
    commentHash = "",
    lastError = "",
    syncedAt = "",
    attemptedAt = "1700000000000"
  )
  unit(Store.saveSyncRow(older, sc, row))
  unit(
    Store.saveSyncRow(
      older,
      sc,
      SqliteLedger.SyncRow(
        itemId = row.itemId,
        syncedLabel = row.syncedLabel,
        commentId = "c9",
        commentHash = "h",
        lastError = "",
        syncedAt = "1700000000500",
        attemptedAt = "1700000000500"
      )
    )
  )
  match Store.syncRows(older, sc) {
    case Ok(rs) -> {
      assertEqualInt(rs.length.toInt(), 1, "one row per item")
      assertEqual(
        rs[0].commentId + "|" + rs[0].syncedAt + "|" + rs[0].attemptedAt,
        "c9|1700000000500|1700000000500",
        "updated in place"
      )
    }
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Store.markSyncAttempt(older, sc, "no token"))
  unit(Store.markSyncAttempt(older, sc, ""))
  // The lease: one holder at a time, released only by its own token.
  val lease = (60000).toLong()
  val first = str(Store.acquireSyncLease(older, sc, lease))
  assertTrue(first.length.toInt() > 0, "first acquire wins")
  assertEqual(str(Store.acquireSyncLease(older, sc, lease)), "", "second acquire loses")
  unit(Store.releaseSyncLease(older, sc, "12345"))
  assertEqual(str(Store.acquireSyncLease(older, sc, lease)), "", "a wrong token releases nothing")
  unit(Store.releaseSyncLease(older, sc, first))
  val third = str(Store.acquireSyncLease(older, sc, lease))
  assertTrue(third.length.toInt() > 0, "reacquired after release")
  unit(Store.releaseSyncLease(older, sc, third))
  val expired = str(Store.acquireSyncLease(older, sc, (0).toLong()))
  assertTrue(expired.length.toInt() > 0, "a zero-length lease")
  assertTrue(str(Store.acquireSyncLease(older, sc, lease)).length.toInt() > 0, "an expired lease is taken over")
}

test "the policy cache and the inbox" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val sid = "s-" + uid()
  match Store.getPolicyCache(sid, sc) {
    case Ok(p) -> assertEqual(p.status + p.json + p.error, "", "empty before any write")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Store.setPolicyCache(sid, sc, "loaded", "{\"rules\":[]}", ""))
  match Store.getPolicyCache(sid, sc) {
    case Ok(p) -> assertEqual(p.status + "|" + p.json, "loaded|{\"rules\":[]}", "cached")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  assertEqual(str(Store.currentSeq(sid, sc)), "0", "caching the policy is not a ledger change")
  addSession(sid, sc)
  val review = insert(sc, draft(sid, "", "decision", "review", "Review me", "pending"))
  val block = insert(sc, draft(sid, "", "blocker", "blocking", "Blocked", "pending"))
  insert(sc, draft(sid, "", "note", "info", "Info", "not_required"))
  match Store.inboxForUser(sc) {
    case Ok(xs) -> {
      assertEqualInt(xs.length.toInt(), 2, "pending review and blocking only")
      assertEqual(xs[0].ledgerEntry.id + "|" + xs[1].ledgerEntry.id, block.id + "|" + review.id, "blocking first")
      assertEqual(xs[0].repoUrl + "|" + xs[0].branch, "https://github.com/acme/shop|main", "session context")
    }
    case Err(e) -> panic(dbErrorMessage(e))
  }
  val other = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "someone-else")
  match Store.inboxForUser(other) {
    case Ok(xs) -> assertEqualInt(xs.length.toInt(), 0, "another user's sessions are not in the inbox")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Store.inboxForUser(fresh()) {
    case Ok(xs) -> assertEqualInt(xs.length.toInt(), 0, "another tenant sees nothing")
    case Err(e) -> panic(dbErrorMessage(e))
  }
}
