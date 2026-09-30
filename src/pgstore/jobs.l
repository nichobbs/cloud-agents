//! CloudAgents.PgStore.Jobs — the Postgres implementation of scheduled jobs
//! (docs/phase8-scheduling.md, docs/phase11-postgres-tenancy.md §5.3a, §9
//! slices B/C). It mirrors the SQLite-backed functions in
//! `CloudAgents.Repository` with the same signatures and semantics.
//!
//! Human and container calls arrive with the owner's scope in the job's
//! tenant, and row-level security confines them to it; within it a job is
//! the owner's alone, as on SQLite.
//!
//! Firing is claimed across every tenant through `claim_scheduled_jobs`
//! (§5.3a), which advances each claimed job's schedule in the same statement:
//! `last_run_at` becomes the firing time, a recurring job moves to the first
//! slot on its cadence after it, and a one-shot job becomes `completed`. So
//! overlapping polls on any number of instances never fire a slot twice, and
//! a run interrupted by an instance crash is not re-fired. A skipped run (its
//! session was busy) releases its claim, which is a no-op if the job was
//! edited in the meantime.
//!
//! Timestamps read back as epoch milliseconds and an unset one as "";
//! `interval_seconds` as decimal text, "" for a one-shot job.
@runtime_checked
package CloudAgents.PgStore.Jobs

import Std.Core
import Std.Uuid
import Db
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

func query(
  sc: in CloudAgents.Pg.TenantScope, sql: in String, params: in slice[String]
): Result[slice[DbRow], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, sql, params)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = rows)
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

/// `@pN` as a timestamp, or NULL when it is "".
func msOpt(n: in Int): String {
  return "(timestamptz 'epoch' + NULLIF(@p" + toString(n) + ", '')::bigint * interval '1 millisecond')"
}

func ms(col: in String): String {
  return CloudAgents.Pg.msOut(col) + " AS " + col
}

func jobCols(): String {
  return "id, user_id, name, prompt, profile_id, repo_url, branch, harness, model, " + ms("run_at") +
    ", interval_seconds::text AS interval_seconds, " +
    ms("next_run_at") +
    ", " +
    ms("last_run_at") +
    ", session_id, status, " +
    ms("created_at")
}

func toJob(r: in DbRow): CloudAgents.Repository.ScheduledJob {
  return CloudAgents.Repository.ScheduledJob(
    id = c(r, "id"),
    userId = c(r, "user_id"),
    name = c(r, "name"),
    prompt = c(r, "prompt"),
    profileId = c(r, "profile_id"),
    repoUrl = c(r, "repo_url"),
    branch = c(r, "branch"),
    harness = c(r, "harness"),
    model = c(r, "model"),
    runAt = c(r, "run_at"),
    intervalSeconds = c(r, "interval_seconds"),
    nextRunAt = c(r, "next_run_at"),
    lastRunAt = c(r, "last_run_at"),
    sessionId = c(r, "session_id"),
    status = c(r, "status"),
    createdAt = c(r, "created_at")
  )
}

func insertSql(): String {
  return "INSERT INTO scheduled_jobs (id, user_id, name, prompt, profile_id, repo_url, branch, harness, model, run_at, " +
    "interval_seconds, next_run_at, session_id, status, created_at) VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6, @p7, @p8, " +
    msOpt(9) +
    ", NULLIF(@p10, '')::integer, " +
    CloudAgents.Pg.msIn(11) +
    ", @p12, 'active', " +
    CloudAgents.Pg.msIn(13) +
    ")"
}

/// Create a new job owned by the caller. `nextRunAt` is `runAt` when a
/// one-shot/start time was given, else "now".
pub func createScheduledJob(
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  prompt: in String,
  profileId: in String,
  repoUrl: in String,
  branch: in String,
  harness: in String,
  model: in String,
  runAt: in String,
  intervalSeconds: in String,
): Result[CloudAgents.Repository.ScheduledJob, CloudAgents.Sqlite.DbError] {
  return insertJob(sc, name, prompt, profileId, repoUrl, branch, harness, model, runAt, intervalSeconds, "")
}

/// Create a new job with `sessionId` already attached, in one statement (the
/// schedule_job MCP callback; #877).
pub func createScheduledJobWithSession(
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  prompt: in String,
  runAt: in String,
  intervalSeconds: in String,
  sessionId: in String,
): Result[CloudAgents.Repository.ScheduledJob, CloudAgents.Sqlite.DbError] {
  return insertJob(sc, name, prompt, "", "", "", "", "", runAt, intervalSeconds, sessionId)
}

func insertJob(
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  prompt: in String,
  profileId: in String,
  repoUrl: in String,
  branch: in String,
  harness: in String,
  model: in String,
  runAt: in String,
  intervalSeconds: in String,
  sessionId: in String,
): Result[CloudAgents.Repository.ScheduledJob, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  val nextRunAt = if runAt.length > 0 { runAt } else { ts }
  exec(sc, insertSql(), [id, sc.userId, name, prompt, profileId, repoUrl, branch, harness, model, runAt, intervalSeconds, nextRunAt, sessionId, ts])?
  return Ok(
    value = CloudAgents.Repository.ScheduledJob(
      id = id,
      userId = sc.userId,
      name = name,
      prompt = prompt,
      profileId = profileId,
      repoUrl = repoUrl,
      branch = branch,
      harness = harness,
      model = model,
      runAt = runAt,
      intervalSeconds = intervalSeconds,
      nextRunAt = nextRunAt,
      lastRunAt = "",
      sessionId = sessionId,
      status = "active",
      createdAt = ts
    )
  )
}

