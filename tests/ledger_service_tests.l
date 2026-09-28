//! End-to-end tests for the session ledger through its HTTP handler
//! functions (docs/session-ledger.md §6, §10): the agent side exactly as the
//! shim calls it (callback-token auth, JSON body, 200 envelope), and the
//! human side exactly as the PWA calls it (owner-scoped). Mirrors the spec's
//! Phase 1 / Phase 2 acceptance scenario minus the container: a three-issue
//! batch with a decision, a blocked item, a rejected entry whose feedback is
//! delivered to the agent once, and auto-unblock. Live SQLite, no network.
@test_module
package CloudAgents.LedgerServiceTests

import Std.Core
import Std.Testing
import Std.Uuid
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Service
import CloudAgents.LedgerHandlers
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

// A session owned by `owner` on github.com/acme/shop with callback token
// `token` (stored, like a real session, only as its hash).
func seedSession(id: in String, owner: in String, token: in String): Unit {
  exec(
    "INSERT INTO sessions (id, user_id, repo_url, branch, container_id, harness, model, native_session_id, status, created_at, last_message_at, callback_token_hash) VALUES ('" +
      id +
      "', '" +
      owner +
      "', 'https://github.com/acme/shop', 'main', '', 'claude', '', '" +
      id +
      "', 'IDLE', '1', '1', '" +
      CloudAgents.Auth.hashCallbackToken(token) +
      "')"
  )
}

// Call a ledger op as the agent; returns the envelope (fails on HTTP error).
func agent(sid: in String, op: in String, body: in String): LedgerToolEnvelope {
  match ledgerCallbackHandler(sid, op, "Bearer tok-" + sid, body) {
    case Ok(env) -> return env
    case Err(e) -> panic(op + " returned HTTP " + toString(e.status) + ": " + e.message)
  }
}

func agentOk(sid: in String, op: in String, body: in String): String {
  val env = agent(sid, op, body)
  assertEqual(env.ok, "true", op + " should succeed; error: " + env.error)
  return env.reply
}

func status(item: in String, state: in String, reason: in String, blockedBy: in String): String {
  return "{\"item\":\"" + item + "\",\"state\":\"" + state + "\",\"reason\":\"" + reason + "\",\"blockedBy\":[" +
    blockedBy +
    "],\"prerequisiteProposal\":\"\",\"recommendation\":\"Merge #1 first.\",\"prUrl\":\"\"}"
}

