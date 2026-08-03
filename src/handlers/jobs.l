//! src/handlers/jobs.l — CloudAgents.Jobs: scheduled jobs
//! (docs/phase8-scheduling.md). A job pairs a prompt + optional profile with
//! a one-shot run time, a recurring interval, or both. There is no
//! in-process timer in Lyric.Web, so an external scheduler polls
//! POST /api/maintenance/trigger-jobs — the same "maintenance endpoint an
//! external cron hits" idiom CloudAgents.Handlers.reapContainers and
//! CloudAgents.Webhooks' outbox already use.
//!
//! Two authentication modes, mirroring CloudAgents.Callbacks exactly:
//!   - User-originated (create/list/get/update/delete a job, trigger the
//!     maintenance sweep): normal AuthMiddleware bearer auth, owner-scoped.
//!   - Container-originated (schedule_job/list_jobs/update_job/cancel_job MCP
//!     tools): the session's own callback bearer token
//!     (authorizeJobCallbackToken below), resolving the session's OWNER user
//!     id — never the current request identity — exactly like
//!     CloudAgents.Callbacks.createSecretRequestHandler does.
//!
//! A job created via the schedule_job MCP tool always attaches the CALLING
//! session immediately ("if it triggers again, continue this session"); a
//! job created via the REST API starts with no session and gets one on its
//! first trigger. Either way, once a job has a session, every later trigger
//! continues that exact session — a fresh CloudAgents.Repository.addMessage
//! per firing, same as a human typing a new message into an existing session.
package CloudAgents.Jobs

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Docker
import CloudAgents.Handlers
import CloudAgents.Proxy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Text

val maxJobNameLen = 200

/// Matches CloudAgents.Handlers.maxPromptLen — a job's prompt goes through the
/// exact same container run path as a human-typed message.
val maxJobPromptLen = 131072

/// A recurring job's cadence floor: below this, an unattended job could hammer
/// the Docker daemon and the host API on every poll tick.
val minIntervalSeconds = 60

/// A recurring job's cadence ceiling (30 days) — generous, but bounded so a
/// typo (e.g. an extra zero) doesn't silently create a job that effectively
/// never recurs within any realistic monitoring window.
val maxIntervalSeconds = 2592000

/// Epoch-millisecond timestamps are 13 digits today; bounded generously above
/// that so this never needs updating before the SQLite-side 64-bit arithmetic
/// itself would need revisiting.
val maxEpochDigits = 15

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

func isAllDigits(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    if c < "0" or c > "9" {
      return false
    }
    i = i + 1
  }
  return true
}

