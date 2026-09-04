@test_module
package CloudAgents.JobsTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Jobs
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/callbacks_v2_tests.l) ────────────
val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
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
  CloudAgents.Auth.setCurrentUserId("default")
}

func mkSession(id: in String): Unit {
  val s = makeAgentSession(
    sessionId = id,
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = id
  )
  match addSession(s) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mintToken(id: in String, ownerUserId: in String): String {
  return match CloudAgents.SessionStore.mintCallbackToken(id, ownerUserId) {
    case Ok(t) -> t
    case Err(e) -> panic("mintCallbackToken failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func bearer(token: in String): String {
  return "Bearer " + token
}

func mkProfile(userId: in String): String {
  return match CloudAgents.Repository.addProfile(userId, "test-profile", "claude", "full", "all", [], [], [], [], "all", []) {
    case Ok(p) -> p.id
    case Err(e) -> panic("addProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func baseCreateReq(prompt: in String, runAt: in String, interval: in String): CreateJobRequest {
  return CreateJobRequest(
    name = "nightly digest",
    prompt = prompt,
    profileId = "",
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    harness = "",
    model = "",
    runAtEpochMillis = runAt,
    intervalSeconds = interval
  )
}

// ── Pure schedule-field validation (docs/phase8-scheduling.md) ───────────────
test "isValidRunAt accepts empty and bounded decimal digit strings, rejects the rest" {
  assertTrue(CloudAgents.Jobs.isValidRunAt(""), "empty means unset — always valid")
  assertTrue(CloudAgents.Jobs.isValidRunAt("1700000000000"), "a real epoch-millis value is valid")
  assertTrue(not CloudAgents.Jobs.isValidRunAt("17000000000e0"), "a non-digit character is rejected")
  assertTrue(not CloudAgents.Jobs.isValidRunAt("-1700000000000"), "a sign character is rejected")
  assertTrue(not CloudAgents.Jobs.isValidRunAt("1234567890123456"), "16 digits exceeds the bound")
}

test "isValidIntervalSeconds enforces the 60..2592000 bound" {
  assertTrue(CloudAgents.Jobs.isValidIntervalSeconds(""), "empty means unset — always valid")
  assertTrue(CloudAgents.Jobs.isValidIntervalSeconds("60"), "the floor (60s) is valid")
  assertTrue(CloudAgents.Jobs.isValidIntervalSeconds("2592000"), "the ceiling (30 days) is valid")
  assertTrue(not CloudAgents.Jobs.isValidIntervalSeconds("59"), "just under the floor is rejected")
  assertTrue(not CloudAgents.Jobs.isValidIntervalSeconds("2592001"), "just over the ceiling is rejected")
  assertTrue(not CloudAgents.Jobs.isValidIntervalSeconds("abc"), "non-digit input is rejected")
}

test "isValidJobStatusUpdate accepts the empty sentinel and the three settable statuses" {
  assertTrue(CloudAgents.Jobs.isValidJobStatusUpdate(""), "empty means leave unchanged")
  assertTrue(CloudAgents.Jobs.isValidJobStatusUpdate("active"), "active is settable")
  assertTrue(CloudAgents.Jobs.isValidJobStatusUpdate("paused"), "paused is settable")
  assertTrue(CloudAgents.Jobs.isValidJobStatusUpdate("cancelled"), "cancelled is settable")
  assertTrue(not CloudAgents.Jobs.isValidJobStatusUpdate("completed"), "completed is system-set only, not client-settable")
  assertTrue(not CloudAgents.Jobs.isValidJobStatusUpdate("bogus"), "an unknown status is rejected")
}

// ── createJobHandler ─────────────────────────────────────────────────────────
test "createJobHandler requires at least one of runAtEpochMillis/intervalSeconds" {
  val dbPath = useFreshTestDb("job-create-no-schedule")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("digest the day's activity", "", "")) {
    case Ok(_) -> assertTrue(false, "a job with no schedule at all must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "missing schedule -> 400")
  }
}

test "createJobHandler rejects an internal/loopback repoUrl (SSRF)" {
  val dbPath = useFreshTestDb("job-create-ssrf")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val req = CreateJobRequest(
    name = "",
    prompt = "digest",
    profileId = "",
    repoUrl = "https://127.0.0.1/evil.git",
    branch = "main",
    harness = "",
    model = "",
    runAtEpochMillis = "",
    intervalSeconds = "3600"
  )
  match CloudAgents.Jobs.createJobHandler("default", req) {
    case Ok(_) -> assertTrue(false, "a loopback repoUrl must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "blocked host -> 400")
  }
}

test "createJobHandler rejects an unknown profileId" {
  val dbPath = useFreshTestDb("job-create-bad-profile")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val req = CreateJobRequest(
    name = "",
    prompt = "digest",
    profileId = "does-not-exist",
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    harness = "",
    model = "",
    runAtEpochMillis = "",
    intervalSeconds = "3600"
  )
  match CloudAgents.Jobs.createJobHandler("default", req) {
    case Ok(_) -> assertTrue(false, "an unknown profileId must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "unknown profile -> 400")
  }
}

test "createJobHandler creates a recurring job with next_run_at defaulted to now" {
  val dbPath = useFreshTestDb("job-create-recurring")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val profileId = mkProfile("default")
  val req = CreateJobRequest(
    name = "nightly digest",
    prompt = "summarize today's commits",
    profileId = profileId,
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    harness = "",
    model = "",
    runAtEpochMillis = "",
    intervalSeconds = "3600"
  )
  val created = match CloudAgents.Jobs.createJobHandler("default", req) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  assertTrue(created.id.length > 0, "a job id is returned")
  assertEqual(created.status, "active", "a new job starts active")
  assertEqual(created.sessionId, "", "a new job has no session until its first trigger")
  assertEqual(created.harness, "claude", "an empty harness defaults to claude")
  assertTrue(created.nextRunAtEpochMillis.length > 0, "next_run_at defaults to now for a pure-interval job")

  match CloudAgents.Jobs.getJobHandler("default", created.id) {
    case Ok(j) -> assertEqual(j.prompt, "summarize today's commits", "the stored job round-trips")
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }
}

test "createJobHandler with only a one-shot runAt uses it as next_run_at" {
  val dbPath = useFreshTestDb("job-create-oneshot")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val created = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("one-time reminder", "1999999999000", "")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  assertEqual(created.nextRunAtEpochMillis, "1999999999000", "a one-shot job's next run is exactly its runAt")
  assertEqual(created.intervalSeconds, "", "no interval was set")
}

// ── listJobsHandler / getJobHandler / deleteJobHandler ───────────────────────
test "listJobsHandler and getJobHandler are owner-scoped; getJobHandler 404s for a foreign job" {
  val dbPath = useFreshTestDb("job-owner-scope")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("alice")
  val created = match CloudAgents.Jobs.createJobHandler("alice", baseCreateReq("alice's job", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }

  match CloudAgents.Jobs.listJobsHandler("alice") {
    case Ok(list) -> assertEqualInt(list.jobs.length.toInt(), 1, "alice sees her own job")
    case Err(e) -> assertTrue(false, "listJobsHandler failed: " + toString(e.status))
  }
  match CloudAgents.Jobs.listJobsHandler("bob") {
    case Ok(list) -> assertEqualInt(list.jobs.length.toInt(), 0, "bob sees none of alice's jobs")
    case Err(e) -> assertTrue(false, "listJobsHandler failed: " + toString(e.status))
  }
  match CloudAgents.Jobs.getJobHandler("bob", created.id) {
    case Ok(_) -> assertTrue(false, "bob must not be able to read alice's job by id")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign job id -> 404, not a leak")
  }
  match CloudAgents.Jobs.deleteJobHandler("bob", created.id) {
    case Ok(_) -> assertTrue(false, "bob must not be able to delete alice's job")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign job id -> 404")
  }
  match CloudAgents.Jobs.deleteJobHandler("alice", created.id) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "alice's own delete should succeed: " + toString(e.status))
  }
  match CloudAgents.Jobs.getJobHandler("alice", created.id) {
    case Ok(_) -> assertTrue(false, "the job should be gone after delete")
    case Err(e) -> assertEqualInt(e.status, 404, "deleted job -> 404")
  }
}

// ── updateJobHandler ─────────────────────────────────────────────────────────
test "updateJobHandler leaves unspecified fields unchanged and can flip a recurring job to one-shot" {
  val dbPath = useFreshTestDb("job-update")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val created = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("original prompt", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }

  // Change only the prompt: schedule/status untouched.
  val afterPromptChange = match CloudAgents.Jobs.updateJobHandler(
    "default", created.id, UpdateJobRequest(prompt = "revised prompt", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "")
  ) {
    case Ok(j) -> j
    case Err(e) -> panic("update failed: " + toString(e.status))
  }
  assertEqual(afterPromptChange.prompt, "revised prompt", "the prompt changed")
  assertEqual(afterPromptChange.intervalSeconds, "3600", "the interval is untouched")
  assertEqual(afterPromptChange.status, "active", "the status is untouched")

  // Pause it.
  val paused = match CloudAgents.Jobs.updateJobHandler(
    "default", created.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "paused")
  ) {
    case Ok(j) -> j
    case Err(e) -> panic("pause failed: " + toString(e.status))
  }
  assertEqual(paused.status, "paused", "the job is now paused")

  // Flip to a one-shot schedule: providing runAtEpochMillis clears intervalSeconds.
  val flipped = match CloudAgents.Jobs.updateJobHandler(
    "default", created.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "1999999999000", intervalSeconds = "", status = "active")
  ) {
    case Ok(j) -> j
    case Err(e) -> panic("schedule flip failed: " + toString(e.status))
  }
  assertEqual(flipped.runAtEpochMillis, "1999999999000", "the one-shot time was set")
  assertEqual(flipped.intervalSeconds, "", "providing runAtEpochMillis clears the old interval")
  assertEqual(flipped.nextRunAtEpochMillis, "1999999999000", "next_run_at follows the new one-shot time")
  assertEqual(flipped.status, "active", "reactivated")
}

test "updateJobHandler rejects clearing the schedule entirely and an unknown status" {
  val dbPath = useFreshTestDb("job-update-invalid")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val created = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("p", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  match CloudAgents.Jobs.updateJobHandler(
    "default", created.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "not-digits", intervalSeconds = "", status = "")
  ) {
    case Ok(_) -> assertTrue(false, "a non-digit runAtEpochMillis must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "invalid runAt -> 400")
  }
  match CloudAgents.Jobs.updateJobHandler(
    "default", created.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "bogus")
  ) {
    case Ok(_) -> assertTrue(false, "an unknown status must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "invalid status -> 400")
  }
  match CloudAgents.Jobs.updateJobHandler(
    "nobody", created.id, UpdateJobRequest(prompt = "x", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "")
  ) {
    case Ok(_) -> assertTrue(false, "a foreign owner must not be able to update this job")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign owner -> 404")
  }
}

// ── Container-originated: schedule_job / list_jobs / update_job / cancel_job ─
test "scheduleJobCallbackHandler requires a valid callback token and a schedule" {
  val dbPath = useFreshTestDb("job-callback-auth")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-jobs-1"
  mkSession(sid)
  val token = mintToken(sid, "default")

  match CloudAgents.Jobs.scheduleJobCallbackHandler(
    sid, "Bearer wrong-token", ScheduleJobCallbackRequest(name = "", prompt = "p", runAtEpochMillis = "", intervalSeconds = "3600")
  ) {
    case Ok(_) -> assertTrue(false, "a wrong callback token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 401, "wrong token -> 401")
  }
  match CloudAgents.Jobs.scheduleJobCallbackHandler(
    sid, bearer(token), ScheduleJobCallbackRequest(name = "", prompt = "p", runAtEpochMillis = "", intervalSeconds = "")
  ) {
    case Ok(_) -> assertTrue(false, "no schedule at all must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "missing schedule -> 400")
  }
}

test "schedule_job attaches the calling session immediately, and list/update/cancel operate on it" {
  val dbPath = useFreshTestDb("job-callback-roundtrip")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-jobs-2"
  mkSession(sid)
  val token = mintToken(sid, "default")

  val created = match CloudAgents.Jobs.scheduleJobCallbackHandler(
    sid,
    bearer(token),
    ScheduleJobCallbackRequest(name = "follow-up", prompt = "check on this in an hour", runAtEpochMillis = "", intervalSeconds = "3600")
  ) {
    case Ok(r) -> r
    case Err(e) -> panic("schedule_job failed: " + toString(e.status))
  }
  assertTrue(created.id.length > 0, "a job id is returned")

  // The job attached THIS session immediately — not empty, and not a
  // different, freshly-minted one.
  match CloudAgents.Repository.getScheduledJob(created.id, "default") {
    case Ok(Some(j)) -> assertEqual(j.sessionId, sid, "schedule_job attaches the calling session at creation time")
    case Ok(None) -> assertTrue(false, "the job must exist")
    case Err(e) -> assertTrue(false, "getScheduledJob failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match CloudAgents.Jobs.listJobsCallbackHandler(sid, bearer(token)) {
    case Ok(list) -> {
      assertEqualInt(list.jobs.length.toInt(), 1, "the session's owner sees the job via list_jobs")
      assertEqual(list.jobs[0].id, created.id, "it's the same job")
    }
    case Err(e) -> assertTrue(false, "list_jobs failed: " + toString(e.status))
  }

  val updated = match CloudAgents.Jobs.updateJobCallbackHandler(
    sid, created.id, bearer(token), UpdateJobRequest(prompt = "revised follow-up", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "")
  ) {
    case Ok(j) -> j
    case Err(e) -> panic("update_job failed: " + toString(e.status))
  }
  assertEqual(updated.prompt, "revised follow-up", "update_job changed the prompt")

  val cancelled = match CloudAgents.Jobs.cancelJobCallbackHandler(sid, created.id, bearer(token)) {
    case Ok(j) -> j
    case Err(e) -> panic("cancel_job failed: " + toString(e.status))
  }
  assertEqual(cancelled.status, "cancelled", "cancel_job sets status to cancelled")

  // A cancelled job is not due, even backdated.
  match CloudAgents.Repository.dueScheduledJobs(100) {
    case Ok(due) -> assertEqualInt(due.length.toInt(), 0, "a cancelled job is never due")
    case Err(e) -> assertTrue(false, "dueScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── update_job/cancel_job callback scope (#881) ───────────────────────────────
test "update_job/cancel_job callbacks cannot reach a job attached to a DIFFERENT session, even same owner" {
  val dbPath = useFreshTestDb("job-callback-cross-session")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val ownerSession = "sess-jobs-owner"
  val otherSession = "sess-jobs-other"
  mkSession(ownerSession)
  mkSession(otherSession)
  val ownerToken = mintToken(ownerSession, "default")
  val otherToken = mintToken(otherSession, "default")

  val created = match CloudAgents.Jobs.scheduleJobCallbackHandler(
    ownerSession,
    bearer(ownerToken),
    ScheduleJobCallbackRequest(name = "mine", prompt = "check on this", runAtEpochMillis = "", intervalSeconds = "3600")
  ) {
    case Ok(r) -> r
    case Err(e) -> panic("schedule_job failed: " + toString(e.status))
  }

  // A DIFFERENT session belonging to the SAME user cannot update or cancel
  // it via the callback route, even though listJobsCallbackHandler (a
  // read-only, deliberately whole-backlog view) would show it.
  match CloudAgents.Jobs.updateJobCallbackHandler(
    otherSession, created.id, bearer(otherToken),
    UpdateJobRequest(prompt = "hijacked", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "")
  ) {
    case Ok(_) -> assertTrue(false, "expected a foreign-session update to be rejected, got Ok")
    case Err(e) -> assertEqualInt(e.status, 404, "a job attached to a different session 404s, like a foreign owner would")
  }
  match CloudAgents.Jobs.cancelJobCallbackHandler(otherSession, created.id, bearer(otherToken)) {
    case Ok(_) -> assertTrue(false, "expected a foreign-session cancel to be rejected, got Ok")
    case Err(e) -> assertEqualInt(e.status, 404, "a job attached to a different session 404s, like a foreign owner would")
  }

  // The job is untouched by either attempt.
  match CloudAgents.Repository.getScheduledJob(created.id, "default") {
    case Ok(Some(j)) -> {
      assertEqual(j.prompt, "check on this", "the prompt was not hijacked by the other session")
      assertEqual(j.status, "active", "the job was not cancelled by the other session")
    }
    case Ok(None) -> assertTrue(false, "the job must still exist")
    case Err(e) -> assertTrue(false, "getScheduledJob failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // The OWNING session can still update/cancel its own job normally.
  match CloudAgents.Jobs.updateJobCallbackHandler(
    ownerSession, created.id, bearer(ownerToken),
    UpdateJobRequest(prompt = "revised by owner", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "")
  ) {
    case Ok(j) -> assertEqual(j.prompt, "revised by owner", "the owning session's edit succeeds")
    case Err(e) -> assertTrue(false, "expected the owning session's update to succeed: " + toString(e.status))
  }
}

test "update_job callback cannot set profileId, even from the owning session" {
  val dbPath = useFreshTestDb("job-callback-profile-restricted")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-jobs-profile"
  mkSession(sid)
  val token = mintToken(sid, "default")
  val profileId = match CloudAgents.Repository.addProfile("default", "escalated", "", "full", "all", [], [], [], [], "all", []) {
    case Ok(p) -> p.id
    case Err(e) -> panic("addProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  val created = match CloudAgents.Jobs.scheduleJobCallbackHandler(
    sid, bearer(token),
    ScheduleJobCallbackRequest(name = "mine", prompt = "p", runAtEpochMillis = "", intervalSeconds = "3600")
  ) {
    case Ok(r) -> r
    case Err(e) -> panic("schedule_job failed: " + toString(e.status))
  }

  // Even the OWNING session's update_job callback cannot attach a profile —
  // that stays REST-only, since a profile governs network access and
  // credential injection (#881).
  match CloudAgents.Jobs.updateJobCallbackHandler(
    sid, created.id, bearer(token),
    UpdateJobRequest(prompt = "", profileId = profileId, runAtEpochMillis = "", intervalSeconds = "", status = "")
  ) {
    case Ok(j) -> assertEqual(j.profileId, "", "the callback-supplied profileId was silently ignored, not applied")
    case Err(e) -> assertTrue(false, "expected Ok (profileId just ignored): " + toString(e.status))
  }
}

// ── dueScheduledJobs scan ─────────────────────────────────────────────────────
test "dueScheduledJobs returns only active jobs whose next_run_at has arrived" {
  val dbPath = useFreshTestDb("job-due-scan")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  // Due now (interval job, defaults next_run_at to "now").
  val dueJob = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("due now", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  // Not due yet: a one-shot far in the future.
  val futureJob = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("not yet", "9999999999000", "")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }

  match CloudAgents.Repository.dueScheduledJobs(100) {
    case Ok(due) -> {
      assertEqualInt(due.length.toInt(), 1, "only the already-due job is returned")
      assertEqual(due[0].id, dueJob.id, "it's the due job, not the future one")
    }
    case Err(e) -> assertTrue(false, "dueScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Marking it recurring-ran pushes next_run_at into the future; it should
  // drop out of the due set.
  match CloudAgents.Repository.markScheduledJobRanRecurring(dueJob.id, CloudAgents.Repository.nowMillis(), dueJob.nextRunAtEpochMillis, "3600") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "markScheduledJobRanRecurring failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.dueScheduledJobs(100) {
    case Ok(due) -> assertEqualInt(due.length.toInt(), 0, "no job is due immediately after firing a recurring job")
    case Err(e) -> assertTrue(false, "dueScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // futureJob is unaffected and still not due.
  match CloudAgents.Jobs.getJobHandler("default", futureJob.id) {
    case Ok(j) -> assertEqual(j.status, "active", "the future one-shot job is still active, just not yet due")
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }
}

// ── claimDueScheduledJob: the first-trigger duplicate-run race (#870) ────────
test "claimDueScheduledJob lets only one of two racing callers win the same due job" {
  val dbPath = useFreshTestDb("job-claim-race")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val job = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("due now", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  val due = match CloudAgents.Repository.dueScheduledJobs(100) {
    case Ok(js) -> js
    case Err(e) -> panic("dueScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertEqualInt(due.length.toInt(), 1, "the job is due")

  // Two overlapping maintenance-endpoint polls both read the same due row
  // (same next_run_at) before either claims it — mirrors triggerDueJobsHandler
  // racing with itself.
  val firstClaim = match CloudAgents.Repository.claimDueScheduledJob(due[0].id, due[0].nextRunAt) {
    case Ok(won) -> won
    case Err(e) -> panic("claimDueScheduledJob failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val secondClaim = match CloudAgents.Repository.claimDueScheduledJob(due[0].id, due[0].nextRunAt) {
    case Ok(won) -> won
    case Err(e) -> panic("claimDueScheduledJob failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertTrue(firstClaim, "the first caller wins the claim")
  assertTrue(not secondClaim, "a second caller racing on the same due row loses the claim")

  // A claimed-but-not-yet-resolved job drops out of the due set (no third
  // caller can pile on either), same as a job whose run is genuinely in flight.
  match CloudAgents.Repository.dueScheduledJobs(100) {
    case Ok(js) -> assertEqualInt(js.length.toInt(), 0, "a claimed job is not due again until resolved")
    case Err(e) -> assertTrue(false, "dueScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // If the run that won the claim is skipped (its session was busy for an
  // unrelated reason), the claim is released so the job is retried, not
  // stuck un-due forever.
  match CloudAgents.Repository.restoreScheduledJobNextRunAt(due[0].id, due[0].nextRunAt) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "restoreScheduledJobNextRunAt failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.dueScheduledJobs(100) {
    case Ok(js) -> assertEqualInt(js.length.toInt(), 1, "a released claim is due again")
    case Err(e) -> assertTrue(false, "dueScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── markScheduledJobRanRecurring: cadence drift (#874) ────────────────────────
test "markScheduledJobRanRecurring advances from the scheduled slot, not the run's completion time" {
  val dbPath = useFreshTestDb("job-recurring-drift")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val job = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("nightly", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }

  // A run that finishes quickly (100s after its due slot, well inside the
  // 3600s interval): next_run_at should be exactly previousNextRunAt +
  // 3600s, not firedAt + 3600s — the interval's own base point is the
  // scheduled slot, so the cadence doesn't drift later run over run.
  match CloudAgents.Repository.markScheduledJobRanRecurring(job.id, "1000000100000", "1000000000000", "3600") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "markScheduledJobRanRecurring failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Jobs.getJobHandler("default", job.id) {
    case Ok(j) ->
      assertEqual(
        j.nextRunAtEpochMillis,
        "1000003600000",
        "next_run_at is previousNextRunAt + intervalSeconds*1000, unaffected by how long the run itself took"
      )
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }

  // A run that takes LONGER than the interval (finishes 100s after where the
  // *next* scheduled slot would already be): next_run_at is clamped to
  // firedAt, not computed into the past.
  match CloudAgents.Repository.markScheduledJobRanRecurring(job.id, "1000003700000", "1000003600000", "60") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "markScheduledJobRanRecurring failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Jobs.getJobHandler("default", job.id) {
    case Ok(j) ->
      assertEqual(
        j.nextRunAtEpochMillis,
        "1000003700000",
        "an overrun run clamps next_run_at to firedAt instead of scheduling it in the past"
      )
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }
}

// ── Post-run bookkeeping vs a concurrent status edit (#876) ──────────────────
test "a status change that lands while a job is in flight is not clobbered by post-run bookkeeping" {
  val dbPath = useFreshTestDb("job-status-race")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val recurring = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("nightly", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  val oneShot = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("once", "1000000000000", "")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }

  // A human pauses/cancels each job while its run is (hypothetically) still
  // in flight — simulated directly, since runOneJob itself can't run here
  // (no CloudAgents.Docker in a @test_module).
  match CloudAgents.Jobs.updateJobHandler(
    "default", recurring.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "paused")
  ) {
    case Ok(_) -> ()
    case Err(e) -> panic("pause failed: " + toString(e.status))
  }
  match CloudAgents.Jobs.updateJobHandler(
    "default", oneShot.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "cancelled")
  ) {
    case Ok(_) -> ()
    case Err(e) -> panic("cancel failed: " + toString(e.status))
  }

  // The run's own post-completion bookkeeping arrives after the status
  // change landed. Both writes should now no-op rather than stomping the
  // human's status choice back toward active/completed.
  match CloudAgents.Repository.markScheduledJobRanRecurring(recurring.id, "2000000000000", recurring.nextRunAtEpochMillis, "3600") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "markScheduledJobRanRecurring failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.markScheduledJobCompleted(oneShot.id, "2000000000000") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "markScheduledJobCompleted failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match CloudAgents.Jobs.getJobHandler("default", recurring.id) {
    case Ok(j) -> assertEqual(j.status, "paused", "a concurrent pause survives the recurring job's own post-run bookkeeping")
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }
  match CloudAgents.Jobs.getJobHandler("default", oneShot.id) {
    case Ok(j) -> assertEqual(j.status, "cancelled", "a concurrent cancel survives the one-shot job's own post-run bookkeeping")
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }
}

// ── applyPostRunBookkeeping re-reads FRESH schedule fields (#876) ────────────
// runOneJob/triggerDueJobsHandler can't run here (no CloudAgents.Docker in a
// @test_module), but the fix lives entirely in applyPostRunBookkeeping, which
// touches only CloudAgents.Repository — directly test-invocable, mirroring
// how claimDueScheduledJob/restoreScheduledJobNextRunAt are pinned above
// without needing runOneJob itself.
test "applyPostRunBookkeeping honors a schedule-type flip that landed while the run was in flight" {
  val dbPath = useFreshTestDb("job-bookkeeping-schedule-race")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")

  // Recurring -> one-shot: the pre-run snapshot triggerDueJobsHandler would
  // have captured still says intervalSeconds="3600".
  val recurring = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("nightly", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  val staleRecurringSnapshot = match CloudAgents.Repository.getScheduledJob(recurring.id, "default") {
    case Ok(Some(j)) -> j
    case Ok(None) -> panic("job must exist")
    case Err(e) -> panic("getScheduledJob failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // A human flips it to one-shot while the (hypothetical) run is in flight.
  match CloudAgents.Jobs.updateJobHandler(
    "default", recurring.id,
    UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "1999999999000", intervalSeconds = "", status = "")
  ) {
    case Ok(_) -> ()
    case Err(e) -> panic("schedule flip failed: " + toString(e.status))
  }
  // Using the STALE snapshot's intervalSeconds ("3600") would wrongly call
  // markScheduledJobRanRecurring and undo the user's flip to one-shot.
  CloudAgents.Jobs.applyPostRunBookkeeping(staleRecurringSnapshot, "2000000000000")
  match CloudAgents.Jobs.getJobHandler("default", recurring.id) {
    case Ok(j) -> {
      assertEqual(j.status, "completed", "honored as one-shot (now completed), not kept recurring by the stale snapshot")
      assertEqual(j.nextRunAtEpochMillis, "", "a completed one-shot job has no next_run_at")
    }
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }

  // Mirror case: one-shot -> recurring.
  val oneShot = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("once", "1000000000000", "")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  val staleOneShotSnapshot = match CloudAgents.Repository.getScheduledJob(oneShot.id, "default") {
    case Ok(Some(j)) -> j
    case Ok(None) -> panic("job must exist")
    case Err(e) -> panic("getScheduledJob failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Jobs.updateJobHandler(
    "default", oneShot.id,
    UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "", intervalSeconds = "1200", status = "")
  ) {
    case Ok(_) -> ()
    case Err(e) -> panic("schedule flip failed: " + toString(e.status))
  }
  // Using the STALE snapshot's intervalSeconds ("") would wrongly call
  // markScheduledJobCompleted and permanently end a job the user just made
  // recurring.
  CloudAgents.Jobs.applyPostRunBookkeeping(staleOneShotSnapshot, "2000000000000")
  match CloudAgents.Jobs.getJobHandler("default", oneShot.id) {
    case Ok(j) -> {
      assertEqual(j.status, "active", "honored as recurring, not ended by the stale snapshot")
      assertTrue(j.nextRunAtEpochMillis.length > 0, "a recurring job's next_run_at was recomputed, not cleared")
    }
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }
}

// ── Reactivating a completed one-shot job (#883) ──────────────────────────────
test "updateJobHandler recomputes next_run_at when reactivating a completed job via status alone" {
  val dbPath = useFreshTestDb("job-reactivate-completed")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val job = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("once", "1000000000000", "")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  // Simulate the job having already fired and completed.
  match CloudAgents.Repository.markScheduledJobCompleted(job.id, "1000000100000") {
    case Ok(_) -> ()
    case Err(e) -> panic("markScheduledJobCompleted failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Jobs.getJobHandler("default", job.id) {
    case Ok(j) -> assertEqual(j.nextRunAtEpochMillis, "", "sanity check: a completed job has no next_run_at")
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }

  // Reactivate with status=active alone, no schedule fields -- the natural
  // "turn it back on" request from a human's perspective.
  val reactivated = match CloudAgents.Jobs.updateJobHandler(
    "default", job.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "active")
  ) {
    case Ok(j) -> j
    case Err(e) -> panic("reactivate failed: " + toString(e.status))
  }
  assertEqual(reactivated.status, "active", "the job is active again")
  assertTrue(reactivated.nextRunAtEpochMillis.length > 0, "next_run_at was recomputed, not left at the empty sentinel")

  match CloudAgents.Repository.dueScheduledJobs(100) {
    case Ok(due) -> assertEqualInt(due.length.toInt(), 1, "the reactivated job is due again, not silently stuck forever")
    case Err(e) -> assertTrue(false, "dueScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── updateJobHandler must not clobber a concurrent claim sentinel (#891) ─────
test "an unrelated updateJobHandler edit never touches next_run_at" {
  val dbPath = useFreshTestDb("job-update-preserves-next-run-at")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val job = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("nightly", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  // Simulate a triggerDueJobsHandler run's own post-run bookkeeping landing
  // FIRST, setting a real future next_run_at...
  match CloudAgents.Repository.markScheduledJobRanRecurring(job.id, "2000000000000", job.nextRunAtEpochMillis, "3600") {
    case Ok(_) -> ()
    case Err(e) -> panic("markScheduledJobRanRecurring failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val expectedNextRunAt = match CloudAgents.Jobs.getJobHandler("default", job.id) {
    case Ok(j) -> j.nextRunAtEpochMillis
    case Err(e) -> panic("getJobHandler failed: " + toString(e.status))
  }
  assertTrue(expectedNextRunAt.length > 0, "sanity check: the run's bookkeeping set a real next_run_at")

  // ...then an unrelated edit (prompt only, no schedule fields) lands
  // AFTERWARD. Before #891's fix, updateScheduledJobSql always wrote
  // next_run_at = existing.nextRunAt (whatever this request happened to
  // read) unconditionally, so this write could win a race against the run's
  // own bookkeeping — or against a concurrent claim's empty sentinel — no
  // matter which side is "stale". The fix leaves next_run_at out of this
  // UPDATE entirely whenever the request itself doesn't touch the schedule.
  match CloudAgents.Jobs.updateJobHandler(
    "default", job.id, UpdateJobRequest(prompt = "revised prompt", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "")
  ) {
    case Ok(j) -> {
      assertEqual(j.prompt, "revised prompt", "the unrelated field did change")
      assertEqual(j.nextRunAtEpochMillis, expectedNextRunAt, "next_run_at is untouched by an edit that doesn't mention the schedule")
    }
    case Err(e) -> assertTrue(false, "update failed: " + toString(e.status))
  }
}

// ── Startup recovery sweep for stranded runs (#882) ───────────────────────────
test "recoverStrandedScheduledJobs restores next_run_at for a job claimed but never resolved" {
  val dbPath = useFreshTestDb("job-recover-stranded")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")

  // A recurring job that has already fired once (has a last_run_at), then
  // claimed for its second run -- the "crash" happens right there, before
  // the run's own bookkeeping ever gets a chance to resolve the claim.
  val recurring = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("nightly", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  match CloudAgents.Repository.markScheduledJobRanRecurring(recurring.id, "1000000000000", recurring.nextRunAtEpochMillis, "3600") {
    case Ok(_) -> ()
    case Err(e) -> panic("markScheduledJobRanRecurring failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val beforeClaim = match CloudAgents.Repository.getScheduledJob(recurring.id, "default") {
    case Ok(Some(j)) -> j
    case Ok(None) -> panic("job must exist")
    case Err(e) -> panic("getScheduledJob failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.claimDueScheduledJob(recurring.id, beforeClaim.nextRunAt) {
    case Ok(won) -> assertTrue(won, "the claim wins (nothing else touched the row)")
    case Err(e) -> panic("claimDueScheduledJob failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Jobs.getJobHandler("default", recurring.id) {
    case Ok(j) -> assertEqual(j.nextRunAtEpochMillis, "", "the claim sentinel is in place, simulating a crash mid-run")
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }

  // A one-shot job stranded on its very FIRST-ever run (no last_run_at yet).
  val oneShot = match CloudAgents.Jobs.createJobHandler("default", baseCreateReq("once", "1500000000000", "")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  match CloudAgents.Repository.claimDueScheduledJob(oneShot.id, oneShot.nextRunAtEpochMillis) {
    case Ok(won) -> assertTrue(won, "the claim wins")
    case Err(e) -> panic("claimDueScheduledJob failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match CloudAgents.Repository.recoverStrandedScheduledJobs() {
    case Ok(n) -> assertEqualInt(n, 2, "both stranded rows are recovered")
    case Err(e) -> assertTrue(false, "recoverStrandedScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match CloudAgents.Jobs.getJobHandler("default", recurring.id) {
    case Ok(j) -> assertTrue(j.nextRunAtEpochMillis.length > 0, "the recurring job's next_run_at was restored, not left at the empty sentinel forever")
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }
  match CloudAgents.Jobs.getJobHandler("default", oneShot.id) {
    case Ok(j) -> assertTrue(j.nextRunAtEpochMillis.length > 0, "the one-shot job's next_run_at was restored from run_at")
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }
  match CloudAgents.Repository.dueScheduledJobs(100) {
    case Ok(due) -> assertEqualInt(due.length.toInt(), 2, "both recovered jobs are due again, not stuck")
    case Err(e) -> assertTrue(false, "dueScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── The maintenance sweep is operator-only (#873) ─────────────────────────────
test "triggerDueJobsHandler refuses a non-operator identity" {
  val dbPath = useFreshTestDb("job-trigger-auth-denied")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("alice")
  match CloudAgents.Jobs.triggerDueJobsHandler() {
    case Ok(_) -> assertTrue(false, "a non-operator identity must not be able to trigger the maintenance sweep")
    case Err(e) -> assertEqualInt(e.status, 401, "non-operator caller -> 401, not the system-wide sweep")
  }
}

test "triggerDueJobsHandler runs for the operator identity when nothing is due" {
  val dbPath = useFreshTestDb("job-trigger-auth-allowed")
  defer {
    cleanupTestDb(dbPath)
  }
  // No due jobs at all in this fresh DB, so the loop body (which would reach
  // CloudAgents.Docker via runOneJob) never executes -- this exercises the
  // #873 auth gate and the empty-summary response path without needing a
  // Docker host.
  CloudAgents.Auth.setCurrentUserId(CloudAgents.Auth.operatorUserId())
  match CloudAgents.Jobs.triggerDueJobsHandler() {
    case Ok(body) -> assertEqual(body, "{\"triggered\":0,\"failed\":0,\"skipped\":0}", "no due jobs -> a clean empty summary")
    case Err(e) -> assertTrue(false, "the operator identity must be allowed to trigger the sweep: " + toString(e.status))
  }
}

// ── Test coverage gaps (#885) ────────────────────────────────────────────────
test "callback handlers scope jobs to the SESSION'S OWNER, not the ambient caller identity" {
  val dbPath = useFreshTestDb("job-callback-owner-vs-caller")
  defer {
    cleanupTestDb(dbPath)
  }
  // The session (and its callback token) belong to alice.
  CloudAgents.Auth.setCurrentUserId("alice")
  val sid = "sess-jobs-owner-vs-caller"
  mkSession(sid)
  val token = mintToken(sid, "alice")

  // A DIFFERENT ambient identity is stamped for this "request" -- exactly
  // what a container-originated callback route sees in production (the host
  // stamps the operator identity for these routes, never a per-tenant one;
  // docs/phase8-scheduling.md §7). The callback handlers must resolve the
  // session's OWNER via ownerOfSession, never trust this ambient value.
  CloudAgents.Auth.setCurrentUserId("mallory")

  val created = match CloudAgents.Jobs.scheduleJobCallbackHandler(
    sid, bearer(token), ScheduleJobCallbackRequest(name = "", prompt = "p", runAtEpochMillis = "", intervalSeconds = "3600")
  ) {
    case Ok(r) -> r
    case Err(e) -> panic("schedule_job failed: " + toString(e.status))
  }

  // The job is owned by alice (the session's real owner), never mallory (the
  // ambient identity at call time).
  match CloudAgents.Repository.getScheduledJob(created.id, "alice") {
    case Ok(Some(j)) -> assertEqual(j.userId, "alice", "the job is scoped to the session's owner")
    case Ok(None) -> assertTrue(false, "alice must be able to see the job she owns")
    case Err(e) -> assertTrue(false, "getScheduledJob failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.getScheduledJob(created.id, "mallory") {
    case Ok(None) -> ()
    case Ok(Some(_)) -> assertTrue(false, "the ambient caller identity must not own the job")
    case Err(e) -> assertTrue(false, "getScheduledJob failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // list_jobs, still invoked with the ambient identity stamped as mallory,
  // resolves ALICE's backlog (the session owner's), not mallory's (empty).
  match CloudAgents.Jobs.listJobsCallbackHandler(sid, bearer(token)) {
    case Ok(list) -> assertEqualInt(list.jobs.length.toInt(), 1, "list_jobs resolves the session owner's backlog, not the ambient caller's")
    case Err(e) -> assertTrue(false, "list_jobs failed: " + toString(e.status))
  }
}

test "createJobHandler's SSRF check catches userinfo smuggling and non-dotted IP literals, not just plain loopback" {
  val dbPath = useFreshTestDb("job-create-ssrf-bypass")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")

  // Same bypass session_tests.l pins against createSession (#257): userinfo
  // smuggled ahead of the real (loopback) host.
  val userinfoReq = CreateJobRequest(
    name = "",
    prompt = "digest",
    profileId = "",
    repoUrl = "https://github.com@127.0.0.1/repo",
    branch = "main",
    harness = "",
    model = "",
    runAtEpochMillis = "",
    intervalSeconds = "3600"
  )
  match CloudAgents.Jobs.createJobHandler("default", userinfoReq) {
    case Ok(_) -> assertTrue(false, "a userinfo-smuggled loopback repoUrl must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "userinfo bypass -> 400")
  }

  // Same bypass webhook_tests.l pins (#260): a decimal IP literal for
  // 127.0.0.1, never containing a literal dot.
  val decimalIpReq = CreateJobRequest(
    name = "",
    prompt = "digest",
    profileId = "",
    repoUrl = "https://2130706433/repo",
    branch = "main",
    harness = "",
    model = "",
    runAtEpochMillis = "",
    intervalSeconds = "3600"
  )
  match CloudAgents.Jobs.createJobHandler("default", decimalIpReq) {
    case Ok(_) -> assertTrue(false, "a decimal IP-literal loopback repoUrl must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "decimal IP literal bypass -> 400")
  }
}
