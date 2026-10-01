//! Tests for the session-ledger observer (docs/session-ledger.md §10): the
//! pure reconciliation and settings rules, the transcript window, and whole
//! report passes against live Postgres.
//!
//! Fixtures (tests/fixtures/observer/): `session.ndjson` is one run in
//! Claude's real `--output-format stream-json` event shape, written by hand
//! for these tests rather than captured from a live run. It plants three
//! undeclared actions: a skipped test (seq 18-22), a change outside the
//! issue's scope (seq 23-25) and an abandoned approach (seq 10-17), plus one
//! decision the agent declared (seq 5-7). `report.json` is the
//! `observer_report` an observer would send for that window, also
//! hand-written: it restates the declared decision and adds a low-confidence
//! guess. The model's judgement is not under test here; the host's
//! reconciliation of whatever the model says is.
@test_module
package CloudAgents.LedgerObserverTests

import Std.Core
import Std.Environment
import Std.File
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Db
import CloudAgents.Capture
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Store
import CloudAgents.Scope as TestScope
import CloudAgents.Ledger.Service
import CloudAgents.Ledger.Reconcile
import CloudAgents.Ledger.ObserverPolicy
import CloudAgents.Ledger.ObserverWindow
import CloudAgents.Ledger.Observer
import CloudAgents.Ledger.ToolArgs
import CloudAgents.LedgerHandlers
import extern System.Text.Encoding as Encoding

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func utf8FromBytes(enc: in Encoding, bytes: in slice[Byte]): String = ""

func readFixture(path: in String): String {
  return match Std.File.readBytes(path) { case Ok(bytes) -> utf8FromBytes(utf8Encoding(), bytes); case Err(_) -> "" }
}

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
  println("SKIP: ledger observer tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
  val u = match CloudAgents.PgStore.open(sc) { case Ok(x) -> x; case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e)) }
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

