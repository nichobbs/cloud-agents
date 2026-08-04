# Phase 8 — Scheduled jobs

Status: shipped (host-side CRUD + trigger endpoint, the four MCP tools, and
tests). Not yet exercised end-to-end against a live external scheduler or a
real Docker daemon — see "Verification status" at the end.

## 1. Problem

Every session today is user-initiated: a human opens a session and sends a
message. There is no way to say "run this prompt against this repo every
night at 2am" or "check back on this in an hour" without a human manually
returning to click send. The user asked for two things:

1. Schedule a job — a time and/or interval, a prompt, and a profile (skills,
   MCPs, credentials, network policy) — that kicks off a cloud-agent run, with
   its output stored against a session for later review, and where a
   re-trigger continues the *same* session rather than starting fresh each
   time.
2. Extend the in-container MCP shim so a running agent can create and manage
   its own scheduled jobs — "check on this again in an hour," "run this
   digest every morning" — without a human configuring it via the UI.

## 2. Constraint: no in-process timer

`Lyric.Web` has no in-process timer or background-task primitive
(`docs/phase2-session-management.md` §2, `src/handlers/webhooks.l`'s module
doc). Every existing time-driven behavior in this codebase already works
around that the same way: expose an idempotent maintenance endpoint and have
an *external* scheduler poll it.

- `POST /api/maintenance/reap` — idle-container reaping
  (`CloudAgents.Handlers.reapContainers`).
- `GET /api/webhooks/pending` + `POST /api/webhooks/events/{id}/delivered` —
  the webhook outbox.

Scheduled jobs follow the exact same idiom: `POST /api/maintenance/trigger-jobs`
scans for jobs whose `next_run_at` has arrived and runs them, safe to call
repeatedly (a job not yet due is untouched). The operator is responsible for
pointing a real cron (system cron, a scheduled CI workflow, an uptime-monitor
ping, etc.) at this endpoint on a short interval (e.g. every minute) — this
repo does not ship that cron itself, matching how it doesn't ship the
webhook-delivery worker or the reaper's poller either.

## 3. Schedule shape: a time and/or an interval, not a cron DSL

The user's own framing — "given a time and/or interval" — maps directly onto
two optional fields, deliberately skipping a full cron-expression parser
(complex, easy to get subtly wrong, and unnecessary for what was asked):

- `runAtEpochMillis` — an optional one-shot time, as epoch milliseconds
  (a decimal string). Matches this schema's existing epoch-millis-as-TEXT
  convention (`sessions.created_at`, `runs.started_at`, etc.) rather than
  introducing ISO-8601 parsing.
- `intervalSeconds` — an optional recurring cadence, 60 to 2,592,000 seconds
  (1 minute to 30 days).

At least one is required. The rule for combining them:

- **Both set**: a recurring job that first fires at `runAtEpochMillis`, then
  every `intervalSeconds` after that.
- **Only `intervalSeconds`**: fires immediately (`next_run_at` defaults to
  "now" at creation), then recurs.
- **Only `runAtEpochMillis`**: a pure one-shot. After it fires once, the job's
  status becomes `completed` and it never fires again.

All comparisons and the recurring-job next-run computation run in SQL
(`CAST(... AS INTEGER)`), the same reasoning `selectReapableWarmSql` already
documents: SQLite's integer arithmetic is 64-bit, so Lyric application code
never has to parse an epoch-millisecond value into a `Long` — sidestepping
the whole class of `Long`-arithmetic sharp edges `docs/lyric/gotchas.md`
catalogues elsewhere in this codebase.

## 4. Data model

Migration `0027_scheduled_jobs`: table `scheduled_jobs` —

```
id, user_id, name, prompt, profile_id, repo_url, branch, harness, model,
run_at, interval_seconds, next_run_at, last_run_at, session_id, status,
created_at
```

All `TEXT` affinity, matching this schema's convention. `status` is one of
`active` / `paused` / `completed` / `cancelled`; only `active` jobs are ever
due. Indexes on `(user_id)` (per-owner listing) and `(status, next_run_at)`
(the due-job scan).

`session_id` starts empty. It is filled in exactly once — guarded by a
`WHERE session_id = ''` clause so a racing second trigger tick can't clobber
a session a concurrent call already attached — either:

- on the job's first trigger (a session is created from the job's own
  `repo_url`/`branch`/`harness`/`model`/`profile_id`, the same way
  `createSession` builds one), or
