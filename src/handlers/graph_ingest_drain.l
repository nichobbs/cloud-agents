//! CloudAgents.GraphIngestDrain — the impure delivery layer for the durable
//! graph-ingest outbox (docs/capture-ingest-outbox.md), replacing the runner's
//! old fire-and-forget POST (docs/capture-runtime-handoff.md §5/§9 "Durable
//! outbox / retry").
//!
//! Two entry points:
//!
//! 1. `enqueueAndAttemptDelivery(sessionId, body)` — called synchronously by
//!    `CloudAgents.Docker.emitRunnerCheckpoint` right after a successful
//!    checkpoint emit. Enqueues the body DURABLY FIRST
//!    (`CloudAgents.Repository.enqueueGraphIngest`), then attempts one
//!    immediate delivery of that exact row — so the happy path is still a
//!    single POST with no added latency beyond the local DB insert, but a
//!    failed POST now leaves a durable row for the drain sweep below instead
//!    of silently losing the session's provenance.
//! 2. `drainGraphIngestHandler()` — the business logic behind
//!    `POST /api/maintenance/drain-graph-ingest`. `Lyric.Web` has no
//!    in-process timer (`docs/phase8-scheduling.md` §2; the same constraint
//!    `CloudAgents.Handlers.reapContainers` and `CloudAgents.Jobs.
//!    triggerDueJobsHandler` already work around), so this package does NOT
//!    spin its own background thread — it follows the exact same
//!    "maintenance endpoint an external scheduler polls" idiom, restricted to
//!    the operator identity for the same reason `triggerDueJobsHandler` is
//!    (a system-wide, unscoped-by-user sweep). It scans due rows, retries
//!    each with exponential backoff + jitter
//!    (`CloudAgents.GraphIngestOutbox`), gives up (marks terminal) past a
//!    configurable attempt cap, and prunes old delivered rows.
//!
//! The bearer token is read fresh from `CLOUDAGENTS_GRAPH_INGEST_TOKEN` on
//! every delivery attempt (never stored on the row) — an operator can rotate
//! or add the token after rows are already queued and the very next drain
//! (or the next `emitRunnerCheckpoint`) picks it up.
package CloudAgents.GraphIngestDrain

import Std.Core
import Std.Environment
import Web
import CloudAgents.Auth
import CloudAgents.GitHubApi
import CloudAgents.GraphIngestOutbox
import CloudAgents.Repository
import CloudAgents.Sqlite

/// Matches the timeout `docs/capture-runtime-handoff.md` §5.2 specified for
/// the original inline POST — short, self-chosen (not the 120s LLM-tuned
/// timeout), since the platform ingest call is a small JSON POST, not an LLM
/// round trip.
val graphIngestTimeoutMillis = 15000

val graphIngestUserAgent = "CloudAgents-runner/checkpoint-ingest"

val defaultDrainLimit = 25

val defaultPruneRetentionDays = 30

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

func digitValue(c: in String): Int {
  if c == "0" {
    return 0
  }
  if c == "1" {
    return 1
  }
  if c == "2" {
    return 2
  }
  if c == "3" {
    return 3
  }
  if c == "4" {
    return 4
  }
  if c == "5" {
    return 5
  }
  if c == "6" {
    return 6
  }
  if c == "7" {
    return 7
  }
  if c == "8" {
    return 8
  }
  if c == "9" {
    return 9
  }
  return -1
}

// Parses a positive-Int env var, falling back to `fallback` on anything
// blank or non-digit — mirrors the codebase's existing digit-parsing idiom
// (CloudAgents.Repository.parseNatString) rather than any numeric-parsing
// stdlib method (none of which are on the confirmed-working list in
// docs/lyric/gotchas.md).
func parsePositiveIntEnv(name: in String, fallback: in Int): Int {
  val v = Std.Environment.getVarOrDefault(name, "")
  if v.length == 0 {
    return fallback
  }
  var n = 0
  var i = 0
  while i < v.length {
    val d = digitValue(v.substring(i, 1))
    if d < 0 {
      return fallback
    }
    n = n * 10 + d
    i = i + 1
  }
  if n <= 0 {
    return fallback
  }
  return n
}

func ingestUrlConfigured(): String {
  return Std.Environment.getVarOrDefault("CLOUDAGENTS_GRAPH_INGEST_URL", "")
}

func ingestTokenConfigured(): String {
  return Std.Environment.getVarOrDefault("CLOUDAGENTS_GRAPH_INGEST_TOKEN", "")
}

/// Rows attempted per `drainGraphIngestHandler` call — bounds one call's
/// wall-clock time the same way `maxJobsPerTrigger` bounds
/// `triggerDueJobsHandler`'s, though far cheaper per row here (one bounded
/// 15s HTTP POST, not a full container run). Overridable via
/// `CLOUDAGENTS_GRAPH_INGEST_DRAIN_LIMIT`.
func drainLimit(): Int {
  return parsePositiveIntEnv("CLOUDAGENTS_GRAPH_INGEST_DRAIN_LIMIT", defaultDrainLimit)
}

