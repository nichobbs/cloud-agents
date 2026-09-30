//! CloudAgents.PgStore.Webhooks — the Postgres implementation of per-user
//! webhooks and their transactional outbox (`webhooks`, `webhook_events`),
//! mirroring the SQLite-backed functions in `CloudAgents.Repository` with the
//! same signatures and semantics (docs/phase11-postgres-tenancy.md §9 slices
//! B/C).
//!
//! Semantics carried over from the SQLite store:
//! - webhooks and events belong to the caller's user within the tenant;
//! - registering a URL the user already has returns the existing webhook
//!   rather than a duplicate;
//! - webhooks list newest first, pending events oldest first;
//! - an event is enqueued only when the user has at least one webhook.
@runtime_checked
package CloudAgents.PgStore.Webhooks

import Std.Core
import Std.Uuid
import Db
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Repository
import CloudAgents.Sqlite

func toWebhook(r: in DbRow): CloudAgents.Repository.Webhook {
  return CloudAgents.Repository.Webhook(
    id = CloudAgents.PgStore.col(r, "id"),
    userId = CloudAgents.PgStore.col(r, "user_id"),
    url = CloudAgents.PgStore.col(r, "url"),
    createdAt = CloudAgents.PgStore.col(r, "created_at")
  )
}

func webhookCols(): String {
  return "id, user_id, url, " + CloudAgents.Pg.msOut("created_at") + " AS created_at"
}

/// Register a webhook URL for the caller; an existing registration of the
/// same URL is returned as is.
pub func addWebhook(
  sc: in CloudAgents.Pg.TenantScope, url: in String
): Result[CloudAgents.Repository.Webhook, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, "INSERT INTO webhooks (id, user_id, url, created_at) VALUES (@p0, @p1, @p2, " + CloudAgents.Pg.msIn(3) + ") " + "ON CONFLICT (tenant_id, user_id, url) DO NOTHING", [Std.Uuid.uuidToString(Std.Uuid.newUuid()), sc.userId, url, CloudAgents.Repository.nowMillis()])?
  val rows = CloudAgents.PgStore.q(u, "SELECT " + webhookCols() + " FROM webhooks WHERE user_id = @p0 AND url = @p1", [sc.userId, url])?
  if rows.length == 0 {
    // Inserted or already present in this unit, so a row must be visible;
    // an empty read is a store fault, reported rather than indexed past.
    return Err(error = CloudAgents.Sqlite.ExecFailed(sql = "SELECT webhooks", message = "webhook missing after insert"))
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = toWebhook(rows[0]))
}

/// The caller's webhooks, newest first.
pub func listWebhooks(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Webhook], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + webhookCols() + " FROM webhooks WHERE user_id = @p0 ORDER BY created_at DESC, id COLLATE \"C\"", [sc.userId])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.Webhook] = []
  for r in rows {
    acc = acc.append(toWebhook(r))
  }
  return Ok(value = acc)
}

/// Delete one of the caller's webhooks; rows affected.
pub func deleteWebhook(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "DELETE FROM webhooks WHERE id = @p0 AND user_id = @p1", [id, sc.userId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

/// Whether the caller has any webhook.
pub func userHasWebhooks(sc: in CloudAgents.Pg.TenantScope): Result[Bool, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT 1 AS one FROM webhooks WHERE user_id = @p0 LIMIT 1", [sc.userId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = rows.length > 0)
}

/// Enqueue a run-finished event for the caller, only when they have a
/// webhook. The check and the insert run in one unit.
pub func enqueueWebhookEvent(
  sc: in CloudAgents.Pg.TenantScope,
  sessionId: in String,
  runId: in String,
  status: in String,
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, "INSERT INTO webhook_events (id, user_id, session_id, run_id, status, created_at) " + "SELECT @p0, @p1, @p2, @p3, @p4, " + CloudAgents.Pg.msIn(5) + " WHERE EXISTS (SELECT 1 FROM webhooks WHERE user_id = @p1)", [Std.Uuid.uuidToString(Std.Uuid.newUuid()), sc.userId, sessionId, runId, status, CloudAgents.Repository.nowMillis()])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

/// The caller's undelivered events, oldest first.
pub func listPendingWebhookEvents(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.WebhookEvent], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT id, user_id, session_id, run_id, status, " + CloudAgents.Pg.msOut("created_at") + " AS created_at " + "FROM webhook_events WHERE user_id = @p0 AND NOT delivered ORDER BY created_at, id COLLATE \"C\"", [sc.userId])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.WebhookEvent] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.Repository.WebhookEvent(
        id = CloudAgents.PgStore.col(r, "id"),
        userId = CloudAgents.PgStore.col(r, "user_id"),
        sessionId = CloudAgents.PgStore.col(r, "session_id"),
        runId = CloudAgents.PgStore.col(r, "run_id"),
        status = CloudAgents.PgStore.col(r, "status"),
        createdAt = CloudAgents.PgStore.col(r, "created_at")
      )
    )
  }
  return Ok(value = acc)
}

/// Mark one of the caller's events delivered; rows affected.
pub func markWebhookEventDelivered(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "UPDATE webhook_events SET delivered = true WHERE id = @p0 AND user_id = @p1", [id, sc.userId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}
