//! CloudAgents.PgStore.SessionEvents — the Postgres implementation of a
//! session's captured provenance events (`session_events`,
//! docs/session-events-store.md), mirroring the SQLite-backed functions in
//! `CloudAgents.Repository` with the same signatures and semantics
//! (docs/phase11-postgres-tenancy.md §9 slices B/C).
//!
//! Semantics carried over from the SQLite store:
//! - an append is all-or-nothing, so a stored chain never has a hole;
//! - re-appending a byte-identical, already-stored event is a no-op, but an
//!   event whose stored payload or hash differs rejects the whole batch
//!   (#965), so a tamper or divergent re-parse is never masked. The check
//!   runs after each insert inside the unit, so it also holds against a
//!   concurrent append of the same sequence number;
//! - the append returns the number of events submitted;
//! - reads are oldest first; an "after" cursor is exclusive, and "" means
//!   from the start (sequence numbers begin at 0);
//! - the resume cursor is one past the highest stored sequence number and
//!   that event's hash, or (0, "") for a session with no events.
@runtime_checked
package CloudAgents.PgStore.SessionEvents

import Std.Core
import Db
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Repository
import CloudAgents.Db
import CloudAgents.Capture

func query(
  sc: in CloudAgents.Pg.TenantScope, sql: in String, params: in slice[String]
): Result[slice[DbRow], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, sql, params)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = rows)
}

val eventCols = "seq::text AS seq, event_type, payload, prev_hash, hash"

func toEvent(r: in DbRow): CaptureEvent {
  // Constructed unqualified: package-qualified record construction is a
  // documented runtime trap (docs/lyric/gotchas.md).
  return CaptureEvent(
    seq = CloudAgents.Repository.parseNatString(CloudAgents.PgStore.col(r, "seq")).toLong(),
    eventType = CloudAgents.PgStore.col(r, "event_type"),
    payload = CloudAgents.PgStore.col(r, "payload"),
    prevHash = CloudAgents.PgStore.col(r, "prev_hash"),
    hash = CloudAgents.PgStore.col(r, "hash")
  )
}

func toEvents(rows: in slice[DbRow]): slice[CaptureEvent] {
  val acc: List[CaptureEvent] = newList()
  for r in rows {
    acc.add(toEvent(r))
  }
  return acc.toArray()
}

/// Append a session's captured events in one unit. See the package comment
/// for the idempotence and tamper-evidence rules.
pub func appendSessionEvents(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, events: in slice[CaptureEvent]
): Result[Int, CloudAgents.Db.DbError] {
  if events.length.toInt() == 0 {
    return Ok(value = 0)
  }
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ts = CloudAgents.Repository.nowMillis()
  var i = 0
  while i < events.length.toInt() {
    val e = events[i]
    val seq = toString(e.seq)
    val inserted = CloudAgents.PgStore.ex(u, "INSERT INTO session_events (session_id, seq, event_type, payload, prev_hash, hash, created_at) " + "VALUES (@p0, @p1::bigint, @p2, @p3, @p4, @p5, " + CloudAgents.Pg.msIn(6) + ") ON CONFLICT (tenant_id, session_id, seq) DO NOTHING", [sessionId, seq, e.eventType, e.payload, e.prevHash, e.hash, ts])?
    if inserted == 0 {
      val stored = CloudAgents.PgStore.q(u, "SELECT payload, hash FROM session_events WHERE session_id = @p0 AND seq = @p1::bigint", [sessionId, seq])?
      if stored.length == 0 or CloudAgents.PgStore.col(stored[0], "payload") != e.payload or CloudAgents.PgStore.col(stored[0], "hash") != e.hash {
        return Err(
          error = CloudAgents.Db.ValidationFailed(
            message = "session_events conflict for session " + sessionId + " seq " + seq +
              ": already-stored content differs from the re-appended content"
          )
        )
      }
    }
    i = i + 1
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = events.length.toInt())
}

/// A session's captured events with seq strictly greater than `afterSeq`
/// ("" = from the start), oldest first.
pub func sessionEventsAfterSeq(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterSeq: in String
): Result[slice[CaptureEvent], CloudAgents.Db.DbError] {
  val normalized = if afterSeq.length == 0 { "-1" } else { afterSeq }
  val rows = query(sc, "SELECT " + eventCols + " FROM session_events WHERE session_id = @p0 AND seq > @p1::bigint ORDER BY session_events.seq", [sessionId, normalized])?
  return Ok(value = toEvents(rows))
}

/// A session's captured events in the window `fromExclusive < seq <=
/// toInclusive` (bounded to 500), ascending.
pub func sessionEventsInRange(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  fromExclusive: in String,
  toInclusive: in String,
): Result[slice[CaptureEvent], CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT " + eventCols + " FROM session_events WHERE session_id = @p0 AND seq > @p1::bigint AND seq <= @p2::bigint " + "ORDER BY session_events.seq LIMIT 500", [sessionId, fromExclusive, toInclusive])?
  return Ok(value = toEvents(rows))
}

/// Up to `limit` captured events after `afterSeq` ("" = from the start),
/// oldest first.
pub func sessionEventsAfterSeqLimited(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  afterSeq: in String,
  limit: in Int,
): Result[slice[CaptureEvent], CloudAgents.Db.DbError] {
  val normalized = if afterSeq.length == 0 { "-1" } else { afterSeq }
  val rows = query(sc, "SELECT " + eventCols + " FROM session_events WHERE session_id = @p0 AND seq > @p1::bigint ORDER BY session_events.seq LIMIT " + toString(limit), [sessionId, normalized])?
  return Ok(value = toEvents(rows))
}

/// The highest captured event seq for a session, or "" when nothing has been
/// captured yet.
pub func latestSessionEventSeq(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[String, CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT max(seq)::text AS seq FROM session_events WHERE session_id = @p0", [sessionId])?
  if rows.length == 0 {
    return Ok(value = "")
  }
  return Ok(value = CloudAgents.PgStore.col(rows[0], "seq"))
}

/// The hash-chain cursor a fresh run's capture resumes from: one past the
/// highest stored seq and that event's hash, or (0, "") with no events.
pub func latestSessionEventCursor(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[CloudAgents.Repository.SessionEventCursor, CloudAgents.Db.DbError] {
  val rows = query(sc, "SELECT seq::text AS seq, hash FROM session_events WHERE session_id = @p0 ORDER BY session_events.seq DESC LIMIT 1", [sessionId])?
  if rows.length == 0 {
    return Ok(value = SessionEventCursor())
  }
  val latest = CloudAgents.Repository.parseNatString(CloudAgents.PgStore.col(rows[0], "seq")).toLong()
  return Ok(
    value = SessionEventCursor(
      nextSeq = latest + 1.toLong(),
      lastHash = CloudAgents.PgStore.col(rows[0], "hash")
    )
  )
}
