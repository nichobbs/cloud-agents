# Spec: Claude cloud session import (findings-only, inbox-only)

Status: **Proposed.** Not built. Extends the session ledger
(`docs/session-ledger.md` §10, the observer) to Claude Code cloud sessions that
cloud-agents did not run: sessions started from claude.ai/code, the Claude app,
`claude --cloud` or a scheduled task, in any repository.

> **Spec location convention.** Specs live flat under `docs/`, named after the
> feature, like the other `docs/*.md` specs.

## 1. Purpose and scope

The owner runs many Claude Code cloud sessions outside cloud-agents. They want
the same review signal the observer gives for cloud-agents sessions:
outstanding work, shortcuts, deviations, unresolved questions and blockers,
surfaced in `/inbox`. That includes **existing, finished sessions**, not only
new ones.

In scope:

- Importing findings about any of the owner's Claude Code cloud sessions,
  across all repositories, old and new.
- Storing them as ordinary observed ledger entries on a read-only "imported"
  session, so `/inbox`, review states and feedback work unchanged.

Out of scope:

- Storing the imported transcript itself (see §2 and §11).
- GitHub sync of imported sessions (inbox-only, §7.4).
- Importing local (non-cloud) Claude Code sessions.

## 2. Why findings-only, and why an importer session

**There is no supported API for reading cloud sessions.** The Claude Code docs
(checked 2026-10-30: "Use Claude Code in the cloud", "Manage sessions",
"Message your other Claude Code sessions") document no REST or SDK endpoint
that lists cloud sessions or returns their transcripts:

- `claude --teleport` pulls one session into a local checkout of its
  repository, interactively. Messages that compaction summarised are not
  copied.
- `claude -p --output-format stream-json`, hook `transcript_path` and the Agent
  SDK only cover sessions running where the script runs.
- The transcript JSONL format is documented as internal and liable to change
  between releases.
- Cross-session messaging sends text but cannot read history.

**What does work is a Claude cloud session reading other sessions.** Inside a
cloud session, the remote-session tools (`list_sessions`, `list_events`) list
the account's sessions across all repositories and return their raw transcript
events, including finished sessions and events that compaction summarised.
These tools are not a documented public contract, so the design keeps that
dependency in one small, replaceable piece: the importer (§4).

**Findings-only, because relaying a transcript costs it twice.** The importer
can only move data by reading it into its context. To forward a verbatim
transcript it would also have to write the transcript back out as a request
body, in output tokens. Instead, the importer runs the extraction itself and
sends only the findings: at most 50 small candidates per chunk. That costs one
read of each transcript and almost no output tokens.

The trade-off, accepted: cloud-agents keeps no `session_events` for imported
sessions. There is no hash chain, and a later, better observer prompt cannot be
re-run over an old import without importing it again.

## 3. Overview

```
claude.ai scheduled task ──► importer cloud session (Claude)
                               │ 1. GET  /api/imports/claude/state   (what's already imported)
                               │ 2. GET  /api/imports/claude/prompt  (extraction rules)
                               │ 3. list_sessions / list_events      (remote-session tools)
                               │ 4. extract candidates per chunk
                               └ 5. POST /api/imports/claude/sessions/{ccrId}/findings
                                        │
                     agents.playdium.games (cloud-agents)
                               │ upsert imported session row
                               │ validate + Reconcile candidates
                               └ insert observed ledger entries ──► /inbox
```

All authentication uses an **import token** bound to one user and one tenant
(§5).

## 4. The importer

### 4.1 Where it runs

The importer is a claude.ai scheduled task that starts a fresh cloud session on
each run (no repository needed). Its environment must have:

- Network access to `agents.playdium.games`. The environment's allowed-domains
  list must include it.
- The import token, stored as an environment network secret attached to
  requests to `agents.playdium.games` (so it never enters the VM), or, if that
  isn't available, as an environment variable `CLOUDAGENTS_IMPORT_TOKEN`.