// Archive a session so the cross-tenant observer sweep stops listing it (best effort).
func retire(sid: in String): Unit {
  match CloudAgents.SessionStore.updateSessionArchived(sid, testScope(), "1") {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: could not archive " + sid + ": " + CloudAgents.Db.dbErrorMessage(e))
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

func ctxOf(sid: in String): SessionContext {
  match sessionContext(sid) {
    case Ok(c) -> return c
    case Err(f) -> panic(f.message)
  }
}

// The first `n` lines of an NDJSON text, and the rest.
func headLines(text: in String, n: Int): String {
  var seen = 0
  var i = 0
  while i < text.length.toInt() {
    if text.substring(i, 1) == "\n" {
      seen = seen + 1
      if seen == n {
        return text.substring(0, i + 1)
      }
    }
    i = i + 1
  }
  return text
}

func tailLines(text: in String, n: Int): String {
  val head = headLines(text, n)
  return text.substring(head.length.toInt(), text.length.toInt() - head.length.toInt())
}

// Capture `ndjson` for `sid`, continuing the session's existing chain.
func capture(sid: in String, ndjson: in String, startSeq: Long, prevHash: in String): CaptureBatch {
  val b = parseStreamJson(ndjson, startSeq, prevHash)
  match CloudAgents.Repository.appendSessionEvents(sid, CloudAgents.Auth.requestScope(), b.events) {
    case Ok(_) -> ()
    case Err(e) -> panic("appendSessionEvents: " + CloudAgents.Db.dbErrorMessage(e))
  }
  return b
}

func candidate(
  kind: in String, summary: in String, item: in String, s: in String, t: in String, conf: in String
): Candidate {
  val none: slice[String] = []
  return Candidate(
    kind = kind,
    summary = summary,
    detail = "",
    itemId = item,
    seqStart = s,
    seqEnd = t,
    tags = none,
    files = none,
    reversible = "",
    confidence = conf,
    evidence = ""
  )
}

func entry(
  id: in String,
  kind: in String,
  source: in String,
  item: in String,
  summary: in String,
  from: in String,
  anchor: in String,
): LedgerEntry {
  val none: slice[String] = []
  return LedgerEntry(
    id = id,
    sessionId = "s",
    itemId = item,
    kind = kind,
    severity = "info",
    declaredSeverity = "",
    summary = summary,
    detail = "",
    optionsConsidered = none,
    chosen = "",
    rationale = "",
    recommendation = "",
    proceedingWith = "",
    reversible = "",
    files = none,
    tags = none,
    source = source,
    undeclared = if source == "observed" { "true" } else { "false" },
    matchedEntryId = "",
    origin = "",
    supersedes = "",
    transcriptSeq = anchor,
    reviewState = "not_required",
    reviewBy = "",
    reviewAt = "",
    reviewComment = "",
    createdAt = "",
    createdSeq = "",
    updatedSeq = "",
    observedFrom = from,
    confidence = "",
    evidence = "",
    provisional = ""
  )
}

func decodeOk(json: in String): slice[Candidate] {
  match decodeObserverReport(json) {
    case Ok(cs) -> return cs
    case Err(e) -> panic("decodeObserverReport: " + e)
  }
}

func accept(sid: in String, cs: in slice[Candidate], provisional: Bool): ObserverReportReply {
  match acceptReport(ctxOf(sid), cs, provisional, defaultReconcileConfig()) {
    case Ok(r) -> return r
    case Err(f) -> panic("acceptReport: " + f.message)
  }
}

func window(sid: in String, final: Bool): ObserverWindowView {
  match buildWindow(ctxOf(sid), final, "") {
    case Ok(w) -> return w
    case Err(f) -> panic("buildWindow: " + f.message)
  }
}

func observedEntries(sid: in String): slice[LedgerEntry] {
  var acc: slice[LedgerEntry] = []
  match listEntries(sid, testScope()) {
    case Ok(es) -> {
      var i = 0
      while i < es.length.toInt() {
        if es[i].source == "observed" {
          acc = acc.append(es[i])
        }
        i = i + 1
      }
    }
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  return acc
}

func observedWith(sid: in String, fragment: in String): LedgerEntry {
  val obs = observedEntries(sid)
  var i = 0
  while i < obs.length.toInt() {
    if obs[i].summary.contains(fragment) {
      return obs[i]
    }
    i = i + 1
  }
  panic("no observed entry mentioning: " + fragment)
}

func countNotifications(sid: in String): Int {
  match CloudAgents.Repository.listNotifications(sid, CloudAgents.Auth.requestScope()) {
    case Ok(ns) -> return ns.length.toInt()
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
}

// ── Pure rules ────────────────────────────────────────────────────────────────
test "confidence is read as hundredths, and anything else is rejected" {
  assertEqualInt(confidencePct("0.5"), 50, "0.5")
  assertEqualInt(confidencePct(".75"), 75, ".75")
  assertEqualInt(confidencePct("1"), 100, "1")
  assertEqualInt(confidencePct("0.834"), 83, "truncated to hundredths")
  assertEqualInt(confidencePct("1.2"), -1, "over 1")
  assertEqualInt(confidencePct("high"), -1, "not a number")
  assertEqualInt(confidencePct(""), -1, "empty")
  assertEqualInt(confidencePct("0.5.1"), -1, "two dots")
}

test "summaries compare by their distinctive words" {
  assertEqualInt(similarityPct("Skipped the flaky refund test", "skipped flaky refund test!"), 100, "same words")
  assertTrue(similarityPct("Skipped the flaky refund test", "Changed invoice rounding") < 20, "different")
  assertEqual(kindFamily("shortcut"), "deviation", "a shortcut is a kind of deviation")
  assertEqual(kindFamily("question"), "blocker", "a question is a kind of blocker")
  assertTrue(not isObservableKind("note"), "notes are the agent's own")
}

test "a candidate is dropped, duplicated, matched or undeclared" {
  val cfg = defaultReconcileConfig()
  val entries: slice[LedgerEntry] = [
    entry(
      "d1",
      "decision",
      "declared",
      "gh:acme/shop#12",
      "Use sliding expiry",
      "",
      "7"
    ),
    entry(
      "o1",
      "shortcut",
      "observed",
      "",
      "Skipped the flaky refund test",
      "18",
      "22"
    )
  ]
  assertEqual(
    reconcile(candidate("decision", "Anything", "", "5", "9", "0.3"), entries, cfg).action,
    "drop",
    "low confidence"
  )
  val matched = reconcile(candidate("decision", "Switched expiry", "gh:acme/shop#12", "5", "9", "0.9"), entries, cfg)
  assertEqual(matched.action, "matched", "a declared decision nearby covers it")
  assertEqual(matched.entryId, "d1", "the declared entry")
  assertEqual(
    reconcile(candidate("decision", "Switched expiry", "gh:acme/shop#99", "5", "9", "0.9"), entries, cfg).action,
    "undeclared",
    "a different work item is not covered"
  )
  assertEqual(
    reconcile(candidate("decision", "Switched expiry", "gh:acme/shop#12", "500", "509", "0.9"), entries, cfg).action,
    "undeclared",
    "too far from the declared anchor"
  )
  assertEqual(
    reconcile(candidate("deviation", "Switched expiry", "gh:acme/shop#12", "5", "9", "0.9"), entries, cfg).action,
    "undeclared",
    "a declared decision doesn't cover a deviation"
  )
  val dup = reconcile(candidate("shortcut", "Skipped flaky refund test", "", "40", "44", "0.9"), entries, cfg)
  assertEqual(dup.action, "duplicate", "the same observation restated in a later window")
  assertEqual(dup.entryId, "o1", "the earlier observation")
  assertEqual(
    reconcile(candidate("shortcut", "Disabled lint rule for auth module", "", "19", "21", "0.9"), entries, cfg).action,
    "undeclared",
    "a different shortcut in the same range is its own finding"
  )
  // Near a declared deviation is not enough: it must be about the same thing.
  val withDeviation: slice[LedgerEntry] = [
    entry(
      "d2",
      "shortcut",
      "declared",
      "",
      "Skipped flaky refund test",
      "",
      "20"
    )
  ]
  assertEqual(
    reconcile(candidate("deviation", "Abandoned the Redis session cache", "", "10", "17", "0.9"), withDeviation, cfg).action,
    "undeclared",
    "an unrelated deviation a few events away is not covered"
  )
  assertEqual(
    reconcile(candidate("shortcut", "Skipped the refund rounding test", "", "18", "19", "0.9"), withDeviation, cfg).action,
    "matched",
    "the same shortcut, described differently, is covered"
  )
}

test "only a confident shortcut or an irreversible action notifies" {
  val cfg = defaultReconcileConfig()
  assertTrue(shouldNotify(candidate("shortcut", "x", "", "1", "2", "0.9"), cfg), "confident shortcut")
  assertTrue(not shouldNotify(candidate("shortcut", "x", "", "1", "2", "0.6"), cfg), "unsure shortcut")
  assertTrue(not shouldNotify(candidate("deviation", "x", "", "1", "2", "0.9"), cfg), "reversible deviation")
  val none: slice[String] = []
  val irreversible = Candidate(
    kind = "decision",
    summary = "x",
    detail = "",
    itemId = "",
    seqStart = "1",
    seqEnd = "2",
    tags = none,
    files = none,
    reversible = "false",
    confidence = "0.85",
    evidence = ""
  )
  assertTrue(shouldNotify(irreversible, cfg), "can't be undone")
}

test "observer settings are validated and pace passes" {
  val ok = ObserverSettings(
    enabled = "true",
    harness = "claude",
    model = "claude-haiku-4-5",
    repoAccess = "workspace",
    midRunMinutes = "15",
    maxPassesPerDay = "48"
  )
  assertEqual(validateObserverSettings(ok), "", "valid")
  val badAccess = ObserverSettings(
    enabled = "true",
    harness = "claude",
    model = "",
    repoAccess = "clone",
    midRunMinutes = "15",
    maxPassesPerDay = "48"
  )
  assertTrue(validateObserverSettings(badAccess).contains("repoAccess"), "repo access")
  val badCap = ObserverSettings(
    enabled = "true",
    harness = "claude",
    model = "",
    repoAccess = "none",
    midRunMinutes = "0",
    maxPassesPerDay = "0"
  )
  assertTrue(validateObserverSettings(badCap).contains("maxPassesPerDay"), "cap")
  val badModel = ObserverSettings(
    enabled = "true",
    harness = "claude",
    model = "x; rm -rf /",
    repoAccess = "none",
    midRunMinutes = "0",
    maxPassesPerDay = "5"
  )
  assertTrue(validateObserverSettings(badModel).contains("model"), "model characters")
  val day = 20000.toLong() * 86400000.toLong()
  assertTrue(midRunDue(ok, day, day + 15.toLong() * 60000.toLong()), "15 minutes on")
  assertTrue(not midRunDue(ok, day, day + 14.toLong() * 60000.toLong()), "not yet")
  assertTrue(not midRunDue(badCap, day, day + 999.toLong() * 60000.toLong()), "mid-run passes off")
  assertTrue(underDailyCap(ok, utcDay(day), "47", day), "47 of 48")
  assertTrue(not underDailyCap(ok, utcDay(day), "48", day), "cap reached")
  assertTrue(underDailyCap(ok, utcDay(day), "48", day + 86400000.toLong()), "a new day resets the count")
}

test "evidence is clipped to a short quote" {
  assertEqual(clipEvidence("  keep   this\nshort  "), "keep this short", "whitespace folded")
  var long = ""
  var i = 0
  while i < 40 {
    long = long + "word" + toString(i) + " "
    i = i + 1
  }
  val clipped = clipEvidence(long)
  assertTrue(clipped.endsWith("…"), "marked as clipped")
  assertTrue(clipped.contains("word29") and not clipped.contains("word30"), "thirty words kept")
}

// ── The transcript window ─────────────────────────────────────────────────────
test "the window shows the agent's words, tool calls and results by seq" {
  val batch = parseStreamJson(readFixture("tests/fixtures/observer/session.ndjson"), 0.toLong(), "")
  val w = renderWindow(batch.events, 60000)
  assertEqual(w.firstSeq, "0", "from the first event")
  assertEqual(w.lastSeq, "28", "to the last")
  assertEqualInt(w.events, 29, "every event counted")
  assertTrue(w.signal > 0, "edits and commands carry signal")
  assertTrue(not w.truncated, "fits")
  assertTrue(w.text.contains("[seq 1] user: Fix the login session timeout bug"), "the task")
  assertTrue(w.text.contains("[seq 21] tool Edit: file_path=/workspace/tests/test_payments.py"), "the skip edit")
  assertTrue(w.text.contains("@pytest.mark.skip"), "with its content")
  assertTrue(w.text.contains("[seq 19] error: FAILED tests/test_payments.py"), "a failing result")
  assertTrue(w.text.contains("[seq 20] agent: test_refund_rounding is unrelated and flaky"), "the agent's words")
  assertTrue(not w.text.contains("[seq 0]"), "system events are left out")
  val small = renderWindow(batch.events, 400)
  assertTrue(small.truncated, "a smaller window stops early")
  assertTrue(decimalLong(small.lastSeq) < 28.toLong(), "and ends before the last event")
}

test "reading and searching are not worth a pass on their own" {
  assertTrue(not toolCarriesSignal("Read", "file_path=/workspace/a.py"), "read")
  assertTrue(not toolCarriesSignal("Bash", "command=git status"), "read-only command")
  assertTrue(toolCarriesSignal("Bash", "command=git status && git push --force"), "chained command")
  assertTrue(toolCarriesSignal("Bash", "command=pytest"), "running tests")
  assertTrue(toolCarriesSignal("Edit", "file_path=/workspace/a.py"), "an edit")
}

// ── Whole passes (live Postgres) ────────────────────────────────────────────────
test "fixtures: planted shortcuts are flagged and the declared decision is matched" {
  if not live() {
    return
  }
  val me = freshUser("observer-accept")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val fixture = readFixture("tests/fixtures/observer/session.ndjson")
  val _ = agentOk(s1, "register-items", "{\"items\":[\"#12\"]}")
  // The run up to the decision, then the agent declares it, then the rest.
  val first = capture(s1, headLines(fixture, 8), 0.toLong(), "")
  val declared = agentOk(
    s1,
    "decision",
    "{\"summary\":\"Use sliding expiry for session tokens\",\"item\":\"#12\",\"chosen\":\"sliding expiry\",\"rationale\":\"Active users should stay signed in\",\"optionsConsidered\":[\"fixed window\",\"sliding expiry\"]}"
  )
  assertTrue(declared.contains("\"severity\":\"info\""), "an ordinary declared decision")
  val _ = capture(s1, tailLines(fixture, 8), first.nextSeq, first.lastHash)

  val w = window(s1, true)
  assertEqual(w.fromSeq, "0", "window starts at the beginning")
  assertEqual(w.toSeq, "28", "and covers the run")
  assertEqual(w.more, "false", "nothing after it")
  assertTrue(
    w.entries.length.toInt() == 1 and w.entries[0].contains("decision gh:acme/shop#12: Use sliding expiry"),
    "lists the declared entry"
  )
  assertTrue(w.workItems[0].startsWith("gh:acme/shop#12"), "lists the work items")

  val reply = accept(s1, decodeOk(readFixture("tests/fixtures/observer/report.json")), false)
  assertEqual(reply.undeclared, "3", "the skipped test, the scope change and the abandoned approach")
  assertEqual(reply.matched, "1", "the restated decision")
  assertEqual(reply.dropped, "1", "the low-confidence guess")
  assertEqual(reply.duplicates, "0", "nothing seen before")

  val skip = observedWith(s1, "test_refund_rounding")
  assertEqual(skip.undeclared, "true", "undeclared")
  assertEqual(skip.severity, "review", "policy raises an undeclared observation to review")
  assertEqual(skip.reviewState, "pending", "awaiting the owner")
  assertEqual(skip.observedFrom, "18", "rests on seq 18")
  assertEqual(skip.transcriptSeq, "22", "to 22")
  assertEqual(skip.confidence, "0.95", "confidence kept")
  assertTrue(skip.evidence.contains("Skipping it so the suite is green"), "evidence kept")
  assertEqual(skip.provisional, "false", "an end-of-run pass is final")
  val offScope = observedWith(s1, "billing/invoice.py")
  assertEqual(offScope.undeclared, "true", "the scope change is undeclared")
  val abandoned = observedWith(s1, "Redis")
  assertEqual(abandoned.itemId, "gh:acme/shop#12", "item refs are normalized")
  val decision = observedWith(s1, "sliding window")
  assertEqual(decision.undeclared, "false", "the declared decision is not flagged")
  assertTrue(decision.matchedEntryId.length.toInt() > 0, "it points at the declared entry")
  assertEqual(decision.severity, "info", "and needs no review")
  assertEqualInt(countNotifications(s1), 1, "only the confident skipped test notifies")

  match observerState(s1, testScope()) {
    case Ok(st) -> {
      assertEqual(st.cursorSeq, "28", "the cursor moved past the window")
      assertEqual(st.windowEnd, "", "and the window is closed")
    }
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  match acceptReport(ctxOf(s1), decodeOk(readFixture("tests/fixtures/observer/report.json")), false, defaultReconcileConfig()) {
    case Ok(_) -> assertTrue(false, "a report without a window is refused")
    case Err(f) -> assertTrue(f.message.contains("observer_get_window"), f.message)
  }
  assertEqual(window(s1, true).empty, "true", "nothing new to read")
}

test "a later window restating an observation is a duplicate" {
  if not live() {
    return
  }
  val me = freshUser("observer-dup")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val fixture = readFixture("tests/fixtures/observer/session.ndjson")
  val all = capture(s1, fixture, 0.toLong(), "")
  val _ = window(s1, true)
  val _ = accept(s1, decodeOk(readFixture("tests/fixtures/observer/report.json")), false)
  val _ = capture(s1, headLines(fixture, 3), all.nextSeq, all.lastHash)
  val w = window(s1, true)
  assertEqual(w.fromSeq, "29", "only the new events")
  val again = accept(
    s1,
    decodeOk(
      "{\"candidates\":[{\"kind\":\"shortcut\",\"summary\":\"Skipped the failing test_refund_rounding instead of fixing it\",\"seqStart\":\"29\",\"seqEnd\":\"31\",\"confidence\":0.9}]}"
    ),
    false
  )
  assertEqual(again.duplicates, "1", "already observed")
  assertEqual(again.undeclared, "0", "nothing new stored")
}

test "a mid-run observation the agent declares later is matched, and settles at run end" {
  if not live() {
    return
  }
  val me = freshUser("observer-provisional")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val fixture = readFixture("tests/fixtures/observer/session.ndjson")
  val part = capture(s1, headLines(fixture, 23), 0.toLong(), "")
  val _ = window(s1, false)
  val mid = accept(
    s1,
    decodeOk(
      "{\"candidates\":[{\"kind\":\"shortcut\",\"summary\":\"Skipped the failing test_refund_rounding\",\"seqStart\":\"18\",\"seqEnd\":\"22\",\"confidence\":\"0.7\"}," +
        "{\"kind\":\"deviation\",\"summary\":\"Abandoned the Redis cache\",\"seqStart\":\"10\",\"seqEnd\":\"17\",\"confidence\":\"0.7\"}]}"
    ),
    true
  )
  assertEqual(mid.undeclared, "2", "two findings mid-run")
  assertEqual(observedWith(s1, "test_refund_rounding").provisional, "true", "provisional while the run goes on")
  // The agent now declares the skip itself.
  val _ = agentOk(
    s1,
    "deviation",
    "{\"kind\":\"shortcut\",\"summary\":\"Skipped flaky test_refund_rounding to unblock the fix\",\"reversible\":true}"
  )
  val _ = capture(s1, tailLines(fixture, 23), part.nextSeq, part.lastHash)
  val _ = window(s1, true)
  val last = accept(s1, decodeOk("{\"candidates\":[]}"), false)
  assertEqual(last.undeclared, "0", "nothing new")
  val skip = observedWith(s1, "test_refund_rounding")
  assertEqual(skip.undeclared, "false", "covered by the later declaration")
  assertTrue(skip.matchedEntryId.length.toInt() > 0, "matched to it")
  assertEqual(skip.severity, "info", "no longer needs review")
  assertEqual(skip.reviewState, "not_required", "nor waits for it")
  val redis = observedWith(s1, "Redis")
  assertEqual(redis.undeclared, "true", "the undeclared one stays flagged")
  assertEqual(redis.provisional, "false", "and is final now the run has ended")
}

test "a report that breaks the rules is refused whole and the cursor stays" {
  if not live() {
    return
  }
  val me = freshUser("observer-invalid")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val _ = capture(s1, readFixture("tests/fixtures/observer/session.ndjson"), 0.toLong(), "")
  val _ = window(s1, true)
  val outside = decodeOk(
    "{\"candidates\":[{\"kind\":\"shortcut\",\"summary\":\"x\",\"seqStart\":\"20\",\"seqEnd\":\"90\",\"confidence\":\"0.9\"}]}"
  )
  match acceptReport(ctxOf(s1), outside, false, defaultReconcileConfig()) {
    case Ok(_) -> assertTrue(false, "a range outside the window is refused")
    case Err(f) -> assertTrue(f.message.contains("inside this window"), f.message)
  }
  val badKind = decodeOk(
    "{\"candidates\":[{\"kind\":\"shortcut\",\"summary\":\"fine\",\"seqStart\":\"2\",\"seqEnd\":\"3\",\"confidence\":\"0.9\"},{\"kind\":\"note\",\"summary\":\"x\",\"seqStart\":\"2\",\"seqEnd\":\"3\",\"confidence\":\"0.9\"}]}"
  )
  match acceptReport(ctxOf(s1), badKind, false, defaultReconcileConfig()) {
    case Ok(_) -> assertTrue(false, "a note is refused")
    case Err(f) -> assertTrue(f.message.contains("candidates[1]"), "names the bad candidate: " + f.message)
  }
  assertEqualInt(observedEntries(s1).length.toInt(), 0, "nothing stored from a refused report")
  match observerState(s1, testScope()) {
    case Ok(st) -> assertEqual(st.cursorSeq, "", "the cursor did not move")
    case Err(e) -> panic(CloudAgents.Db.dbErrorMessage(e))
  }
  match decodeObserverReport("{\"candidates\":\"[{\\\"kind\\\":\\\"shortcut\\\",\\\"summary\\\":\\\"s\\\",\\\"seqStart\\\":2,\\\"seqEnd\\\":3,\\\"confidence\\\":0.8}]\"}") {
    case Ok(cs) -> {
      assertEqualInt(cs.length.toInt(), 1, "a stringified array is unwrapped")
      assertEqual(cs[0].seqStart, "2", "numbers read as text")
    }
    case Err(e) -> assertTrue(false, e)
  }
}

test "a report raises at most three notifications" {
  if not live() {
    return
  }
  val me = freshUser("observer-notify-cap")
  val s1 = seedSession()
  defer {
    retire(s1)
  }
  val _ = capture(s1, readFixture("tests/fixtures/observer/session.ndjson"), 0.toLong(), "")
  val _ = window(s1, true)
  var body = "{\"candidates\":["
  var i = 0
  while i < 6 {
    if i > 0 {
      body = body + ","
    }
    body = body + "{\"kind\":\"shortcut\",\"summary\":\"Distinct shortcut number " + toString(i) + " zebra" + toString(i) +
      "\",\"seqStart\":\"" +
      toString(i * 4) +
      "\",\"seqEnd\":\"" +
      toString(i * 4) +
      "\",\"confidence\":\"0.95\"}"
    i = i + 1
  }
  body = body + "]}"
  val r = accept(s1, decodeOk(body), false)
  assertEqual(r.undeclared, "6", "every finding is recorded")
  assertEqualInt(countNotifications(s1), 3, "but only three notify")
}

test "an observer receives only its harness's model credentials" {
  assertTrue(observerMayReceiveCredential("claude", "ANTHROPIC_API_KEY"), "claude gets its API key")
  assertTrue(observerMayReceiveCredential("claude", "CLAUDE_CODE_OAUTH_TOKEN"), "claude gets its OAuth token")
  assertTrue(observerMayReceiveCredential("claude", "CLAUDE_CREDENTIALS_JSON"), "claude gets its refreshable login")
  assertFalse(observerMayReceiveCredential("claude", "OPENAI_API_KEY"), "claude gets no other model's key")
  assertTrue(observerMayReceiveCredential("antigravity", "ANTIGRAVITY_API_KEY"), "antigravity gets its key")
  assertTrue(observerMayReceiveCredential("opencode", "OPENCODE_ZEN_API_KEY"), "opencode gets its key")
  assertFalse(observerMayReceiveCredential("claude", "GITHUB_TOKEN"), "no repository token")
  assertFalse(observerMayReceiveCredential("codex", "GITEA_TOKEN"), "nor one under an unforeseen name")
  assertFalse(observerMayReceiveCredential("codex", "AWS_SECRET_ACCESS_KEY"), "nor a cloud token")
  assertFalse(observerMayReceiveCredential("codex", "openai_api_key"), "names match exactly")
  assertFalse(observerMayReceiveCredential("unknown", "OPENAI_API_KEY"), "an unknown harness gets nothing")
}

// The scope the store calls run under: the current test's fresh user.
func testScope(): TestScope.TenantScope {
  return CloudAgents.Auth.requestScope()
}
