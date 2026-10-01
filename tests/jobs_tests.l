//! Scheduled-job tests (schedule validation, the job handlers, the container
//! schedule_job callbacks and the due-job claim) against the Postgres store.
//!
//! The due-job claim is cross-tenant: it sees jobs left by other tests and
//! earlier runs. Every test therefore claims through `claimMine`, which keeps
//! only its own user's claims, and removes the jobs it created when it ends
//! (`dropJobs`), so nothing it leaves behind can be due for a later test.
@test_module
package CloudAgents.JobsTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Jobs
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Db
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
  println("SKIP: jobs tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Db.dbErrorMessage(e))
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

/// Session ids are global primary keys that persist across runs.
func uniq(prefix: in String): String {
  return prefix + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

/// freshUser plus the encryption key the handlers need.
func fresh(tag: in String): String {
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
  return freshUser(tag)
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
  match addSession(s, CloudAgents.Auth.requestScope()) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func mintToken(id: in String, ownerUserId: in String): String {
  return match CloudAgents.SessionStore.mintCallbackToken(id, CloudAgents.Pg.personalScope(ownerUserId)) {
    case Ok(t) -> t
    case Err(e) -> panic("mintCallbackToken failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func bearer(token: in String): String {
  return "Bearer " + token
}

func mkProfile(userId: in String): String {
  return match CloudAgents.Repository.addProfile(CloudAgents.Pg.personalScope(userId), "test-profile", "claude", "full", "all", [], [], [], [], "all", []) {
    case Ok(p) -> p.id
    case Err(e) -> panic("addProfile failed: " + CloudAgents.Db.dbErrorMessage(e))
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
  if not live() {
    return
  }
  val me = fresh("job-create-no-schedule")
  defer {
    dropJobs(me)
  }
  match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("digest the day's activity", "", "")) {
    case Ok(_) -> assertTrue(false, "a job with no schedule at all must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "missing schedule -> 400")
  }
}

test "createJobHandler rejects an internal/loopback repoUrl (SSRF)" {
  if not live() {
    return
  }
  val me = fresh("job-create-ssrf")
  defer {
    dropJobs(me)
  }
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
  match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), req) {
    case Ok(_) -> assertTrue(false, "a loopback repoUrl must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "blocked host -> 400")
  }
}

test "createJobHandler rejects an unknown profileId" {
  if not live() {
    return
  }
  val me = fresh("job-create-bad-profile")
  defer {
    dropJobs(me)
  }
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
  match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), req) {
    case Ok(_) -> assertTrue(false, "an unknown profileId must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "unknown profile -> 400")
  }
}

test "createJobHandler creates a recurring job with next_run_at defaulted to now" {
  if not live() {
    return
  }
  val me = fresh("job-create-recurring")
  defer {
    dropJobs(me)
  }
  val profileId = mkProfile(me)
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
  val created = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), req) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  assertTrue(created.id.length > 0, "a job id is returned")
  assertEqual(created.status, "active", "a new job starts active")
  assertEqual(created.sessionId, "", "a new job has no session until its first trigger")
  assertEqual(created.harness, "claude", "an empty harness defaults to claude")
  assertTrue(created.nextRunAtEpochMillis.length > 0, "next_run_at defaults to now for a pure-interval job")

  match CloudAgents.Jobs.getJobHandler(CloudAgents.Pg.personalScope(me), created.id) {
    case Ok(j) -> assertEqual(j.prompt, "summarize today's commits", "the stored job round-trips")
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }
}

test "createJobHandler with only a one-shot runAt uses it as next_run_at" {
  if not live() {
    return
  }
  val me = fresh("job-create-oneshot")
  defer {
    dropJobs(me)
  }
  val created = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("one-time reminder", "1999999999000", "")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  assertEqual(created.nextRunAtEpochMillis, "1999999999000", "a one-shot job's next run is exactly its runAt")
  assertEqual(created.intervalSeconds, "", "no interval was set")
}

// ── listJobsHandler / getJobHandler / deleteJobHandler ───────────────────────
test "listJobsHandler and getJobHandler are owner-scoped; getJobHandler 404s for a foreign job" {
  if not live() {
    return
  }
  val alice = fresh("job-owner-scope")
  val bob = newUser("job-owner-scope-bob")
  defer {
    dropJobs(alice)
  }
  val created = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(alice), baseCreateReq("alice's job", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }

  match CloudAgents.Jobs.listJobsHandler(CloudAgents.Pg.personalScope(alice)) {
    case Ok(list) -> assertEqualInt(list.jobs.length.toInt(), 1, "alice sees her own job")
    case Err(e) -> assertTrue(false, "listJobsHandler failed: " + toString(e.status))
  }
  match CloudAgents.Jobs.listJobsHandler(CloudAgents.Pg.personalScope(bob)) {
    case Ok(list) -> assertEqualInt(list.jobs.length.toInt(), 0, "bob sees none of alice's jobs")
    case Err(e) -> assertTrue(false, "listJobsHandler failed: " + toString(e.status))
  }
  match CloudAgents.Jobs.getJobHandler(CloudAgents.Pg.personalScope(bob), created.id) {
    case Ok(_) -> assertTrue(false, "bob must not be able to read alice's job by id")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign job id -> 404, not a leak")
  }
  match CloudAgents.Jobs.deleteJobHandler(CloudAgents.Pg.personalScope(bob), created.id) {
    case Ok(_) -> assertTrue(false, "bob must not be able to delete alice's job")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign job id -> 404")
  }
  match CloudAgents.Jobs.deleteJobHandler(CloudAgents.Pg.personalScope(alice), created.id) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "alice's own delete should succeed: " + toString(e.status))
  }
  match CloudAgents.Jobs.getJobHandler(CloudAgents.Pg.personalScope(alice), created.id) {
    case Ok(_) -> assertTrue(false, "the job should be gone after delete")
    case Err(e) -> assertEqualInt(e.status, 404, "deleted job -> 404")
  }
}