test "agent calls are authenticated with the session's callback token" {
  val path = useFreshTestDb("ledger-svc-auth")
  defer {
    cleanupTestDb(path)
  }
  seedSession("s1", "alice", "tok-s1")
  match ledgerCallbackHandler("s1", "state", "Bearer wrong", "{}") {
    case Ok(_) -> assertTrue(false, "a wrong token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 401, "401")
  }
  match ledgerCallbackHandler("nope", "state", "Bearer tok-nope", "{}") {
    case Ok(_) -> assertTrue(false, "an unknown session must be rejected")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
  match ledgerCallbackHandler("s1", "drop-tables", "Bearer tok-s1", "{}") {
    case Ok(_) -> assertTrue(false, "an unknown op must be rejected")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown op is 404")
  }
  val bad = agent("s1", "decision", "not json")
  assertEqual(bad.ok, "false", "a malformed body is an in-band error")
  assertTrue(bad.error.contains("not valid JSON"), bad.error)
}

test "a three-issue batch: register, progress, decide, block, review, feedback, auto-unblock" {
  val path = useFreshTestDb("ledger-svc-flow")
  defer {
    cleanupTestDb(path)
  }
  seedSession("s1", "alice", "tok-s1")

  // Register the batch in the three forms an agent writes refs.
  val reg = agentOk(
    "s1",
    "register-items",
    "{\"items\":[{\"id\":\"#1\",\"title\":\"Add schema\",\"url\":\"\"},{\"id\":\"acme/shop#2\",\"title\":\"Use schema\",\"url\":\"\"},{\"id\":\"https://github.com/acme/shop/issues/3\",\"title\":\"Docs\",\"url\":\"\"}]}"
  )
  assertTrue(reg.contains("\"registered\":\"3\""), reg)

  agentOk("s1", "item-status", status("#1", "in_progress", "", ""))
  val decision = agentOk(
    "s1",
    "decision",
    "{\"summary\":\"Store refs as JSON arrays\",\"detail\":\"\",\"optionsConsidered\":[\"JSON\",\"join table\"],\"chosen\":\"JSON\",\"rationale\":\"Small, read whole\",\"recommendation\":\"Accept\",\"reversible\":\"false\",\"item\":\"#1\",\"tags\":[\"schema\"],\"files\":[],\"severity\":\"\",\"supersedes\":\"\"}"
  )
  assertTrue(
    decision.contains("\"severity\":\"review\""),
    "irreversible schema decision is raised to review: " + decision
  )

  // Block #2 on #1: a blocking entry + a notification.
  val blocked = agentOk("s1", "item-status", status("#2", "blocked", "Needs the schema from #1", "\"#1\""))
  assertTrue(blocked.contains("\"state\":\"blocked\""), blocked)
  match CloudAgents.Repository.listNotifications("s1") {
    case Ok(ns) -> assertEqualInt(ns.length.toInt(), 1, "the owner is notified of the blocker")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // An illegal move is an in-band error the agent can read.
  val illegal = agent("s1", "item-status", status("#3", "done", "", ""))
  assertEqual(illegal.ok, "false", "queued -> done is illegal")
  assertTrue(illegal.error.contains("cannot move gh:acme/shop#3 from queued to done"), illegal.error)

  // The human sees the attention queue and rejects the decision.
  CloudAgents.Auth.setCurrentUserId("alice")
  val snap = match getLedgerHandler("s1", "") { case Ok(s) -> s; case Err(e) -> panic("getLedger: " + e.message) }
  assertEqual(snap.full, "true", "full snapshot")
  assertEqual(snap.summary.total, "3", "three items")
  assertEqual(snap.summary.blocked, "1", "one blocked")
  assertEqual(snap.summary.pendingReview, "2", "decision + blocker need review")
  assertEqual(snap.summary.blockingCount, "1", "one blocking")
  assertEqualInt(snap.items.length.toInt(), 3, "items")
  assertEqual(snap.items[1].blockedBy[0], "gh:acme/shop#1", "blockedBy normalised")
  var decisionId = ""
  var i = 0
  while i < snap.entries.length.toInt() {
    if snap.entries[i].kind == "decision" {
      decisionId = snap.entries[i].id
    }
    i = i + 1
  }
  assertTrue(decisionId.length.toInt() > 0, "decision listed")
  match reviewLedgerEntryHandler("s1", decisionId, ReviewEntryRequest(kind = "reject", body = "")) {
    case Ok(_) -> assertTrue(false, "reject needs a body")
    case Err(e) -> assertEqualInt(e.status, 400, "400")
  }
  match reviewLedgerEntryHandler("s1", decisionId, ReviewEntryRequest(kind = "reject", body = "Use a join table; we query by blocker.")) {
    case Ok(f) -> assertEqual(f.kind, "reject", "feedback queued")
    case Err(e) -> assertTrue(false, "review: " + e.message)
  }

  // The next run is nudged, and the agent's next reply carries the count.
  assertTrue(nextRunPromptPrefix("s1", "alice", "").contains("ledger_check_feedback"), "next-run nudge")
  val nudged = agentOk("s1", "item-status", status("#1", "in_progress", "", ""))
  assertTrue(nudged.contains("\"pendingFeedback\":\"1\""), nudged)

  // Delivered exactly once, with the entry it answers.
  val fb = agentOk("s1", "check-feedback", "{}")
  assertTrue(fb.contains("Use a join table"), fb)
  assertTrue(fb.contains("Store refs as JSON arrays"), "names the entry: " + fb)
  val again = agentOk("s1", "check-feedback", "{}")
  assertTrue(again.contains("\"feedback\":[]"), again)
  assertEqual(nextRunPromptPrefix("s1", "alice", ""), "", "no nudge once delivered")

  // Finishing #1 unblocks #2 and resolves its blocker.
  val finished = agentOk("s1", "item-status", status("#1", "done", "", ""))
  assertTrue(finished.contains("gh:acme/shop#2"), "auto-unblocked: " + finished)
  val after = match getLedgerHandler("s1", "") { case Ok(s) -> s; case Err(e) -> panic("getLedger: " + e.message) }
  assertEqual(after.summary.done, "1", "one done")
  assertEqual(after.summary.queued, "2", "#2 requeued alongside #3")
  assertEqual(after.summary.blockingCount, "0", "blocker resolved")

  // Delta polling returns only what changed.
  val delta = match getLedgerHandler("s1", after.cursor) {
    case Ok(s) -> s
    case Err(e) -> panic("delta: " + e.message)
  }
  assertEqual(delta.unchanged, "true", "no changes since the cursor")
  agentOk(
    "s1",
    "note",
    "{\"summary\":\"Left a TODO in docs\",\"detail\":\"\",\"recommendation\":\"\",\"needsReview\":\"false\",\"item\":\"#3\",\"tags\":[],\"files\":[],\"severity\":\"\"}"
  )
  val delta2 = match getLedgerHandler("s1", after.cursor) {
    case Ok(s) -> s
    case Err(e) -> panic("delta: " + e.message)
  }
  assertEqual(delta2.full, "false", "a delta")
  assertEqualInt(delta2.entries.length.toInt(), 1, "only the new note")

  // The agent can re-orient.
  val state = agentOk("s1", "state", "{}")
  assertTrue(state.contains("\"state\":\"done\""), state)

  // The inbox shows nothing blocking any more but the review-less note
  // never entered it.
  match ledgerInboxHandler() {
    case Ok(v) -> assertEqualInt(v.entries.length.toInt(), 0, "decision reviewed, blocker resolved, note info")
    case Err(e) -> assertTrue(false, e.message)
  }
}

test "the human API is owner-scoped" {
  val path = useFreshTestDb("ledger-svc-owner")
  defer {
    cleanupTestDb(path)
  }
  seedSession("s1", "alice", "tok-s1")
  CloudAgents.Auth.setCurrentUserId("mallory")
  match getLedgerHandler("s1", "") {
    case Ok(_) -> assertTrue(false, "another user's ledger must not be readable")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
  match ledgerFeedbackHandler("s1", LedgerFeedbackRequest(item = "", kind = "directive", body = "rm -rf")) {
    case Ok(_) -> assertTrue(false, "another user cannot direct the agent")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
}

test "human item actions follow the state machine" {
  val path = useFreshTestDb("ledger-svc-human")
  defer {
    cleanupTestDb(path)
  }
  seedSession("s1", "alice", "tok-s1")
  CloudAgents.Auth.setCurrentUserId("alice")
  val add = RegisterItemsRequest(items = [RegisterItemInput(id = "#7", title = "Human-queued", url = "")])
  match addLedgerItemsHandler("s1", add) {
    case Ok(r) -> assertEqual(r.registered, "1", "added")
    case Err(e) -> assertTrue(false, e.message)
  }
  agentOk("s1", "item-status", status("#7", "needs_human", "Which API version?", ""))
  match ledgerItemStateHandler("s1", LedgerItemStateRequest(item = "gh:acme/shop#7", to = "done", reason = "")) {
    case Ok(_) -> assertTrue(false, "needs_human -> done is illegal")
    case Err(e) -> assertEqualInt(e.status, 400, "400")
  }
  match ledgerItemStateHandler("s1", LedgerItemStateRequest(item = "gh:acme/shop#7", to = "queued", reason = "v2")) {
    case Ok(w) -> assertEqual(w.state, "queued", "requeued")
    case Err(e) -> assertTrue(false, e.message)
  }
  match ledgerFeedbackHandler("s1", LedgerFeedbackRequest(item = "#7", kind = "directive", body = "Use API v2.")) {
    case Ok(f) -> assertEqual(f.itemId, "gh:acme/shop#7", "item-level directive")
    case Err(e) -> assertTrue(false, e.message)
  }
  // An agent can't take an item back out of needs_human on its own.
  agentOk("s1", "item-status", status("#7", "needs_human", "Still unsure", ""))
  val stuck = agent("s1", "item-status", status("#7", "in_progress", "", ""))
  assertEqual(stuck.ok, "false", "needs_human -> in_progress is human-only")
}

test "a blocker the human raised resolves when the human clears it" {
  val path = useFreshTestDb("ledger-svc-human-blocker")
  defer {
    cleanupTestDb(path)
  }
  seedSession("s1", "alice", "tok-s1")
  CloudAgents.Auth.setCurrentUserId("alice")
  val add = RegisterItemsRequest(items = [RegisterItemInput(id = "#8", title = "Escalated", url = "")])
  match addLedgerItemsHandler("s1", add) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, e.message)
  }
  match ledgerItemStateHandler("s1", LedgerItemStateRequest(item = "gh:acme/shop#8", to = "needs_human", reason = "Legal must sign off")) {
    case Ok(w) -> assertEqual(w.state, "needs_human", "escalated")
    case Err(e) -> assertTrue(false, e.message)
  }
  assertEqual(blockerReview("s1", "gh:acme/shop#8"), "pending", "blocker raised")
  match ledgerItemStateHandler("s1", LedgerItemStateRequest(item = "gh:acme/shop#8", to = "queued", reason = "Signed off")) {
    case Ok(w) -> assertEqual(w.state, "queued", "requeued")
    case Err(e) -> assertTrue(false, e.message)
  }
  assertEqual(blockerReview("s1", "gh:acme/shop#8"), "resolved", "blocker resolved on clear")
}

// The review state of an item's (single) automatic blocker entry.
func blockerReview(sid: in String, itemId: in String): String {
  match CloudAgents.Sqlite.query("SELECT review_state FROM ledger_entries WHERE session_id = '" + sid + "' AND item_id = '" + itemId + "' AND kind = 'blocker'") {
    case Ok(rows) -> {
      if CloudAgents.Sqlite.getRowArrayLength(rows) != 1 {
        return "rows=" + toString(CloudAgents.Sqlite.getRowArrayLength(rows))
      }
      val r = CloudAgents.Sqlite.getRowArrayValue(rows, 0)
      return CloudAgents.Sqlite.getStringArrayValue(r.cols, 0)
    }
    case Err(e) -> return CloudAgents.Sqlite.dbErrorMessage(e)
  }
}

test "tool arguments are decoded tolerantly, as LLM callers fill them" {
  val path = useFreshTestDb("ledger-svc-args")
  defer {
    cleanupTestDb(path)
  }
  seedSession("s1", "alice", "tok-s1")
  // Bare ref strings instead of objects.
  val reg = agentOk("s1", "register-items", "{\"items\":[\"#1\", \"local:tidy-up\"]}")
  assertTrue(reg.contains("\"registered\":\"2\""), reg)
  // A real boolean and a single string where a list is expected.
  val d = agentOk(
    "s1",
    "decision",
    "{\"summary\":\"Keep the old API\",\"chosen\":\"keep\",\"rationale\":\"no callers yet\",\"reversible\":true,\"tags\":\"api-change\"}"
  )
  assertTrue(d.contains("\"severity\":\"review\""), "api-change tag parsed from a lone string: " + d)
  // Missing required fields are named.
  val missing = agent("s1", "register-items", "{}")
  assertEqual(missing.ok, "false", "items required")
  assertTrue(missing.error.contains("'items' is required"), missing.error)
  val wrongType = agent("s1", "decision", "{\"summary\":{\"x\":1}}")
  assertEqual(wrongType.ok, "false", "object where a string belongs")
  assertTrue(wrongType.error.contains("'summary' must be a string"), wrongType.error)
  // No arguments at all is fine for the argument-free tools.
  agentOk("s1", "state", "")
  agentOk("s1", "check-feedback", "null")
  // Unknown fields are ignored rather than rejected.
  val _ = agentOk("s1", "note", "{\"summary\":\"fine\",\"extra\":42}")
}
