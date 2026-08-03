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
  match CloudAgents.Repository.dueScheduledJobs() {
    case Ok(due) -> assertEqualInt(due.length.toInt(), 0, "a cancelled job is never due")
    case Err(e) -> assertTrue(false, "dueScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
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

  match CloudAgents.Repository.dueScheduledJobs() {
    case Ok(due) -> {
      assertEqualInt(due.length.toInt(), 1, "only the already-due job is returned")
      assertEqual(due[0].id, dueJob.id, "it's the due job, not the future one")
    }
    case Err(e) -> assertTrue(false, "dueScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Marking it recurring-ran pushes next_run_at into the future; it should
  // drop out of the due set.
  match CloudAgents.Repository.markScheduledJobRanRecurring(dueJob.id, CloudAgents.Repository.nowMillis(), "3600") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "markScheduledJobRanRecurring failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.Repository.dueScheduledJobs() {
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
  val due = match CloudAgents.Repository.dueScheduledJobs() {
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
  match CloudAgents.Repository.dueScheduledJobs() {
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
  match CloudAgents.Repository.dueScheduledJobs() {
    case Ok(js) -> assertEqualInt(js.length.toInt(), 1, "a released claim is due again")
    case Err(e) -> assertTrue(false, "dueScheduledJobs failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}