/// Overridable via `CLOUDAGENTS_GRAPH_INGEST_MAX_ATTEMPTS`.
func maxAttemptsConfigured(): Int {
  return parsePositiveIntEnv("CLOUDAGENTS_GRAPH_INGEST_MAX_ATTEMPTS", CloudAgents.GraphIngestOutbox.defaultMaxAttempts)
}

/// Overridable via `CLOUDAGENTS_GRAPH_INGEST_PRUNE_DAYS`.
func pruneRetentionDaysConfigured(): Int {
  return parsePositiveIntEnv("CLOUDAGENTS_GRAPH_INGEST_PRUNE_DAYS", defaultPruneRetentionDays)
}

/// Record a failed delivery attempt against `row`: bump attempts, and either
/// schedule a backoff retry or (past the attempt cap) mark the row terminal.
/// Never fails the caller — a DB write failure here is logged and swallowed,
/// same best-effort posture as every other hop in this pipeline.
func recordFailure(row: in CloudAgents.Repository.GraphIngestOutboxRow, rawError: in String): Unit {
  val priorAttempts = CloudAgents.GraphIngestOutbox.parseAttemptsCount(row.attempts)
  val newAttempts = priorAttempts + 1
  val cap = maxAttemptsConfigured()
  if CloudAgents.GraphIngestOutbox.isTerminal(newAttempts, cap) {
    val msg = CloudAgents.GraphIngestOutbox.terminalErrorMessage(rawError)
    println(
      "WARNING: graph-ingest-outbox: id=" + row.id + " session=" + row.sessionId + " reached max attempts (" +
        toString(newAttempts) +
        "/" +
        toString(cap) +
        "); giving up"
    )
    match CloudAgents.Repository.markGraphIngestTerminal(row.id, toString(newAttempts), msg) {
      case Ok(_) -> ()
      case Err(e) -> println(
        "WARNING: graph-ingest-outbox: failed to mark id=" + row.id + " terminal: " +
          CloudAgents.Sqlite.dbErrorMessage(e)
      )
    }
  } else {
    val delay = CloudAgents.GraphIngestOutbox.backoffDelayMillis(newAttempts, row.id)
    val msg = CloudAgents.GraphIngestOutbox.truncateError(rawError, CloudAgents.GraphIngestOutbox.maxErrorLen)
    println(
      "WARNING: graph-ingest-outbox: delivery failed id=" + row.id + " session=" + row.sessionId + " attempt=" +
        toString(newAttempts) +
        "/" +
        toString(cap) +
        " retryInMs=" +
        toString(delay)
    )
    match CloudAgents.Repository.markGraphIngestAttempt(row.id, toString(newAttempts), msg, CloudAgents.Repository.nowMillis(), delay) {
      case Ok(_) -> ()
      case Err(e) -> println(
        "WARNING: graph-ingest-outbox: failed to record attempt for id=" + row.id + ": " +
          CloudAgents.Sqlite.dbErrorMessage(e)
      )
    }
  }
}

/// Attempt one delivery of `row` — bearer-authed, 2xx-only, no-redirect,
/// bounded-timeout POST (`CloudAgents.GitHubApi.httpPostJsonWithBearerTimeout`,
/// no new HTTP stack). Returns `true` iff it was actually delivered this call
/// (and marks the row delivered as a side effect); `false` on any failure
/// (token not configured, transport error, non-2xx) — the row is left (or
/// re-scheduled / marked terminal via `recordFailure`) for the next attempt.
pub func attemptDeliverRow(row: in CloudAgents.Repository.GraphIngestOutboxRow): Bool {
  val ingestToken = ingestTokenConfigured()
  if ingestToken == "" {
    recordFailure(row, "graph ingest token not configured (CLOUDAGENTS_GRAPH_INGEST_TOKEN is empty)")
    return false
  }
  return match CloudAgents.GitHubApi.httpPostJsonWithBearerTimeout(row.url, row.body, ingestToken, graphIngestUserAgent, graphIngestTimeoutMillis) {
    case Ok(_) -> {
      match CloudAgents.Repository.markGraphIngestDelivered(row.id, CloudAgents.Repository.nowMillis()) {
        case Ok(_) -> ()
        case Err(e) -> println(
          "WARNING: graph-ingest-outbox: delivered id=" + row.id + " but failed to mark delivered: " +
            CloudAgents.Sqlite.dbErrorMessage(e)
        )
      }
      println("graph-ingest-outbox: delivered id=" + row.id + " session=" + row.sessionId + " url=" + row.url)
      true
    }
    case Err(m) -> {
      recordFailure(row, m)
      false
    }
  }
}