The task prompt is checked in at `deploy/importer/claude-session-importer.md`,
so it is reviewed like code. The prompt is short: almost all of the extraction
guidance comes from the prompt endpoint (§6.2), so it has one source of truth in
`CloudAgents.Ledger.Observer`.

### 4.2 Run procedure

Each run:

1. `GET /api/imports/claude/state`: the already-imported sessions with their
   cursors (§6.1), plus run budgets.
2. `GET /api/imports/claude/prompt`: the extraction instructions.
3. Page `list_sessions` from newest to oldest and pick candidates:
   - Skip sessions that are still working (status bucket `working`), or whose
     `updated_at` is under `settleMinutes` old (default 60).
   - Skip sessions tagged `cloudagents-importer`. The importer tags its own
     sessions with that tag when it starts, so it never imports itself.
   - Skip sessions whose `updated_at` is not newer than the state's
     `lastEventAt` for that session.
   - Stop after `maxSessionsPerRun` sessions (default 5).
4. For each picked session:
   - Page `list_events` with `kinds = ["user", "assistant"]`, oldest first,
     starting after the stored cursor event id.
   - Number the events with a 0-based **ordinal** in chronological order,
     counting from the start of the session, not from the cursor. The state
     endpoint returns the ordinal the cursor stands at.
   - Work in **chunks** of at most `maxEventsPerChunk` events (default 200). A
     very long session spans several chunks and, if need be, several runs.
   - For each chunk, extract candidates per the prompt and POST them (§6.3)
     with `throughEventId` and `throughOrdinal` set to the chunk's last event.
     A POST with no candidates still moves the cursor.
5. End with a one-line summary: sessions imported, chunks posted, candidates
   sent.

On any error from cloud-agents, the importer stops processing that session
without moving its cursor, and the next run retries it.

### 4.3 Backfill

The first runs work through history newest-first under the same budgets. For a
faster backfill, the owner fires the scheduled task on demand or temporarily
raises `maxSessionsPerRun` in the state response (§8). Cost scales with total
transcript volume read, once.

## 5. Import tokens

Imported findings must belong to a real user and tenant, and must reach that
user's inbox. The operator token (`CLOUD_AGENTS_API_TOKEN`) authenticates as the
`default` operator user, so it is the wrong principal for this.

New table `import_tokens` (tenant-owned, migration §9):

| Column | Type | Notes |
|---|---|---|
| `id` | text | PK with `tenant_id` |
| `user_id` | text | owner of the imports |
| `token_hash` | text UNIQUE | SHA-256 of the raw token, same scheme as invitations |
| `label` | text | e.g. "claude importer" |
| `created_at` | timestamptz | |
| `last_used_at` | timestamptz NULL | |
| `revoked_at` | timestamptz NULL | |

- The token is created with `POST /api/imports/tokens` (an authenticated user in
  their current request scope). The raw token is returned once, prefixed
  `cai_`. Revoke with `DELETE /api/imports/tokens/{id}`; list with `GET`.
- `AuthMiddleware` recognises a `cai_` bearer, looks up the hash in a global
  route table (like `session_routes`), checks it is not revoked and that the
  membership is still active, and sets the request's user and tenant scope.
- An import token authorises **only** the `/api/imports/claude/*` routes. Every
  other route refuses it with 403, so a leaked token cannot read sessions or
  start runs.
- The PWA gets a small "Imports" section under settings: create, list, revoke.

## 6. Endpoints

All three are under `/api/imports/claude/` and require an import token.

### 6.1 `GET /api/imports/claude/state`

```json
{
  "budgets": { "maxSessionsPerRun": 5, "maxEventsPerChunk": 200, "settleMinutes": 60 },
  "sessions": [
    { "ccrSessionId": "session_...", "throughEventId": "1bff...", "throughOrdinal": 412,
      "lastEventAt": "2026-10-30T09:19:23Z" }
  ]
}
```

`sessions` lists every imported session in the token's tenant. It is small
(one row per session), so no pagination in v1.

### 6.2 `GET /api/imports/claude/prompt`