/// "" (unset) or a bounded run of decimal digits — never parsed into a Lyric
/// integer: the only place it is ever compared/added is inside SQL
/// (CAST ... AS INTEGER, SQLite's 64-bit arithmetic), matching this schema's
/// existing epoch-millis-as-TEXT convention. pub so tests/jobs_tests.l can
/// pin this boundary directly — createJobHandler/updateJobHandler/
/// scheduleJobCallbackHandler all reach CloudAgents.SessionStore/Repository,
/// which stay test-invocable, but this validator is worth pinning on its own
/// too (mirrors CloudAgents.Handlers.promptExceedsMaxLength/parseOutputOffset).
pub func isValidRunAt(s: in String): Bool {
  return s.length == 0 or (isAllDigits(s) and s.length <= maxEpochDigits)
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

/// Parse a run of 1..9 decimal digits into an Int, or -1 for anything else —
/// mirrors CloudAgents.Callbacks.tryParseMillis (package-private there).
/// intervalSeconds is the only schedule field ever parsed into a Lyric
/// integer, since it is only ever compared against small, fixed Int bounds
/// (min/maxIntervalSeconds) rather than added to an epoch timestamp.
func parseBoundedInt(s: in String): Int {
  if s.length == 0 or s.length > 9 {
    return -1
  }
  var n = 0
  var i = 0
  while i < s.length {
    val d = digitValue(s.substring(i, 1))
    if d < 0 {
      return -1
    }
    n = n * 10 + d
    i = i + 1
  }
  return n
}

pub func isValidIntervalSeconds(s: in String): Bool {
  if s.length == 0 {
    return true
  }
  val n = parseBoundedInt(s)
  return n >= minIntervalSeconds and n <= maxIntervalSeconds
}

@generate(Json)
pub record CreateJobRequest {
  pub name: String
  pub prompt: String
  pub profileId: String
  pub repoUrl: String
  pub branch: String
  pub harness: String
  pub model: String
  pub runAtEpochMillis: String
  pub intervalSeconds: String
}

@generate(Json)
pub record JobSummary {
  pub id: String
  pub name: String
  pub prompt: String
  pub profileId: String
  pub repoUrl: String
  pub branch: String
  pub harness: String
  pub model: String
  pub runAtEpochMillis: String
  pub intervalSeconds: String
  pub nextRunAtEpochMillis: String
  pub lastRunAtEpochMillis: String
  pub sessionId: String
  pub status: String
  pub createdAt: String
}

@generate(Json)
pub record JobListResponse {
  pub jobs: slice[JobSummary]
}

/// Every field is an OPTIONAL change: "" means "leave this field as it is",
/// matching NotifyRequest's level="" default convention elsewhere in this
/// codebase. runAtEpochMillis/intervalSeconds are a pair — providing EITHER
/// one replaces the whole schedule (the other reverts to unset, then
/// re-validated), so a job can move from "recurring" to "one-shot" or back
/// without a separate "clear" flag. `status`, when non-empty, must be one of
/// active/paused/cancelled ('completed' is system-set only).
@generate(Json)
pub record UpdateJobRequest {
  pub prompt: String
  pub profileId: String
  pub runAtEpochMillis: String
  pub intervalSeconds: String
  pub status: String
}

func jobSummaryOf(j: in CloudAgents.Repository.ScheduledJob): JobSummary {
  return JobSummary(
    id = j.id,
    name = j.name,
    prompt = j.prompt,
    profileId = j.profileId,
    repoUrl = j.repoUrl,
    branch = j.branch,
    harness = j.harness,
    model = j.model,
    runAtEpochMillis = j.runAt,
    intervalSeconds = j.intervalSeconds,
    nextRunAtEpochMillis = j.nextRunAt,
    lastRunAtEpochMillis = j.lastRunAt,
    sessionId = j.sessionId,
    status = j.status,
    createdAt = j.createdAt
  )
}

// ─── User-originated CRUD ────────────────────────────────────────────────────
/// Create a scheduled job. Repo/branch/harness/model go through the exact
/// same validation createSession applies (CloudAgents.Handlers, made pub for
/// this reuse) — a job's first trigger creates a session the same way a
/// human-initiated createSession call does.
pub func createJobHandler(userId: in String, req: in CreateJobRequest): Result[JobSummary, Web.ApiError] {
  if req.prompt.length == 0 {
    return Err(Web.badRequest("prompt is required"))
  }
  if not CloudAgents.Text.withinMaxByteLength(req.prompt, maxJobPromptLen) {
    return Err(Web.badRequest("prompt is too long (max " + toString(maxJobPromptLen) + " bytes)"))
  }
  if not CloudAgents.Text.withinMaxLength(req.name, maxJobNameLen) {
    return Err(Web.badRequest("name is too long (max " + toString(maxJobNameLen) + " characters)"))
  }
  if req.repoUrl.length == 0 {
    return Err(Web.badRequest("repoUrl is required"))
  }
  if not CloudAgents.Handlers.isHttpsUrl(req.repoUrl) {
    return Err(Web.badRequest("repoUrl must use the https:// scheme"))
  }
  if not CloudAgents.Handlers.isSafeRepoUrl(req.repoUrl) {
    return Err(Web.badRequest("repoUrl contains invalid characters or is too long"))
  }
  if CloudAgents.Handlers.isBlockedRepoHost(req.repoUrl) {
    return Err(Web.badRequest("repoUrl must not point at an internal, loopback, or private host"))
  }
  if req.branch.length == 0 {
    return Err(Web.badRequest("branch is required"))
  }
  if not CloudAgents.Handlers.isSafeBranchName(req.branch) {
    return Err(Web.badRequest("branch is not a valid git branch name"))
  }
  if req.harness.length > 0 and not CloudAgents.Handlers.isKnownHarness(req.harness) {
    return Err(Web.badRequest("harness must be one of: claude, codex, opencode, gemini"))
  }
  val harness = if req.harness.length == 0 { "claude" } else { req.harness }
  if not CloudAgents.Proxy.isHarnessEnabled(harness) {
    return Err(Web.badRequest("harness '" + harness + "' is not enabled on this deployment"))
  }
  if not CloudAgents.Handlers.isSafeModelName(req.model) {
    return Err(Web.badRequest("model contains invalid characters or is too long"))
  }
  val model = if req.model.length == 0 { CloudAgents.SessionStore.defaultModelForHarness(harness) } else { req.model }
  if req.profileId.length > 0 {
    match CloudAgents.Repository.getProfile(req.profileId, userId) {
      case Ok(Some(_)) -> ()
      case Ok(None) -> return Err(Web.badRequest("profileId does not reference a known profile"))
      case Err(e) -> return Err(dbError(e))
    }
  }
  if not isValidRunAt(req.runAtEpochMillis) {
    return Err(Web.badRequest("runAtEpochMillis must be empty or a decimal epoch-millisecond timestamp"))
  }
  if not isValidIntervalSeconds(req.intervalSeconds) {
    return Err(
      Web.badRequest(
        "intervalSeconds must be empty or between " + toString(minIntervalSeconds) + " and " +
          toString(maxIntervalSeconds)
      )
    )
  }
  if req.runAtEpochMillis.length == 0 and req.intervalSeconds.length == 0 {
    return Err(Web.badRequest("at least one of runAtEpochMillis or intervalSeconds is required"))
  }
  match CloudAgents.Repository.createScheduledJob(
    userId,
    req.name,
    req.prompt,
    req.profileId,
    req.repoUrl,
    req.branch,
    harness,
    model,
    req.runAtEpochMillis,
    req.intervalSeconds
  ) {
    case Ok(job) -> return Ok(jobSummaryOf(job))
    case Err(e) -> return Err(dbError(e))
  }
}

pub func listJobsHandler(userId: in String): Result[JobListResponse, Web.ApiError] {
  match CloudAgents.Repository.listScheduledJobs(userId) {
    case Ok(js) -> {
      var acc: slice[JobSummary] = []
      for j in js {
        acc = acc.append(jobSummaryOf(j))
      }
      return Ok(JobListResponse(jobs = acc))
    }
    case Err(e) -> return Err(dbError(e))
  }
}

pub func getJobHandler(userId: in String, id: in String): Result[JobSummary, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  match CloudAgents.Repository.getScheduledJob(id, userId) {
    case Ok(Some(j)) -> return Ok(jobSummaryOf(j))
    case Ok(None) -> return Err(Web.notFound("job not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

pub func deleteJobHandler(userId: in String, id: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  match CloudAgents.Repository.deleteScheduledJob(id, userId) {
    case Ok(n) -> {
      if n > 0 {
        return Ok(())
      }
      return Err(Web.notFound("job not found"))
    }
    case Err(e) -> return Err(dbError(e))
  }
}

pub func isValidJobStatusUpdate(s: in String): Bool {
  return s == "" or s == "active" or s == "paused" or s == "cancelled"
}

/// Update a job's prompt/profile/schedule/status. See UpdateJobRequest's doc
/// comment for the "" == "leave unchanged" convention and the
/// runAtEpochMillis/intervalSeconds pairing rule.
pub func updateJobHandler(userId: in String, id: in String, req: in UpdateJobRequest): Result[JobSummary, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  val existing = match CloudAgents.Repository.getScheduledJob(id, userId) {
    case Ok(Some(j)) -> j
    case Ok(None) -> return Err(Web.notFound("job not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if not isValidJobStatusUpdate(req.status) {
    return Err(Web.badRequest("status must be one of: active, paused, cancelled"))
  }
  val prompt = if req.prompt.length > 0 { req.prompt } else { existing.prompt }
  if not CloudAgents.Text.withinMaxByteLength(prompt, maxJobPromptLen) {
    return Err(Web.badRequest("prompt is too long (max " + toString(maxJobPromptLen) + " bytes)"))
  }
  val profileId = if req.profileId.length > 0 { req.profileId } else { existing.profileId }
  if profileId.length > 0 and profileId != existing.profileId {
    match CloudAgents.Repository.getProfile(profileId, userId) {
      case Ok(Some(_)) -> ()
      case Ok(None) -> return Err(Web.badRequest("profileId does not reference a known profile"))
      case Err(e) -> return Err(dbError(e))
    }
  }
  // Providing EITHER schedule field replaces the whole schedule; the other
  // reverts to unset rather than keeping its old value, so a job can move
  // between "recurring" and "one-shot" without a separate clear flag.
  val scheduleChanged = req.runAtEpochMillis.length > 0 or req.intervalSeconds.length > 0
  val runAt = if req.runAtEpochMillis.length > 0 {
    req.runAtEpochMillis
  } else if scheduleChanged {
    ""
  } else {
    existing.runAt
  }
  val intervalSeconds = if req.intervalSeconds.length > 0 {
    req.intervalSeconds
  } else if scheduleChanged {
    ""
  } else {
    existing.intervalSeconds
  }
  if not isValidRunAt(runAt) {
    return Err(Web.badRequest("runAtEpochMillis must be empty or a decimal epoch-millisecond timestamp"))
  }
  if not isValidIntervalSeconds(intervalSeconds) {
    return Err(
      Web.badRequest(
        "intervalSeconds must be empty or between " + toString(minIntervalSeconds) + " and " +
          toString(maxIntervalSeconds)
      )
    )
  }
  if runAt.length == 0 and intervalSeconds.length == 0 {
    return Err(Web.badRequest("at least one of runAtEpochMillis or intervalSeconds is required"))
  }
  val nextRunAt = if scheduleChanged {
    if runAt.length > 0 { runAt } else { CloudAgents.Repository.nowMillis() }
  } else {
    existing.nextRunAt
  }
  val status = if req.status.length > 0 { req.status } else { existing.status }
  match CloudAgents.Repository.updateScheduledJob(
    id,
    userId,
    existing.name,
    prompt,
    profileId,
    runAt,
    intervalSeconds,
    nextRunAt,
    status
  ) {
    case Ok(n) -> {
      if n > 0 {
        return getJobHandler(userId, id)
      }
      return Err(Web.notFound("job not found"))
    }
    case Err(e) -> return Err(dbError(e))
  }
}

// ─── Running a due job ───────────────────────────────────────────────────────
/// Whether a job's due-run attempt actually happened. JobSkipped means the
/// session was busy (a concurrent human message or another job's run) —
/// next_run_at is left untouched so the poller retries on its next tick,
/// unlike JobFailed (a real run that errored), which still advances the
/// schedule so a persistently-broken job doesn't retry-storm every tick.
pub union JobRunOutcome {
  case JobSucceeded
  case JobFailed(message: String)
  case JobSkipped(reason: String)
}

/// The session a job's run targets: the job's own sessionId if it already has
/// one, else a freshly created session (mirrors createSession, minus
/// re-validating fields already validated at job-creation time), persisted
/// back onto the job row so every later trigger reuses it.
func ensureJobSession(job: in CloudAgents.Repository.ScheduledJob): Result[String, String] {
  if job.sessionId.length > 0 {
    return Ok(value = job.sessionId)
  }
  val sessionId = CloudAgents.Handlers.generateSessionId()
  val session = CloudAgents.SessionStore.makeAgentSession(
    sessionId = sessionId,
    repoUrl = job.repoUrl,
    branch = job.branch,
    containerId = "",
    harness = job.harness,
    model = job.model,
    nativeSessionId = sessionId
  )
  match CloudAgents.SessionStore.addSession(session) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = "failed to create a session for this job: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  if job.profileId.length > 0 {
    match CloudAgents.SessionStore.setSessionProfile(sessionId, job.profileId) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
  }
  match CloudAgents.Repository.attachScheduledJobSession(job.id, sessionId) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  return Ok(value = sessionId)
}

/// Run one due job's prompt against its session, mirroring
/// CloudAgents.Handlers.streamSendMessage's claim/persist/resolve/record
/// lifecycle but via CloudAgents.Docker.runSessionMessageBlocking (no
/// ResponseWriter — there is no live viewer for a scheduler-triggered run).
func runOneJob(job: in CloudAgents.Repository.ScheduledJob): JobRunOutcome {
  CloudAgents.Auth.setCurrentUserId(job.userId)
  val sessionId = match ensureJobSession(job) {
    case Ok(sid) -> sid
    case Err(msg) -> return JobFailed(message = msg)
  }
  val began = match CloudAgents.SessionStore.tryBeginRun(sessionId) {
    case Ok(b) -> b
    case Err(e) -> return JobFailed(message = "failed to claim session: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  if not began {
    return JobSkipped(reason = "a run is already in progress for this job's session")
  }
  defer {
    match CloudAgents.SessionStore.endRun(sessionId) {
      case Ok(_) -> ()
      case Err(e) -> println(
        "WARNING: failed to release run claim for scheduled job session " + sessionId + ": " +
          CloudAgents.Sqlite.dbErrorMessage(e)
      )
    }
  }
  match CloudAgents.Repository.addMessage(sessionId, "user", job.prompt) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  val extraRepos = match CloudAgents.Repository.listSessionRepos(sessionId) {
    case Ok(rs) -> CloudAgents.Handlers.extraReposEnvValue(rs)
    case Err(_) -> ""
  }
  var harness = job.harness
  if job.profileId.length > 0 {
    match CloudAgents.Repository.getProfile(job.profileId, job.userId) {
      case Ok(Some(p)) -> {
        if p.harness.length > 0 {
          harness = p.harness
        }
      }
      case Ok(None) -> ()
      case Err(_) -> ()
    }
  }
  val runId = match CloudAgents.Repository.recordRunStart(sessionId, job.userId, job.prompt, harness, job.model) {
    case Ok(rid) -> rid
    case Err(_) -> ""
  }
  val runResult = CloudAgents.Docker.runSessionMessageBlocking(
    repoUrl = job.repoUrl,
    branch = job.branch,
    prompt = job.prompt,
    sessionId = sessionId,
    harness = harness,
    model = job.model,
    nativeSessionId = sessionId,
    profileId = job.profileId,
    userId = job.userId,
    extraRepos = extraRepos
  )
  return match runResult {
    case Ok(logs) -> {
      if runId.length > 0 {
        val _ = CloudAgents.Repository.recordRunEnd(runId, job.userId, "succeeded")
        val _ = CloudAgents.Repository.enqueueWebhookEvent(job.userId, sessionId, runId, "succeeded")
      }
      match CloudAgents.Repository.addMessage(sessionId, "agent", logs) {
        case Ok(_) -> ()
        case Err(e) -> println(
          "WARNING: failed to persist agent message for scheduled job session " + sessionId + ": " +
            CloudAgents.Sqlite.dbErrorMessage(e)
        )
      }
      JobSucceeded
    }
    case Err(msg) -> {
      if runId.length > 0 {
        val _ = CloudAgents.Repository.recordRunEnd(runId, job.userId, "failed")
        val _ = CloudAgents.Repository.enqueueWebhookEvent(job.userId, sessionId, runId, "failed")
      }
      JobFailed(message = msg)
    }
  }
}

/// POST /api/maintenance/trigger-jobs — a maintenance endpoint for an
/// external scheduler to poll (Lyric.Web has no in-process timer), mirroring
/// CloudAgents.Handlers.reapContainers exactly. Safe to call repeatedly: a
/// job not yet due is untouched, and a skipped (busy-session) job is retried
/// on the next call with no double-firing. Returns
/// `{"triggered":N,"failed":M,"skipped":K}`.
pub func triggerDueJobsHandler(): Result[String, Web.ApiError] {
  val due = match CloudAgents.Repository.dueScheduledJobs() {
    case Ok(js) -> js
    case Err(e) -> return Err(dbError(e))
  }
  var triggered = 0
  var failed = 0
  var skipped = 0
  var i = 0
  while i < due.length {
    val job = due[i]
    val claimed = match CloudAgents.Repository.claimDueScheduledJob(job.id, job.nextRunAt) {
      case Ok(b) -> b
      case Err(_) -> false
    }
    if not claimed {
      // Lost the race to a concurrent trigger-jobs call (or the row changed
      // underneath us) — the other caller (or a later poll) owns this job now.
      skipped = skipped + 1
      i = i + 1
      continue
    }
    match runOneJob(job) {
      case JobSucceeded -> {
        triggered = triggered + 1
        if job.intervalSeconds.length > 0 {
          val _ = CloudAgents.Repository.markScheduledJobRanRecurring(job.id, CloudAgents.Repository.nowMillis(), job.intervalSeconds)
        } else {
          val _ = CloudAgents.Repository.markScheduledJobCompleted(job.id, CloudAgents.Repository.nowMillis())
        }
      }
      case JobFailed(msg) -> {
        failed = failed + 1
        println("WARNING: scheduled job " + job.id + " failed: " + msg)
        if job.intervalSeconds.length > 0 {
          val _ = CloudAgents.Repository.markScheduledJobRanRecurring(job.id, CloudAgents.Repository.nowMillis(), job.intervalSeconds)
        } else {
          val _ = CloudAgents.Repository.markScheduledJobCompleted(job.id, CloudAgents.Repository.nowMillis())
        }
      }
      case JobSkipped(_) -> {
        skipped = skipped + 1
        val _ = CloudAgents.Repository.restoreScheduledJobNextRunAt(job.id, job.nextRunAt)
      }
    }
    i = i + 1
  }
  return Ok(
    value = "{\"triggered\":" + toString(triggered) + ",\"failed\":" + toString(failed) + ",\"skipped\":" +
      toString(skipped) +
      "}"
  )
}

// ─── Container-originated (schedule_job / list_jobs / update_job / cancel_job
// MCP tools) ───────────────────────────────────────────────────────────────
//
// Authenticates with the calling session's own callback bearer token — never
// the current request identity — then resolves the session's OWNER (not the
// caller) to scope every job operation, mirroring
// CloudAgents.Callbacks.createSecretRequestHandler's ownerUserId lookup
// exactly. A job these tools create always attaches the CALLING session
// immediately (repoUrl/branch/harness/model stay empty on the row — they are
// only ever consulted by ensureJobSession when a job has no session yet,
// which never happens for one of these).
func authorizeJobCallbackToken(sessionId: in String, authHeaderValue: in String): Result[Unit, Web.ApiError] {
  val stored = match CloudAgents.SessionStore.callbackTokenForSession(sessionId) {
    case Ok(Some(t)) -> t
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
  if stored.length == 0 or not CloudAgents.Auth.authorizeCallback(authHeaderValue, stored) {
    return Err(Web.unauthorized("invalid callback token"))
  }
  return Ok(())
}

func ownerOfSession(sessionId: in String): Result[String, Web.ApiError] {
  match CloudAgents.SessionStore.sessionOwnerUserId(sessionId) {
    case Ok(Some(u)) -> return Ok(value = u)
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(dbError(e))
  }
}

@generate(Json)
pub record ScheduleJobCallbackRequest {
  pub name: String
  pub prompt: String
  pub runAtEpochMillis: String
  pub intervalSeconds: String
}

@generate(Json)
pub record ScheduleJobCallbackResponse {
  pub id: String
}

/// POST /api/sessions/{id}/callbacks/jobs — container-originated
/// (schedule_job MCP tool). Always attaches the calling session
/// immediately, so every future firing continues this exact session.
pub func scheduleJobCallbackHandler(
  sessionId: in String, authHeaderValue: in String, req: in ScheduleJobCallbackRequest
): Result[ScheduleJobCallbackResponse, Web.ApiError] {
  if sessionId.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  authorizeJobCallbackToken(sessionId, authHeaderValue)?
  if req.prompt.length == 0 {
    return Err(Web.badRequest("prompt is required"))
  }
  if not CloudAgents.Text.withinMaxByteLength(req.prompt, maxJobPromptLen) {
    return Err(Web.badRequest("prompt is too long (max " + toString(maxJobPromptLen) + " bytes)"))
  }
  if not CloudAgents.Text.withinMaxLength(req.name, maxJobNameLen) {
    return Err(Web.badRequest("name is too long (max " + toString(maxJobNameLen) + " characters)"))
  }
  if not isValidRunAt(req.runAtEpochMillis) {
    return Err(Web.badRequest("runAtEpochMillis must be empty or a decimal epoch-millisecond timestamp"))
  }
  if not isValidIntervalSeconds(req.intervalSeconds) {
    return Err(
      Web.badRequest(
        "intervalSeconds must be empty or between " + toString(minIntervalSeconds) + " and " +
          toString(maxIntervalSeconds)
      )
    )
  }
  if req.runAtEpochMillis.length == 0 and req.intervalSeconds.length == 0 {
    return Err(Web.badRequest("at least one of runAtEpochMillis or intervalSeconds is required"))
  }
  val ownerUserId = ownerOfSession(sessionId)?
  val job = match CloudAgents.Repository.createScheduledJob(
    ownerUserId,
    req.name,
    req.prompt,
    "",
    "",
    "",
    "",
    "",
    req.runAtEpochMillis,
    req.intervalSeconds
  ) {
    case Ok(j) -> j
    case Err(e) -> return Err(dbError(e))
  }
  match CloudAgents.Repository.attachScheduledJobSession(job.id, sessionId) {
    case Ok(_) -> ()
    case Err(e) -> return Err(dbError(e))
  }
  return Ok(ScheduleJobCallbackResponse(id = job.id))
}

/// GET /api/sessions/{id}/callbacks/jobs — container-originated (list_jobs
/// MCP tool). Lists every job owned by this session's owner, not just jobs
/// tied to this session — an agent can review and manage the whole backlog it
/// (or the human) has scheduled.
pub func listJobsCallbackHandler(sessionId: in String, authHeaderValue: in String): Result[JobListResponse, Web.ApiError] {
  if sessionId.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  authorizeJobCallbackToken(sessionId, authHeaderValue)?
  val ownerUserId = ownerOfSession(sessionId)?
  return listJobsHandler(ownerUserId)
}

/// POST /api/sessions/{id}/callbacks/jobs/{jid}/update — container-originated
/// (update_job MCP tool).
pub func updateJobCallbackHandler(
  sessionId: in String, jobId: in String, authHeaderValue: in String, req: in UpdateJobRequest
): Result[JobSummary, Web.ApiError] {
  if sessionId.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if jobId.length == 0 {
    return Err(Web.badRequest("job id is required"))
  }
  authorizeJobCallbackToken(sessionId, authHeaderValue)?
  val ownerUserId = ownerOfSession(sessionId)?
  return updateJobHandler(ownerUserId, jobId, req)
}

/// POST /api/sessions/{id}/callbacks/jobs/{jid}/cancel — container-originated
/// (cancel_job MCP tool). A thin wrapper over updateJobHandler's status
/// field, kept as a distinct tool since "stop this job" is a far more common
/// agent intent than a general field edit.
pub func cancelJobCallbackHandler(
  sessionId: in String, jobId: in String, authHeaderValue: in String
): Result[JobSummary, Web.ApiError] {
  return updateJobCallbackHandler(
    sessionId,
    jobId,
    authHeaderValue,
    UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "cancelled")
  )
}
