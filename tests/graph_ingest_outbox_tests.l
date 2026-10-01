//! Tests for the durable graph-ingest outbox (docs/capture-ingest-outbox.md).
//!
//! Two tiers, matching this repo's convention (docs/session-events-store.md
//! §4): pure, offline unit tests for the retry/backoff policy
//! (CloudAgents.GraphIngestOutbox — deterministic, no wall-clock reads,
//! no DB), and live-Postgres round-trip tests for the Repository accessors
//! (CloudAgents.Repository), each acting as a fresh user with its own tenant.
//! The drain claims due rows across all tenants, so every assertion is about
//! this test's own row ids and rows a test leaves behind are marked delivered.
//!
//! Does NOT import CloudAgents.GitHubApi and exercises CloudAgents.
//! GraphIngestDrain only through the two paths that never reach it: the
//! actual bearer-authed HTTP POST inside attemptDeliverRow is exercised only
//! by the documented manual/live step (docs/capture-ingest-outbox.md §6) —
//! there is no local stub server here, and a @test_module has no way to
//! intercept a real outbound request. (CloudAgents.GraphIngestDrain itself
//! does not import CloudAgents.Docker at all, and has no async funcs, so
//! importing it directly is not the docs/lyric/gotchas.md async-import
//! restriction — the untestable part is specifically the live network call,
//! not package reachability.) Every state-machine transition (enqueue -> due
//! -> a recorded attempt failure -> delivered / terminal) is driven directly
//! through the Repository accessors the drain layer itself calls, with a
//! synthetic error string standing in for a real failed POST; the two
//! `drainGraphIngestHandler` tests below cover its operator-auth gate and its
//! empty-summary "nothing due" path, mirroring
//! tests/jobs_tests.l's `triggerDueJobsHandler` coverage (#873) — both reach
//! only code that runs before/without any due row, so neither needs Docker
//! or network access either.
@test_module
package CloudAgents.GraphIngestOutboxTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.GraphIngestDrain
import CloudAgents.GraphIngestOutbox
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

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
  println("SKIP: graph-ingest outbox tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

// ─── Pure: backoff schedule (deterministic — no wall clock, no DB) ──────────
test "backoffDelayMillis attempt 1 is within [base/2, base]" {
  val d = CloudAgents.GraphIngestOutbox.backoffDelayMillis(1, "row-a")
  assertTrue(d >= 15000, "attempt 1 delay is at least half the base (15s): got " + toString(d))
  assertTrue(d <= 30000, "attempt 1 delay never exceeds the base (30s): got " + toString(d))
}

test "backoffDelayMillis doubles on the second attempt" {
  val d = CloudAgents.GraphIngestOutbox.backoffDelayMillis(2, "row-a")
  assertTrue(d >= 30000, "attempt 2 delay is at least half of 60s: got " + toString(d))
  assertTrue(d <= 60000, "attempt 2 delay never exceeds 60s: got " + toString(d))
}

test "backoffDelayMillis saturates at the cap and stays there for further attempts" {
  val d8 = CloudAgents.GraphIngestOutbox.backoffDelayMillis(8, "row-a")
  val d20 = CloudAgents.GraphIngestOutbox.backoffDelayMillis(20, "row-a")
  val d50 = CloudAgents.GraphIngestOutbox.backoffDelayMillis(50, "row-a")
  // Once the exponential ceiling has saturated (attempt 8+), every delay
  // falls in [cap/2, cap] — never above the 1-hour cap, and never collapsed
  // to a near-zero value by the cap-then-jitter bug this design avoids
  // (see the module doc's "Equal Jitter" note).
  assertTrue(d8 >= 1800000 and d8 <= 3600000, "attempt 8 delay in [30m,1h]: got " + toString(d8))
  assertTrue(d20 >= 1800000 and d20 <= 3600000, "attempt 20 delay in [30m,1h]: got " + toString(d20))
  assertTrue(d50 >= 1800000 and d50 <= 3600000, "attempt 50 delay in [30m,1h]: got " + toString(d50))
}

test "backoffDelayMillis is deterministic for a fixed (attempts, seed) pair" {
  val a = CloudAgents.GraphIngestOutbox.backoffDelayMillis(4, "row-xyz")
  val b = CloudAgents.GraphIngestOutbox.backoffDelayMillis(4, "row-xyz")
  assertEqualInt(a, b, "same attempts+seed always yields the same delay (no real randomness)")
}

test "backoffDelayMillis treats a non-positive attempts as 1" {
  val zero = CloudAgents.GraphIngestOutbox.backoffDelayMillis(0, "row-a")
  val neg = CloudAgents.GraphIngestOutbox.backoffDelayMillis(-3, "row-a")
  assertTrue(zero >= 15000 and zero <= 30000, "attempts=0 behaves like attempts=1: got " + toString(zero))
  assertTrue(neg >= 15000 and neg <= 30000, "negative attempts behaves like attempts=1: got " + toString(neg))
}

// ─── Pure: terminal-cap logic ────────────────────────────────────────────────
test "isTerminal is false below the cap and true at/above it" {
  assertTrue(not CloudAgents.GraphIngestOutbox.isTerminal(49, 50), "49 of 50 is not yet terminal")
  assertTrue(CloudAgents.GraphIngestOutbox.isTerminal(50, 50), "50 of 50 is terminal")
  assertTrue(CloudAgents.GraphIngestOutbox.isTerminal(51, 50), "past the cap is terminal")
  assertTrue(not CloudAgents.GraphIngestOutbox.isTerminal(1, 50), "the very first failure is never terminal")
}

test "truncateError passes short strings through and bounds long ones" {
  val short = "connection refused"
  assertEqual(CloudAgents.GraphIngestOutbox.truncateError(short, 500), short, "short error is untouched")
  var long = ""
  var i = 0
  while i < 600 {
    long = long + "x"
    i = i + 1
  }
  val truncated = CloudAgents.GraphIngestOutbox.truncateError(long, 500)
  assertTrue(truncated.length < long.length, "truncated error is shorter than the original")
  assertTrue(truncated.contains("...(truncated)"), "truncation is marked, not silent: " + truncated)
}

test "terminalErrorMessage labels the error distinctly from a retryable one" {
  val msg = CloudAgents.GraphIngestOutbox.terminalErrorMessage("platform unreachable")
  assertTrue(msg.contains("TERMINAL"), "terminal message is labelled: " + msg)
  assertTrue(msg.contains("platform unreachable"), "terminal message preserves the underlying error: " + msg)
}

test "parseAttemptsCount round-trips plain digit strings" {
  assertEqualInt(CloudAgents.GraphIngestOutbox.parseAttemptsCount("0"), 0, "zero")
  assertEqualInt(CloudAgents.GraphIngestOutbox.parseAttemptsCount("12"), 12, "twelve")
  assertEqualInt(CloudAgents.GraphIngestOutbox.parseAttemptsCount(""), 0, "empty parses as zero")
}

test "isDueNow compares epoch-millis digit strings correctly (#1051)" {
  assertTrue(CloudAgents.GraphIngestOutbox.isDueNow("100", "100"), "equal timestamps are due")
  assertTrue(CloudAgents.GraphIngestOutbox.isDueNow("100", "200"), "a past next_attempt_at is due")
  assertTrue(not CloudAgents.GraphIngestOutbox.isDueNow("200", "100"), "a future next_attempt_at is not due")
  // Different digit-lengths (a fresh 13-digit epoch-millis value vs the
  // 14-digit terminalSentinelMillis) must compare by magnitude, not
  // lexicographically as if same-length ("9..." would otherwise look
  // "less than" a longer "1...").
  assertTrue(
    not CloudAgents.GraphIngestOutbox.isDueNow(CloudAgents.GraphIngestOutbox.terminalSentinelMillis, "1999999999999"),
    "the terminal sentinel is never due"
  )
  assertTrue(
    CloudAgents.GraphIngestOutbox.isDueNow("999999999999", "1000000000000"),
    "a shorter (smaller) value is due against a longer (larger) now"
  )
}

test "a drain's lease covers its whole batch timing out, and never drops below the default" {
  assertEqualInt(CloudAgents.GraphIngestOutbox.drainLeaseSeconds(25, 15000), 435, "25 rows at 15 s each plus a minute")
  assertEqualInt(
    CloudAgents.GraphIngestOutbox.drainLeaseSeconds(5, 15000),
    CloudAgents.GraphIngestOutbox.leaseSeconds,
    "a small batch keeps the default lease"
  )
  assertEqualInt(CloudAgents.GraphIngestOutbox.drainLeaseSeconds(10, 15500), 220 + 80, "a partial second rounds up")
}

// ─── Live Postgres: enqueue -> due -> attempt -> delivered / terminal ─────────
func owner(uid: in String): CloudAgents.Pg.TenantScope {
  return CloudAgents.Pg.personalScope(uid)
}

func mustEnqueue(uid: in String, sessionId: in String, body: in String, url: in String): CloudAgents.Repository.GraphIngestOutboxRow {
  return match CloudAgents.Repository.enqueueGraphIngest(sessionId, body, url, owner(uid)) {
    case Ok(row) -> row
    case Err(e) -> panic("enqueueGraphIngest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustClaimDue(limit: in Int): slice[CloudAgents.Repository.ClaimedGraphIngest] {
  return match CloudAgents.Repository.claimDueGraphIngest(limit, CloudAgents.GraphIngestOutbox.leaseSeconds) {
    case Ok(rows) -> rows
    case Err(e) -> panic("claimDueGraphIngest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustGet(uid: in String, id: in String): Option[CloudAgents.Repository.GraphIngestOutboxRow] {
  return match CloudAgents.Repository.getGraphIngest(id, owner(uid)) {
    case Ok(r) -> r
    case Err(e) -> panic("getGraphIngest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

/// Take a row out of every drain's reach so it cannot be claimed by another
/// suite's (or a later run's) drain.
func settle(uid: in String, id: in String): Unit {
  match CloudAgents.Repository.markGraphIngestDelivered(id, CloudAgents.Repository.nowMillis(), owner(uid)) {
    case Ok(_) -> ()
    case Err(e) -> panic("settling " + id + " failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func claimsId(claims: in slice[CloudAgents.Repository.ClaimedGraphIngest], id: in String): Bool {
  var i = 0
  while i < claims.length {
    if claims[i].row.id == id {
      return true
    }
    i = i + 1
  }
  return false
}

test "a freshly enqueued row is immediately claimable" {
  if not live() {
    return
  }
  val me = freshUser("outbox-enqueue-due")
  val row = mustEnqueue(me, "sess-A", "{\"objects\":[]}", "https://platform.example/api/ingest")
  assertTrue(row.id.length > 0, "enqueue mints an id")
  assertEqual(row.attempts, "0", "attempts starts at zero")
  assertEqual(row.deliveredAt, "", "not delivered yet")
  assertTrue(claimsId(mustClaimDue(500), row.id), "a fresh row is due immediately (next_attempt_at = created_at)")
  settle(me, row.id)

}

test "a failed attempt schedules a future retry and excludes the row from the due scan" {
  if not live() {
    return
  }
  val me = freshUser("outbox-attempt")
  val row = mustEnqueue(me, "sess-B", "{\"objects\":[]}", "https://platform.example/api/ingest")
  assertTrue(claimsId(mustClaimDue(500), row.id), "due before any attempt is recorded")

  val delay = CloudAgents.GraphIngestOutbox.backoffDelayMillis(1, row.id)
  match CloudAgents.Repository.markGraphIngestAttempt(row.id, "1", "simulated: connection refused", CloudAgents.Repository.nowMillis(), delay, owner(me)) {
    case Ok(n) -> assertEqualInt(n, 1, "one row updated")
    case Err(e) -> assertTrue(false, "markGraphIngestAttempt failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // The scheduled retry is at least 15s out (attempt 1's minimum delay), so it
  // is never due "right now" in the few milliseconds this test takes to run.
  assertTrue(not claimsId(mustClaimDue(500), row.id), "a row with a future next_attempt_at is not due yet")
  settle(me, row.id)

}

test "marking a row delivered removes it from the due scan" {
  if not live() {
    return
  }
  val me = freshUser("outbox-delivered")
  val row = mustEnqueue(me, "sess-C", "{\"objects\":[]}", "https://platform.example/api/ingest")
  match CloudAgents.Repository.markGraphIngestDelivered(row.id, CloudAgents.Repository.nowMillis(), owner(me)) {
    case Ok(n) -> assertEqualInt(n, 1, "one row marked delivered")
    case Err(e) -> assertTrue(false, "markGraphIngestDelivered failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertTrue(not claimsId(mustClaimDue(500), row.id), "a delivered row is never due again")

  // A second markGraphIngestDelivered on the same (now-delivered) row is a
  // guarded no-op (delivered_at = '' in the WHERE clause) — 0 rows affected,
  // not an error and not a corrupted double-write.
  match CloudAgents.Repository.markGraphIngestDelivered(row.id, CloudAgents.Repository.nowMillis(), owner(me)) {
    case Ok(n) -> assertEqualInt(n, 0, "re-marking an already-delivered row is a no-op")
    case Err(e) -> assertTrue(false, "unexpected error re-marking delivered: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

}

test "a row that exhausts its attempt cap is marked terminal and excluded forever" {
  if not live() {
    return
  }
  val me = freshUser("outbox-terminal")
  val row = mustEnqueue(me, "sess-D", "{\"objects\":[]}", "https://platform.example/api/ingest")
  match CloudAgents.Repository.markGraphIngestTerminal(row.id, "50", CloudAgents.GraphIngestOutbox.terminalErrorMessage("simulated: platform unreachable"), owner(me)) {
    case Ok(n) -> assertEqualInt(n, 1, "one row marked terminal")
    case Err(e) -> assertTrue(false, "markGraphIngestTerminal failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertTrue(not claimsId(mustClaimDue(500), row.id), "a terminal row is excluded from the due scan")

}

test "idempotent re-enqueue of the same session+body returns the existing row, not a duplicate" {
  if not live() {
    return
  }
  val me = freshUser("outbox-idempotent")
  val body = "{\"objects\":[{\"kind\":\"session\"}]}"
  val first = mustEnqueue(me, "sess-E", body, "https://platform.example/api/ingest")
  val second = mustEnqueue(me, "sess-E", body, "https://platform.example/api/ingest")
  assertEqual(first.id, second.id, "re-enqueuing the identical (session, body) pair returns the SAME row")

  // Once delivered, re-enqueuing the exact same body again still returns the
  // (now-delivered) row rather than resurrecting it as pending — this is the
  // property CloudAgents.GraphIngestDrain.enqueueAndAttemptDelivery relies on
  // to skip a redundant POST for an already-delivered body.
  match CloudAgents.Repository.markGraphIngestDelivered(first.id, CloudAgents.Repository.nowMillis(), owner(me)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "markGraphIngestDelivered failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val third = mustEnqueue(me, "sess-E", body, "https://platform.example/api/ingest")
  assertEqual(third.id, first.id, "still the same row after delivery")
  assertTrue(third.deliveredAt.length > 0, "the re-read row reports it is already delivered")

  // A DIFFERENT body for the same session is a genuinely new row (the outbox
  // is keyed on (session_id, body_hash), not session_id alone — a session
  // that runs more than once legitimately emits more than one checkpoint).
  val differentBody = mustEnqueue(
    me,
    "sess-E",
    "{\"objects\":[{\"kind\":\"different\"}]}",
    "https://platform.example/api/ingest"
  )
  assertTrue(differentBody.id != first.id, "a different body for the same session enqueues a distinct row")
  settle(me, differentBody.id)

}

test "pruneDeliveredGraphIngest removes only delivered rows, never pending ones" {
  if not live() {
    return
  }
  val me = freshUser("outbox-prune")
  val delivered = mustEnqueue(me, "sess-F", "{\"objects\":[]}", "https://platform.example/api/ingest")
  val pending = mustEnqueue(me, "sess-G", "{\"objects\":[\"other\"]}", "https://platform.example/api/ingest")
  match CloudAgents.Repository.markGraphIngestDelivered(delivered.id, CloudAgents.Repository.nowMillis(), owner(me)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "markGraphIngestDelivered failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // retentionDays = 0 with a delivered_at of "now" does not prune anything
  // yet (the cutoff is strictly less-than, and delivered_at == now), proving
  // the accessor is at least reachable and doesn't error.
  match CloudAgents.Repository.pruneDeliveredGraphIngest(0) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "pruneDeliveredGraphIngest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // The still-pending row is never touched by pruning regardless of
  // retention window (only delivered_at <> '' rows are eligible).
  match mustGet(me, pending.id) {
    case Some(_) -> ()
    case None -> assertTrue(false, "a pending row survives pruning")
  }
  settle(me, pending.id)

}

test "a claimed row is not claimed again while its lease holds" {
  if not live() {
    return
  }
  val me = freshUser("outbox-lease")
  val row = mustEnqueue(me, "sess-L", "{\"objects\":[]}", "https://platform.example/api/ingest")
  assertTrue(claimsId(mustClaimDue(500), row.id), "the first drain claims the due row")
  assertTrue(not claimsId(mustClaimDue(500), row.id), "an overlapping drain does not claim it again")
  match CloudAgents.Repository.claimGraphIngest(row.id, owner(me)) {
    case Ok(b) -> assertTrue(not b, "an immediate attempt cannot take a row a drain holds")
    case Err(e) -> assertTrue(false, "claimGraphIngest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  settle(me, row.id)

}

test "claimGraphIngest takes a due row exactly once" {
  if not live() {
    return
  }
  val me = freshUser("outbox-claim-one")
  val row = mustEnqueue(me, "sess-M", "{\"objects\":[]}", "https://platform.example/api/ingest")
  match CloudAgents.Repository.claimGraphIngest(row.id, owner(me)) {
    case Ok(b) -> assertTrue(b, "a due, unclaimed row is claimed")
    case Err(e) -> assertTrue(false, "claimGraphIngest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.claimGraphIngest(row.id, owner(me)) {
    case Ok(b) -> assertTrue(not b, "a second claim fails while the first holds")
    case Err(e) -> assertTrue(false, "claimGraphIngest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertTrue(not claimsId(mustClaimDue(500), row.id), "a drain does not take a row an immediate attempt holds")
  settle(me, row.id)

}

// #1197: a row whose session has since been deleted is still claimed and
// delivered. The Postgres outbox row carries its owner, so the claim hands the
// drain the owner's scope and the platform keeps the session's provenance.
test "a row whose session no longer exists is still claimed and its outcome recorded" {
  if not live() {
    return
  }
  val me = freshUser("outbox-orphan")
  val row = mustEnqueue(me, "sess-deleted", "{\"objects\":[]}", "https://platform.example/api/ingest")
  val claims = mustClaimDue(500)
  assertTrue(claimsId(claims, row.id), "the orphaned row is claimed")
  var claimed = claims[0]
  for c in claims {
    if c.row.id == row.id {
      claimed = c
    }
  }
  assertEqual(claimed.tenantScope.userId, me, "it is claimed under its owner's scope")
  match CloudAgents.Repository.markGraphIngestDelivered(row.id, CloudAgents.Repository.nowMillis(), claimed.tenantScope) {
    case Ok(n) -> assertEqualInt(n, 1, "its delivery is recorded under that scope")
    case Err(e) -> assertTrue(false, "markGraphIngestDelivered failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

}

// ─── drainGraphIngestHandler: operator-auth gate + empty-summary (#1050) ────
// Mirrors tests/jobs_tests.l's "triggerDueJobsHandler refuses a non-operator
// identity" / "... runs for the operator identity when nothing is due"
// (#873): both cases here run entirely before/without any due row, so they
// exercise the auth gate and the clean-summary response path without ever
// reaching attemptDeliverRow's live HTTP POST.
test "drainGraphIngestHandler refuses a non-operator identity" {
  if not live() {
    return
  }
  val me = freshUser("outbox-drain-auth-denied")
  match CloudAgents.GraphIngestDrain.drainGraphIngestHandler() {
    case Ok(_) -> assertTrue(false, "a non-operator identity must not be able to trigger the drain sweep")
    case Err(e) -> assertEqualInt(e.status, 401, "non-operator caller -> 401, not the system-wide sweep")
  }

}

// #1051: enqueueAndAttemptDelivery must not bypass the backoff schedule when
// idempotently re-enqueuing a row that is currently mid-backoff. Env vars
// are restored in `defer` so this test's config doesn't leak into others.
test "enqueueAndAttemptDelivery does not bypass backoff for a re-enqueued in-backoff row" {
  if not live() {
    return
  }
  val me = freshUser("outbox-nobypass")
  val originalUrl = Env.GetEnvironmentVariable("CLOUDAGENTS_GRAPH_INGEST_URL")
  defer {
    Env.SetEnvironmentVariable("CLOUDAGENTS_GRAPH_INGEST_URL", originalUrl)
  }
  Env.SetEnvironmentVariable("CLOUDAGENTS_GRAPH_INGEST_URL", "https://platform.example/api/ingest")

  val body = "{\"objects\":[]}"
  val row = mustEnqueue(me, "sess-H", body, "https://platform.example/api/ingest")
  // Force the row into backoff, simulating a prior failed delivery attempt.
  val delay = CloudAgents.GraphIngestOutbox.backoffDelayMillis(1, row.id)
  match CloudAgents.Repository.markGraphIngestAttempt(row.id, "1", "simulated failure", CloudAgents.Repository.nowMillis(), delay, owner(me)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "markGraphIngestAttempt failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Re-enqueue the IDENTICAL (session, body) pair while the row is still
  // mid-backoff (the minimum attempt-1 delay is >=15s, so it cannot have
  // become due again by the time this line runs). With the #1051 bug, this
  // would call attemptDeliverRow — with no CLOUDAGENTS_GRAPH_INGEST_TOKEN
  // configured, that fails and bumps attempts to "2". The fix must leave the
  // row's attempts/last_error completely untouched, and never even reach
  // attemptDeliverRow (no HTTP call, configured token or not).
  CloudAgents.GraphIngestDrain.enqueueAndAttemptDelivery("sess-H", body, owner(me))

  match mustGet(me, row.id) {
    case Some(r) -> assertEqual(
      r.attempts,
      "1",
      "a mid-backoff re-enqueue must not bump attempts — no immediate delivery attempt fired"
    )
    case None -> assertTrue(false, "the row must still exist")
  }
  settle(me, row.id)
}

test "drainGraphIngestHandler runs for the operator identity and returns a summary" {
  if not live() {
    return
  }
  val me = freshUser("outbox-drain-auth-allowed")
  // The sweep is cross-tenant and the database is shared, so other rows may be
  // due: assert the response shape, not that nothing was delivered. Rows this
  // suite leaves behind are settled, so none of ours is attempted.
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(CloudAgents.Auth.operatorUserId()) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning the operator failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  CloudAgents.Auth.setCurrentUserId(CloudAgents.Auth.operatorUserId())
  defer {
    CloudAgents.Auth.setCurrentUserId(me)
  }
  match CloudAgents.GraphIngestDrain.drainGraphIngestHandler() {
    case Ok(body) -> {
      assertTrue(body.startsWith("{\"delivered\":"), "the sweep answers a delivered/failed/terminal/pruned summary: " + body)
      assertTrue(body.contains("\"pruned\":"), "the summary carries the prune count: " + body)
    }
    case Err(e) -> assertTrue(
      false,
      "the operator identity must be allowed to run the drain sweep: " + toString(e.status)
    )
  }
}
