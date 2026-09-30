//! CloudAgents.PgStore.GraphIngest — the Postgres implementation of the
//! graph-ingest outbox (docs/capture-ingest-outbox.md,
//! docs/phase11-postgres-tenancy.md §5.3, §5.3a). It mirrors the
//! SQLite-backed functions in `CloudAgents.Repository` with the same
//! signatures and semantics.
//!
//! Enqueue and every outcome run under the session owner's scope, and
//! row-level security confines them to its tenant. A drain finds due rows in
//! every tenant through `claim_graph_ingest_outbox`, which leases each row
//! for `CloudAgents.GraphIngestOutbox.leaseSeconds` in the statement that
//! selects it; the immediate attempt after an enqueue takes the same lease on
//! its one row. Recording an outcome clears the lease, and a lease left by a
//! crashed worker runs out, so the row is claimed again later. Delivered rows
//! are pruned across tenants through `prune_graph_ingest_outbox`, which can
//! delete delivered rows only.
//!
//! Rows read back in the SQLite shape: timestamps as epoch milliseconds, an
//! undelivered row's `deliveredAt` as "", and a row that has been given up on
//! with `CloudAgents.GraphIngestOutbox.terminalSentinelMillis` as its
//! `nextAttemptAt`.
@runtime_checked
package CloudAgents.PgStore.GraphIngest

import Std.Core
import Std.Uuid
import Db
import CloudAgents.Crypto
import CloudAgents.GraphIngestOutbox
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Repository
import CloudAgents.Sqlite

func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func c(r: in DbRow, name: in String): String {
  return CloudAgents.PgStore.col(r, name)
}

func exec(
  sc: in CloudAgents.Pg.TenantScope, sql: in String, params: in slice[String]
): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, sql, params)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

func rowCols(): String {
  return "id, session_id, body, url, " + CloudAgents.Pg.msOut("created_at") +
    " AS created_at, attempts::text AS attempts, " +
    "CASE WHEN given_up_at IS NOT NULL THEN '" +
    CloudAgents.GraphIngestOutbox.terminalSentinelMillis +
    "' ELSE " +
    CloudAgents.Pg.msOut("next_attempt_at") +
    " END AS next_attempt_at, last_error, " +
    CloudAgents.Pg.msOut("delivered_at") +
    " AS delivered_at"
}

func toRow(r: in DbRow): CloudAgents.Repository.GraphIngestOutboxRow {
  return CloudAgents.Repository.GraphIngestOutboxRow(
    id = c(r, "id"),
    sessionId = c(r, "session_id"),
    body = c(r, "body"),
    url = c(r, "url"),
    createdAt = c(r, "created_at"),
    attempts = c(r, "attempts"),
    nextAttemptAt = c(r, "next_attempt_at"),
    lastError = c(r, "last_error"),
    deliveredAt = c(r, "delivered_at")
  )
}

/// Enqueue a body for delivery. Idempotent per (session, body): a
/// byte-identical re-enqueue returns the existing row in its current state.
/// A new row is due at once.
pub func enqueueGraphIngest(
  sessionId: in String, body: in String, url: in String, sc: in CloudAgents.Pg.TenantScope
): Result[CloudAgents.Repository.GraphIngestOutboxRow, CloudAgents.Sqlite.DbError] {
  val bodyHash = CloudAgents.Crypto.sha256Base64(body)
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, "INSERT INTO graph_ingest_outbox (id, user_id, session_id, body, body_hash, url, created_at, next_attempt_at) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, now(), now()) " + "ON CONFLICT (tenant_id, session_id, body_hash) DO NOTHING", [newId(), sc.userId, sessionId, body, bodyHash, url])?
  val rows = CloudAgents.PgStore.q(u, "SELECT " + rowCols() + " FROM graph_ingest_outbox WHERE session_id = @p0 AND body_hash = @p1", [sessionId, bodyHash])?
  CloudAgents.PgStore.commit(u)?
  if rows.length == 0 {
    return Err(error = CloudAgents.Sqlite.ValidationFailed(message = "graph-ingest outbox row missing after enqueue"))
  }
  return Ok(value = toRow(rows[0]))
}

/// One row by id, or None.
pub func getGraphIngest(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.GraphIngestOutboxRow], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + rowCols() + " FROM graph_ingest_outbox WHERE id = @p0", [id])?
  CloudAgents.PgStore.commit(u)?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toRow(rows[0])))
}

