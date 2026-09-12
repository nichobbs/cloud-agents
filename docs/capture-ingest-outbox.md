# Spec: durable graph-ingest outbox (at-least-once runner → platform handoff)

Status: **Implemented.** Closes the deferred item named in both
`docs/capture-runtime-handoff.md` §9 ("Durable outbox / retry") and
AGENTS.md's "Provenance capture" section ("Still deferred: a durable
outbox/retry"). Follows the runtime graph handoff
(`docs/capture-runtime-handoff.md`) and reuses its serializer
(`CloudAgents.CheckpointBridge.objectsToIngestJson`) and HTTP primitive
(`CloudAgents.GitHubApi.httpPostJsonWithBearerTimeout`) unchanged.

> **Spec location convention.** Same as the rest of the capture arc: this spec
> lives flat under `docs/` (`docs/capture-ingest-outbox.md`), not under a
> `docs/specs/` subdirectory — see `docs/capture-runtime-handoff.md`'s own
> callout of this repo's convention.

## 1. Purpose and scope

`docs/capture-runtime-handoff.md` shipped `emitRunnerCheckpoint` POSTing a
session's emitted Testamur `ProvenanceObject`s to the platform's
`POST /api/ingest` — but as **one fire-and-forget bearer POST**: a transient
platform outage, a network blip, or a temporarily-misconfigured token
silently loses that session's provenance forever, with only a `WARNING` log
line as evidence. That spec named this gap explicitly in its own §9 ("Durable
outbox / retry ... out of scope for the opt-in phase").

This work package replaces that fire-and-forget POST with **at-least-once
delivery**: a durable, persisted outbox row per emitted body, an immediate
delivery attempt (so the happy path is unchanged — still one POST, no added
latency beyond a local DB insert), and a background drain sweep with
exponential backoff + jitter that retries a failed delivery until it succeeds
or a bounded attempt cap is reached.

**In scope:**

- The `graph_ingest_outbox` schema (migration `0035`) and `CloudAgents.
  Repository` accessors (enqueue, due-scan, record-attempt, record-terminal,
  mark-delivered, prune).
- The pure retry/backoff policy (`CloudAgents.GraphIngestOutbox`): bounded
  exponential backoff with deterministic jitter, and the max-attempts /
  terminal-give-up decision.
- The impure delivery layer (`CloudAgents.GraphIngestDrain`): the
  enqueue-then-immediately-attempt producer path, and the maintenance-endpoint
  drain sweep.
- `emitRunnerCheckpoint` (`src/docker_manager.l`) rewired to call the new
  durable path instead of POSTing inline.
- Tests: pure unit tests for the backoff schedule and terminal-cap logic;
  live-SQLite tests for the enqueue → due → attempt → delivered/terminal state
  machine, including idempotent re-enqueue.

**Out of scope / deferred (§9):** the actual Docker + live-platform POST, which
remains the documented manual/live step, same as every other capture-arc
package that reaches `CloudAgents.Docker` or a real network endpoint;
credential issuance/rotation for the bearer token; the NuGet migration of the
vendored checkpoint contract; a dead-letter *review* UI for terminal rows
(today an operator reads `last_error`/`attempts` directly, e.g. via `sqlite3`
against the deployment's DB file).

## 2. Why "durable, at-least-once" is safe here

The platform ingest endpoint is **idempotent by construction**
(`docs/capture-runtime-handoff.md` §6): every emitted object's id is a content
address (session id, step ids, `ckpt-…`), and the platform's `GraphIngest.
ingestObjects` upserts on those ids. So:

- Re-delivering the exact same body twice (a retry after a transient network
  error whose response was actually lost, or two overlapping drain calls
  racing on the same row) is a safe no-op on the platform side — not a
  duplicate or a double count.
- The outbox itself additionally de-duplicates at the SOURCE (§4): re-enqueuing
  a byte-identical `(sessionId, body)` pair returns the existing row rather
  than minting a new one, so even a caller bug that calls
  `emitRunnerCheckpoint` twice for the same completed run doesn't grow the
  outbox unbounded.

This is what makes "retry on any failure, as many times as the attempt cap
allows" the correct policy, rather than something that needs careful
exactly-once bookkeeping.

## 3. Design decision: no in-process timer — a maintenance endpoint, like the rest of this codebase

The task brief that motivated this spec described a periodic **in-process**
background loop (an env-configured interval, e.g. every 30 seconds). This repo
already answered that exact question for two prior features and reached the
same conclusion both times — **`Lyric.Web` has no in-process timer or
background-task primitive** (`docs/phase8-scheduling.md` §2's own words, which
this section quotes rather than re-derives):

> "Every existing time-driven behavior in this codebase already works around
> that the same way: expose an idempotent maintenance endpoint and have an
> *external* scheduler poll it." — `POST /api/maintenance/reap` (idle-container
> reaping) and `POST /api/maintenance/trigger-jobs` (scheduled jobs) are the
> two existing instances.

Rather than reach for a raw OS thread/timer primitive as a workaround (the
task brief's own fallback for "if no periodic mechanism exists"), this spec
follows the mechanism that **does** already exist and is proven in production
in this exact codebase: `POST /api/maintenance/drain-graph-ingest` — a third
instance of the identical idiom, restricted to the operator identity for the
same reason `triggerDueJobsHandler` is (a system-wide, unscoped-by-user sweep;
see `CloudAgents.Jobs.triggerDueJobsHandler`'s own doc comment for the
multi-tenant-OAuth-deployment rationale, which applies here verbatim). An
operator points a real cron (or the same external scheduler already polling
`/api/maintenance/reap`/`/api/maintenance/trigger-jobs`) at this endpoint on a
short interval — 30 seconds is a reasonable default, matching the task brief's
intent, though nothing in this repo enforces a specific cadence any more than
it does for the other two maintenance endpoints.

**Consequence for the env-var surface:** `CLOUDAGENTS_GRAPH_INGEST_DRAIN_SECS`
(an in-process loop interval) does not exist, because there is no in-process
loop for it to configure — adding an env var nothing reads would be exactly
the kind of stub this repo's production-readiness standard forbids. In its
place:

- `CLOUDAGENTS_GRAPH_INGEST_DRAIN_LIMIT` (default `25`) bounds how many due
  rows one drain call attempts — the outbox's analogue of
  `CloudAgents.Jobs.maxJobsPerTrigger`, bounding a single call's wall-clock
  time (each attempt is a bounded 15s HTTP POST at worst, so a full drain call
  is bounded at `limit * 15s` in the pathological all-timeout case).
- The recommended poll interval is **operator/deployment configuration** (the
  cron schedule itself, e.g. `* * * * *` with `sleep 30 &&` twice, or a
  30-second systemd timer), not a value this process reads — exactly like the
  existing two maintenance endpoints, neither of which has an
  `_INTERVAL_SECS`-shaped env var either.

## 4. Schema (migration `0035_graph_ingest_outbox`)

```sql
CREATE TABLE IF NOT EXISTS graph_ingest_outbox (
  id              TEXT PRIMARY KEY,
  session_id      TEXT NOT NULL,
  body            TEXT NOT NULL,   -- exact canonical JSON CheckpointBridge.objectsToIngestJson produced
  body_hash       TEXT NOT NULL,   -- sha256Base64(body); carries the uniqueness constraint
  url             TEXT NOT NULL,   -- snapshotted at enqueue time, never re-read from env at drain time
  created_at      TEXT NOT NULL,
  attempts        TEXT NOT NULL,   -- digit string, starts '0'
  next_attempt_at TEXT NOT NULL,   -- epoch-millis digit string; starts at created_at (due immediately)
  last_error      TEXT NOT NULL,   -- bounded to 500 chars; NEVER the bearer token (see §5)
  delivered_at    TEXT NOT NULL,   -- '' = not yet delivered; the "delivered" sentinel
  UNIQUE(session_id, body_hash)
);
CREATE INDEX IF NOT EXISTS idx_graph_ingest_outbox_due
  ON graph_ingest_outbox(delivered_at, next_attempt_at);
```

Design notes (all mirroring existing conventions in this schema, cited
per-choice so a reviewer can check each against precedent):

- **No `tenant`/bearer column, ever.** The bearer token is read fresh from
  `CLOUDAGENTS_GRAPH_INGEST_TOKEN` at the moment of every delivery attempt
  (`CloudAgents.GraphIngestDrain`), never persisted. A row is pure metadata —
  content, destination, and retry state — nothing an attacker who reads the
  SQLite file gains a credential from.
- **`url` is snapshotted, not re-read.** If an operator changes
  `CLOUDAGENTS_GRAPH_INGEST_URL` after rows are already queued, those rows keep
  delivering to the URL they were enqueued against. Only a fresh
  `emitRunnerCheckpoint` call picks up a new URL. This is the deliberate,
  simpler alternative to "always deliver to whatever URL is configured right
  now" — reasoned about here rather than left as an accidental consequence of
  either implementation choice.
- **`delivered_at = ''` is the "pending" sentinel** — the same
  empty-string-as-null idiom `scheduled_jobs.session_id`/`last_run_at` already
  use throughout this file, rather than a nullable column or a separate
  boolean.
- **A terminal (attempt-cap-exhausted) row is never a fourth boolean state** —
  it reuses the existing `next_attempt_at` column, pushed out to a sentinel far
  enough in the future (`"99999999999999"`, the year 5138) that it is
  permanently excluded from the due scan's `CAST(next_attempt_at AS INTEGER)
  <= CAST(now AS INTEGER)` filter. `last_error`'s
  `"TERMINAL (max attempts reached): "` prefix
  (`CloudAgents.GraphIngestOutbox.terminalErrorMessage`) is what an operator
  actually reads to distinguish "given up" from "still retrying" — see §8 for
  how an operator finds these rows today (no dedicated read endpoint).
- **`UNIQUE(session_id, body_hash)` + `INSERT ... ON CONFLICT DO NOTHING`**
  mirrors `insertWebhookSql`'s idempotent-register idiom exactly. `body_hash`
  (not `body`) carries the constraint so the unique index is over a
  fixed-size column.
- **Every timestamp arithmetic operation happens in SQL**, never as `Long`
  arithmetic in Lyric application code — see
  `src/capture/graph_ingest_outbox.l`'s module doc for the full reasoning
  (not a confirmed bug for a one-line add, but it costs nothing and keeps the
  whole feature `Long`-free, matching this schema's own
  `recoverStrandedScheduledJobsSql`/`markScheduledJobRanRecurringSql`
  precedent for exactly this reason).

## 5. Config (env vars)

| Env var | Meaning | Default |
|---|---|---|
| `CLOUDAGENTS_GRAPH_INGEST_URL` | platform ingest endpoint (unchanged from `docs/capture-runtime-handoff.md`) | empty ⇒ no enqueue at all (§6) |
| `CLOUDAGENTS_GRAPH_INGEST_TOKEN` | bearer token, read fresh at every delivery attempt (unchanged in spirit; now read by the drain layer too, not just the producer) | empty ⇒ every attempt fails with a typed, non-terminal (until the cap) error |
| `CLOUDAGENTS_GRAPH_INGEST_DRAIN_LIMIT` | max due rows one `POST /api/maintenance/drain-graph-ingest` call attempts | `25` |
| `CLOUDAGENTS_GRAPH_INGEST_MAX_ATTEMPTS` | attempts before a row is given up on (marked terminal) | `50` |
| `CLOUDAGENTS_GRAPH_INGEST_PRUNE_DAYS` | delivered rows older than this are deleted on every drain call | `30` |

`CLOUDAGENTS_GRAPH_INGEST_DRAIN_SECS` (named in the originating task brief)
does not exist — see §3 for why, and what an operator configures instead (the
external scheduler's own poll cadence).

## 6. Retry policy

`CloudAgents.GraphIngestOutbox.backoffDelayMillis(attempts, seed)` implements
**"Equal Jitter"**
([AWS's exponential-backoff-and-jitter writeup](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)):

```
ceiling = min(baseDelayMillis * 2^(attempts-1), maxDelayMillis)   // 30s, 60s, 120s, ... capped at 1h
delay   = ceiling/2 + deterministicJitter(seed, attempts, ceiling/2)   // uniform in [ceiling/2, ceiling]
```

- `seed` is the outbox row's own id (a UUID) — deterministic, not real
  randomness (`System.Security.Cryptography`), so a test can pin `(attempts,
  seed)` and assert an exact bound. Two different rows failing at the same
  `attempts` count get different (but reproducible) jitter, so a burst of
  simultaneously-failing rows spreads across the retry window instead of
  synchronizing.
- **Equal Jitter over Full Jitter, deliberately.** An earlier draft capped
  `raw + jitter` at `maxDelayMillis` directly; once `raw` alone reached the cap
  (attempt 8+), every jitter value got clamped back down to exactly
  `maxDelayMillis` — collapsing jitter to nothing at exactly the point (many
  simultaneously-capped rows) where it matters most. Equal Jitter avoids this
  because the jitter *range* itself saturates at `maxDelayMillis/2`, so capped
  rows still spread uniformly across `[maxDelayMillis/2, maxDelayMillis]`
  rather than converging on one instant. This bug-and-fix is preserved as a
  test case (`tests/graph_ingest_outbox_tests.l`'s "saturates at the cap"
  test) and in the module's own doc comment as a warning against
  reintroducing it.
- `CloudAgents.GraphIngestOutbox.isTerminal(attempts, maxAttempts)` is a
  one-line `>=` check — a row's `attempts` count (after the failure that just
  happened) reaching the configured cap (§5, default 50) marks the row
  terminal rather than scheduling yet another retry. With the default 30s
  base and 1h cap, 50 attempts spans roughly 2 days of retrying before giving
  up — generous enough to survive a multi-hour platform outage or an
  overnight misconfiguration, bounded enough that a permanently-broken
  destination doesn't retry forever.

## 7. Delivery flow

### 7.1 Producer (`CloudAgents.GraphIngestDrain.enqueueAndAttemptDelivery`)

Called synchronously (no new `await`, so `emitRunnerCheckpoint` stays
`#6249`-safe) from `emitRunnerCheckpoint` right after
`CheckpointBridge.objectsToIngestJson` produces the body:

1. `CLOUDAGENTS_GRAPH_INGEST_URL` empty ⇒ return immediately — no row, no
   growth, byte-identical to today's "log-only" behavior for a deployment that
   never configured a destination (mirroring
   `CloudAgents.Repository.enqueueWebhookEvent`'s `userHasWebhooks` guard for
   the exact same "don't grow an outbox nobody will ever drain" reason).
2. A non-empty but non-`http(s)` URL is logged and skipped (fail-closed,
   unchanged from `docs/capture-runtime-handoff.md` §3).
3. **Enqueue durably FIRST** (`CloudAgents.Repository.enqueueGraphIngest`). A
   DB failure here is logged and the call returns — nothing to deliver.
4. If the returned row is not already delivered (the idempotent-re-enqueue
   case, §4) **AND is actually due right now**
   (`CloudAgents.GraphIngestOutbox.isDueNow(row.nextAttemptAt, now)`), attempt
   **one immediate delivery** (`CloudAgents.GraphIngestDrain.attemptDeliverRow`).
   Success marks the row delivered; failure records the first backoff attempt
   via the shared `recordFailure` path (§6) — leaving a durable row for the
   drain sweep. The due-check matters only for the idempotent-re-enqueue case:
   a brand-new row's `next_attempt_at` starts at `created_at` (always due), so
   the ordinary first-enqueue happy path never skips this step — but without
   it, re-enqueuing a byte-identical body for a row that is currently
   mid-backoff (scheduled minutes-to-hours out after prior failures) would
   fire a second delivery attempt ahead of the Equal-Jitter schedule §6
   computed for it, silently jumping the queue (#1051). A not-yet-due row is
   simply logged and left for the drain sweep, same as any other pending row.

The happy path (destination configured, platform reachable) is therefore
still exactly one enqueue + one POST, with the enqueue adding a single local
SQLite insert's worth of latency — no behavior change for the common case,
only a durable fallback for the failure case.

### 7.2 Drain sweep (`CloudAgents.GraphIngestDrain.drainGraphIngestHandler`)

`POST /api/maintenance/drain-graph-ingest` (operator-only, §3):

1. Scan up to `CLOUDAGENTS_GRAPH_INGEST_DRAIN_LIMIT` due rows
   (`CloudAgents.Repository.dueGraphIngest`), earliest-due first.
2. For each: `attemptDeliverRow` (same function the producer path calls) —
   success marks delivered; failure calls `recordFailure`, which either
   schedules the next backoff (§6) or marks the row terminal past the attempt
   cap.
3. Prune delivered rows older than `CLOUDAGENTS_GRAPH_INGEST_PRUNE_DAYS`
   (`CloudAgents.Repository.pruneDeliveredGraphIngest`) — the outbox is a
   transit buffer, not a permanent audit log; the platform is the durable
   record of what was ingested.
4. Return `{"delivered":N,"failed":M,"terminal":K,"pruned":P}`.

Safe to call repeatedly (a row not yet due is untouched); a lost race between
two overlapping drain calls attempting the same row is harmless (both POST —
the platform's idempotent upsert absorbs the duplicate, §2 — and the losing
call's DB write is a guarded no-op via `delivered_at = ''` in every UPDATE's
`WHERE` clause, so it can't corrupt the winner's state).

## 8. Test strategy

Honest split, matching the rest of the capture arc (`docs/capture-runtime-
handoff.md` §7's own framing):

**Offline pure unit tests (`tests/graph_ingest_outbox_tests.l`, no DB, no
network):**
- `backoffDelayMillis` bounds at attempts 1, 2, and the 8/20/50 (saturated)
  cases, and is deterministic for a fixed `(attempts, seed)` pair.
- `isTerminal` at, below, and above the cap.
- `truncateError`/`terminalErrorMessage` bound and label a stored error.
- `parseAttemptsCount` round-trips the stored digit string.

**Live-SQLite tests (`tests/graph_ingest_outbox_tests.l`, same fresh-temp-DB
harness as `tests/session_events_tests.l`):**
- A freshly enqueued row is immediately due.
- `markGraphIngestAttempt` schedules a future retry and the row drops out of
  the due scan (the scheduled delay is always ≥15s, so it is never
  spuriously due again within the test's own runtime).
- `markGraphIngestDelivered` removes a row from the due scan permanently; a
  second call is a guarded no-op (0 rows affected).
- `markGraphIngestTerminal` excludes a row from the due scan permanently.
- Re-enqueuing an identical `(sessionId, body)` pair — pending, or after
  delivery — returns the SAME row rather than a duplicate; a genuinely
  different body for the same session enqueues a distinct row.
- `pruneDeliveredGraphIngest` only ever removes delivered rows, never a
  pending one.

**Deliberately NOT unit-tested (documented, not faked):** the actual bearer-
authed HTTP POST to a real platform endpoint, and the Docker glue
(`emitRunnerCheckpoint` calling `enqueueAndAttemptDelivery`) — same
`@test_module`-cannot-reach-`CloudAgents.Docker` constraint as every other
runtime-wired piece of the capture arc. The manual/live check from
`docs/capture-runtime-handoff.md` §7 is extended: point
`CLOUDAGENTS_GRAPH_INGEST_URL` at a stub that returns 500 for the first N
requests then 200, run a real session, and confirm (a) the row is NOT lost —
`sqlite3` against the deployment DB shows one `graph_ingest_outbox` row with
increasing `attempts` and a growing `next_attempt_at`, and (b)
`POST /api/maintenance/drain-graph-ingest` eventually delivers it once the stub
starts returning 200, or marks it terminal if the stub never does.

## 9. Acceptance criteria

1. Migration `0035` applies cleanly on a fresh DB.
2. With `CLOUDAGENTS_GRAPH_INGEST_URL` unset, `emitRunnerCheckpoint` behaves
   byte-identically to before this change (no row, no POST) — verified by
   inspection (the guard is the same URL-empty check `docs/capture-runtime-
   handoff.md` already had, now inside `enqueueAndAttemptDelivery`).
3. A successful delivery (producer path OR drain sweep) marks the row
   delivered and it never appears in a future due scan (live-tested).
4. A failed delivery leaves a durable row with a scheduled retry — the
   session's provenance is not lost on a single POST failure, closing the
   exact gap this spec exists to close (live-tested, backoff-bounded-tested).
5. A row that exhausts `CLOUDAGENTS_GRAPH_INGEST_MAX_ATTEMPTS` is marked
   terminal, logged once, and never retried again — never silently dropped
   with no trace (live-tested; the terminal `last_error` prefix is the trace).
6. Re-enqueuing an identical `(session, body)` pair is idempotent — no
   duplicate row, no duplicate delivery attempt for an already-delivered body
   (live-tested).
7. No new HTTP stack (`CloudAgents.GitHubApi.httpPostJsonWithBearerTimeout`,
   unchanged) and no new async function anywhere in the delivery path —
   `emitRunnerCheckpoint` stays sync (`#6249`-safe).
8. The bearer token is never persisted to the outbox table (schema review:
   the `graph_ingest_outbox` DDL has no token/credential column at all).

## 10. Deferred

- **The actual Docker + live-platform POST** — the documented manual step
  (§8), same as the rest of the capture arc.
- **Credential issuance/rotation** for the bearer token — unchanged deferral
  from `docs/capture-runtime-handoff.md` §9.
- **NuGet migration** of the vendored `Testamur.CheckpointFormat` — unchanged
  deferral.
- **A dead-letter review UI/endpoint** for terminal rows — today an operator
  reads `graph_ingest_outbox.last_error`/`attempts` directly against the
  deployment's SQLite file; a `GET /api/maintenance/graph-ingest-outbox`
  listing (or similar) is a natural, small follow-up if operators find that
  insufficient in practice, but nothing in the current task asked for it and
  adding an unused read surface ahead of a real need would be scope creep.
- **Envelope-form body as an alternative** (`docs/capture-runtime-handoff.md`
  §7's open question 1) — unaffected by this change; the outbox stores
  whatever `objectsToIngestJson` produces today, and would store whatever a
  future envelope-form serializer produces if that decision is ever revisited.

## Exact call sites / functions / files touched

| File | Symbol / location | Change |
|---|---|---|
| `src/db/db_client.l` | new `graphIngestOutboxSchemaSql`/`graphIngestOutboxDueIndexSql`/`insertGraphIngestOutboxSql`/`selectGraphIngestOutboxBySessionAndHashSql`/`selectDueGraphIngestOutboxSql`/`updateGraphIngestOutboxAttemptSql`/`updateGraphIngestOutboxTerminalSql`/`updateGraphIngestOutboxDeliveredSql`/`pruneDeliveredGraphIngestOutboxSql` | the outbox DDL + parameterized SQL builders |
| `src/db/repository.l` | migration `0035_graph_ingest_outbox`; new `GraphIngestOutboxRow` record + `enqueueGraphIngest`/`dueGraphIngest`/`markGraphIngestAttempt`/`markGraphIngestTerminal`/`markGraphIngestDelivered`/`pruneDeliveredGraphIngest` | the storage layer |
| `src/capture/graph_ingest_outbox.l` | new package `CloudAgents.GraphIngestOutbox` | pure backoff/terminal/error-bounding policy |
| `src/handlers/graph_ingest_drain.l` | new package `CloudAgents.GraphIngestDrain` (`enqueueAndAttemptDelivery`, `attemptDeliverRow`, `drainGraphIngestHandler`) | the impure delivery layer |
| `src/docker_manager.l` | `emitRunnerCheckpoint` | POST section replaced with `objectsToIngestJson` → `CloudAgents.GraphIngestDrain.enqueueAndAttemptDelivery` |
| `src/main.l` | new `RouteDrainGraphIngestOutbox` + `POST /api/maintenance/drain-graph-ingest` | the maintenance endpoint route |
| `tests/graph_ingest_outbox_tests.l` | new suite | pure backoff/terminal tests + live-SQLite state-machine tests |
| `lyric.toml` | `[project.packages]` + `[project.tests]` | register the two new packages and the new test suite |
| `docs/capture-ingest-outbox.md` | new spec | this document |
| `docs/capture-runtime-handoff.md` | §6/§9 | updated to point at this spec instead of listing the outbox as an open deferral |
| `AGENTS.md` | "Provenance capture" | the "Still deferred: a durable outbox/retry" sentence updated to reflect landing |