/// Durable-first enqueue + immediate delivery attempt (docs/capture-ingest-
/// outbox.md §3). Called synchronously (no `await`) from
/// `CloudAgents.Docker.emitRunnerCheckpoint`. Never fails the caller: every
/// failure (unconfigured/malformed URL, enqueue error, delivery error) is
/// logged and swallowed.
///
/// `ingestUrl` empty ⇒ no destination configured; behaves exactly like today
/// (no row, no POST) rather than growing an undeliverable backlog forever —
/// the same "only enqueue when there's somewhere to deliver to" guard
/// `CloudAgents.Repository.enqueueWebhookEvent` already uses for the webhook
/// outbox (`userHasWebhooks`). A non-empty but non-http(s) URL is a
/// misconfiguration, logged and skipped the same way (fail-closed, matching
/// docs/capture-runtime-handoff.md §3's URL-validation rule).
///
/// The immediate attempt only fires for a row that is BOTH undelivered AND
/// actually due (`CloudAgents.GraphIngestOutbox.isDueNow`) — #1051: a fresh
/// row's `next_attempt_at` starts at `created_at` (immediately due), so the
/// ordinary first-enqueue happy path is unaffected, but `enqueueGraphIngest`
/// is idempotent on `(sessionId, bodyHash)`, so a re-enqueue of a
/// byte-identical body for a row that is currently mid-backoff (scheduled
/// minutes-to-hours out after prior failures) must NOT jump that schedule —
/// see `docs/capture-ingest-outbox.md` §6.
pub func enqueueAndAttemptDelivery(sessionId: in String, body: in String): Unit {
  val ingestUrl = ingestUrlConfigured()
  if ingestUrl == "" {
    return ()
  }
  if not (ingestUrl.startsWith("http://") or ingestUrl.startsWith("https://")) {
    println("WARNING: graph ingest URL is not http(s), skipping enqueue for session " + sessionId + ": " + ingestUrl)
    return ()
  }
  match CloudAgents.Repository.enqueueGraphIngest(sessionId, body, ingestUrl) {
    case Err(e) -> println(
      "WARNING: graph-ingest-outbox enqueue failed for session " + sessionId + ": " +
        CloudAgents.Sqlite.dbErrorMessage(e)
    )
    case Ok(row) -> {
      if row.deliveredAt != "" {
        println(
          "graph-ingest-outbox: session " + sessionId + " re-enqueue is already delivered (idempotent no-op), id=" + row.id
        )
      } else if CloudAgents.GraphIngestOutbox.isDueNow(row.nextAttemptAt, CloudAgents.Repository.nowMillis()) {
        val _ = attemptDeliverRow(row)
      } else {
        // #1051: a re-enqueue of an already-queued, currently-mid-backoff
        // row (identical session + body, e.g. a caller that reproduces the
        // same mapped objects) must not jump the Equal-Jitter schedule
        // recordFailure computed for it — leave it for the drain sweep
        // instead of firing a second attempt ahead of schedule.
        println(
          "graph-ingest-outbox: session " + sessionId + " re-enqueue is mid-backoff (next attempt at " + row.nextAttemptAt +
            "), leaving id=" +
            row.id +
            " for the drain sweep"
        )
      }
    }
  }
}

/// `POST /api/maintenance/drain-graph-ingest` — an operator-only maintenance
/// endpoint for an external scheduler to poll (no in-process timer; see the
/// module doc), mirroring `CloudAgents.Jobs.triggerDueJobsHandler` exactly:
/// restricted to the operator identity because `dueGraphIngest` is a
/// system-wide, unscoped-by-user sweep. Safe to call repeatedly — a row not
/// yet due is untouched, and a delivered/terminal row is excluded from the
/// scan. Processes at most `drainLimit()` due rows (earliest-due first) per
/// call; anything left over is picked up on the next poll. Also prunes
/// delivered rows older than `pruneRetentionDaysConfigured()` days on every
/// call. Returns `{"delivered":N,"failed":M,"terminal":K,"pruned":P}`.
pub func drainGraphIngestHandler(): Result[String, Web.ApiError] {
  if CloudAgents.Auth.currentUserId() != CloudAgents.Auth.operatorUserId() {
    return Err(Web.unauthorized("the graph-ingest-outbox drain may only be triggered by the operator identity"))
  }
  val due = match CloudAgents.Repository.dueGraphIngest(CloudAgents.Repository.nowMillis(), drainLimit()) {
    case Ok(rs) -> rs
    case Err(e) -> return Err(dbError(e))
  }
  val cap = maxAttemptsConfigured()
  var delivered = 0
  var failed = 0
  var terminal = 0
  var i = 0
  while i < due.length {
    val row = due[i]
    val beforeAttempts = CloudAgents.GraphIngestOutbox.parseAttemptsCount(row.attempts)
    if attemptDeliverRow(row) {
      delivered = delivered + 1
    } else if CloudAgents.GraphIngestOutbox.isTerminal(beforeAttempts + 1, cap) {
      terminal = terminal + 1
    } else {
      failed = failed + 1
    }
    i = i + 1
  }
  val pruned = match CloudAgents.Repository.pruneDeliveredGraphIngest(pruneRetentionDaysConfigured()) {
    case Ok(n) -> n
    case Err(e) -> {
      println("WARNING: graph-ingest-outbox: prune failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      0
    }
  }
  return Ok(
    value = "{\"delivered\":" + toString(delivered) + ",\"failed\":" + toString(failed) + ",\"terminal\":" +
      toString(terminal) +
      ",\"pruned\":" +
      toString(pruned) +
      "}"
  )
}
