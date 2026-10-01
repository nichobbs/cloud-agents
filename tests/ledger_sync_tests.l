//! Tests for session-ledger GitHub reconciliation (docs/session-ledger.md §9,
//! Phase 3): the pure rules (CloudAgents.Ledger.GitHubSync), the response
//! parsing (CloudAgents.Ledger.GitHubPort), and full sync passes
//! (CloudAgents.Ledger.Sync) against an in-memory GitHub. Live Postgres, no
//! network. Sessions are global and the sweeps (`sessionsToSync`) list across
//! tenants, so every test uses fresh session ids, asserts only about its own,
//! and archives them on exit so it leaves nothing due behind.
@test_module
package CloudAgents.LedgerSyncTests

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
import CloudAgents.Db
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Store
import CloudAgents.Scope as TestScope
import CloudAgents.Ledger.Service
import CloudAgents.Ledger.GitHubSync
import CloudAgents.Ledger.GitHubPort
import CloudAgents.Ledger.Sync
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
  println("SKIP: ledger sync tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Db.dbErrorMessage(e))
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

// A new session owned by the current test user on github.com/acme/shop with
// callback token "tok-" + its id (stored, like a real session, only as its
// hash). Session ids are global (session_routes), so each is unique.
func seedSession(): String {
  val id = "s-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  val sc = testScope()
  match CloudAgents.SessionStore.addSession(makeAgentSession(sessionId = id, repoUrl = "https://github.com/acme/shop", branch = "main", containerId = "", harness = "claude", model = "", nativeSessionId = id), sc) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  val u = match CloudAgents.PgStore.open(sc) {
    case Ok(x) -> x
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, "UPDATE session_routes SET callback_token_hash = @p1 WHERE session_id = @p0 AND tenant_id = @p2", [id, CloudAgents.Auth.hashCallbackToken("tok-" + id), sc.tenantId]) {
    case Ok(n) -> assertEqualInt(n, 1, "token stored on the session's route")
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  return id
}

// Archive a session so the cross-tenant sweeps stop listing it (best effort).
func retire(sid: in String): Unit {
  match CloudAgents.SessionStore.updateSessionArchived(sid, testScope(), "1") {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: could not archive " + sid + ": " + CloudAgents.Db.dbErrorMessage(e))
  }
}

// Run one statement in the test user's tenant (fixtures the store has no call for).
func execScoped(sql: in String, params: in slice[String]): Unit {
  val u = match CloudAgents.PgStore.open(testScope()) {
    case Ok(x) -> x
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, sql, params) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "exec failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Db.dbErrorMessage(e))
  }
}

func indexIn(xs: in slice[String], x: in String): Int {
  var i = 0
  while i < xs.length.toInt() {
    if xs[i] == x {
      return i
    }
    i = i + 1
  }
  return -1
}

// The sessions due for a sync pass, across tenants (the store's cap is 100).
func due(): slice[String] {
  match sessionsToSync(100) {
    case Ok(ids) -> return ids
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
}

func agentOk(sid: in String, op: in String, body: in String): String {
  match ledgerCallbackHandler(sid, op, "Bearer tok-" + sid, body) {
    case Ok(env) -> {
      assertEqual(env.ok, "true", op + " should succeed; error: " + env.error)
      return env.reply
    }
    case Err(e) -> panic(op + " returned HTTP " + toString(e.status) + ": " + e.message)
  }
}

func setStatus(
  sid: in String,
  item: in String,
  state: in String,
  reason: in String,
  blockedBy: in String,
  prUrl: in String,
): Unit {
  val _ = agentOk(
    sid,
    "item-status",
    "{\"item\":\"" + item + "\",\"state\":\"" + state + "\",\"reason\":\"" + reason + "\",\"blockedBy\":[" +
      blockedBy +
      "],\"prerequisiteProposal\":\"\",\"recommendation\":\"Merge the schema first.\",\"prUrl\":\"" +
      prUrl +
      "\"}"
  )
}

func register(sid: in String, refs: in String): Unit {
  val _ = agentOk(sid, "register-items", "{\"items\":[" + refs + "]}")
}

func ctxOf(sid: in String): SessionContext {
  match sessionContext(sid) {
    case Ok(c) -> return c
    case Err(f) -> panic(f.message)
  }
}

func stateOf(sid: in String, id: in String): String {
  match getItem(sid, testScope(), id) {
    case Ok(Some(w)) -> return w.state
    case Ok(None) -> return "(missing)"
    case Err(e) -> return CloudAgents.Db.dbErrorMessage(e)
  }
}

// ── An in-memory GitHub ───────────────────────────────────────────────────────
// Issues are keyed "owner/repo#n"; labels travel "\n"-joined. Parallel
// slices rather than record lists (docs/lyric/gotchas.md).
record FakeGitHub {
  pub var issueKeys: slice[String]
  pub var issueStates: slice[String]
  pub var issueLabels: slice[String]
  pub var mergedPulls: slice[String]
  pub var commentIds: slice[String]
  pub var commentIssues: slice[String]
  pub var commentBodies: slice[String]
  pub var ensuredLabels: slice[String]
  pub var calls: Int
  pub var failIssues: String
  // When set, only this issue key fails.
  pub var failKey: String
}

func fakeGitHub(): FakeGitHub {
  val none: slice[String] = []
  return FakeGitHub(
    issueKeys = none,
    issueStates = none,
    issueLabels = none,
    mergedPulls = none,
    commentIds = none,
    commentIssues = none,
    commentBodies = none,
    ensuredLabels = none,
    calls = 0,
    failIssues = "",
    failKey = ""
  )
}

func keyOf(ownerRepo: in String, number: in String): String {
  return ownerRepo + "#" + number
}

func indexOf(xs: in slice[String], x: in String): Int {
  var i = 0
  while i < xs.length.toInt() {
    if xs[i] == x {
      return i
    }
    i = i + 1
  }
  return -1
}

func openIssue(gh: in FakeGitHub, key: in String): Int {
  var at = indexOf(gh.issueKeys, key)
  if at < 0 {
    gh.issueKeys = gh.issueKeys.append(key)
    gh.issueStates = gh.issueStates.append("open")
    gh.issueLabels = gh.issueLabels.append("")
    at = gh.issueKeys.length.toInt() - 1
  }
  return at
}

func labelsOf(gh: in FakeGitHub, key: in String): slice[String] {
  val at = indexOf(gh.issueKeys, key)
  if at < 0 or gh.issueLabels[at].length.toInt() == 0 {
    val none: slice[String] = []
    return none
  }
  return splitOn(gh.issueLabels[at], "\n")
}

func setLabels(gh: in FakeGitHub, key: in String, labels: in slice[String]): Unit {
  val at = openIssue(gh, key)
  var joined = ""
  var i = 0
  while i < labels.length.toInt() {
    if i > 0 {
      joined = joined + "\n"
    }
    joined = joined + labels[i]
    i = i + 1
  }
  var next: slice[String] = []
  var j = 0
  while j < gh.issueLabels.length.toInt() {
    if j == at {
      next = next.append(joined)
    } else {
      next = next.append(gh.issueLabels[j])
    }
    j = j + 1
  }
  gh.issueLabels = next
}

func closeIssue(gh: in FakeGitHub, key: in String): Unit {
  val at = openIssue(gh, key)
  var next: slice[String] = []
  var j = 0
  while j < gh.issueStates.length.toInt() {
    if j == at {
      next = next.append("closed")
    } else {
      next = next.append(gh.issueStates[j])
    }
    j = j + 1
  }
  gh.issueStates = next
}

func commentsOn(gh: in FakeGitHub, key: in String): slice[String] {
  var acc: slice[String] = []
  var i = 0
  while i < gh.commentIssues.length.toInt() {
    if gh.commentIssues[i] == key {
      acc = acc.append(gh.commentBodies[i])
    }
    i = i + 1
  }
  return acc
}

impl GitHubPort for FakeGitHub {
  func getIssue(ownerRepo: in String, number: in String): Result[IssueFacts, String] {
    self.calls = self.calls + 1
    val key = keyOf(ownerRepo, number)
    if self.failIssues.length.toInt() > 0 and (self.failKey.length.toInt() == 0 or self.failKey == key) {
      return Err(error = self.failIssues)
    }
    val at = openIssue(self, key)
    return Ok(value = IssueFacts(state = self.issueStates[at], labels = labelsOf(self, key)))
  }

  func pullMerged(ownerRepo: in String, number: in String): Result[Bool, String] {
    self.calls = self.calls + 1
    return Ok(value = indexOf(self.mergedPulls, keyOf(ownerRepo, number)) >= 0)
  }

  func ensureLabel(ownerRepo: in String, label: in String): Result[Unit, String] {
    self.calls = self.calls + 1
    if indexOf(self.ensuredLabels, ownerRepo + "|" + label) < 0 {
      self.ensuredLabels = self.ensuredLabels.append(ownerRepo + "|" + label)
    }
    return Ok(())
  }

  func addLabel(ownerRepo: in String, number: in String, label: in String): Result[Unit, String] {
    self.calls = self.calls + 1
    val key = keyOf(ownerRepo, number)
    var labels = labelsOf(self, key)
    if indexOf(labels, label) < 0 {
      labels = labels.append(label)
    }
    setLabels(self, key, labels)
    return Ok(())
  }

  func removeLabel(ownerRepo: in String, number: in String, label: in String): Result[Unit, String] {
    self.calls = self.calls + 1
    val key = keyOf(ownerRepo, number)
    val labels = labelsOf(self, key)
    var kept: slice[String] = []
    var i = 0
    while i < labels.length.toInt() {
      if labels[i] != label {
        kept = kept.append(labels[i])
      }
      i = i + 1
    }
    setLabels(self, key, kept)
    return Ok(())
  }

  func findComment(ownerRepo: in String, number: in String, marker: in String): Result[String, String] {
    self.calls = self.calls + 1
    val key = keyOf(ownerRepo, number)
    var i = 0
    while i < self.commentIssues.length.toInt() {
      if self.commentIssues[i] == key and self.commentBodies[i].contains(marker) {
        return Ok(value = self.commentIds[i])
      }
      i = i + 1
    }
    return Ok(value = "")
  }

  func createComment(ownerRepo: in String, number: in String, body: in String): Result[String, String] {
    self.calls = self.calls + 1
    val id = toString(1000 + self.commentIds.length.toInt())
    self.commentIds = self.commentIds.append(id)
    self.commentIssues = self.commentIssues.append(keyOf(ownerRepo, number))
    self.commentBodies = self.commentBodies.append(body)
    return Ok(value = id)
  }

  func updateComment(ownerRepo: in String, commentId: in String, body: in String): Result[Unit, String] {
    self.calls = self.calls + 1
    val at = indexOf(self.commentIds, commentId)
    if at < 0 {
      return Err(error = "PATCH failed: The remote server returned an error: (404) Not Found.")
    }
    var next: slice[String] = []
    var j = 0
    while j < self.commentBodies.length.toInt() {
      if j == at {
        next = next.append(body)
      } else {
        next = next.append(self.commentBodies[j])
      }
      j = j + 1
    }
    self.commentBodies = next
    return Ok(())
  }
}

func sync(gh: in FakeGitHub, sid: in String): SyncOutcome {
  return syncSession(ctxOf(sid), gh, 200)
}

func expectNoErrors(o: in SyncOutcome): Unit {
  if o.errors.length.toInt() > 0 {
    assertTrue(false, "sync errors: " + o.errors[0])
  }
}

// ── Pure rules ────────────────────────────────────────────────────────────────
test "labels are planned so exactly the state's agent label remains" {
  val current: slice[String] = ["bug", "agent:queued", "agent:blocked"]
  val plan = planLabels(current, "blocked")
  assertEqualInt(plan.add.length.toInt(), 0, "agent:blocked already there")
  assertEqualInt(plan.remove.length.toInt(), 1, "one stale agent label")
  assertEqual(plan.remove[0], "agent:queued", "agent:queued removed, bug untouched")
  val skipped = planLabels(current, "skipped")
  assertEqualInt(skipped.remove.length.toInt(), 2, "a skipped item carries no agent label")
  val none: slice[String] = []
  assertEqual(planLabels(none, "pr_open").add[0], "agent:pr-open", "label spelling")
}

test "refs map to GitHub issues and pull requests" {
  match issueRefOf("gh:acme/shop#12") {
    case Some(r) -> {
      assertEqual(r.ownerRepo, "acme/shop", "repo")
      assertEqual(r.number, "12", "number")
    }
    case _ -> assertTrue(false, "gh ref")
  }
  match issueRefOf("local:tidy") {
    case Some(_) -> assertTrue(false, "a local ref has no issue")
    case _ -> ()
  }
  match pullRefOf("https://github.com/Acme/Shop/pull/7") {
    case Some(r) -> assertEqual(r.ownerRepo + "#" + r.number, "acme/shop#7", "PR url")
    case _ -> assertTrue(false, "PR url")
  }
  match pullRefOf("https://github.com/acme/shop/issues/7") {
    case Some(_) -> assertTrue(false, "an issue URL is not a PR")
    case _ -> ()
  }
}

test "the blocker comment carries the marker and the structured fields" {
  val item = WorkItem(
    id = "gh:acme/shop#2",
    sessionId = "s1",
    title = "",
    url = "",
    state = "blocked",
    blockedBy = ["gh:acme/shop#1", "gh:acme/other#9", "local:tidy"],
    blockedReason = "needs the schema",
    prerequisiteProposal = "add the users table",
    recommendation = "merge #1 first",
    prUrl = "",
    order = "0",
    createdAt = "1",
    updatedAt = "1",
    updatedSeq = "1"
  )
  val body = blockerComment("s1", item)
  assertTrue(body.startsWith("<!-- agent-ledger:session=s1;item=gh:acme/shop#2 -->"), body)
  assertTrue(body.contains("**Blocked:** needs the schema"), body)
  assertTrue(body.contains("**Blocked by:** #1, acme/other#9, tidy (not a GitHub issue)"), body)
  assertTrue(body.contains("**Proposed prerequisite work:** add the users table"), body)
  assertTrue(body.contains("**Agent recommendation:** merge #1 first"), body)
}

test "GitHub response bodies are read as recorded" {
  match parseIssue("{\"number\":3,\"state\":\"closed\",\"labels\":[{\"id\":1,\"name\":\"bug\"},{\"id\":2,\"name\":\"agent:blocked\"}]}") {
    case Ok(f) -> {
      assertEqual(f.state, "closed", "state")
      assertEqualInt(f.labels.length.toInt(), 2, "labels")
      assertEqual(f.labels[1], "agent:blocked", "label names")
    }
    case Err(e) -> assertTrue(false, e)
  }
  match parsePullMerged("{\"number\":7,\"merged\":true,\"state\":\"closed\"}") {
    case Ok(m) -> assertTrue(m, "merged")
    case Err(e) -> assertTrue(false, e)
  }
  match parsePullMerged("{\"number\":7,\"merged\":false}") {
    case Ok(m) -> assertTrue(not m, "not merged")
    case Err(e) -> assertTrue(false, e)
  }
  // A redirect or error body is not an issue with no labels, nor an unmerged PR.
  match parseIssue("{\"message\":\"Moved Permanently\",\"url\":\"https://api.github.com/repositories/1/issues/3\"}") {
    case Ok(_) -> assertTrue(false, "a redirect body must not parse as an issue")
    case Err(_) -> ()
  }
  match parseIssue("{\"state\":\"open\"}") {
    case Ok(_) -> assertTrue(false, "an issue body without labels is not trusted")
    case Err(_) -> ()
  }
  match parsePullMerged("{\"message\":\"Moved Permanently\"}") {
    case Ok(_) -> assertTrue(false, "a redirect body must not parse as a PR")
    case Err(_) -> ()
  }
  val page = commentWithMarker(
    "[{\"id\":11,\"body\":\"lgtm\"},{\"id\":12345678901,\"body\":\"<!-- agent-ledger:session=s1;item=x -->\\n**Blocked:** y\"}]",
    "<!-- agent-ledger:session=s1;item=x -->"
  )
  assertEqual(page.id, "12345678901", "large comment ids survive as text")
  assertEqualInt(page.count, 2, "page size")
  match idOf("{\"id\":987654321012,\"body\":\"x\"}") {
    case Ok(id) -> assertEqual(id, "987654321012", "created id")
    case Err(e) -> assertTrue(false, e)
  }
}

// ── Sync passes ───────────────────────────────────────────────────────────────
test "labels on GitHub follow the ledger state" {
  if not live() {
    return
  }
  val me = freshUser("sync-labels")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val gh = fakeGitHub()
  setLabels(gh, "acme/shop#1", ["bug"])
  register(s1, "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"}")
  setStatus(s1, "#1", "in_progress", "", "", "")
  expectNoErrors(sync(gh, s1))
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#1")), "agent:in-progress,bug", "state label added, others kept")

  setStatus(s1, "#1", "done", "", "", "")
  expectNoErrors(sync(gh, s1))
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#1")), "agent:done,bug", "previous agent label removed")

  val before = gh.calls
  val quiet = sync(gh, s1)
  assertEqualInt(quiet.calls, 0, "an unchanged done item costs no GitHub calls")
  assertEqualInt(gh.calls, before, "nothing called")
}

test "a blocked item gets one comment, edited in place, and marked resolved" {
  if not live() {
    return
  }
  val me = freshUser("sync-comment")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val gh = fakeGitHub()
  register(s1, "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"},{\"id\":\"#2\",\"title\":\"\",\"url\":\"\"}")
  setStatus(s1, "#2", "blocked", "needs the schema", "\"#1\"", "")
  expectNoErrors(sync(gh, s1))
  assertEqualInt(commentsOn(gh, "acme/shop#2").length.toInt(), 1, "one comment")
  assertTrue(commentsOn(gh, "acme/shop#2")[0].contains("**Blocked:** needs the schema"), "structured body")
  assertTrue(joinSorted(labelsOf(gh, "acme/shop#2")).contains("agent:blocked"), "blocked label")

  // A same-state update changes the comment, not the comment count.
  setStatus(s1, "#2", "blocked", "needs the schema and a migration", "", "")
  expectNoErrors(sync(gh, s1))
  assertEqualInt(commentsOn(gh, "acme/shop#2").length.toInt(), 1, "still one comment")
  assertTrue(commentsOn(gh, "acme/shop#2")[0].contains("and a migration"), "edited in place")

  // Re-syncing an unchanged blocked item rewrites nothing.
  val calls = sync(gh, s1).calls
  assertTrue(calls <= 3, "a blocked item only polls its issue and blockers: " + toString(calls))

  val _ = humanSetStatus(ctxOf(s1), "gh:acme/shop#2", "queued", "done by hand")
  expectNoErrors(sync(gh, s1))
  assertEqualInt(commentsOn(gh, "acme/shop#2").length.toInt(), 1, "still one comment")
  assertTrue(commentsOn(gh, "acme/shop#2")[0].contains("**Resolved:**"), commentsOn(gh, "acme/shop#2")[0])
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#2")), "agent:queued", "label follows")
}

test "closing a blocking issue on GitHub unblocks the dependent in one pass" {
  if not live() {
    return
  }
  val me = freshUser("sync-closed")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val gh = fakeGitHub()
  register(s1, "{\"id\":\"#2\",\"title\":\"\",\"url\":\"\"}")
  setStatus(s1, "#2", "blocked", "waits on the other repo", "\"acme/other#9\"", "")
  expectNoErrors(sync(gh, s1))
  assertEqual(stateOf(s1, "gh:acme/shop#2"), "blocked", "still blocked while #9 is open")

  closeIssue(gh, "acme/other#9")
  val o = sync(gh, s1)
  expectNoErrors(o)
  assertEqualInt(o.transitions, 1, "one transition")
  assertEqual(stateOf(s1, "gh:acme/shop#2"), "queued", "requeued by the sync")
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#2")), "agent:queued", "and its label follows in the same pass")
}

test "a merged PR finishes its item and unblocks what waited on it" {
  if not live() {
    return
  }
  val me = freshUser("sync-merged")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val gh = fakeGitHub()
  register(s1, "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"},{\"id\":\"#2\",\"title\":\"\",\"url\":\"\"}")
  setStatus(s1, "#1", "in_progress", "", "", "")
  setStatus(s1, "#1", "pr_open", "", "", "https://github.com/acme/shop/pull/5")
  setStatus(s1, "#2", "blocked", "needs #1", "\"#1\"", "")
  expectNoErrors(sync(gh, s1))
  assertEqual(stateOf(s1, "gh:acme/shop#1"), "pr_open", "PR not merged yet")

  gh.mergedPulls = gh.mergedPulls.append("acme/shop#5")
  expectNoErrors(sync(gh, s1))
  assertEqual(stateOf(s1, "gh:acme/shop#1"), "done", "merged PR -> done")
  assertEqual(stateOf(s1, "gh:acme/shop#2"), "queued", "auto-unblocked")
  assertTrue(joinSorted(labelsOf(gh, "acme/shop#1")).contains("agent:done"), "done label")
}

test "a person removing agent:blocked on GitHub requeues the item" {
  if not live() {
    return
  }
  val me = freshUser("sync-human")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val gh = fakeGitHub()
  register(s1, "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"},{\"id\":\"#2\",\"title\":\"\",\"url\":\"\"}")
  setStatus(s1, "#2", "blocked", "needs #1", "\"#1\"", "")
  expectNoErrors(sync(gh, s1))
  setLabels(gh, "acme/shop#2", ["bug"])
  expectNoErrors(sync(gh, s1))
  assertEqual(stateOf(s1, "gh:acme/shop#2"), "queued", "label removal is a human requeue")
  match listTransitions(s1, testScope(), "gh:acme/shop#2") {
    case Ok(ts) -> assertEqual(ts[ts.length.toInt() - 1].actor, "human", "recorded as the human's move")
    case Err(e) -> assertTrue(false, CloudAgents.Db.dbErrorMessage(e))
  }
}

test "the ledger's own stale agent:queued label is not read as a human requeue" {
  if not live() {
    return
  }
  val me = freshUser("sync-stale")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val gh = fakeGitHub()
  register(s1, "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"},{\"id\":\"#2\",\"title\":\"\",\"url\":\"\"}")
  expectNoErrors(sync(gh, s1))
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#2")), "agent:queued", "queued label applied")
  setStatus(s1, "#2", "blocked", "needs #1", "\"#1\"", "")
  expectNoErrors(sync(gh, s1))
  assertEqual(stateOf(s1, "gh:acme/shop#2"), "blocked", "still blocked")
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#2")), "agent:blocked", "label swapped")
}

test "GitHub failures are recorded per item and retried" {
  if not live() {
    return
  }
  val me = freshUser("sync-errors")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val gh = fakeGitHub()
  register(s1, "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"}")
  gh.failIssues = "GET failed: The remote server returned an error: (403) Forbidden."
  val failed = sync(gh, s1)
  assertEqualInt(failed.errors.length.toInt(), 1, "one error")
  assertTrue(failed.errors[0].contains("(403)"), failed.errors[0])
  match syncRows(s1, testScope()) {
    case Ok(rows) -> assertTrue(rows[0].lastError.contains("(403)"), "error kept on the item")
    case Err(e) -> assertTrue(false, CloudAgents.Db.dbErrorMessage(e))
  }
  gh.failIssues = ""
  expectNoErrors(sync(gh, s1))
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#1")), "agent:queued", "retried and applied")
  match syncRows(s1, testScope()) {
    case Ok(rows) -> assertEqual(rows[0].lastError, "", "error cleared")
    case Err(e) -> assertTrue(false, CloudAgents.Db.dbErrorMessage(e))
  }
}

test "a pass stops at its call budget and the rest waits for the next" {
  if not live() {
    return
  }
  val me = freshUser("sync-budget")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val gh = fakeGitHub()
  register(
    s1,
    "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"},{\"id\":\"#2\",\"title\":\"\",\"url\":\"\"},{\"id\":\"#3\",\"title\":\"\",\"url\":\"\"}"
  )
  val partial = syncSession(ctxOf(s1), gh, 4)
  assertTrue(partial.calls <= 4, "never over budget: " + toString(partial.calls))
  assertTrue(partial.items < 3, "not everything fit")
  assertTrue(indexIn(due(), s1) >= 0, "the session is still due")
  expectNoErrors(sync(gh, s1))
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#3")), "agent:queued", "finished on the next pass")
  assertTrue(indexIn(due(), s1) < 0, "nothing due once synced")
}

test "items waiting on GitHub don't starve the rest of a batch" {
  if not live() {
    return
  }
  val me = freshUser("sync-fair-items")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val gh = fakeGitHub()
  register(
    s1,
    "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"},{\"id\":\"#2\",\"title\":\"\",\"url\":\"\"},{\"id\":\"#3\",\"title\":\"\",\"url\":\"\"}"
  )
  // Stuck items are due on every pass; the queued #3 must still get its turn.
  setStatus(s1, "#1", "needs_human", "pick a vendor", "", "")
  setStatus(s1, "#2", "needs_human", "pick a region", "", "")
  var passes = 0
  while passes < 3 {
    val o = syncSession(ctxOf(s1), gh, 6)
    assertTrue(o.calls <= 6, "never over budget")
    passes = passes + 1
  }
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#1")), "agent:needs-human", "#1 labelled")
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#2")), "agent:needs-human", "#2 labelled")
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#3")), "agent:queued", "#3 reached despite the always-due items")
}

test "the maintenance run takes the least recently attempted sessions first" {
  if not live() {
    return
  }
  val me = freshUser("sync-fair-sessions")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val s2 = seedSession()
  defer {
    retire(s2)
  }
  register(s1, "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"}")
  register(s2, "{\"id\":\"#2\",\"title\":\"\",\"url\":\"\"}")
  assertTrue(indexIn(due(), s1) >= 0 and indexIn(due(), s2) >= 0, "both due")
  // s1 fails without reaching GitHub (no token): it still takes its turn.
  match markSyncAttempt(s1, testScope(), "no usable GitHub token") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Db.dbErrorMessage(e))
  }
  val order = due()
  assertTrue(
    indexIn(order, s2) >= 0 and indexIn(order, s2) < indexIn(order, s1),
    "the failing session goes to the back"
  )
  assertTrue(indexIn(due(), s1) >= 0 and indexIn(due(), s2) >= 0, "both still due")
}

