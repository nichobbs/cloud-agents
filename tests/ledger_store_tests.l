//! Tests for the session-ledger store on Postgres (docs/session-ledger.md §4):
//! the change cursor, optimistic item transitions, entries, reviews, atomic
//! feedback delivery and the cross-session inbox. Each test acts as a fresh
//! user with its own personal tenant, so ledger rows (keyed by session id
//! within a tenant) never meet another test's; no network, no clock assertions.
@test_module
package CloudAgents.LedgerStoreTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Schema
import CloudAgents.Ledger.StateMachine
import CloudAgents.Ledger.Store
import CloudAgents.Scope as TestScope
import CloudAgents.Ledger.Summary

// ── Live Postgres ─────────────────────────────────────────────────────────────
//
// The store is Postgres (docs/phase11-postgres-tenancy.md). These tests run iff
// LYRIC_CONFIG_DB_CONNECTION_URL (cloudagents_app) and
// CLOUD_AGENTS_MIGRATE_DATABASE_URL (cloudagents_owner) are set, and fail rather
// than skip when CLOUD_AGENTS_REQUIRE_LIVE_PG=1 (CI). Each test acts as a fresh
// user with its own personal tenant, so tests, suites and repeated runs against
// the same database never see each other's rows.
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
  println("SKIP: ledger store tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

/// A new user with a provisioned personal tenant. Does not change the request
/// identity.
func newUser(tag: in String): String {
  val uid = "t-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(uid) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return uid
}

/// Migrate, then make a new user the request identity (what handlers read via
/// CloudAgents.Auth.requestScope()).
func freshUser(tag: in String): String {
  migrate()
  val uid = newUser(tag)
  CloudAgents.Auth.setCurrentUserId(uid)
  return uid
}

func noStrings(): slice[String] {
  val none: slice[String] = []
  return none
}

func register(sid: in String, ids: in slice[String]): Int {
  var titles: slice[String] = []
  var urls: slice[String] = []
  var i = 0
  while i < ids.length.toInt() {
    titles = titles.append("Title " + ids[i])
    urls = urls.append("")
    i = i + 1
  }
  match registerItems(sid, testScope(), ids, titles, urls) {
    case Ok(n) -> return n
    case Err(e) -> {
      assertTrue(false, "registerItems failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      return 0
    }
  }
}

func mustItem(sid: in String, id: in String): WorkItem {
  match getItem(sid, testScope(), id) {
    case Ok(Some(w)) -> return w
    case Ok(None) -> panic("item not found: " + id)
    case Err(e) -> panic("getItem failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func noAuto(): AutoEntry {
  return AutoEntry(kind = "", severity = "", source = "", summary = "", detail = "")
}

// Plan and apply a status change for `actor`; returns the applied flag.
func move(
  sid: in String, id: in String, to: in String, reason: in String, blockedBy: in slice[String], actor: in String
): Bool {
  val current = mustItem(sid, id)
  val c = StatusChange(
    to = to,
    reason = reason,
    blockedBy = blockedBy,
    prerequisiteProposal = "",
    recommendation = "",
    prUrl = ""
  )
  match planStatusChange(current, c, actor) {
    case Err(msg) -> panic("plan failed: " + msg)
    case Ok(plan) -> {
      var auto = noAuto()
      if plan.blockerSummary.length.toInt() > 0 {
        auto = AutoEntry(
          kind = "blocker",
          severity = "blocking",
          source = "declared",
          summary = plan.blockerSummary,
          detail = plan.blockerDetail
        )
      }
      match applyItemUpdate(sid, testScope(), plan.item, current.updatedSeq, plan.fromState, plan.stateChanged, actor, reason, auto, plan.resolvesBlockers) {
        case Ok(applied) -> return applied
        case Err(e) -> panic("apply failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      }
    }
  }
}

func declaredEntry(sid: in String, kind: in String, severity: in String, review: in String): LedgerEntry {
  return LedgerEntry(
    id = "",
    sessionId = sid,
    itemId = "gh:a/b#1",
    kind = kind,
    severity = severity,
    declaredSeverity = "",
    summary = "Chose SQLite over Postgres",
    detail = "single node",
    optionsConsidered = ["sqlite", "postgres, with \"quotes\""],
    chosen = "sqlite",
    rationale = "fewer moving parts",
    recommendation = "accept",
    proceedingWith = "",
    reversible = "true",
    files = ["src/db.l"],
    tags = ["schema"],
    source = "declared",
    undeclared = "false",
    matchedEntryId = "",
    origin = "",
    supersedes = "",
    transcriptSeq = "12",
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

func mustInsert(e: in LedgerEntry): LedgerEntry {
  match insertEntry(testScope(), e) {
    case Ok(stored) -> return stored
    case Err(err) -> panic("insertEntry failed: " + CloudAgents.Sqlite.dbErrorMessage(err))
  }
}

test "string list codec round-trips awkward values" {
  val xs: slice[String] = ["a", "", "quote \" and \\ backslash", "comma, separated"]
  val back = decodeStringList(encodeStringList(xs))
  assertEqualInt(back.length.toInt(), 4, "length")
  assertEqual(back[2], "quote \" and \\ backslash", "escapes")
  assertEqualInt(decodeStringList("").length.toInt(), 0, "empty")
  assertEqualInt(decodeStringList("not json").length.toInt(), 0, "corrupt degrades to empty")
  assertEqual(encodeStringList(noStrings()), "[]", "empty encodes as []")
}

test "register is ordered and idempotent" {
  if not live() {
    return
  }
  val me = freshUser("ledger-register")
  assertEqualInt(register("s1", ["gh:a/b#1", "gh:a/b#2"]), 2, "two new")
  assertEqualInt(register("s1", ["gh:a/b#2", "gh:a/b#3"]), 1, "one new, one refreshed")
  match listItems("s1", testScope()) {
    case Ok(items) -> {
      assertEqualInt(items.length.toInt(), 3, "three items")
      assertEqual(items[0].id, "gh:a/b#1", "batch order")
      assertEqual(items[2].id, "gh:a/b#3", "appended last")
      assertEqual(items[2].state, "queued", "new items are queued")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match listItems("other", testScope()) {
    case Ok(items) -> assertEqualInt(items.length.toInt(), 0, "session scoped")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "a transition writes the item, a transition row and a blocker entry" {
  if not live() {
    return
  }
  val me = freshUser("ledger-transition")
  register("s1", ["gh:a/b#1", "gh:a/b#2"])
  assertTrue(move("s1", "gh:a/b#1", "in_progress", "", noStrings(), "agent"), "start applied")
  assertTrue(move("s1", "gh:a/b#1", "blocked", "needs #2's schema", ["gh:a/b#2"], "agent"), "block applied")
  val w = mustItem("s1", "gh:a/b#1")
  assertEqual(w.state, "blocked", "state persisted")
  assertEqualInt(w.blockedBy.length.toInt(), 1, "blockedBy persisted")
  assertEqual(w.blockedBy[0], "gh:a/b#2", "blocker ref")
  match listTransitions("s1", testScope(), "gh:a/b#1") {
    case Ok(ts) -> {
      assertEqualInt(ts.length.toInt(), 2, "two transitions")
      assertEqual(ts[1].fromState, "in_progress", "from")
      assertEqual(ts[1].toState, "blocked", "to")
      assertEqual(ts[1].actor, "agent", "actor")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match listEntries("s1", testScope()) {
    case Ok(es) -> {
      assertEqualInt(es.length.toInt(), 1, "one automatic blocker entry")
      assertEqual(es[0].kind, "blocker", "kind")
      assertEqual(es[0].severity, "blocking", "severity")
      assertEqual(es[0].reviewState, "pending", "in the attention queue")
      assertEqual(es[0].origin, "transition", "origin")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // Leaving blocked resolves the automatic blocker.
  assertTrue(move("s1", "gh:a/b#1", "queued", "", noStrings(), "human"), "requeue applied")
  match listEntries("s1", testScope()) {
    case Ok(es) -> assertEqual(es[0].reviewState, "resolved", "blocker resolved")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "a stale plan is rejected and writes nothing" {
  if not live() {
    return
  }
  val me = freshUser("ledger-conflict")
  register("s1", ["gh:a/b#1"])
  val stale = mustItem("s1", "gh:a/b#1")
  assertTrue(move("s1", "gh:a/b#1", "in_progress", "", noStrings(), "agent"), "concurrent writer wins")
  val c = StatusChange(
    to = "needs_human",
    reason = "which API?",
    blockedBy = noStrings(),
    prerequisiteProposal = "",
    recommendation = "",
    prUrl = ""
  )
  match planStatusChange(stale, c, "human") {
    case Err(msg) -> assertTrue(false, "plan: " + msg)
    case Ok(plan) -> {
      val auto = AutoEntry(
        kind = "blocker",
        severity = "blocking",
        source = "declared",
        summary = plan.blockerSummary,
        detail = ""
      )
      match applyItemUpdate("s1", testScope(), plan.item, stale.updatedSeq, plan.fromState, plan.stateChanged, "human", "which API?", auto, false) {
        case Ok(applied) -> assertTrue(not applied, "stale version must not apply")
        case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
      }
    }
  }
  assertEqual(mustItem("s1", "gh:a/b#1").state, "in_progress", "state unchanged")
  match listEntries("s1", testScope()) {
    case Ok(es) -> assertEqualInt(es.length.toInt(), 0, "no blocker written")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match listTransitions("s1", testScope(), "gh:a/b#1") {
    case Ok(ts) -> assertEqualInt(ts.length.toInt(), 1, "only the winning transition")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "entries round-trip and the cursor returns only changes" {
  if not live() {
    return
  }
  val me = freshUser("ledger-entries")
  val e1 = mustInsert(declaredEntry("s1", "decision", "review", "pending"))
  assertEqual(e1.optionsConsidered[1], "postgres, with \"quotes\"", "options round-trip")
  assertEqual(e1.files[0], "src/db.l", "files")
  assertEqual(e1.tags[0], "schema", "tags")
  assertEqual(e1.transcriptSeq, "12", "transcript ref")
  val cursor = match currentSeq("s1", testScope()) {
    case Ok(s) -> s
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val e2 = mustInsert(declaredEntry("s1", "note", "info", "not_required"))
  match entriesChangedAfter("s1", testScope(), cursor) {
    case Ok(es) -> {
      assertEqualInt(es.length.toInt(), 1, "only the new entry")
      assertEqual(es[0].id, e2.id, "the new entry")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match currentSeq("never-written", testScope()) {
    case Ok(s) -> assertEqual(s, "0", "fresh session cursor")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "a review updates the entry and queues feedback delivered exactly once" {
  if not live() {
    return
  }
  val me = freshUser("ledger-review")
  val e = mustInsert(declaredEntry("s1", "shortcut", "review", "pending"))
  match reviewEntry("s1", testScope(), e, "rejected", "reject", "Don't skip; quarantine it.", "gh-1") {
    case Ok(f) -> {
      assertEqual(f.entryId, e.id, "linked to the entry")
      assertEqual(f.itemId, "gh:a/b#1", "inherits the entry's item")
      assertEqual(f.deliveredAt, "", "undelivered")
    }
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match addFeedback("s1", testScope(), "", "directive", "Also update the changelog.", "gh-1") {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match getEntry("s1", testScope(), e.id) {
    case Ok(Some(stored)) -> {
      assertEqual(stored.reviewState, "rejected", "review state")
      assertEqual(stored.reviewComment, "Don't skip; quarantine it.", "comment")
      assertEqual(stored.reviewBy, "gh-1", "reviewer")
    }
    case Ok(None) -> assertTrue(false, "entry missing")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match pendingFeedbackCount("s1", testScope()) {
    case Ok(n) -> assertEqualInt(n, 2, "two pending")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match collectFeedback("s1", testScope(), "mcp_poll") {
    case Ok(fs) -> {
      assertEqualInt(fs.length.toInt(), 2, "both delivered")
      assertEqual(fs[0].deliveredVia, "mcp_poll", "via")
    }
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match collectFeedback("s1", testScope(), "mcp_poll") {
    case Ok(fs) -> assertEqualInt(fs.length.toInt(), 0, "never delivered twice")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match pendingFeedbackCount("s1", testScope()) {
    case Ok(n) -> assertEqualInt(n, 0, "none pending")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
}

test "a released claim is delivered again" {
  if not live() {
    return
  }
  val me = freshUser("ledger-release")
  match addFeedback("s1", testScope(), "", "directive", "Use API v2.", "gh-1") {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match collectFeedback("s1", testScope(), "mcp_poll") {
    case Ok(fs) -> assertEqualInt(fs.length.toInt(), 1, "claimed")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  // The read-back failure path: the claimed batch is handed back.
  releaseFeedbackBatch("s1", testScope(), batchOf("s1"))
  match pendingFeedbackCount("s1", testScope()) {
    case Ok(n) -> assertEqualInt(n, 1, "pending again")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match collectFeedback("s1", testScope(), "mcp_poll") {
    case Ok(fs) -> assertEqualInt(fs.length.toInt(), 1, "delivered on the next check")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
}

func batchOf(sid: in String): String {
  val u = match CloudAgents.PgStore.open(testScope()) {
    case Ok(x) -> x
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.q(u, "SELECT delivery_batch FROM ledger_feedback WHERE session_id = @p0 LIMIT 1", [sid]) {
    case Ok(rows) -> return CloudAgents.PgStore.col(rows[0], "delivery_batch")
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "the inbox is scoped to the owner and orders blocking first" {
  if not live() {
    return
  }
  val me = freshUser("ledger-inbox")
  val bob = newUser("ledger-inbox-bob")
  val bobScope = TestScope.personalScope(bob)
  // Session ids are global (session_routes), so these are unique to the run.
  val s1 = "s-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  val s2 = "s-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  addSession(s1, testScope())
  addSession(s2, bobScope)
  mustInsert(declaredEntry(s1, "shortcut", "review", "pending"))
  mustInsert(declaredEntry(s1, "blocker", "blocking", "pending"))
  mustInsert(declaredEntry(s1, "note", "info", "not_required"))
  match insertEntry(bobScope, declaredEntry(s2, "shortcut", "review", "pending")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match inboxForUser(testScope()) {
    case Ok(xs) -> {
      assertEqualInt(xs.length.toInt(), 2, "the owner sees her two attention entries only")
      assertEqual(xs[0].ledgerEntry.kind, "blocker", "blocking first")
      assertEqual(xs[0].repoUrl, "https://github.com/a/b", "session context")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "policy cache round-trips" {
  if not live() {
    return
  }
  val me = freshUser("ledger-policy")
  match getPolicyCache("s1", testScope()) {
    case Ok(p) -> assertEqual(p.status, "", "unfetched")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match setPolicyCache("s1", testScope(), "loaded", "{\"rules\":[]}", "") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match getPolicyCache("s1", testScope()) {
    case Ok(p) -> {
      assertEqual(p.status, "loaded", "status")
      assertEqual(p.json, "{\"rules\":[]}", "json")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// Insert `n` info notes for `sid` directly, numbered 1..n by created_seq.
func bulkNotes(sid: in String, n: in Int): Unit {
  val u = match CloudAgents.PgStore.open(testScope()) {
    case Ok(x) -> x
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, "INSERT INTO ledger_entries (id, session_id, item_id, kind, severity, summary, source, undeclared, review_state, created_at, created_seq, updated_seq) " + "SELECT 'e' || x::text, @p0, '', 'note', 'info', 'note ' || x::text, 'declared', false, 'not_required', " + "timestamptz 'epoch' + x * interval '1 millisecond', x, x FROM generate_series(1, @p1::int) AS x", [sid, toString(n)]) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "bulk insert failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "past the row cap the entry list keeps the newest" {
  if not live() {
    return
  }
  val me = freshUser("ledger-cap")
  bulkNotes("s1", entryRowCap + 3)
  match listEntries("s1", testScope()) {
    case Ok(es) -> {
      assertEqualInt(es.length.toInt(), entryRowCap, "capped")
      assertEqual(es[0].createdSeq, "4", "the oldest three are the ones left out")
      assertEqual(es[es.length.toInt() - 1].createdSeq, toString(entryRowCap + 3), "the newest is kept, last")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match countEntries("s1", testScope()) {
    case Ok(n) -> assertEqualInt(n, entryRowCap + 3, "count sees every row")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "the SQL summary matches the in-memory one" {
  if not live() {
    return
  }
  val me = freshUser("ledger-summary")
  val ids: slice[String] = ["gh:a/b#1", "gh:a/b#2", "gh:a/b#3"]
  val _ = register("s1", ids)
  val _ = move("s1", "gh:a/b#1", "in_progress", "", noStrings(), "agent")
  val _ = move("s1", "gh:a/b#2", "blocked", "waiting", ["gh:a/b#1"], "agent")
  val _ = mustInsert(declaredEntry("s1", "shortcut", "review", "pending"))
  val _ = mustInsert(declaredEntry("s1", "decision", "info", "not_required"))
  val fromSql = match summaryOf("s1", testScope(), 2) {
    case Ok(x) -> x
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val items = match listItems("s1", testScope()) {
    case Ok(xs) -> xs
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val entries = match listEntries("s1", testScope()) {
    case Ok(es) -> es
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val inMemory = summarize("s1", items, entries, 2)
  assertEqual(fromSql.toJson(), inMemory.toJson(), "same counts either way")
  assertEqual(fromSql.blockingCount, "1", "the blocker entry is counted")
}

test "re-registering without a url keeps the item's url" {
  if not live() {
    return
  }
  val me = freshUser("ledger-url")
  val ids: slice[String] = ["gh:a/b#7"]
  val titles: slice[String] = ["Seven"]
  val custom: slice[String] = ["https://example.com/tracker/7"]
  match registerItems("s1", testScope(), ids, titles, custom) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val _ = register("s1", ids)
  assertEqual(mustItem("s1", "gh:a/b#7").url, "https://example.com/tracker/7", "custom url kept")
  val fresh: slice[String] = ["gh:a/b#8"]
  val _ = register("s1", fresh)
  assertEqual(mustItem("s1", "gh:a/b#8").url, "https://github.com/a/b/issues/8", "a new item gets the ref's url")
}

// The scope the store calls run under: the current test's fresh user.
func testScope(): TestScope.TenantScope {
  return CloudAgents.Auth.requestScope()
}

func addSession(sid: in String, sc: in TestScope.TenantScope): Unit {
  match CloudAgents.SessionStore.addSession(makeAgentSession(sessionId = sid, repoUrl = "https://github.com/a/b", branch = "main", containerId = "", harness = "claude", model = "", nativeSessionId = sid), sc) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}