/// One of the caller's jobs, or None (unknown id or foreign owner).
pub func getScheduledJob(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.ScheduledJob], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + jobCols() + " FROM scheduled_jobs WHERE id = @p0 AND user_id = @p1", [id, sc.userId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toJob(rows[0])))
}

/// All of the caller's jobs, newest first.
pub func listScheduledJobs(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.ScheduledJob], CloudAgents.Sqlite.DbError] {
  val rows = query(sc, "SELECT " + jobCols() + " FROM scheduled_jobs WHERE user_id = @p0 " + "ORDER BY scheduled_jobs.created_at DESC, scheduled_jobs.id COLLATE \"C\"", [sc.userId])?
  var acc: slice[CloudAgents.Repository.ScheduledJob] = []
  for r in rows {
    acc = acc.append(toJob(r))
  }
  return Ok(value = acc)
}

/// Claim up to `limit` due jobs across every tenant, earliest-due first, via
/// `claim_scheduled_jobs` (§5.3a). Each claimed job is returned with its
/// owner's scope in its tenant and the row as it was before the claim.
pub func claimDueScheduledJobs(
  limit: in Int
): Result[slice[CloudAgents.Repository.ClaimedJob], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val keys = CloudAgents.PgStore.q(u, "SELECT tenant_id, id, user_id, " + ms("due_at") + ", " + ms("previous_last_run_at") + " FROM public.claim_scheduled_jobs(@p0::integer)", [toString(limit)])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.ClaimedJob] = []
  for k in keys {
    val sc = CloudAgents.Pg.TenantScope(tenantId = c(k, "tenant_id"), userId = c(k, "user_id"))
    // The claim has committed: a failure reading the job back loses this one
    // firing (its slot is already advanced), never fires it twice.
    match getScheduledJob(c(k, "id"), sc) {
      case Ok(Some(claimed)) -> {
        val before = CloudAgents.Repository.ScheduledJob(
          id = claimed.id,
          userId = claimed.userId,
          name = claimed.name,
          prompt = claimed.prompt,
          profileId = claimed.profileId,
          repoUrl = claimed.repoUrl,
          branch = claimed.branch,
          harness = claimed.harness,
          model = claimed.model,
          runAt = claimed.runAt,
          intervalSeconds = claimed.intervalSeconds,
          nextRunAt = c(k, "due_at"),
          lastRunAt = c(k, "previous_last_run_at"),
          sessionId = claimed.sessionId,
          status = "active",
          createdAt = claimed.createdAt
        )
        acc = acc.append(
          CloudAgents.Repository.ClaimedJob(
            tenantScope = sc,
            job = before,
            claimedAt = claimed.lastRunAt,
            claimedNextRunAt = claimed.nextRunAt,
            claimedStatus = claimed.status
          )
        )
      }
      case Ok(None) -> println("WARNING: claimed scheduled job " + c(k, "id") + " vanished before it could run")
      case Err(e) -> println(
        "WARNING: could not read claimed scheduled job " + c(k, "id") + ": " +
          CloudAgents.Sqlite.dbErrorMessage(e)
      )
    }
  }
  return Ok(value = acc)
}

/// Undo a claim whose run was skipped (its session was busy), so the slot is
/// retried on the next poll. A no-op if the row changed since the claim.
pub func releaseScheduledJobClaim(c0: in CloudAgents.Repository.ClaimedJob): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(c0.tenantScope, "UPDATE scheduled_jobs SET next_run_at = " + msOpt(2) + ", last_run_at = " + msOpt(3) + ", status = 'active' " + "WHERE id = @p0 AND user_id = @p1 AND last_run_at = " + msOpt(4) + " AND next_run_at IS NOT DISTINCT FROM " + msOpt(5) + " AND status = @p6", [c0.job.id, c0.tenantScope.userId, c0.job.nextRunAt, c0.job.lastRunAt, c0.claimedAt, c0.claimedNextRunAt, c0.claimedStatus])?
  return Ok(value = ())
}

/// Attach a session to a job on its first run — a no-op if it already has one.
pub func attachScheduledJobSession(
  id: in String, sc: in CloudAgents.Pg.TenantScope, sessionId: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  exec(sc, "UPDATE scheduled_jobs SET session_id = @p1 WHERE id = @p0 AND session_id = ''", [id, sessionId])?
  return Ok(value = ())
}

/// Update one of the caller's jobs. Returns the affected row count.
/// `writeNextRunAt` false leaves `next_run_at` out of the UPDATE (#891).
pub func updateScheduledJob(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  prompt: in String,
  profileId: in String,
  runAt: in String,
  intervalSeconds: in String,
  nextRunAt: in String,
  status: in String,
  writeNextRunAt: in Bool,
): Result[Int, CloudAgents.Sqlite.DbError] {
  val sql = "UPDATE scheduled_jobs SET name = @p2, prompt = @p3, profile_id = @p4, run_at = " + msOpt(5) +
    ", interval_seconds = NULLIF(@p6, '')::integer, status = @p7"
  val params: slice[String] = [id, sc.userId, name, prompt, profileId, runAt, intervalSeconds, status]
  if writeNextRunAt {
    return exec(sc, sql + ", next_run_at = " + msOpt(8) + " WHERE id = @p0 AND user_id = @p1", params.append(nextRunAt))
  }
  return exec(sc, sql + " WHERE id = @p0 AND user_id = @p1", params)
}

/// Delete one of the caller's jobs. Returns the affected row count.
pub func deleteScheduledJob(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Sqlite.DbError] {
  return exec(sc, "DELETE FROM scheduled_jobs WHERE id = @p0 AND user_id = @p1", [id, sc.userId])
}