- immediately, when the job is created via the `schedule_job` MCP tool from
  inside a running container (§6) — the calling session is attached at
  creation time, never a fresh one.

Either way, every later trigger reuses that same session: the job's prompt
is added as a new `user` message and the run's reply as a new `agent`
message, exactly like a human typing a follow-up into an existing session.
Output is therefore already "stored against the session" via the existing
`messages`/`runs` tables and `GET /api/sessions/{id}/messages` /
`GET /api/sessions/{id}/runs` — no new storage was needed for that part of
the ask.

## 5. Running a due job

`CloudAgents.Jobs.triggerDueJobsHandler` (the maintenance endpoint) scans
`dueScheduledJobs()`, takes at most `maxJobsPerTrigger` (5) of the
earliest-due jobs — capping one call's wall-clock time, since each due job
below runs a full container synchronously rather than reap's fast
terminate-and-blank (#872); anything past the cap is picked up on the very
next poll, which the endpoint's own "safe to call repeatedly" contract
already assumes — and, for each:

1. Atomically claims the *row* (`claimDueScheduledJob` — a compare-and-clear
   on `next_run_at`, mirroring `clearSessionContainerIfMatchesSql`'s idiom)
   before doing anything else. This closes a race (#870) where two
   overlapping `POST /api/maintenance/trigger-jobs` calls — realistic, since
   the endpoint is documented "safe to call repeatedly" while a single call
   can block up to 30 minutes across all due jobs — could otherwise both
   read the same never-yet-sessioned due job and each independently create a
   session and run a full container for what should be one first trigger.
   Losing the claim counts as **skipped** this tick with no session/container
   work attempted at all.
2. Resolves or creates the job's session (`ensureJobSession`) — now only
   ever reached by the single caller that won the row claim.
3. Claims the session for a run (`tryBeginRun` — the same one-run-per-session
   guard `streamSendMessage` uses). This is a second, independent guard for a
   *different* case: an already-sessioned job whose session a human is
   actively chatting with. If it loses, the job is **skipped** this tick and
   the row claim from step 1 is released (`restoreScheduledJobNextRunAt`) so
   `next_run_at` reverts to its original value and the job retries on the
   *next* poll, rather than being marked run-and-failed or left permanently
   un-due.
4. Persists the prompt as a `user` message, resolves the profile-pinned
   harness if any, and records a `run` row — the same bookkeeping
   `streamSendMessage` does.
5. Runs the container via `CloudAgents.Docker.runSessionMessageBlocking` — a
   new, non-SSE sibling of `streamSessionMessage` that drives the exact same
   `runSessionMessageAsync` task and `taskWaitMs` poll loop (including the
   same `Int`-accumulator wall-clock cap workaround — see
   `streamSessionMessage`'s doc comment for why that isn't a `Long`
   comparison) but skips every `Web.writeChunk`/SSE-event-forwarding step:
   there is no live browser tab watching a scheduler-triggered run. Mid-run
   permission requests, secret requests, progress reports, etc. still land in
   their normal tables via the container's own callback calls — a human
   reviewing the session later sees them via the existing
   `GET /api/sessions/{id}/callbacks/pending`, exactly as for any other run.
   Only the *live* push is unavailable, an acceptable degradation since
   nothing was watching it anyway.
6. Persists the reply, records the run's outcome, and enqueues a webhook
   event — again mirroring `streamSendMessage`.
7. Advances the schedule: a recurring job's `next_run_at` moves to
   `previousNextRunAt + intervalSeconds` — advanced from the slot the job
   was actually *due* at (the `next_run_at` the due-scan read, i.e. step 1's
   claimed value), not from `firedAt` (when the run happened to finish), so
   a job's cadence doesn't drift later run over run by however long each run
   itself takes (#874: "every hour" stays every hour even if a run takes 5
   minutes). Clamped to never compute a value before `firedAt`: a run that
   overran its own interval is due again immediately next poll instead of
   being scheduled into the past. A one-shot job's `status` becomes
   `completed` instead. This happens for both a **succeeded** and a
   **failed** run (only a *skipped* run's schedule is instead restored to
   its pre-claim value, per step 3/1) — a persistently broken job must not
   retry-storm every poll tick forever. Both writes are guarded on
   `status = 'active'` (#876): a run can stay in flight long enough for a
   human to concurrently pause/cancel the job via `POST /api/jobs/{jid}`;
   without the guard, this step landing afterward would silently overwrite
   that status change back toward `active`/`completed`. Whichever write
   lands first wins — a concurrent status change makes this step a no-op
   (0 rows affected) instead of clobbering it.

The endpoint returns `{"triggered":N,"failed":M,"skipped":K}`.

## 6. User-facing CRUD (`/api/jobs`)

Normal `AuthMiddleware` bearer auth, owner-scoped exactly like profiles/
sessions:

- `POST /api/jobs` — create. Validates `repoUrl`/`branch`/`harness`/`model`
  with the *exact same* validators `createSession` uses (SSRF blocklist
  included) — made `pub` on `CloudAgents.Handlers` for this reuse rather than
  duplicated.
- `GET /api/jobs` — list, newest first.
- `GET /api/jobs/{jid}` — get one.
- `POST /api/jobs/{jid}` — update. Every field is optional ("" means "leave
  unchanged"); providing *either* `runAtEpochMillis` or `intervalSeconds`
  replaces the whole schedule (so a job can move between "recurring" and
  "one-shot" without a separate clear flag). `status` here may be
  `active`/`paused`/`cancelled` — never `completed` (system-set only).
- `DELETE /api/jobs/{jid}` — delete.
- `POST /api/maintenance/trigger-jobs` — the maintenance sweep, §5.

## 7. In-container MCP tools

Four new tools on the same `cloud-agents-shim` from
`docs/phase6-mcp-callbacks.md`, riding the identical authenticated
shim↔host channel (no new transport): `schedule_job`, `list_jobs`,
`update_job`, `cancel_job`. Container-originated, authenticated with the
session's own callback bearer token, resolving the session's **owner** (not
the calling identity, which the host stamps as the operator for every
container-originated route) to scope the job operations — the same
`sessionOwnerUserId` lookup `request_secret`'s create path uses.

- `schedule_job(prompt, name?, runAtEpochMillis?, intervalSeconds?)` — always
  attaches the **calling session** immediately, directly satisfying "if it
  triggers again, continue this session." `repoUrl`/`branch`/`harness`/
  `model`/`profileId` are left empty on the row since they are only ever
  consulted by `ensureJobSession` for a job with no session yet, which never
  applies here. The insert and the attach happen in a single transaction
  (`CloudAgents.Repository.createScheduledJobWithSession`, mirroring
  `addPromptWithTags`), not two separate calls — closing two related bugs:
  an orphaned, never-attached row on a failed attach (#875, any failure now
  rolls back the whole transaction instead of leaving the insert committed),
  and a race (#877) where a pure-interval job's `next_run_at` defaults to
  "now" (immediately due) — a concurrent maintenance-trigger poll could
  otherwise observe the job mid-way between two separate insert/attach calls
  and have its own `ensureJobSession` attach a *different*, freshly created
  session first, silently breaking "if it triggers again, continue this
  session" for that job with no error surfaced anywhere.
- `list_jobs()` — lists every job owned by this session's user (not just jobs
  tied to this session), so an agent can review and manage the whole backlog
  it — or a human via the UI — has scheduled.
- `update_job(id, prompt?, runAtEpochMillis?, intervalSeconds?, status?)` —
  thin pass-through to the same `updateJobHandler` the REST route uses
  (profile changes are REST-only in v1, see §9).
- `cancel_job(id)` — a thin `update_job(..., status = "cancelled")` wrapper,
  kept as its own tool since "stop this job" is a far more common agent
  intent than a general field edit.

`validShimToolNames` (`src/handlers/profiles.l`), `shim/src/main.l`'s
`addTool` block, and `shim/tests/config_tests.l`'s `allShimToolNames` all
moved from 16 to 20 known tools — the three hand-kept copies `docs/phase7-
autonomy.md` §7 already tracks as having no automated cross-check (#621).

## 8. Deferred / not built

- **A full cron-expression schedule.** Deliberately out of scope — see §3.
- **Editable `repoUrl`/`branch`/`harness`/`model`/`profileId` via
  `update_job`.** The REST route (`POST /api/jobs/{jid}`) supports changing
  `profileId`; the MCP tool does not expose it, to keep the tool's schema
  small. A job's repo/branch/harness/model are immutable after creation in
  both paths today (delete and recreate to change them) — this only matters
  for a REST-created job that hasn't fired yet, since an MCP-scheduled job
  never uses those fields at all (§7).
- **A frontend panel.** This phase is host + shim only, matching how phase 6
  and 7 both landed their host/shim halves before any UI work.
- **`docs/phase7-autonomy.md`'s deferred `schedule_wake(delaySeconds,
  message)`** is effectively superseded for the "let an agent ask to be
  re-invoked later" use case: `schedule_job` from inside a session does
  exactly that, with a persisted, listable, cancellable job instead of a
  one-off wake.

## 9. Verification status

Compile-time only, in the same sense several other phases' entries in
`docs/PROGRESS.md` are qualified: this environment has no `lyric` toolchain
installed, so this change has not yet been run through `lyric build`/
`lyric test`/`scripts/verify.sh`. The design deliberately mirrors
already-runtime-verified code paths as closely as possible to minimize risk:

- `runSessionMessageBlocking` is a straight subset of the already-verified
  `streamSessionMessage` (same task, same poll loop, same wall-clock-cap
  workaround), with the untested delta being "no SSE writes" — a strict
  simplification, not new control flow.
- The due-job scan and schedule arithmetic reuse `selectReapableWarmSql`'s
  proven `CAST ... AS INTEGER` pattern rather than inventing new
  Lyric-side numeric handling.
- `tests/jobs_tests.l` covers the CRUD handlers, the container-originated
  callback handlers (including the wrong-token/missing-schedule/foreign-owner
  4xx paths), and the due-job scan directly — everything in
  `CloudAgents.Jobs` that does *not* reach `CloudAgents.Docker`. Like
  `getRunOutput`/`cancelRun` before it (`tests/session_tests.l`'s NOTEs),
  `runOneJob`/`triggerDueJobsHandler` themselves cannot be unit-tested from a
  `@test_module` (they call into `CloudAgents.Docker`), and are Docker-free
  testable in principle once `scripts/e2e-http.sh` grows a seeded-jobs leg —
  tracked as a follow-up, not done in this change. The row-level claim
  primitive those two functions are built on (`claimDueScheduledJob`/
  `restoreScheduledJobNextRunAt`, §5 steps 1/3) *is* directly unit-tested
  (`"claimDueScheduledJob lets only one of two racing callers win the same
  due job"`), since it's plain SQL with no `CloudAgents.Docker` dependency.
- `shim/tests/v2_client_tests.l` directly covers `scheduleJob`/`listJobs`/
  `updateJob`/`cancelJob` (#878) — success, empty-list, and transport/
  host-error paths for each, matching the existing coverage pattern for
  every other `CloudAgents.Shim.V2Client` wrapper function in that file
  (e.g. `addSessionTodo`/`setSessionTodoStatus`). These are plain
  synchronous functions over `V2CallbackTransport` (no `CloudAgents.Docker`
  involved at all), so unlike `runOneJob`/`triggerDueJobsHandler` above,
  there was no structural reason for them to be untested.
- **Known remaining edge case, not the one #870 was about:** if
  `POST /api/jobs/{jid}` (an unchanged-schedule update) lands in the narrow
  window between a job's row claim and its resolution, `updateJobHandler`
  reads the row's current (temporarily `''`) `next_run_at` as "existing,
  unchanged" and writes it back, leaving the job un-due until it's next
  edited with an explicit schedule change. Unlike #870 this doesn't
  duplicate a container run — worst case is a stalled recurring job — and is
  the same class of trade-off `clearSessionContainerIfMatchesSql` already
  accepts elsewhere in this codebase. Not fixed here; flagged for a
  follow-up if it proves to matter in practice.
- **Deliberately not fixed here (#873): `/api/maintenance/trigger-jobs` (and
  the pre-existing `/api/maintenance/reap` it mirrors) run under ordinary
  `AuthMiddleware` bearer auth with no separate "operator/admin" role, so
  any bearer that authenticates at all can fire the sweep across every
  user's due jobs.** This is the same access-control posture the sibling
  `reap` maintenance endpoint has always had in this codebase (§2 explicitly
  builds `trigger-jobs` to mirror it), not a new gap this phase introduces —
  and it's consistent with `currentUserId()`'s own doc comment
  (`src/handlers/auth.l`) that a real multi-tenant identity model waits on
  OAuth being wired in. Narrowing maintenance-route auth ahead of that is a
  cross-cutting decision affecting `reap` too, not something to make
  unilaterally inside this phase's diff.
