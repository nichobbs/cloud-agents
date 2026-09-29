//! Live-SQLite tests for the session-ledger store (docs/session-ledger.md
//! §4): migration 0037, the change cursor, optimistic item transitions,
//! entries, reviews, atomic feedback delivery, the cross-session inbox, and
//! the retired-tool profile-grant rewrite. Fresh temp DB per test (the
//! tests/session_events_tests.l harness); no network, no clock assertions.
@test_module
package CloudAgents.LedgerStoreTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Schema
import CloudAgents.Ledger.StateMachine
import CloudAgents.Ledger.Store
import CloudAgents.Ledger.Summary
import extern System.Environment as Env

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return path
}

func cleanupTestDb(path: in String): Unit {
  try {
    fileDelete(path)
  } catch Bug as b {
    // locked or already gone — fine for a temp file
  }
}

func exec(sql: in String): Unit {
  match CloudAgents.Sqlite.execute(sql) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "exec failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
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
  match registerItems(sid, ids, titles, urls) {
    case Ok(n) -> return n
    case Err(e) -> {
      assertTrue(false, "registerItems failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      return 0
    }
  }
}

func mustItem(sid: in String, id: in String): WorkItem {
  match getItem(sid, id) {
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
      match applyItemUpdate(sid, plan.item, current.updatedSeq, plan.fromState, plan.stateChanged, actor, reason, auto, plan.resolvesBlockers) {
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
  match insertEntry(e) {
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
  val path = useFreshTestDb("ledger-register")
  defer {
    cleanupTestDb(path)
  }
  assertEqualInt(register("s1", ["gh:a/b#1", "gh:a/b#2"]), 2, "two new")
  assertEqualInt(register("s1", ["gh:a/b#2", "gh:a/b#3"]), 1, "one new, one refreshed")
  match listItems("s1") {
    case Ok(items) -> {
      assertEqualInt(items.length.toInt(), 3, "three items")
      assertEqual(items[0].id, "gh:a/b#1", "batch order")
      assertEqual(items[2].id, "gh:a/b#3", "appended last")
      assertEqual(items[2].state, "queued", "new items are queued")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match listItems("other") {
    case Ok(items) -> assertEqualInt(items.length.toInt(), 0, "session scoped")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "a transition writes the item, a transition row and a blocker entry" {
  val path = useFreshTestDb("ledger-transition")
  defer {
    cleanupTestDb(path)
  }
  register("s1", ["gh:a/b#1", "gh:a/b#2"])
  assertTrue(move("s1", "gh:a/b#1", "in_progress", "", noStrings(), "agent"), "start applied")
  assertTrue(move("s1", "gh:a/b#1", "blocked", "needs #2's schema", ["gh:a/b#2"], "agent"), "block applied")
  val w = mustItem("s1", "gh:a/b#1")
  assertEqual(w.state, "blocked", "state persisted")
  assertEqualInt(w.blockedBy.length.toInt(), 1, "blockedBy persisted")
  assertEqual(w.blockedBy[0], "gh:a/b#2", "blocker ref")
  match listTransitions("s1", "gh:a/b#1") {
    case Ok(ts) -> {
      assertEqualInt(ts.length.toInt(), 2, "two transitions")
      assertEqual(ts[1].fromState, "in_progress", "from")
      assertEqual(ts[1].toState, "blocked", "to")
      assertEqual(ts[1].actor, "agent", "actor")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match listEntries("s1") {
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
  match listEntries("s1") {
    case Ok(es) -> assertEqual(es[0].reviewState, "resolved", "blocker resolved")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "a stale plan is rejected and writes nothing" {
  val path = useFreshTestDb("ledger-conflict")
  defer {
    cleanupTestDb(path)
  }
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
      match applyItemUpdate("s1", plan.item, stale.updatedSeq, plan.fromState, plan.stateChanged, "human", "which API?", auto, false) {
        case Ok(applied) -> assertTrue(not applied, "stale version must not apply")
        case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
      }
    }
  }
  assertEqual(mustItem("s1", "gh:a/b#1").state, "in_progress", "state unchanged")
  match listEntries("s1") {
    case Ok(es) -> assertEqualInt(es.length.toInt(), 0, "no blocker written")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match listTransitions("s1", "gh:a/b#1") {
    case Ok(ts) -> assertEqualInt(ts.length.toInt(), 1, "only the winning transition")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "entries round-trip and the cursor returns only changes" {
  val path = useFreshTestDb("ledger-entries")
  defer {
    cleanupTestDb(path)
  }
  val e1 = mustInsert(declaredEntry("s1", "decision", "review", "pending"))
  assertEqual(e1.optionsConsidered[1], "postgres, with \"quotes\"", "options round-trip")
  assertEqual(e1.files[0], "src/db.l", "files")
  assertEqual(e1.tags[0], "schema", "tags")
  assertEqual(e1.transcriptSeq, "12", "transcript ref")
  val cursor = match currentSeq("s1") { case Ok(s) -> s; case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e)) }
  val e2 = mustInsert(declaredEntry("s1", "note", "info", "not_required"))
  match entriesChangedAfter("s1", cursor) {
    case Ok(es) -> {
      assertEqualInt(es.length.toInt(), 1, "only the new entry")
      assertEqual(es[0].id, e2.id, "the new entry")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match currentSeq("never-written") {
    case Ok(s) -> assertEqual(s, "0", "fresh session cursor")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "a review updates the entry and queues feedback delivered exactly once" {
  val path = useFreshTestDb("ledger-review")
  defer {
    cleanupTestDb(path)
  }
  val e = mustInsert(declaredEntry("s1", "shortcut", "review", "pending"))
  match reviewEntry("s1", e, "rejected", "reject", "Don't skip; quarantine it.", "gh-1") {
    case Ok(f) -> {
      assertEqual(f.entryId, e.id, "linked to the entry")
      assertEqual(f.itemId, "gh:a/b#1", "inherits the entry's item")
      assertEqual(f.deliveredAt, "", "undelivered")
    }
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match addFeedback("s1", "", "directive", "Also update the changelog.", "gh-1") {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match getEntry("s1", e.id) {
    case Ok(Some(stored)) -> {
      assertEqual(stored.reviewState, "rejected", "review state")
      assertEqual(stored.reviewComment, "Don't skip; quarantine it.", "comment")
      assertEqual(stored.reviewBy, "gh-1", "reviewer")
    }
    case Ok(None) -> assertTrue(false, "entry missing")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match pendingFeedbackCount("s1") {
    case Ok(n) -> assertEqualInt(n, 2, "two pending")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match collectFeedback("s1", "mcp_poll") {
    case Ok(fs) -> {
      assertEqualInt(fs.length.toInt(), 2, "both delivered")
      assertEqual(fs[0].deliveredVia, "mcp_poll", "via")
    }
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match collectFeedback("s1", "mcp_poll") {
    case Ok(fs) -> assertEqualInt(fs.length.toInt(), 0, "never delivered twice")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match pendingFeedbackCount("s1") {
    case Ok(n) -> assertEqualInt(n, 0, "none pending")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
}

test "a released claim is delivered again" {
  val path = useFreshTestDb("ledger-release")
  defer {
    cleanupTestDb(path)
  }
  match addFeedback("s1", "", "directive", "Use API v2.", "gh-1") {
    case Ok(_) -> ()
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match collectFeedback("s1", "mcp_poll") {
    case Ok(fs) -> assertEqualInt(fs.length.toInt(), 1, "claimed")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  // The read-back failure path: the claimed batch is handed back.
  releaseFeedbackBatch("s1", batchOf("s1"))
  match pendingFeedbackCount("s1") {
    case Ok(n) -> assertEqualInt(n, 1, "pending again")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
  match collectFeedback("s1", "mcp_poll") {
    case Ok(fs) -> assertEqualInt(fs.length.toInt(), 1, "delivered on the next check")
    case Err(err) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(err))
  }
}

func batchOf(sid: in String): String {
  match CloudAgents.Sqlite.query("SELECT delivery_batch FROM ledger_feedback WHERE session_id = '" + sid + "' LIMIT 1") {
    case Ok(rows) -> {
      val r = CloudAgents.Sqlite.getRowArrayValue(rows, 0)
      return CloudAgents.Sqlite.getStringArrayValue(r.cols, 0)
    }
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "the inbox is scoped to the owner and orders blocking first" {
  val path = useFreshTestDb("ledger-inbox")
  defer {
    cleanupTestDb(path)
  }
  exec(
    "INSERT INTO sessions (id, user_id, repo_url, branch, container_id, harness, model, native_session_id, status, created_at, last_message_at) VALUES ('s1', 'alice', 'https://github.com/a/b', 'main', '', 'claude', '', 's1', 'IDLE', '1', '1')"
  )
  exec(
    "INSERT INTO sessions (id, user_id, repo_url, branch, container_id, harness, model, native_session_id, status, created_at, last_message_at) VALUES ('s2', 'bob', 'https://github.com/c/d', 'main', '', 'claude', '', 's2', 'IDLE', '1', '1')"
  )
  mustInsert(declaredEntry("s1", "shortcut", "review", "pending"))
  mustInsert(declaredEntry("s1", "blocker", "blocking", "pending"))
  mustInsert(declaredEntry("s1", "note", "info", "not_required"))
  mustInsert(declaredEntry("s2", "shortcut", "review", "pending"))
  match inboxForUser("alice") {
    case Ok(xs) -> {
      assertEqualInt(xs.length.toInt(), 2, "alice sees her two attention entries only")
      assertEqual(xs[0].ledgerEntry.kind, "blocker", "blocking first")
      assertEqual(xs[0].repoUrl, "https://github.com/a/b", "session context")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "policy cache round-trips" {
  val path = useFreshTestDb("ledger-policy")
  defer {
    cleanupTestDb(path)
  }
  match getPolicyCache("s1") {
    case Ok(p) -> assertEqual(p.status, "", "unfetched")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match setPolicyCache("s1", "loaded", "{\"rules\":[]}", "") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match getPolicyCache("s1") {
    case Ok(p) -> {
      assertEqual(p.status, "loaded", "status")
      assertEqual(p.json, "{\"rules\":[]}", "json")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "profiles that granted retired tools are granted the ledger tools" {
  val path = useFreshTestDb("ledger-profiles")
  defer {
    cleanupTestDb(path)
  }
  exec("INSERT INTO profile_tools (id, profile_id, user_id, tool_name) VALUES ('t1', 'p1', 'alice', 'add_todo')")
  exec("INSERT INTO profile_tools (id, profile_id, user_id, tool_name) VALUES ('t2', 'p1', 'alice', 'notify')")
  exec("INSERT INTO profile_tools (id, profile_id, user_id, tool_name) VALUES ('t3', 'p2', 'alice', 'notify')")
  // Re-run the migration's statements (all idempotent) against these grants.
  match CloudAgents.Sqlite.executeTransaction(sessionLedgerMigrationSql()) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Sqlite.executeTransaction(sessionLedgerMigrationSql()) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "second run: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val p1 = toolsOf("p1")
  assertTrue(p1.contains("ledger_check_feedback,"), "p1 gains ledger tools: " + p1)
  assertTrue(p1.contains("ledger_get_state,"), "p1 gains every ledger tool: " + p1)
  assertTrue(p1.contains("notify,"), "p1 keeps notify")
  assertTrue(not p1.contains("add_todo"), "retired tool removed")
  assertEqual(toolsOf("p2"), "notify,", "p2 never granted a retired tool, so it is unchanged")
}

test "a profile shared across user ids is granted each ledger tool once" {
  val path = useFreshTestDb("ledger-profiles-shared")
  defer {
    cleanupTestDb(path)
  }
  exec("INSERT INTO profile_tools (id, profile_id, user_id, tool_name) VALUES ('t1', 'p1', 'alice', 'add_todo')")
  exec("INSERT INTO profile_tools (id, profile_id, user_id, tool_name) VALUES ('t2', 'p1', 'bob', 'list_todos')")
  match CloudAgents.Sqlite.executeTransaction(sessionLedgerMigrationSql()) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val p1 = toolsOf("p1")
  assertTrue(p1.startsWith("ledger_ask,ledger_check_feedback,"), "each tool once: " + p1)
  assertTrue(not p1.contains("ledger_ask,ledger_ask"), "no duplicates: " + p1)
}

// A profile's granted tool names, sorted, each followed by ",".
func toolsOf(profileId: in String): String {
  match CloudAgents.Sqlite.query("SELECT tool_name FROM profile_tools WHERE profile_id = '" + profileId + "' ORDER BY tool_name") {
    case Ok(rows) -> {
      var acc = ""
      var i = 0
      while i < CloudAgents.Sqlite.getRowArrayLength(rows) {
        val r = CloudAgents.Sqlite.getRowArrayValue(rows, i)
        acc = acc + CloudAgents.Sqlite.getStringArrayValue(r.cols, 0) + ","
        i = i + 1
      }
      return acc
    }
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// Insert `n` info notes for `sid` directly, numbered 1..n by created_seq.
func bulkNotes(sid: in String, n: in Int): Unit {
  exec(
    "WITH RECURSIVE k(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM k WHERE x < " + toString(n) +
      ") INSERT INTO ledger_entries (id, session_id, item_id, kind, severity, declared_severity, summary, detail, options_json, chosen, rationale, recommendation, proceeding_with, reversible, files_json, tags_json, source, undeclared, matched_entry_id, origin, supersedes, transcript_seq, review_state, review_by, review_at, review_comment, created_at, created_seq, updated_seq) SELECT 'e' || x, '" +
      sid +
      "', '', 'note', 'info', '', 'note ' || x, '', '[]', '', '', '', '', '', '[]', '[]', 'declared', 'false', '', '', '', '', 'not_required', '', '', '', CAST(x AS TEXT), CAST(x AS TEXT), CAST(x AS TEXT) FROM k"
  )
}

test "past the row cap the entry list keeps the newest" {
  val path = useFreshTestDb("ledger-cap")
  defer {
    cleanupTestDb(path)
  }
  bulkNotes("s1", entryRowCap + 3)
  match listEntries("s1") {
    case Ok(es) -> {
      assertEqualInt(es.length.toInt(), entryRowCap, "capped")
      assertEqual(es[0].createdSeq, "4", "the oldest three are the ones left out")
      assertEqual(es[es.length.toInt() - 1].createdSeq, toString(entryRowCap + 3), "the newest is kept, last")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match countEntries("s1") {
    case Ok(n) -> assertEqualInt(n, entryRowCap + 3, "count sees every row")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "the SQL summary matches the in-memory one" {
  val path = useFreshTestDb("ledger-summary")
  defer {
    cleanupTestDb(path)
  }
  val ids: slice[String] = ["gh:a/b#1", "gh:a/b#2", "gh:a/b#3"]
  val _ = register("s1", ids)
  val _ = move("s1", "gh:a/b#1", "in_progress", "", noStrings(), "agent")
  val _ = move("s1", "gh:a/b#2", "blocked", "waiting", ["gh:a/b#1"], "agent")
  val _ = mustInsert(declaredEntry("s1", "shortcut", "review", "pending"))
  val _ = mustInsert(declaredEntry("s1", "decision", "info", "not_required"))
  val fromSql = match summaryOf("s1", 2) { case Ok(x) -> x; case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e)) }
  val items = match listItems("s1") { case Ok(xs) -> xs; case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e)) }
  val entries = match listEntries("s1") {
    case Ok(es) -> es
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val inMemory = summarize("s1", items, entries, 2)
  assertEqual(fromSql.toJson(), inMemory.toJson(), "same counts either way")
  assertEqual(fromSql.blockingCount, "1", "the blocker entry is counted")
}

test "re-registering without a url keeps the item's url" {
  val path = useFreshTestDb("ledger-url")
  defer {
    cleanupTestDb(path)
  }
  val ids: slice[String] = ["gh:a/b#7"]
  val titles: slice[String] = ["Seven"]
  val custom: slice[String] = ["https://example.com/tracker/7"]
  match registerItems("s1", ids, titles, custom) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val _ = register("s1", ids)
  assertEqual(mustItem("s1", "gh:a/b#7").url, "https://example.com/tracker/7", "custom url kept")
  val fresh: slice[String] = ["gh:a/b#8"]
  val _ = register("s1", fresh)
  assertEqual(mustItem("s1", "gh:a/b#8").url, "https://github.com/a/b/issues/8", "a new item gets the ref's url")
}
