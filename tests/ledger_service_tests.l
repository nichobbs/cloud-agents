//! End-to-end tests for the session ledger through its HTTP handler
//! functions (docs/session-ledger.md §6, §10): the agent side exactly as the
//! shim calls it (callback-token auth, JSON body, 200 envelope), and the
//! human side exactly as the PWA calls it (owner-scoped). Mirrors the spec's
//! Phase 1 / Phase 2 acceptance scenario minus the container: a three-issue
//! batch with a decision, a blocked item, a rejected entry whose feedback is
//! delivered to the agent once, and auto-unblock. Live Postgres, no network;
//! every test is a fresh user with a fresh session id.
@test_module
package CloudAgents.LedgerServiceTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import Web
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Service
import CloudAgents.LedgerHandlers

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
  println("SKIP: ledger service tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

// A new session owned by `owner` on github.com/acme/shop with callback token
// "tok-" + its id (stored, like a real session, only as its hash). Session ids
// are global (session_routes), so each is unique to the call.
func seedSession(owner: in String): String {
  val id = "s-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  val sc = CloudAgents.Pg.personalScope(owner)
  match CloudAgents.SessionStore.addSession(makeAgentSession(sessionId = id, repoUrl = "https://github.com/acme/shop", branch = "main", containerId = "", harness = "claude", model = "", nativeSessionId = id), sc) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val u = match CloudAgents.PgStore.open(sc) {
    case Ok(x) -> x
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, "UPDATE session_routes SET callback_token_hash = @p1 WHERE session_id = @p0 AND tenant_id = @p2", [id, CloudAgents.Auth.hashCallbackToken("tok-" + id), sc.tenantId]) {
    case Ok(n) -> assertEqualInt(n, 1, "token stored on the session's route")
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return id
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
  if not live() {
    return
  }
  val me = freshUser("ledger-svc-auth")
  val sid = seedSession(me)
  match ledgerCallbackHandler(sid, "state", "Bearer wrong", "{}") {
    case Ok(_) -> assertTrue(false, "a wrong token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 401, "401")
  }
  match ledgerCallbackHandler("nope", "state", "Bearer tok-nope", "{}") {
    case Ok(_) -> assertTrue(false, "an unknown session must be rejected")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
  match ledgerCallbackHandler(sid, "drop-tables", "Bearer tok-" + sid, "{}") {
    case Ok(_) -> assertTrue(false, "an unknown op must be rejected")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown op is 404")
  }
  val bad = agent(sid, "decision", "not json")
  assertEqual(bad.ok, "false", "a malformed body is an in-band error")
  assertTrue(bad.error.contains("not valid JSON"), bad.error)
}

test "a three-issue batch: register, progress, decide, block, review, feedback, auto-unblock" {
  if not live() {
    return
  }
  val me = freshUser("ledger-svc-flow")
  val sid = seedSession(me)

  // Register the batch in the three forms an agent writes refs.
  val reg = agentOk(
    sid,
    "register-items",
    "{\"items\":[{\"id\":\"#1\",\"title\":\"Add schema\",\"url\":\"\"},{\"id\":\"acme/shop#2\",\"title\":\"Use schema\",\"url\":\"\"},{\"id\":\"https://github.com/acme/shop/issues/3\",\"title\":\"Docs\",\"url\":\"\"}]}"
  )
  assertTrue(reg.contains("\"registered\":\"3\""), reg)

  agentOk(sid, "item-status", status("#1", "in_progress", "", ""))
  val decision = agentOk(
    sid,
    "decision",
    "{\"summary\":\"Store refs as JSON arrays\",\"detail\":\"\",\"optionsConsidered\":[\"JSON\",\"join table\"],\"chosen\":\"JSON\",\"rationale\":\"Small, read whole\",\"recommendation\":\"Accept\",\"reversible\":\"false\",\"item\":\"#1\",\"tags\":[\"schema\"],\"files\":[],\"severity\":\"\",\"supersedes\":\"\"}"
  )
  assertTrue(
    decision.contains("\"severity\":\"review\""),
    "irreversible schema decision is raised to review: " + decision
  )

  // Block #2 on #1: a blocking entry + a notification.
  val blocked = agentOk(sid, "item-status", status("#2", "blocked", "Needs the schema from #1", "\"#1\""))
  assertTrue(blocked.contains("\"state\":\"blocked\""), blocked)
  match CloudAgents.Repository.listNotifications(sid, CloudAgents.Auth.requestScope()) {
    case Ok(ns) -> assertEqualInt(ns.length.toInt(), 1, "the owner is notified of the blocker")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // An illegal move is an in-band error the agent can read.
  val illegal = agent(sid, "item-status", status("#3", "done", "", ""))
  assertEqual(illegal.ok, "false", "queued -> done is illegal")
  assertTrue(illegal.error.contains("cannot move gh:acme/shop#3 from queued to done"), illegal.error)

  // The human sees the attention queue and rejects the decision.
  CloudAgents.Auth.setCurrentUserId(me)
  val snap = match getLedgerHandler(sid, "") { case Ok(s) -> s; case Err(e) -> panic("getLedger: " + e.message) }
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
  match reviewLedgerEntryHandler(sid, decisionId, ReviewEntryRequest(kind = "reject", body = "")) {
    case Ok(_) -> assertTrue(false, "reject needs a body")
    case Err(e) -> assertEqualInt(e.status, 400, "400")
  }
  match reviewLedgerEntryHandler(sid, decisionId, ReviewEntryRequest(kind = "reject", body = "Use a join table; we query by blocker.")) {
    case Ok(f) -> assertEqual(f.kind, "reject", "feedback queued")
    case Err(e) -> assertTrue(false, "review: " + e.message)
  }

  // The next run is nudged, and the agent's next reply carries the count.
  assertTrue(nextRunPromptPrefix(sid, "").contains("ledger_check_feedback"), "next-run nudge")
  val nudged = agentOk(sid, "item-status", status("#1", "in_progress", "", ""))
  assertTrue(nudged.contains("\"pendingFeedback\":\"1\""), nudged)

  // Delivered exactly once, with the entry it answers.
  val fb = agentOk(sid, "check-feedback", "{}")
  assertTrue(fb.contains("Use a join table"), fb)
  assertTrue(fb.contains("Store refs as JSON arrays"), "names the entry: " + fb)
  val again = agentOk(sid, "check-feedback", "{}")
  assertTrue(again.contains("\"feedback\":[]"), again)
  assertEqual(nextRunPromptPrefix(sid, ""), "", "no nudge once delivered")

  // Finishing #1 unblocks #2 and resolves its blocker.
  val finished = agentOk(sid, "item-status", status("#1", "done", "", ""))
  assertTrue(finished.contains("gh:acme/shop#2"), "auto-unblocked: " + finished)
  val after = match getLedgerHandler(sid, "") { case Ok(s) -> s; case Err(e) -> panic("getLedger: " + e.message) }
  assertEqual(after.summary.done, "1", "one done")
  assertEqual(after.summary.queued, "2", "#2 requeued alongside #3")
  assertEqual(after.summary.blockingCount, "0", "blocker resolved")

  // Delta polling returns only what changed.
  val delta = match getLedgerHandler(sid, after.cursor) { case Ok(s) -> s; case Err(e) -> panic("delta: " + e.message) }
  assertEqual(delta.unchanged, "true", "no changes since the cursor")
  agentOk(
    sid,
    "note",
    "{\"summary\":\"Left a TODO in docs\",\"detail\":\"\",\"recommendation\":\"\",\"needsReview\":\"false\",\"item\":\"#3\",\"tags\":[],\"files\":[],\"severity\":\"\"}"
  )
  val delta2 = match getLedgerHandler(sid, after.cursor) {
    case Ok(s) -> s
    case Err(e) -> panic("delta: " + e.message)
  }
  assertEqual(delta2.full, "false", "a delta")
  assertEqualInt(delta2.entries.length.toInt(), 1, "only the new note")

  // The agent can re-orient.
  val state = agentOk(sid, "state", "{}")
  assertTrue(state.contains("\"state\":\"done\""), state)

  // The inbox shows nothing blocking any more but the review-less note
  // never entered it.
  match ledgerInboxHandler() {
    case Ok(v) -> assertEqualInt(v.entries.length.toInt(), 0, "decision reviewed, blocker resolved, note info")
    case Err(e) -> assertTrue(false, e.message)
  }
}

test "the human API is owner-scoped" {
  if not live() {
    return
  }
  val me = freshUser("ledger-svc-owner")
  val sid = seedSession(me)
  val mallory = newUser("ledger-mallory")
  CloudAgents.Auth.setCurrentUserId(mallory)
  match getLedgerHandler(sid, "") {
    case Ok(_) -> assertTrue(false, "another user's ledger must not be readable")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
  match ledgerFeedbackHandler(sid, LedgerFeedbackRequest(item = "", kind = "directive", body = "rm -rf")) {
    case Ok(_) -> assertTrue(false, "another user cannot direct the agent")
    case Err(e) -> assertEqualInt(e.status, 404, "404")
  }
  // The owner records something real, so the remaining routes have a real
  // entry and item to be refused.
  CloudAgents.Auth.setCurrentUserId(me)
  val add = RegisterItemsRequest(items = [RegisterItemInput(id = "#5", title = "Owned", url = "")])
  match addLedgerItemsHandler(sid, add) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, e.message)
  }
  val recorded = agentOk(
    sid,
    "deviation",
    "{\"kind\":\"shortcut\",\"summary\":\"Skipped a test\",\"detail\":\"\",\"item\":\"\",\"tags\":[],\"files\":[],\"severity\":\"\",\"recommendation\":\"\",\"reversible\":\"\"}"
  )
  val entryId = jsonField(recorded, "id")
  assertTrue(entryId.length.toInt() > 0, recorded)
  CloudAgents.Auth.setCurrentUserId(mallory)
  match getLedgerEntryHandler(sid, entryId) {
    case Ok(_) -> assertTrue(false, "entry detail is owner-scoped")
    case Err(e) -> assertEqualInt(e.status, 404, "entry detail 404")
  }
  match reviewLedgerEntryHandler(sid, entryId, ReviewEntryRequest(kind = "approve", body = "")) {
    case Ok(_) -> assertTrue(false, "review is owner-scoped")
    case Err(e) -> assertEqualInt(e.status, 404, "review 404")
  }
  match addLedgerItemsHandler(sid, add) {
    case Ok(_) -> assertTrue(false, "adding items is owner-scoped")
    case Err(e) -> assertEqualInt(e.status, 404, "add items 404")
  }
  match ledgerItemStateHandler(sid, LedgerItemStateRequest(item = "gh:acme/shop#5", to = "skipped", reason = "")) {
    case Ok(_) -> assertTrue(false, "item state is owner-scoped")
    case Err(e) -> assertEqualInt(e.status, 404, "item state 404")
  }
  CloudAgents.Auth.setCurrentUserId(me)
  match getLedgerEntryHandler(sid, entryId) {
    case Ok(d) -> assertEqual(d.ledgerEntry.reviewState, "pending", "the refused review changed nothing")
    case Err(e) -> assertTrue(false, e.message)
  }
}

// A string field's value from a flat JSON object ("" when absent).
func jsonField(json: in String, name: in String): String {
  val key = "\"" + name + "\":\""
  var i = 0
  val n = json.length.toInt()
  val k = key.length.toInt()
  while i + k <= n {
    if json.substring(i, k) == key {
      var j = i + k
      while j < n and json.substring(j, 1) != "\"" {
        j = j + 1
      }
      return json.substring(i + k, j - i - k)
    }
    i = i + 1
  }
  return ""
}

test "human item actions follow the state machine" {
  if not live() {
    return
  }
  val me = freshUser("ledger-svc-human")
  val sid = seedSession(me)
  CloudAgents.Auth.setCurrentUserId(me)
  val add = RegisterItemsRequest(items = [RegisterItemInput(id = "#7", title = "Human-queued", url = "")])
  match addLedgerItemsHandler(sid, add) {
    case Ok(r) -> assertEqual(r.registered, "1", "added")
    case Err(e) -> assertTrue(false, e.message)
  }
  agentOk(sid, "item-status", status("#7", "needs_human", "Which API version?", ""))
  match ledgerItemStateHandler(sid, LedgerItemStateRequest(item = "gh:acme/shop#7", to = "done", reason = "")) {
    case Ok(_) -> assertTrue(false, "needs_human -> done is illegal")
    case Err(e) -> assertEqualInt(e.status, 400, "400")
  }
  match ledgerItemStateHandler(sid, LedgerItemStateRequest(item = "gh:acme/shop#7", to = "queued", reason = "v2")) {
    case Ok(w) -> assertEqual(w.state, "queued", "requeued")
    case Err(e) -> assertTrue(false, e.message)
  }
  match ledgerFeedbackHandler(sid, LedgerFeedbackRequest(item = "#7", kind = "directive", body = "Use API v2.")) {
    case Ok(f) -> assertEqual(f.itemId, "gh:acme/shop#7", "item-level directive")
    case Err(e) -> assertTrue(false, e.message)
  }
  // An agent can't take an item back out of needs_human on its own.
  agentOk(sid, "item-status", status("#7", "needs_human", "Still unsure", ""))
  val stuck = agent(sid, "item-status", status("#7", "in_progress", "", ""))
  assertEqual(stuck.ok, "false", "needs_human -> in_progress is human-only")
}

test "a blocker the human raised resolves when the human clears it" {
  if not live() {
    return
  }
  val me = freshUser("ledger-svc-human-blocker")
  val sid = seedSession(me)
  CloudAgents.Auth.setCurrentUserId(me)
  val add = RegisterItemsRequest(items = [RegisterItemInput(id = "#8", title = "Escalated", url = "")])
  match addLedgerItemsHandler(sid, add) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, e.message)
  }
  match ledgerItemStateHandler(sid, LedgerItemStateRequest(item = "gh:acme/shop#8", to = "needs_human", reason = "Legal must sign off")) {
    case Ok(w) -> assertEqual(w.state, "needs_human", "escalated")
    case Err(e) -> assertTrue(false, e.message)
  }
  assertEqual(blockerReview(sid, "gh:acme/shop#8"), "pending", "blocker raised")
  match ledgerItemStateHandler(sid, LedgerItemStateRequest(item = "gh:acme/shop#8", to = "queued", reason = "Signed off")) {
    case Ok(w) -> assertEqual(w.state, "queued", "requeued")
    case Err(e) -> assertTrue(false, e.message)
  }
  assertEqual(blockerReview(sid, "gh:acme/shop#8"), "resolved", "blocker resolved on clear")
}

// The review state of an item's (single) automatic blocker entry.
func blockerReview(sid: in String, itemId: in String): String {
  val u = match CloudAgents.PgStore.open(CloudAgents.Auth.requestScope()) {
    case Ok(x) -> x
    case Err(e) -> return CloudAgents.Sqlite.dbErrorMessage(e)
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.q(u, "SELECT review_state FROM ledger_entries WHERE session_id = @p0 AND item_id = @p1 AND kind = 'blocker'", [sid, itemId]) {
    case Ok(rows) -> {
      if rows.length.toInt() != 1 {
        return "rows=" + toString(rows.length.toInt())
      }
      return CloudAgents.PgStore.col(rows[0], "review_state")
    }
    case Err(e) -> return CloudAgents.Sqlite.dbErrorMessage(e)
  }
}

test "tool arguments are decoded tolerantly, as LLM callers fill them" {
  if not live() {
    return
  }
  val me = freshUser("ledger-svc-args")
  val sid = seedSession(me)
  // Bare ref strings instead of objects.
  val reg = agentOk(sid, "register-items", "{\"items\":[\"#1\", \"local:tidy-up\"]}")
  assertTrue(reg.contains("\"registered\":\"2\""), reg)
  // A real boolean and a single string where a list is expected.
  val d = agentOk(
    sid,
    "decision",
    "{\"summary\":\"Keep the old API\",\"chosen\":\"keep\",\"rationale\":\"no callers yet\",\"reversible\":true,\"tags\":\"api-change\"}"
  )
  assertTrue(d.contains("\"severity\":\"review\""), "api-change tag parsed from a lone string: " + d)
  // Missing required fields are named.
  val missing = agent(sid, "register-items", "{}")
  assertEqual(missing.ok, "false", "items required")
  assertTrue(missing.error.contains("'items' is required"), missing.error)
  val wrongType = agent(sid, "decision", "{\"summary\":{\"x\":1}}")
  assertEqual(wrongType.ok, "false", "object where a string belongs")
  assertTrue(wrongType.error.contains("'summary' must be a string"), wrongType.error)
  // No arguments at all is fine for the argument-free tools.
  agentOk(sid, "state", "")
  agentOk(sid, "check-feedback", "null")
  // Unknown fields are ignored rather than rejected.
  val _ = agentOk(sid, "note", "{\"summary\":\"fine\",\"extra\":42}")
}

test "a full snapshot says when older rows were left out" {
  if not live() {
    return
  }
  val me = freshUser("ledger-svc-truncated")
  val sid = seedSession(me)
  CloudAgents.Auth.setCurrentUserId(me)
  agentOk(
    sid,
    "note",
    "{\"summary\":\"first\",\"detail\":\"\",\"item\":\"\",\"tags\":[],\"files\":[],\"severity\":\"\"}"
  )
  match getLedgerHandler(sid, "0") {
    case Ok(snap) -> assertEqual(snap.truncated, "false", "small session: complete")
    case Err(e) -> assertTrue(false, e.message)
  }
  val u = match CloudAgents.PgStore.open(CloudAgents.Auth.requestScope()) {
    case Ok(x) -> x
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, "INSERT INTO ledger_entries (id, session_id, item_id, kind, severity, summary, source, undeclared, review_state, created_at, created_seq, updated_seq) " + "SELECT 'bulk' || x::text, @p0, '', 'note', 'review', 'bulk ' || x::text, 'declared', false, 'pending', " + "timestamptz 'epoch' + x * interval '1 millisecond', x, x FROM generate_series(1, 5001) AS x", [sid]) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "bulk insert failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match getLedgerHandler(sid, "0") {
    case Ok(snap) -> {
      assertEqual(snap.truncated, "true", "older rows left out")
      assertEqualInt(snap.entries.length.toInt(), 5000, "capped list")
      assertEqual(snap.summary.pendingReview, "5001", "the summary still counts every row")
    }
    case Err(e) -> assertTrue(false, e.message)
  }
}

test "a session's batch is capped" {
  if not live() {
    return
  }
  val me = freshUser("ledger-svc-itemcap")
  val sid = seedSession(me)
  var batch = 0
  while batch < 5 {
    var items = ""
    var i = 0
    while i < 200 {
      if i > 0 {
        items = items + ","
      }
      items = items + "{\"id\":\"local:item-" + toString(batch * 200 + i) + "\",\"title\":\"\",\"url\":\"\"}"
      i = i + 1
    }
    agentOk(sid, "register-items", "{\"items\":[" + items + "]}")
    batch = batch + 1
  }
  val over = agent(sid, "register-items", "{\"items\":[{\"id\":\"local:one-more\",\"title\":\"\",\"url\":\"\"}]}")
  assertEqual(over.ok, "false", "item 1001 is refused")
  assertTrue(over.error.contains("at most 1000"), over.error)
  val again = agent(sid, "register-items", "{\"items\":[{\"id\":\"local:item-3\",\"title\":\"renamed\",\"url\":\"\"}]}")
  assertEqual(again.ok, "true", "re-registering an existing item still works at the cap")
  // Every other tool registers an unknown item on first mention: same cap.
  val viaNote = agent(sid, "note", "{\"summary\":\"x\",\"item\":\"local:via-note\"}")
  assertEqual(viaNote.ok, "false", "a note can't register item 1001")
  assertTrue(viaNote.error.contains("at most 1000"), viaNote.error)
  val viaStatus = agent(sid, "item-status", status("local:via-status", "in_progress", "", ""))
  assertEqual(viaStatus.ok, "false", "a status change can't register item 1001")
  val known = agent(sid, "note", "{\"summary\":\"x\",\"item\":\"local:item-7\"}")
  assertEqual(known.ok, "true", "a note on an existing item still works at the cap")
}

test "no next-run nudge when MCP callbacks are off" {
  if not live() {
    return
  }
  val me = freshUser("ledger-svc-nocallbacks")
  defer {
    Env.SetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS", "")
  }
  val sid = seedSession(me)
  match ledgerFeedbackHandler(sid, LedgerFeedbackRequest(item = "", kind = "directive", body = "Also update the changelog.")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, e.message)
  }
  assertTrue(nextRunPromptPrefix(sid, "").length.toInt() > 0, "nudged with callbacks on")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS", "0")
  assertEqual(nextRunPromptPrefix(sid, ""), "", "no tool to call, so no nudge")
}

// Run one DDL/DML statement as the schema owner: the service role cannot
// create triggers.
func ownerExec(sql: in String): Unit {
  val conn = match CloudAgents.Pg.connectDsn(Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "")) {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  match conn.execute(sql, []) {
    case Ok(_) -> ()
    case Err(e) -> panic("owner statement failed: " + e.message)
  }
}

// A test-only trigger that, while armed (`times` > 0), moves the session's
// item versions inside the same transaction as the seq bump every write
// starts with, so the version-guarded item update misses exactly as it would
// if another writer had got there first. A lost attempt rolls its whole
// transaction back, so the countdown lives in a sequence (`nextval` is not
// transactional) compared against the armed limit. Scoped to one session id
// and named uniquely, so it is inert for every other test; `disarmConflicts`
// drops it.
func armConflicts(name: in String, sid: in String, times: in Int): Unit {
  ownerExec("DROP TABLE IF EXISTS public." + name)
  ownerExec("DROP SEQUENCE IF EXISTS public." + name + "_s")
  ownerExec("CREATE TABLE public." + name + " (n integer NOT NULL)")
  ownerExec("GRANT SELECT ON public." + name + " TO PUBLIC")
  ownerExec("INSERT INTO public." + name + " (n) VALUES (" + toString(times) + ")")
  ownerExec("CREATE SEQUENCE public." + name + "_s")
  ownerExec("GRANT USAGE ON SEQUENCE public." + name + "_s TO PUBLIC")
  ownerExec(
    "CREATE OR REPLACE FUNCTION public." + name + "_fn() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN " +
      "IF nextval('public." +
      name +
      "_s') <= (SELECT n FROM public." +
      name +
      ") THEN " +
      "UPDATE public.ledger_items SET updated_seq = updated_seq + 1000000 WHERE session_id = NEW.session_id; " +
      "END IF; RETURN NEW; END $f$"
  )
  ownerExec("DROP TRIGGER IF EXISTS " + name + "_trg ON public.ledger_sessions")
  ownerExec(
    "CREATE TRIGGER " + name +
      "_trg AFTER UPDATE OF seq ON public.ledger_sessions FOR EACH ROW WHEN (NEW.session_id = '" +
      sid +
      "') EXECUTE FUNCTION public." +
      name +
      "_fn()"
  )
}

func rearmConflicts(name: in String, times: in Int): Unit {
  ownerExec("UPDATE public." + name + " SET n = " + toString(times))
  ownerExec("ALTER SEQUENCE public." + name + "_s RESTART WITH 1")
}

func disarmConflicts(name: in String): Unit {
  ownerExec("DROP TRIGGER IF EXISTS " + name + "_trg ON public.ledger_sessions")
  ownerExec("DROP FUNCTION IF EXISTS public." + name + "_fn()")
  ownerExec("DROP TABLE IF EXISTS public." + name)
  ownerExec("DROP SEQUENCE IF EXISTS public." + name + "_s")
}

test "a transition that loses a race is re-planned and retried" {
  if not live() {
    return
  }
  val me = freshUser("ledger-svc-conflict")
  val sid = seedSession(me)
  val name = "tc_" + Std.Uuid.uuidToString(Std.Uuid.newUuid()).replace("-", "")
  defer {
    disarmConflicts(name)
  }
  agentOk(sid, "register-items", "{\"items\":[{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"}]}")
  armConflicts(name, sid, 2)
  val moved = agent(sid, "item-status", status("#1", "in_progress", "", ""))
  assertEqual(moved.ok, "true", "applied on the third attempt: " + moved.error)

  rearmConflicts(name, 3)
  val lost = agent(sid, "item-status", status("#1", "pr_open", "", ""))
  assertEqual(lost.ok, "false", "three lost races give up")
  assertTrue(lost.error.contains("changed concurrently"), lost.error)
  rearmConflicts(name, 0)
  val u = match CloudAgents.PgStore.open(CloudAgents.Auth.requestScope()) {
    case Ok(x) -> x
    case Err(e) -> panic(CloudAgents.Sqlite.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.q(u, "SELECT state FROM ledger_items WHERE session_id = @p0 AND item_id = 'gh:acme/shop#1'", [sid]) {
    case Ok(rows) -> assertEqual(
      CloudAgents.PgStore.col(rows[0], "state"),
      "in_progress",
      "the lost update wrote nothing"
    )
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "a blocker notifies the owner" {
  if not live() {
    return
  }
  val me = freshUser("ledger-svc-notify")
  val sid = seedSession(me)
  agentOk(
    sid,
    "register-items",
    "{\"items\":[{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"},{\"id\":\"#2\",\"title\":\"\",\"url\":\"\"}]}"
  )
  agentOk(sid, "item-status", status("#2", "blocked", "needs the schema", "\"#1\""))
  match CloudAgents.Repository.listNotifications(sid, CloudAgents.Auth.requestScope()) {
    case Ok(ns) -> {
      assertEqualInt(ns.length.toInt(), 1, "one notification")
      assertEqual(ns[0].level, "blocked", "level")
      assertTrue(ns[0].summary.contains("needs the schema"), "summary names the reason")
    }
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
}