/// Lease one row for an immediate delivery attempt: true when it is
/// undelivered, not given up on, due, and not held by another claim.
pub func claimGraphIngest(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Bool, CloudAgents.Sqlite.DbError] {
  val n = exec(sc, "UPDATE graph_ingest_outbox SET claimed_until = now() + make_interval(secs => @p1::integer) " + "WHERE id = @p0 AND delivered_at IS NULL AND given_up_at IS NULL AND next_attempt_at <= now() " + "AND (claimed_until IS NULL OR claimed_until < now())", [id, toString(CloudAgents.GraphIngestOutbox.leaseSeconds)])?
  return Ok(value = n == 1)
}

/// Claim up to `limit` due rows across every tenant, each leased, and read
/// each back under its owner's scope.
pub func claimDueGraphIngest(
  limit: in Int, leaseSeconds: in Int
): Result[slice[CloudAgents.Repository.ClaimedGraphIngest], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val keys = CloudAgents.PgStore.q(u, "SELECT tenant_id, id, user_id FROM public.claim_graph_ingest_outbox(@p0::integer, @p1::integer)", [toString(limit), toString(leaseSeconds)])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.ClaimedGraphIngest] = []
  for k in keys {
    val sc = CloudAgents.Pg.TenantScope(tenantId = c(k, "tenant_id"), userId = c(k, "user_id"))
    // The lease has committed: a failed read-back leaves the row for a
    // later drain once the lease runs out.
    match getGraphIngest(c(k, "id"), sc) {
      case Ok(Some(row)) -> {
        acc = acc.append(CloudAgents.Repository.ClaimedGraphIngest(tenantScope = sc, row = row))
      }
      case Ok(None) -> println("WARNING: claimed graph-ingest row " + c(k, "id") + " vanished before delivery")
      case Err(e) -> println(
        "WARNING: could not read claimed graph-ingest row " + c(k, "id") + ": " +
          CloudAgents.Sqlite.dbErrorMessage(e)
      )
    }
  }
  return Ok(value = acc)
}

/// Record a retryable failure and schedule the next attempt at
/// `nowMillisStr + delayMillis`, releasing the lease. Returns rows affected.
pub func markGraphIngestAttempt(
  id: in String,
  newAttempts: in String,
  error: in String,
  nowMillisStr: in String,
  delayMillis: in Int,
  sc: in CloudAgents.Pg.TenantScope,
): Result[Int, CloudAgents.Sqlite.DbError] {
  return exec(
    sc,
    "UPDATE graph_ingest_outbox SET attempts = @p1::integer, last_error = @p2, next_attempt_at = " +
      CloudAgents.Pg.msIn(3) +
      " + @p4::bigint * interval '1 millisecond', claimed_until = NULL " +
      "WHERE id = @p0 AND delivered_at IS NULL",
    [id, newAttempts, error, nowMillisStr, toString(delayMillis)]
  )
}

/// Record that a row has exhausted its retry budget: it is never claimed
/// again. Returns rows affected.
pub func markGraphIngestTerminal(
  id: in String,
  newAttempts: in String,
  error: in String,
  sc: in CloudAgents.Pg.TenantScope,
): Result[Int, CloudAgents.Sqlite.DbError] {
  return exec(
    sc,
    "UPDATE graph_ingest_outbox SET attempts = @p1::integer, last_error = @p2, given_up_at = now(), " +
      "claimed_until = NULL WHERE id = @p0 AND delivered_at IS NULL",
    [id, newAttempts, error]
  )
}

/// Mark a row delivered, releasing the lease. Returns rows affected (0 when
/// it was already delivered).
pub func markGraphIngestDelivered(
  id: in String, deliveredAt: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Int, CloudAgents.Sqlite.DbError] {
  return exec(
    sc,
    "UPDATE graph_ingest_outbox SET delivered_at = " + CloudAgents.Pg.msIn(1) +
      ", last_error = '', claimed_until = NULL WHERE id = @p0 AND delivered_at IS NULL",
    [id, deliveredAt]
  )
}

/// Delete delivered rows older than `retentionDays` (at least one day) in
/// every tenant. Returns rows deleted.
pub func pruneDeliveredGraphIngest(retentionDays: in Int): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT public.prune_graph_ingest_outbox(@p0::integer)::text AS n", [toString(retentionDays)])?
  CloudAgents.PgStore.commit(u)?
  if rows.length == 0 {
    return Ok(value = 0)
  }
  return Ok(value = CloudAgents.Repository.parseNatString(c(rows[0], "n")))
}
