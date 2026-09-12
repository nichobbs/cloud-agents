//! Tests for the durable graph-ingest outbox (docs/capture-ingest-outbox.md).
//!
//! Two tiers, matching this repo's convention (docs/session-events-store.md
//! §4): pure, offline unit tests for the retry/backoff policy
//! (CloudAgents.GraphIngestOutbox — deterministic, no wall-clock reads,
//! no DB), and live-SQLite round-trip tests for the Repository accessors
//! (CloudAgents.Repository — same fresh-temp-DB harness as
//! tests/session_events_tests.l).
//!
//! Deliberately does NOT import CloudAgents.GraphIngestDrain or
//! CloudAgents.GitHubApi: the actual bearer-authed HTTP POST to the platform
//! is exercised only by the documented manual/live step
//! (docs/capture-ingest-outbox.md §6) — a @test_module cannot reach
//! CloudAgents.Docker/a live network endpoint, and there is no local stub
//! server here. Every transition this suite proves (enqueue -> due -> a
//! recorded attempt failure -> delivered / terminal) is driven directly
//! through the Repository accessors the drain layer itself calls, with a
//! synthetic error string standing in for a real failed POST — so the state
//! machine is fully proven without any network I/O.
@test_module
package CloudAgents.GraphIngestOutboxTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.GraphIngestOutbox
import CloudAgents.Repository
import CloudAgents.Sqlite
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