Returns `text/plain`: `importerPrompt()` from `CloudAgents.Ledger.Observer`. It
shares the "what counts as undeclared work" guidance with `observerPrompt`
(factored into a common helper so the two can't drift), and replaces the
tool-calling steps with:

- the candidate JSON shape of §6.3,
- the ordinal rules (seqStart/seqEnd are the event ordinals the evidence spans),
- that `evidence` must quote the transcript and include the event uuid,
- that the session has no declared ledger entries, so everything worth
  surfacing is a candidate, but at no lower bar than the observer: honest
  confidence, `minConfidence` still applies.

### 6.3 `POST /api/imports/claude/sessions/{ccrSessionId}/findings`

```json
{
  "session": {
    "title": "Issues: JVM backend gaps",
    "repoUrl": "https://github.com/nichobbs/lyric-lang",
    "branch": "claude/...",
    "createdAt": "2026-10-30T08:24:43Z",
    "updatedAt": "2026-10-30T09:19:23Z",
    "prUrls": ["https://github.com/nichobbs/lyric-lang/pull/8617"]
  },
  "fromOrdinal": 0,
  "throughOrdinal": 199,
  "throughEventId": "1bff672c-...",
  "lastEventAt": "2026-10-30T09:19:23Z",
  "backfill": true,
  "candidates": [
    { "kind": "shortcut", "summary": "...", "detail": "...", "item": "",
      "seqStart": "120", "seqEnd": "131", "tags": [], "files": ["src/x.l"],
      "reversible": "true", "confidence": "0.8",
      "evidence": "event 7f3a...: \"skipping the JVM test for now\"" }
  ]
}
```

- `candidates` uses the observer's candidate shape exactly, decoded by the
  existing `decodeObserverReport` / `candidateOf`, so the two paths share a
  decoder and the 50-candidate cap.
- `session.repoUrl` and `branch` come from the session's context in
  `list_sessions`/`get_session` and may be empty (a session with no
  repository).
- Response: `{ "localSessionId", "undeclared", "duplicates", "dropped",
  "throughOrdinal" }`.
- 409 if `fromOrdinal` is not the stored `throughOrdinal + 1` (or 0 for a new
  session), so a replayed or out-of-order chunk can't double-insert. A replay
  of the chunk that was last accepted (same `throughEventId`) returns 200 with
  the original counts and changes nothing.

## 7. cloud-agents side

### 7.1 The imported session row

The first POST for a `ccrSessionId` creates a `sessions` row:

- `id`: a new cloud-agents session id
- `user_id` / `tenant_id`: from the import token
- `harness = 'claude'`, `native_session_id = ccrSessionId`
- `repo_url` / `branch`: from the payload
- `status = 'DESTROYED'`: there is no container, and nothing should claim one
- `imported_from = 'claude-cloud'` (new column, §9)
- `progress_summary`: the session's title
- `created_at` / `last_message_at`: from the payload

The row exists because the inbox query joins `sessions`, `sessionContext`
needs one, and the PWA can then show the imported session in lists (badged
"imported", with a link to `https://claude.ai/code/{ccrSessionId}`).

**Imported sessions are read-only.** Every route that sends a message, starts a
run, forks, changes the profile, or enables the observer refuses an imported
session with 409. A single guard in the session-mutation path checks
`imported_from <> ''`. The PWA hides the composer for them.

The mapping and cursor live in a new tenant-owned table
`claude_session_imports` (§9): `ccr_session_id` (unique per tenant),
`session_id`, `through_event_id`, `through_ordinal`, `last_event_at`,
`last_counts` (JSON of the last accepted chunk's reply, for idempotent
replays), `imported_at`, `updated_at`.

### 7.2 Accepting findings: `CloudAgents.Ledger.Import`

A new pure package beside `CloudAgents.Ledger.Observer`:

- `acceptImportChunk(target: SessionContext, chunk: ImportChunk,
  existing: slice[LedgerEntry], cfg: ReconcileConfig): ImportDecision`
- It validates each candidate with the observer's `candidateProblem`, with the
  window check replaced by `fromOrdinal <= seqStart <= seqEnd <=
  throughOrdinal`. That window predicate is passed in as a parameter, so
  `candidateProblem` is shared, not copied. As with the observer, one invalid
  candidate rejects the whole chunk (422 with the problem), so the importer
  learns about it.
- It runs `Reconcile.reconcile` for each candidate against the session's
  existing entries. On an imported session these are all `source = observed`,
  so the useful verdicts are `drop` (low confidence) and `duplicate`. Dedup
  across chunks and re-imports works because `findDuplicate` compares against
  earlier observed entries.
- For `undeclared` verdicts it builds entries with the observer's
  `observedEntry`: `source = observed`, `undeclared = true`,
  `observedFrom = seqStart`, `transcriptSeq = seqEnd`, `provisional = false`
  (imported sessions are finished). Severity goes through `effectiveSeverity`
  as for any observed entry, so the existing review/inbox thresholds apply.

The handler (`src/handlers/imports.l`) does the I/O: it authorises, upserts the
session and mapping, loads existing entries, calls `acceptImportChunk`, inserts
the entries and advances the cursor in one transaction.

No new `source` or `origin` value is needed, so `ledger_entries` and its CHECK
constraints are unchanged. "Imported" is a property of the session, not the
entry.

### 7.3 Notifications

When `backfill` is true, the import sends no notifications (a backfill could
produce hundreds). Otherwise `shouldNotify` applies as for the observer, capped
by `maxNotificationsPerReport`.

### 7.4 Kept away from GitHub sync and the observer sweep

- **GitHub sync:** an import never writes `ledger_items`, and
  `list_sessions_to_sync` only selects sessions with `gh:` items, so imported
  sessions are never synced. Belt and braces: add `AND s.imported_from = ''` to
  that function, so a later change that adds items can't start posting to
  merged PRs.
- **Observer sweep:** imported sessions never get a `ledger_observer` row, and
  the read-only guard refuses enabling one.

## 8. Config (env vars)

| Variable | Default | Meaning |
|---|---|---|
| `CLOUDAGENTS_IMPORT_MAX_SESSIONS_PER_RUN` | `5` | returned in state budgets |
| `CLOUDAGENTS_IMPORT_MAX_EVENTS_PER_CHUNK` | `200` | returned in state budgets; the POST also rejects a wider chunk |
| `CLOUDAGENTS_IMPORT_SETTLE_MINUTES` | `60` | returned in state budgets |
| `CLOUDAGENTS_IMPORTS_ENABLED` | `0` | `1` enables the routes; otherwise 404 |

Budgets are served by cloud-agents rather than baked into the importer prompt,
so cost can be tuned without editing the scheduled task.

## 9. Schema (migration `0005_claude_session_import`)

- `sessions`: add `imported_from text NOT NULL DEFAULT '' CHECK (imported_from
  IN ('', 'claude-cloud'))`.
- New tenant table `claude_session_imports` (§7.1), with a `UNIQUE (tenant_id,
  ccr_session_id)` constraint.
- New tenant table `import_tokens` (§5), plus a global `import_token_routes`
  (`token_hash` PK → `tenant_id`, `user_id`, `token_id`) so the middleware can
  find the tenant before RLS scope is set, mirroring `session_routes`.
- `list_sessions_to_sync`: add the `imported_from = ''` filter.

## 10. Test strategy

- **Pure (`tests/ledger_import_tests.l`):** `acceptImportChunk` covers the
  window predicate (boundaries, out-of-range rejects the chunk), drop below
  `minConfidence`, duplicate against an earlier chunk's entry, undeclared entry
  fields, `provisional = false`, and severity via `effectiveSeverity`. Plus
  `importerPrompt` vs `observerPrompt` sharing the common guidance (a drift
  test asserting the shared helper's text appears in both).
- **Fixture:** a sanitized real `list_events` page captured from a cloud
  session (`tests/fixtures/ccr-events/`), used to check the documented ordinal
  rules against real event shapes.
- **Live Postgres (`tests/claude_import_store_tests.l`):**
  - token create → auth → revoke
  - an import token refused on a non-import route
  - first chunk creates the session and mapping
  - cursor advance, a 409 on a gap, and an idempotent replay of the last chunk
  - the inbox shows an imported `review` entry
  - `list_sessions_to_sync` excludes imported sessions
  - the read-only guard refuses a message
- **Manual / live:** run the importer task against a few real finished
  sessions and check that `/inbox` shows sensible findings and that a second
  run imports nothing new.

## 11. Acceptance criteria

1. With an import token and the importer task configured, a finished cloud
   session in any repository appears in cloud-agents as an imported, read-only
   session within one importer run.
2. Its findings appear in `/inbox` as observed entries, can be reviewed like
   any other, and are never posted to GitHub.
3. Re-running the importer imports nothing new for unchanged sessions, and
   only new chunks for sessions that continued.
4. A session longer than one chunk imports correctly across chunks and runs.
5. An import token cannot call any non-import route.
6. Backfill sends no notifications.

## 12. Deferred

- **Verbatim import via resume + Stop hook.** A cheaper path to full
  transcripts: put a `Stop` hook in the cloud environment's setup script (it
  writes `~/.claude/settings.json` on every VM start, so it covers every repo
  and old branch). Then send each old session a trivial message (`claude -p
  "reply OK" --cloud <id>`), so it reopens and the hook POSTs its
  `transcript_path`. That costs one input pass per session, not a full read and
  rewrite. Open questions to test before adopting it:
  - whether a restored VM's JSONL holds the full history or only what follows
    compaction,
  - that the hook fires on that turn,
  - the stray visible turn left in each poked session,
  - that archived sessions refuse messages,
  - that the JSONL format is internal and unversioned.
  If adopted, imports would carry `session_events`, and the existing observer
  would run on them in place of the importer's extraction.
- **A supported sessions API.** If Anthropic publishes one, cloud-agents can
  pull directly and the importer task goes away. The endpoints in §6 stay as
  they are.
- **Re-extracting old imports** with a newer prompt (needs the transcript
  again; see the first item).
- **Linking imported findings to work items** (`gh:` items from `prUrls`),
  which would need a decision on GitHub sync for imported sessions.

## Exact call sites / functions / files touched

| File | Symbol / location | Change |
|---|---|---|
| `src/pg/schema.l` | `migrations()` | add `0005_claude_session_import` (§9) |
| `src/pg/schema.l` | `list_sessions_to_sync` | `imported_from = ''` filter |
| `src/pgstore/imports.l` (new) | tokens, mapping, cursor | storage for §5 and §7.1 |
| `src/ledger/import.l` (new) | `CloudAgents.Ledger.Import.acceptImportChunk` | pure acceptance (§7.2) |
| `src/ledger/observer.l` | `candidateProblem`, `observerPrompt`, new `importerPrompt` | window predicate parameter; shared guidance helper |
| `src/handlers/imports.l` (new) | state, prompt, findings, token CRUD | §5, §6 |
| `src/main.l` | `AuthMiddleware`, routes | `cai_` bearer, import-only route allowlist, new routes |
| session mutation handlers (`src/handlers/sessions.l` and friends) | send/run/fork/profile/observer enable | read-only guard for imported sessions |
| `frontend/src/` | session list, session view, settings | "imported" badge and claude.ai link, no composer, Imports token UI |
| `deploy/importer/claude-session-importer.md` (new) | scheduled task prompt | §4 |
| `tests/ledger_import_tests.l`, `tests/claude_import_store_tests.l` (new) | | §10 |
| `tests/fixtures/ccr-events/` (new) | | sanitized real `list_events` page |
| `lyric.toml` | packages, `[project.tests]` | register new packages and suites |
| `docs/session-ledger.md` | §10 | pointer to this spec |
| `AGENTS.md` | Session ledger section | one paragraph on imports |