test "an item that keeps failing doesn't eat every pass" {
  if not live() {
    return
  }
  val me = freshUser("sync-fail-order")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val gh = fakeGitHub()
  register(s1, "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"},{\"id\":\"#2\",\"title\":\"\",\"url\":\"\"}")
  // #1 can never be read; each pass affords only one issue read.
  gh.failIssues = "GET failed: (403) Forbidden"
  gh.failKey = "acme/shop#1"
  val first = syncSession(ctxOf(s1), gh, 1)
  assertEqualInt(first.errors.length.toInt(), 1, "#1 failed first")
  val second = syncSession(ctxOf(s1), gh, 3)
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#2")), "agent:queued", "#2 went ahead of the failing #1")
  assertEqualInt(second.errors.length.toInt(), 0, "the pass spent its budget on #2 first")
}

test "one session at a time manages an issue" {
  if not live() {
    return
  }
  val me = freshUser("sync-owner")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val s2 = seedSession()
  defer {
    retire(s2)
  }
  val gh = fakeGitHub()
  register(s1, "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"}")
  expectNoErrors(sync(gh, s1))
  setStatus(s1, "#1", "needs_human", "pick a vendor", "", "")
  expectNoErrors(sync(gh, s1))
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#1")), "agent:needs-human", "s1 labelled it")
  // s2 picks the same issue up later: it owns it now.
  execScoped("UPDATE ledger_items SET created_at = " + CloudAgents.Pg.msIn(1) + " WHERE session_id = @p0", [s1, "1"])
  register(s2, "{\"id\":\"#1\",\"title\":\"\",\"url\":\"\"}")
  setStatus(s2, "#1", "in_progress", "", "", "")
  expectNoErrors(sync(gh, s2))
  assertEqual(joinSorted(labelsOf(gh, "acme/shop#1")), "agent:in-progress", "s2 relabelled it")
  val before = gh.calls
  val stale = sync(gh, s1)
  assertEqualInt(gh.calls, before, "the superseded session doesn't touch the issue")
  assertEqualInt(stale.transitions, 0, "nor reads s2's label change as a human's")
  assertEqual(stateOf(s1, "gh:acme/shop#1"), "needs_human", "s1's item is left as it was")
  assertTrue(indexIn(due(), s1) < 0, "s1 isn't due for an issue it doesn't own")
  // Archiving s2 hands the issue back.
  retire(s2)
  match ownedIssueItems(s1, testScope()) {
    case Ok(ids) -> assertEqualInt(ids.length.toInt(), 1, "s1 owns it again")
    case Err(e) -> assertTrue(false, CloudAgents.Db.dbErrorMessage(e))
  }
  match ownedIssueItems(s2, testScope()) {
    case Ok(ids) -> assertEqualInt(ids.length.toInt(), 0, "an archived session owns nothing")
    case Err(e) -> assertTrue(false, CloudAgents.Db.dbErrorMessage(e))
  }
}