// ── updateJobHandler ─────────────────────────────────────────────────────────
test "updateJobHandler leaves unspecified fields unchanged and can flip a recurring job to one-shot" {
  if not live() {
    return
  }
  val me = fresh("job-update")
  defer {
    dropJobs(me)
  }
  val created = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("original prompt", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }

  // Change only the prompt: schedule/status untouched.
  val afterPromptChange = match CloudAgents.Jobs.updateJobHandler(
    CloudAgents.Pg.personalScope(me), created.id, UpdateJobRequest(prompt = "revised prompt", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "")
  ) {
    case Ok(j) -> j
    case Err(e) -> panic("update failed: " + toString(e.status))
  }
  assertEqual(afterPromptChange.prompt, "revised prompt", "the prompt changed")
  assertEqual(afterPromptChange.intervalSeconds, "3600", "the interval is untouched")
  assertEqual(afterPromptChange.status, "active", "the status is untouched")

  // Pause it.
  val paused = match CloudAgents.Jobs.updateJobHandler(
    CloudAgents.Pg.personalScope(me), created.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "paused")
  ) {
    case Ok(j) -> j
    case Err(e) -> panic("pause failed: " + toString(e.status))
  }
  assertEqual(paused.status, "paused", "the job is now paused")

  // Flip to a one-shot schedule: providing runAtEpochMillis clears intervalSeconds.
  val flipped = match CloudAgents.Jobs.updateJobHandler(
    CloudAgents.Pg.personalScope(me), created.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "1999999999000", intervalSeconds = "", status = "active")
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
  if not live() {
    return
  }
  val me = fresh("job-update-invalid")
  defer {
    dropJobs(me)
  }
  val created = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("p", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  match CloudAgents.Jobs.updateJobHandler(
    CloudAgents.Pg.personalScope(me), created.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "not-digits", intervalSeconds = "", status = "")
  ) {
    case Ok(_) -> assertTrue(false, "a non-digit runAtEpochMillis must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "invalid runAt -> 400")
  }
  match CloudAgents.Jobs.updateJobHandler(
    CloudAgents.Pg.personalScope(me), created.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "bogus")
  ) {
    case Ok(_) -> assertTrue(false, "an unknown status must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "invalid status -> 400")
  }
  val nobody = newUser("job-update-nobody")
  match CloudAgents.Jobs.updateJobHandler(
    CloudAgents.Pg.personalScope(nobody), created.id, UpdateJobRequest(prompt = "x", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "")
  ) {
    case Ok(_) -> assertTrue(false, "a foreign owner must not be able to update this job")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign owner -> 404")
  }
}