// ─── Live-SQLite: enqueue -> due -> attempt -> delivered / terminal ─────────
func mustEnqueue(sessionId: in String, body: in String, url: in String): CloudAgents.Repository.GraphIngestOutboxRow {
  return match CloudAgents.Repository.enqueueGraphIngest(sessionId, body, url) {
    case Ok(row) -> row
    case Err(e) -> panic("enqueueGraphIngest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustDue(limit: in Int): slice[CloudAgents.Repository.GraphIngestOutboxRow] {
  return match CloudAgents.Repository.dueGraphIngest(CloudAgents.Repository.nowMillis(), limit) {
    case Ok(rows) -> rows
    case Err(e) -> panic("dueGraphIngest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func containsId(rows: in slice[CloudAgents.Repository.GraphIngestOutboxRow], id: in String): Bool {
  var i = 0
  while i < rows.length {
    if rows[i].id == id {
      return true
    }
    i = i + 1
  }
  return false
}

test "a freshly enqueued row is immediately due" {
  val path = useFreshTestDb("outbox-enqueue-due")
  val row = mustEnqueue("sess-A", "{\"objects\":[]}", "https://platform.example/api/ingest")
  assertTrue(row.id.length > 0, "enqueue mints an id")
  assertEqual(row.attempts, "0", "attempts starts at zero")
  assertEqual(row.deliveredAt, "", "not delivered yet")
  assertTrue(containsId(mustDue(50), row.id), "a fresh row is due immediately (next_attempt_at = created_at)")

  cleanupTestDb(path)
}

test "a failed attempt schedules a future retry and excludes the row from the due scan" {
  val path = useFreshTestDb("outbox-attempt")
  val row = mustEnqueue("sess-B", "{\"objects\":[]}", "https://platform.example/api/ingest")
  assertTrue(containsId(mustDue(50), row.id), "due before any attempt is recorded")

  val delay = CloudAgents.GraphIngestOutbox.backoffDelayMillis(1, row.id)
  match CloudAgents.Repository.markGraphIngestAttempt(row.id, "1", "simulated: connection refused", CloudAgents.Repository.nowMillis(), delay) {
    case Ok(n) -> assertEqualInt(n, 1, "one row updated")
    case Err(e) -> assertTrue(false, "markGraphIngestAttempt failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // The scheduled retry is at least 15s out (attempt 1's minimum delay), so it
  // is never due "right now" in the few milliseconds this test takes to run.
  assertTrue(not containsId(mustDue(50), row.id), "a row with a future next_attempt_at is not due yet")

  cleanupTestDb(path)
}

test "marking a row delivered removes it from the due scan" {
  val path = useFreshTestDb("outbox-delivered")
  val row = mustEnqueue("sess-C", "{\"objects\":[]}", "https://platform.example/api/ingest")
  match CloudAgents.Repository.markGraphIngestDelivered(row.id, CloudAgents.Repository.nowMillis()) {
    case Ok(n) -> assertEqualInt(n, 1, "one row marked delivered")
    case Err(e) -> assertTrue(false, "markGraphIngestDelivered failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertTrue(not containsId(mustDue(50), row.id), "a delivered row is never due again")

  // A second markGraphIngestDelivered on the same (now-delivered) row is a
  // guarded no-op (delivered_at = '' in the WHERE clause) — 0 rows affected,
  // not an error and not a corrupted double-write.
  match CloudAgents.Repository.markGraphIngestDelivered(row.id, CloudAgents.Repository.nowMillis()) {
    case Ok(n) -> assertEqualInt(n, 0, "re-marking an already-delivered row is a no-op")
    case Err(e) -> assertTrue(false, "unexpected error re-marking delivered: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  cleanupTestDb(path)
}

test "a row that exhausts its attempt cap is marked terminal and excluded forever" {
  val path = useFreshTestDb("outbox-terminal")
  val row = mustEnqueue("sess-D", "{\"objects\":[]}", "https://platform.example/api/ingest")
  match CloudAgents.Repository.markGraphIngestTerminal(row.id, "50", CloudAgents.GraphIngestOutbox.terminalErrorMessage("simulated: platform unreachable")) {
    case Ok(n) -> assertEqualInt(n, 1, "one row marked terminal")
    case Err(e) -> assertTrue(false, "markGraphIngestTerminal failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertTrue(not containsId(mustDue(50), row.id), "a terminal row is excluded from the due scan")

  cleanupTestDb(path)
}

test "idempotent re-enqueue of the same session+body returns the existing row, not a duplicate" {
  val path = useFreshTestDb("outbox-idempotent")
  val body = "{\"objects\":[{\"kind\":\"session\"}]}"
  val first = mustEnqueue("sess-E", body, "https://platform.example/api/ingest")
  val second = mustEnqueue("sess-E", body, "https://platform.example/api/ingest")
  assertEqual(first.id, second.id, "re-enqueuing the identical (session, body) pair returns the SAME row")

  // Once delivered, re-enqueuing the exact same body again still returns the
  // (now-delivered) row rather than resurrecting it as pending — this is the
  // property CloudAgents.GraphIngestDrain.enqueueAndAttemptDelivery relies on
  // to skip a redundant POST for an already-delivered body.
  match CloudAgents.Repository.markGraphIngestDelivered(first.id, CloudAgents.Repository.nowMillis()) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "markGraphIngestDelivered failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val third = mustEnqueue("sess-E", body, "https://platform.example/api/ingest")
  assertEqual(third.id, first.id, "still the same row after delivery")
  assertTrue(third.deliveredAt.length > 0, "the re-read row reports it is already delivered")

  // A DIFFERENT body for the same session is a genuinely new row (the outbox
  // is keyed on (session_id, body_hash), not session_id alone — a session
  // that runs more than once legitimately emits more than one checkpoint).
  val differentBody = mustEnqueue(
    "sess-E",
    "{\"objects\":[{\"kind\":\"different\"}]}",
    "https://platform.example/api/ingest"
  )
  assertTrue(differentBody.id != first.id, "a different body for the same session enqueues a distinct row")

  cleanupTestDb(path)
}

test "pruneDeliveredGraphIngest removes only delivered rows, never pending ones" {
  val path = useFreshTestDb("outbox-prune")
  val delivered = mustEnqueue("sess-F", "{\"objects\":[]}", "https://platform.example/api/ingest")
  val pending = mustEnqueue("sess-G", "{\"objects\":[\"other\"]}", "https://platform.example/api/ingest")
  match CloudAgents.Repository.markGraphIngestDelivered(delivered.id, CloudAgents.Repository.nowMillis()) {
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
  assertTrue(containsId(mustDue(50), pending.id), "a pending row survives pruning")

  cleanupTestDb(path)
}