test "only one sync pass holds a session at a time" {
  if not live() {
    return
  }
  val me = freshUser("sync-lease")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val lease = 60000.toLong()
  val first = match acquireSyncLease(s1, testScope(), lease) {
    case Ok(t) -> t
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  assertTrue(first.length.toInt() > 0, "the first pass gets the lease")
  val second = match acquireSyncLease(s1, testScope(), lease) {
    case Ok(t) -> t
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  assertEqual(second, "", "a concurrent pass is refused")
  match releaseSyncLease(s1, testScope(), "not-the-token") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Db.dbErrorMessage(e))
  }
  val stillHeld = match acquireSyncLease(s1, testScope(), lease) {
    case Ok(t) -> t
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  assertEqual(stillHeld, "", "only the holder's token releases it")
  match releaseSyncLease(s1, testScope(), first) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, CloudAgents.Db.dbErrorMessage(e))
  }
  val third = match acquireSyncLease(s1, testScope(), lease) {
    case Ok(t) -> t
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  assertTrue(third.length.toInt() > 0, "free again once released")
  // An expired lease (a crashed pass) is taken over.
  execScoped(
    "UPDATE ledger_github_sync_runs SET lease_until = " + CloudAgents.Pg.msIn(1) + " WHERE session_id = @p0",
    [s1, "1"]
  )
  val fourth = match acquireSyncLease(s1, testScope(), lease) {
    case Ok(t) -> t
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  assertTrue(fourth.length.toInt() > 0, "an expired lease is taken over")
}

func joinSorted(xs: in slice[String]): String {
  var sorted: slice[String] = []
  var i = 0
  while i < xs.length.toInt() {
    var inserted = false
    var next: slice[String] = []
    var j = 0
    while j < sorted.length.toInt() {
      if not inserted and lessThan(xs[i], sorted[j]) {
        next = next.append(xs[i])
        inserted = true
      }
      next = next.append(sorted[j])
      j = j + 1
    }
    if not inserted {
      next = next.append(xs[i])
    }
    sorted = next
    i = i + 1
  }
  var acc = ""
  var k = 0
  while k < sorted.length.toInt() {
    if k > 0 {
      acc = acc + ","
    }
    acc = acc + sorted[k]
    k = k + 1
  }
  return acc
}

// Ordinal string comparison over the lowercase ASCII these labels use.
func lessThan(a: in String, b: in String): Bool {
  val order = "-:0123456789abcdefghijklmnopqrstuvwxyz"
  var i = 0
  while i < a.length.toInt() and i < b.length.toInt() {
    val ca = rank(order, a.substring(i, 1))
    val cb = rank(order, b.substring(i, 1))
    if ca != cb {
      return ca < cb
    }
    i = i + 1
  }
  return a.length.toInt() < b.length.toInt()
}

func rank(order: in String, c: in String): Int {
  var i = 0
  while i < order.length.toInt() {
    if order.substring(i, 1) == c {
      return i
    }
    i = i + 1
  }
  return order.length.toInt()
}

// The scope the store calls run under: the current test's fresh user.
func testScope(): TestScope.TenantScope {
  return CloudAgents.Auth.requestScope()
}