// ── Container-originated: schedule_job / list_jobs / update_job / cancel_job ─
test "scheduleJobCallbackHandler requires a valid callback token and a schedule" {
  if not live() {
    return
  }
  val me = fresh("job-callback-auth")
  defer {
    dropJobs(me)
  }
  val sid = uniq("sess-jobs-1")
  mkSession(sid)
  val token = mintToken(sid, me)

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
  if not live() {
    return
  }
  val me = fresh("job-callback-roundtrip")
  defer {
    dropJobs(me)
  }
  val sid = uniq("sess-jobs-2")
  mkSession(sid)
  val token = mintToken(sid, me)

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
  match CloudAgents.Repository.getScheduledJob(created.id, CloudAgents.Pg.personalScope(me)) {
    case Ok(Some(j)) -> assertEqual(j.sessionId, sid, "schedule_job attaches the calling session at creation time")
    case Ok(None) -> assertTrue(false, "the job must exist")
    case Err(e) -> assertTrue(false, "getScheduledJob failed: " + CloudAgents.Db.dbErrorMessage(e))
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

  // A cancelled job is never claimed.
  assertEqualInt(claimMine(me).length.toInt(), 0, "a cancelled job is never due")
}

// ── update_job/cancel_job callback scope (#881) ───────────────────────────────
test "update_job/cancel_job callbacks cannot reach a job attached to a DIFFERENT session, even same owner" {
  if not live() {
    return
  }
  val me = fresh("job-callback-cross-session")
  defer {
    dropJobs(me)
  }
  val ownerSession = uniq("sess-jobs-owner")
  val otherSession = uniq("sess-jobs-other")
  mkSession(ownerSession)
  mkSession(otherSession)
  val ownerToken = mintToken(ownerSession, me)
  val otherToken = mintToken(otherSession, me)

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
  match CloudAgents.Repository.getScheduledJob(created.id, CloudAgents.Pg.personalScope(me)) {
    case Ok(Some(j)) -> {
      assertEqual(j.prompt, "check on this", "the prompt was not hijacked by the other session")
      assertEqual(j.status, "active", "the job was not cancelled by the other session")
    }
    case Ok(None) -> assertTrue(false, "the job must still exist")
    case Err(e) -> assertTrue(false, "getScheduledJob failed: " + CloudAgents.Db.dbErrorMessage(e))
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
  if not live() {
    return
  }
  val me = fresh("job-callback-profile-restricted")
  defer {
    dropJobs(me)
  }
  val sid = uniq("sess-jobs-profile")
  mkSession(sid)
  val token = mintToken(sid, me)
  val profileId = match CloudAgents.Repository.addProfile(CloudAgents.Pg.personalScope(me), "escalated", "", "full", "all", [], [], [], [], "all", []) {
    case Ok(p) -> p.id
    case Err(e) -> panic("addProfile failed: " + CloudAgents.Db.dbErrorMessage(e))
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

// ── Claiming due jobs (docs/phase11-postgres-tenancy.md §5.3a) ───────────────
/// Claim every due job (the claim is cross-tenant, 100 at a time) and return
/// only `owner`'s claims: other tests' and earlier runs' due jobs are claimed
/// too, but they are not this test's concern.
func claimMine(owner: in String): slice[CloudAgents.Repository.ClaimedJob] {
  var mine: slice[CloudAgents.Repository.ClaimedJob] = []
  var rounds = 0
  while rounds < 50 {
    val batch = match CloudAgents.Repository.claimDueScheduledJobs(100) {
      case Ok(cs) -> cs
      case Err(e) -> panic("claimDueScheduledJobs failed: " + CloudAgents.Db.dbErrorMessage(e))
    }
    for c in batch {
      if c.tenantScope.userId == owner {
        mine = mine.append(c)
      }
    }
    if batch.length < 100 {
      return mine
    }
    rounds = rounds + 1
  }
  return mine
}

/// Remove every job `owner` has, so none can be due for a later test or run.
func dropJobs(owner: in String): Unit {
  val sc = CloudAgents.Pg.personalScope(owner)
  match CloudAgents.Jobs.listJobsHandler(sc) {
    case Ok(list) -> {
      for j in list.jobs {
        match CloudAgents.Jobs.deleteJobHandler(sc, j.id) {
          case Ok(_) -> ()
          case Err(_) -> ()
        }
      }
    }
    case Err(_) -> ()
  }
}

func jobNow(owner: in String, id: in String): JobSummary {
  return match CloudAgents.Jobs.getJobHandler(CloudAgents.Pg.personalScope(owner), id) {
    case Ok(j) -> j
    case Err(e) -> panic("getJobHandler failed: " + toString(e.status))
  }
}

func millisAgo(ms: in Int): String {
  return toString(CloudAgents.Repository.nowMillisLong() - ms.toLong())
}

test "claimDueScheduledJobs claims only active jobs whose next_run_at has arrived" {
  if not live() {
    return
  }
  val me = fresh("job-due-scan")
  defer {
    dropJobs(me)
  }
  val dueJob = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("due now", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  val futureJob = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("not yet", "9999999999000", "")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  val claims = claimMine(me)
  assertEqualInt(claims.length.toInt(), 1, "only the already-due job is claimed")
  assertEqual(claims[0].job.id, dueJob.id, "it's the due job, not the future one")
  assertEqual(claims[0].job.nextRunAt, dueJob.nextRunAtEpochMillis, "the claim carries the slot the job was due at")
  assertEqual(claims[0].tenantScope.userId, me, "and the owner's scope")
  assertEqual(claims[0].claimedStatus, "active", "a recurring job stays active")
  // The claim advanced the schedule, so an immediate second poll finds nothing.
  assertEqualInt(claimMine(me).length.toInt(), 0, "a claimed slot is never claimed twice")
  val after = jobNow(me, dueJob.id)
  assertEqual(after.lastRunAtEpochMillis, claims[0].claimedAt, "last_run_at is the firing time")
  assertEqual(after.nextRunAtEpochMillis, claims[0].claimedNextRunAt, "next_run_at is the advanced slot")
  assertEqual(jobNow(me, futureJob.id).status, "active", "the future one-shot job is still active, just not yet due")
}

test "a recurring claim advances from the slot it was due at and skips missed slots" {
  if not live() {
    return
  }
  val me = fresh("job-recurring-drift")
  defer {
    dropJobs(me)
  }
  // Due 100s ago, every hour: the next slot is the due slot + 3600s, not the
  // firing time + 3600s, so the cadence doesn't drift (#874).
  val slot = millisAgo(100000)
  val onTime = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("hourly", slot, "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  // Due two hours ago, every minute: the missed slots are skipped, so the job
  // fires once now, not 120 times, and stays on its own cadence.
  val behindSlot = millisAgo(7200000)
  val behind = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("minutely", behindSlot, "60")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  assertEqualInt(claimMine(me).length.toInt(), 2, "both are due")
  val a = jobNow(me, onTime.id)
  assertEqual(a.nextRunAtEpochMillis, toString(stringToLong(slot) + 3600000.toLong()), "next slot = due slot + interval")
  val b = jobNow(me, behind.id)
  val next = stringToLong(b.nextRunAtEpochMillis)
  val fired = stringToLong(b.lastRunAtEpochMillis)
  assertTrue(next > fired and next - fired <= 60000.toLong(), "a job that fell behind moves to the first slot after the firing time")
  assertTrue((next - stringToLong(behindSlot)) % 60000.toLong() == 0.toLong(), "on its original cadence")
  assertEqualInt(claimMine(me).length.toInt(), 0, "and neither is due again straight away")
}

test "a claimed one-shot job completes at once, so an interrupted run is never re-fired" {
  if not live() {
    return
  }
  val me = fresh("job-oneshot-claim")
  defer {
    dropJobs(me)
  }
  val job = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("once", "1000000000000", "")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  val claims = claimMine(me)
  assertEqualInt(claims.length.toInt(), 1, "the one-shot job is due")
  assertEqual(claims[0].claimedStatus + "|" + claims[0].claimedNextRunAt, "completed|", "the claim completes it")
  val after = jobNow(me, job.id)
  assertEqual(after.status + "|" + after.nextRunAtEpochMillis, "completed|", "completed with no next run")
  // Nothing records the run's outcome afterwards, so an instance dying mid-run
  // leaves the job completed rather than firing it again.
  assertEqualInt(claimMine(me).length.toInt(), 0, "never claimed again")
}

test "of two overlapping polls only one claims a slot, and a released claim is due again" {
  if not live() {
    return
  }
  val me = fresh("job-claim-race")
  defer {
    dropJobs(me)
  }
  val job = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("due now", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  val first = claimMine(me)
  val second = claimMine(me)
  assertEqualInt(first.length.toInt() + second.length.toInt(), 1, "exactly one poll wins the slot")
  // The run was skipped (its session was busy): releasing the claim puts the
  // slot, last_run_at and status back so the next poll retries it.
  match CloudAgents.Repository.releaseScheduledJobClaim(first[0]) {
    case Ok(_) -> ()
    case Err(e) -> panic("releaseScheduledJobClaim failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  val released = jobNow(me, job.id)
  assertEqual(released.nextRunAtEpochMillis + "|" + released.lastRunAtEpochMillis, job.nextRunAtEpochMillis + "|", "the claim is undone")
  assertEqualInt(claimMine(me).length.toInt(), 1, "a released claim is due again")
}

test "releasing a claim never overwrites an edit made while the run was in flight" {
  if not live() {
    return
  }
  val me = fresh("job-status-race")
  defer {
    dropJobs(me)
  }
  val recurring = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("nightly", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  val claims = claimMine(me)
  assertEqualInt(claims.length.toInt(), 1, "claimed")
  // A human pauses the job while its (skipped) run is in flight.
  match CloudAgents.Jobs.updateJobHandler(
    CloudAgents.Pg.personalScope(me), recurring.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "paused")
  ) {
    case Ok(_) -> ()
    case Err(e) -> panic("pause failed: " + toString(e.status))
  }
  match CloudAgents.Repository.releaseScheduledJobClaim(claims[0]) {
    case Ok(_) -> ()
    case Err(e) -> panic("releaseScheduledJobClaim failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  val after = jobNow(me, recurring.id)
  assertEqual(after.status, "paused", "the concurrent pause stands")
  assertEqual(after.nextRunAtEpochMillis, claims[0].claimedNextRunAt, "and the release changed nothing")
}

func stringToLong(s: in String): Long {
  var n = 0.toLong()
  var i = 0
  while i < s.length.toInt() {
    n = n * 10.toLong() + CloudAgents.Repository.parseNatString(s.substring(i, 1)).toLong()
    i = i + 1
  }
  return n
}

// ── Reactivating a completed one-shot job (#883) ──────────────────────────────
test "updateJobHandler recomputes next_run_at when reactivating a completed job via status alone" {
  if not live() {
    return
  }
  val me = fresh("job-reactivate-completed")
  defer {
    dropJobs(me)
  }
  val job = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("once", "1000000000000", "")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  // The job fires (the claim completes a one-shot job).
  assertEqualInt(claimMine(me).length.toInt(), 1, "the one-shot job fires")
  match CloudAgents.Jobs.getJobHandler(CloudAgents.Pg.personalScope(me), job.id) {
    case Ok(j) -> assertEqual(j.nextRunAtEpochMillis, "", "sanity check: a completed job has no next_run_at")
    case Err(e) -> assertTrue(false, "getJobHandler failed: " + toString(e.status))
  }

  // Reactivate with status=active alone, no schedule fields -- the natural
  // "turn it back on" request from a human's perspective.
  val reactivated = match CloudAgents.Jobs.updateJobHandler(
    CloudAgents.Pg.personalScope(me), job.id, UpdateJobRequest(prompt = "", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "active")
  ) {
    case Ok(j) -> j
    case Err(e) -> panic("reactivate failed: " + toString(e.status))
  }
  assertEqual(reactivated.status, "active", "the job is active again")
  assertTrue(reactivated.nextRunAtEpochMillis.length > 0, "next_run_at was recomputed, not left at the empty sentinel")

  assertEqualInt(claimMine(me).length.toInt(), 1, "the reactivated job is due again, not silently stuck forever")
}

// ── updateJobHandler must not clobber a concurrently advanced slot (#891) ───
test "an unrelated updateJobHandler edit never touches next_run_at" {
  if not live() {
    return
  }
  val me = fresh("job-update-preserves-next-run-at")
  defer {
    dropJobs(me)
  }
  val job = match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), baseCreateReq("nightly", "", "3600")) {
    case Ok(j) -> j
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  // A trigger poll claims the job first, advancing next_run_at...
  assertEqualInt(claimMine(me).length.toInt(), 1, "the job is claimed")
  val expectedNextRunAt = match CloudAgents.Jobs.getJobHandler(CloudAgents.Pg.personalScope(me), job.id) {
    case Ok(j) -> j.nextRunAtEpochMillis
    case Err(e) -> panic("getJobHandler failed: " + toString(e.status))
  }
  assertTrue(expectedNextRunAt.length > 0, "sanity check: the claim set a real next_run_at")

  // ...then an unrelated edit (prompt only, no schedule fields) lands
  // afterwards. It leaves next_run_at out of its UPDATE entirely, so it can't
  // put back the stale slot this request read (#891).
  match CloudAgents.Jobs.updateJobHandler(
    CloudAgents.Pg.personalScope(me), job.id, UpdateJobRequest(prompt = "revised prompt", profileId = "", runAtEpochMillis = "", intervalSeconds = "", status = "")
  ) {
    case Ok(j) -> {
      assertEqual(j.prompt, "revised prompt", "the unrelated field did change")
      assertEqual(j.nextRunAtEpochMillis, expectedNextRunAt, "next_run_at is untouched by an edit that doesn't mention the schedule")
    }
    case Err(e) -> assertTrue(false, "update failed: " + toString(e.status))
  }
}

// ── The maintenance sweep is operator-only (#873) ─────────────────────────────
test "triggerDueJobsHandler refuses a non-operator identity" {
  if not live() {
    return
  }
  val me = fresh("job-trigger-auth-denied")
  match CloudAgents.Jobs.triggerDueJobsHandler() {
    case Ok(_) -> assertTrue(false, "a non-operator identity must not be able to trigger the maintenance sweep")
    case Err(e) -> assertEqualInt(e.status, 401, "non-operator caller -> 401, not the system-wide sweep")
  }
}

test "triggerDueJobsHandler runs for the operator identity when nothing is due" {
  if not live() {
    return
  }
  val me = fresh("job-trigger-auth-allowed")
  // The sweep is cross-tenant, so jobs other tests or earlier runs left due
  // would reach CloudAgents.Docker via runOneJob. Claiming them first (which
  // advances their schedules) leaves nothing due, so this exercises the #873
  // auth gate and the empty-summary response path without a Docker host.
  claimMine(me)
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(CloudAgents.Auth.operatorUserId()) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning the operator failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  CloudAgents.Auth.setCurrentUserId(CloudAgents.Auth.operatorUserId())
  defer {
    CloudAgents.Auth.setCurrentUserId(me)
  }
  match CloudAgents.Jobs.triggerDueJobsHandler() {
    case Ok(body) -> assertEqual(body, "{\"triggered\":0,\"failed\":0,\"skipped\":0}", "no due jobs -> a clean empty summary")
    case Err(e) -> assertTrue(false, "the operator identity must be allowed to trigger the sweep: " + toString(e.status))
  }
}

// ── Test coverage gaps (#885) ────────────────────────────────────────────────
test "callback handlers scope jobs to the SESSION'S OWNER, not the ambient caller identity" {
  if not live() {
    return
  }
  val alice = fresh("job-callback-owner-vs-caller")
  val mallory = newUser("job-callback-mallory")
  defer {
    dropJobs(alice)
  }
  // The session (and its callback token) belong to alice.
  val sid = uniq("sess-jobs-owner-vs-caller")
  mkSession(sid)
  val token = mintToken(sid, alice)

  // A DIFFERENT ambient identity is stamped for this "request" -- exactly
  // what a container-originated callback route sees in production (the host
  // stamps the operator identity for these routes, never a per-tenant one;
  // docs/phase8-scheduling.md §7). The callback handlers must resolve the
  // session's OWNER from its route, never trust this ambient value.
  CloudAgents.Auth.setCurrentUserId(mallory)

  val created = match CloudAgents.Jobs.scheduleJobCallbackHandler(
    sid, bearer(token), ScheduleJobCallbackRequest(name = "", prompt = "p", runAtEpochMillis = "", intervalSeconds = "3600")
  ) {
    case Ok(r) -> r
    case Err(e) -> panic("schedule_job failed: " + toString(e.status))
  }

  // The job is owned by alice (the session's real owner), never mallory (the
  // ambient identity at call time).
  match CloudAgents.Repository.getScheduledJob(created.id, CloudAgents.Pg.personalScope(alice)) {
    case Ok(Some(j)) -> assertEqual(j.userId, alice, "the job is scoped to the session's owner")
    case Ok(None) -> assertTrue(false, "alice must be able to see the job she owns")
    case Err(e) -> assertTrue(false, "getScheduledJob failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match CloudAgents.Repository.getScheduledJob(created.id, CloudAgents.Pg.personalScope(mallory)) {
    case Ok(None) -> ()
    case Ok(Some(_)) -> assertTrue(false, "the ambient caller identity must not own the job")
    case Err(e) -> assertTrue(false, "getScheduledJob failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // list_jobs, still invoked with the ambient identity stamped as mallory,
  // resolves ALICE's backlog (the session owner's), not mallory's (empty).
  match CloudAgents.Jobs.listJobsCallbackHandler(sid, bearer(token)) {
    case Ok(list) -> assertEqualInt(list.jobs.length.toInt(), 1, "list_jobs resolves the session owner's backlog, not the ambient caller's")
    case Err(e) -> assertTrue(false, "list_jobs failed: " + toString(e.status))
  }
}

test "createJobHandler's SSRF check catches userinfo smuggling and non-dotted IP literals, not just plain loopback" {
  if not live() {
    return
  }
  val me = fresh("job-create-ssrf-bypass")
  defer {
    dropJobs(me)
  }

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
  match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), userinfoReq) {
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
  match CloudAgents.Jobs.createJobHandler(CloudAgents.Pg.personalScope(me), decimalIpReq) {
    case Ok(_) -> assertTrue(false, "a decimal IP-literal loopback repoUrl must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "decimal IP literal bypass -> 400")
  }
}
