# Capability Audit — cloud-agents vs. Containment Plane role (§5.2) and Managed-Sessions Capture Adapter role (§4.1)

Date: 2026-08-14. Audited against the platform architecture document
("Agentic Development Security Platform: Architecture & Plan", 2026-08 revision
— an external document not committed to this repo; its canonical copy is
destined for `docs/ARCHITECTURE.md` in the Testamur platform monorepo per its
§9.2, and section references below are to that document), which assigns
cloud-agents two roles:

- **§5.2 Containment Plane control surface**: session runner and human control
  surface — start/monitor agent sessions, approve credential grants, kill
  switches — plus workspace profiles and (later) broker client.
- **§4.1 Managed-session provenance capture adapter**: server-side capture via
  the Managed Agents API event history (`sessions.events.list`, including
  `agent.mcp_tool_use` events), "which cloud-agents already consumes".

Headline verdict up front, because it reframes everything below:

1. **The §4.1 premise is factually wrong.** cloud-agents does **not** consume
   the Managed Agents API at all. There are zero references to
   `sessions.events.list` or `agent.mcp_tool_use` anywhere in the repo; the
   only mention of the managed agents API is ADR-001, which **explicitly
   rejected it** ("requires API credits, not subscription" —
   `docs/architecture-decisions.md:11`). Sessions run as `claude -p` (and
   codex/opencode/gemini equivalents) inside self-hosted ephemeral Docker
   containers, capturing **plain-text stdout** (`docker/entrypoint.sh:486-503`
   — no `--output-format stream-json`). The "event history" the architecture
   doc wants to mine does not exist here in any structured form.
2. **The §5.2 stack description is wrong.** "Its existing PWA + Workers/KV
   architecture" — the PWA half is real (React/Vite PWA,
   `frontend/src/pwaOptions.ts`), but the backend is **not** Cloudflare
   Workers/KV or TypeScript. It is a **Lyric** application (an experimental,
   safety-oriented language compiling to .NET 10 — `lyric.toml`,
   `src/*.l`) with **SQLite** storage (`src/db/`), orchestrating Docker on a
   single VM (`deploy/docker-compose.yml`, ADR-004). There is no KV, no
   Workers, no Hono anywhere.
3. What *is* here is a genuinely working, personal-scale, self-hosted
   session runner with a mature-for-its-size control surface: real session
   CRUD, real SSE streaming, per-request permission/secret approval with
   audit rows, an encrypted write-only credential vault, network/tool policy
   profiles, and a large unit-test suite that almost entirely passes (34/36
   suites on the current toolchain; §3). It is a prototype in deployment
   posture (auth open by default, single VM, single SQLite file), not in
   code hygiene.

Every claim below carries file evidence. Test-run evidence is from a clean
checkout on 2026-08-14 with lyric 0.4.36 + .NET SDK 10 installed in-session
(see §3).

---

## 1. Implemented inventory

### 1.1 Session lifecycle — **working** (for self-hosted Docker sessions; no managed-API sessions at all)

| Capability | State | Evidence |
|---|---|---|
| Create session (validated repo/branch/harness/model, SSRF blocklist) | working | `src/handlers/sessions.l:151-207`; route `POST /api/sessions` (`src/main.l:1799`) |
| List sessions (with status/attention/group projections) | working | `src/handlers/sessions.l:259`, `src/sessions/session_manager.l` (`sessionSummariesJson`) |
| Send message → spawn container → **live SSE stream** of output | working | `src/handlers/sessions.l:439-603` (`streamSendMessage`), `src/docker_manager.l:544-843` (poll loop over `docker logs`), streaming route `src/main.l:2030` |
| Monitor: polling fallback (`/output`, `/output/{offset}` incremental) | working | `src/handlers/sessions.l:756-929` |
| Cancel in-flight run (terminates container, audits `cancelled`) | working | `src/handlers/sessions.l:612-674`; `POST /api/sessions/{id}/cancel` |
| Delete session (container + workspace volume teardown, refuses mid-run) | working | `src/handlers/sessions.l:932-981` |
| Restart container, archive/unarchive, model switch, profile attach | working | `src/handlers/sessions.l:985-1083`, `:214-251` |
| One-run-per-session concurrency claim (guarded UPDATE), stranded-RUN recovery via `defer` | working | `src/handlers/sessions.l:476-495` |
| Idle-container reaping | working, but **pull-based** — an external scheduler must poll `POST /api/maintenance/reap`; the server has no in-process timer | `src/handlers/sessions.l:697-717` |
| Run history per session | working | `runs` table `src/db/db_client.l:2009`, `GET /api/sessions/{id}/runs` |
| Multi-repo sessions (linked checkouts) | working | `src/handlers/sessions.l:275-394`, `docker/reconcile-repos.sh` |
| Scheduled jobs (recurring prompts) | working, same pull-based trigger caveat (`POST /api/maintenance/trigger-jobs`) | `src/handlers/jobs.l`, migration 0027 |
| End-to-end verification | manual only (2026-07-15 live run confirmed: server answered curl, container cloned repo, streamed output) plus a CI HTTP smoke test without Docker | `docs/BUILD.md` "Net effect", `scripts/e2e-http.sh`, `.github/workflows/ci.yml:159-166`; the automated container e2e asked for in nichobbs/cloud-agents#354 still does not exist |

The five harnesses (claude/codex/opencode/gemini/antigravity) each get their own runner
image and entrypoint (`docker/Dockerfile*`, `docker/entrypoint*.sh`).

### 1.2 Event-stream handling — **working as a UI transport; absent as a capture pipeline**

There is **no SSE proxy of an upstream agent API**. The SSE stream is
generated by this server itself: the run loop polls `docker logs` (full log
refetch per tick, 1–5 s adaptive), diffs by byte offset, and frames deltas as
SSE (`src/docker_manager.l:638-810`, `src/streaming/streaming.l`).

Event types **emitted** on the session stream (all defined in
`src/streaming/streaming.l:99-254`, forwarded from the run-loop at
`src/docker_manager.l:694-810`):

- `data {chunk}` — raw ANSI text deltas of harness stdout (opaque; parsed only
  by the frontend's ansi_up renderer, never semantically)
- `done` / `done {messageId}` / `error` / keepalive comments
- Platform-originated MCP-callback events, i.e. events from **cloud-agents'
  own in-container shim** (`shim/src/*.l`), not from the harness:
  `permission_request`, `user_question`, `progress_update`, `secret_request`,
  `artifact_reported`, `notification`, `todo_update`

**`agent.mcp_tool_use`: not surfaced, not parsed, not received.** The
harness's own tool calls are invisible except when Claude's permission-prompt
mechanism routes a gated tool through the shim's `permission_prompt` tool —
which does persist `tool_name` + `input_json` to the `permission_requests`
table (`src/db/db_client.l:2535`) and streams it — but that covers only
permission-gated calls, only for the claude harness with callbacks enabled,
and is an approval mechanism, not an event history. Auto-allowed tool calls
leave no structured trace anywhere. Transcript persistence is **one `agent`
message per run containing the entire raw log blob**
(`src/handlers/sessions.l:565`).

The frontend parses `done`/`error`/chunk frames and treats all other named
events as "refresh a panel" signals (`frontend/src/lib/api.ts:307-337`,
`frontend/src/hooks/useStreamMessage.ts`).

### 1.3 GitHub integration — **implemented** (OAuth working; PR correlation shallow but real)

- **OAuth web flow**: implemented and wired. `POST /api/auth/github/exchange`,
  `/refresh`, `/logout`, config discovery (`src/handlers/oauth.l`, routes
  `src/main.l:2014-2017`; frontend `src/pages/AuthCallback.tsx`,
  `src/lib/auth.ts`). Refresh tokens encrypted at rest
  (`src/db/repository.l:1088-1101`). Bearer validation against
  `api.github.com/user` with a SHA-256-keyed TTL cache
  (`github_token_cache`, `src/db/db_client.l:2252`).
- **PR correlation**: two mechanisms, both implemented:
  1. Transcript scraping — regex extraction of GitHub PR URLs from agent
     output, display-only (`frontend/src/lib/sessionPRs.ts:19-53`).
  2. Server-side proxy for repo/PR/CI status by session branch —
     `GET /api/github/pulls/{owner}/{repo}/{branch}`,
     `/checks/...` (`src/handlers/proxy.l`, routes `src/main.l:2002-2005`),
     rendered in `frontend/src/components/GitHubPanel.tsx`.
  3. Opt-in "Open PR" (compare→dedupe→create via GitHub API) —
     `POST /api/sessions/{id}/open-pr` (`src/handlers/open_pr.l`).
  There is **no durable session↔PR link in the database** — correlation is
  recomputed from branch names and transcript regexes each render.
- Branch-name slashes don't fit the proxy's single path segment (documented
  fallback in ADR-006).

### 1.4 Persistence — **working**, single-file SQLite

- Store: one SQLite file (`CLOUD_AGENTS_DB_PATH`), WAL + busy_timeout applied
  per connection (`src/db/sqlite_driver.l`), TEXT-only column driver
  (acknowledged limitation, `docs/PROGRESS.md` "SQLite concurrency" note).
- ~30 tables via a versioned migration ledger (29 migrations,
  `src/db/db_client.l:2216-2246`, applied in `src/db/repository.l`):
  `sessions`, `session_repos`, `session_groups`, `messages` (+ `messages_fts`
  FTS5 with sync trigger, `:821-835`), `comments`, `todos`, `runs`,
  `credentials` (encrypted values), `profiles` + grant join tables
  (`profile_credentials`, `profile_tools`, `profile_skills`,
  `profile_subagents`, `profile_mcp_servers`), `skills`/`subagents`/
  `mcp_servers` library, `webhooks`/`webhook_events`, `permission_requests`,
  `permission_rules`, `user_questions`, `secret_requests`, `artifacts`
  (bytes on disk under `CLOUD_AGENTS_ARTIFACTS_DIR`), `memories`,
  `repo_tasks`, `notifications`, `scheduled_jobs`, `github_token_cache`,
  `github_oauth_refresh`, `model_listing_cache`.
- Workspace and harness-home state lives on Docker volumes, not the DB
  (ADR-002; `docs/credentials.md` table).

### 1.5 PWA state — **installable: yes; push notifications: no**

- Installable PWA via vite-plugin-pwa: manifest, icons, maskable icon,
  standalone display, Workbox precache with `/api/` never cached
  (`frontend/src/pwaOptions.ts:7-50`, tested in `pwaOptions.test.ts`).
- Notifications are **browser `Notification` API only**, fired on
  attention-state transitions while the app is open, opt-in via localStorage
  (`frontend/src/lib/notifications.ts`,
  `frontend/src/hooks/useAttentionNotifications.ts`). **No Web Push, no
  service-worker push subscription, no server-side push** — a closed
  app/phone gets nothing. Server-side "webhooks" exist but delivery is
  pull-based: an external agent must poll `GET /api/webhooks/pending` and mark
  events delivered (`src/handlers/webhooks.l`, routes `src/main.l:1909-1913`)
  — the server never makes an outbound delivery call.

---

## 2. External interfaces

### 2.1 Routes (all registered in `src/main.l:1798-2030`)

~100 routes. Families:

- Sessions: CRUD + `model`/`profile`/`archive`/`restart`/`viewed`/`group`,
  `POST .../messages` (SSE streaming route, `:2030`), `cancel`, `runs`,
  `output`, `output/{offset}`, `repos` (linked repos), `open-pr`,
  `workspace/diff|files|file` (read-only workspace inspection via a
  short-lived inspect container, `src/workspace.l`,
  `src/handlers/workspace.l`).
- Transcript & annotation: `messages`, `comments`, `todos`,
  `search/messages` (FTS5), `highlights`.
- Library/config: `prompts` (+tags/render/use), `profiles`, `library/skills`,
  `library/subagents`, `library/mcp-servers`, `credentials` (list names /
  put / delete — never returns a value), `groups`, `jobs`, `webhooks`.
- Container-originated callback surface (bearer = per-session callback token,
  not user auth): `POST/GET /api/sessions/{id}/callbacks/{permission,question,
  secret,progress,todo,todos,artifact,memory,notify,jobs,tasks}` with
  user-originated `/answer` counterparts flowing through normal auth
  (`src/main.l:1922-1977`; split enforced by
  `CloudAgents.Auth.isContainerCallbackRoute`, `src/handlers/auth.l:534-536`).
- GitHub/model proxy: `GET /api/github/repos|pulls|checks/...`,
  `GET /api/models/{harness}`, `POST /api/models/validate`,
  `GET /api/harnesses` (`src/handlers/proxy.l`).
- Auth: `GET /api/auth/github/config`, `POST exchange|refresh|logout`.
- Maintenance (external scheduler): `POST /api/maintenance/reap`,
  `POST /api/maintenance/trigger-jobs`.
- `GET /api/health` (unauthenticated).

### 2.2 Auth model

`AuthMiddleware` (`src/main.l:66-95`) → `CloudAgents.OAuth.authenticateRequest`
(`src/handlers/oauth.l:691-704`):

1. Bearer == `CLOUD_AGENTS_API_TOKEN` (constant-time) → operator identity.
2. Otherwise, if GitHub OAuth is configured → validate as GitHub token
   (cached by SHA-256; optional `CLOUD_AGENTS_WHITELIST` of GitHub user IDs);
   tenant key = `gh-<github-id>`.
3. Otherwise → `enforce()`: **requests are allowed through unauthenticated
   unless the route touches credentials** (`src/handlers/auth.l:499-504`).
   i.e. **a deployment with neither `CLOUD_AGENTS_API_TOKEN` nor OAuth
   configured is an open, unauthenticated session runner by design** — the
   README warns about this (`README.md:24-31`), though its blanket "no
   endpoint currently enforces authentication" wording is stale (enforcement
   landed with the Lyric.Web 0.4.26 migration; it's now *conditional*, not
   absent).
4. Container callback routes authenticate against a per-session minted
   callback bearer token instead (`src/handlers/callbacks.l:163`).

Ownership scoping: per-request identity is stamped thread-locally and every
repository query is owner-scoped (`src/main.l:79-89`, throughout
`src/db/repository.l`).

### 2.3 Environment/config surface (grep of `src/**/*.l`)

`CLOUD_AGENTS_API_TOKEN`, `_WHITELIST`, `_GITHUB_CLIENT_ID/SECRET` (or
`LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_*`), `ENCRYPTION_KEY` (32-byte base64;
credential vault master key), `_DB_PATH`, `_ARTIFACTS_DIR`,
`_DOCKER_TCP_HOST`, `_RESTRICTED_NETWORK`, `_EGRESS_PROXY`,
`_CALLBACK_API_URL`, `_CALLBACK_NETWORK`, `_CALLBACK_TIMEOUT_MS`,
`_MCP_CALLBACKS` (on unless "0"), `_ENABLED_HARNESSES`,
`_INGEST_AGENT_PLAN`, `_SEED_{SKILLS,SUBAGENTS,MCP_SERVERS}_DIR`,
`_SUMMARIZER_{URL,KEY,MODEL}` (highlights), `LYRIC_CONFIG_WEB_SERVER_PORT`.
Deployment topology: API + nginx frontend + Caddy on one VM
(`deploy/docker-compose.yml`, `deploy/.env.example`, `deploy/RUNBOOK.md`).

### 2.4 Storage schemas

See §1.4. Notables for the platform roles: `permission_requests` /
`secret_requests` rows **are** decision-audit records (tool name + input JSON
/ credential name + reason, status, decided-at —
`src/db/db_client.l:2535,2783`; "the row IS the audit record",
`src/handlers/callbacks.l:595-599`); `runs` records prompt preview, harness,
model, status, timestamps per run. Nothing stores structured harness events.

---

## 3. Test coverage

**Backend (`lyric test`, clean checkout, lyric 0.4.36 + .NET 10 SDK installed
in this session): 34 of 36 suites passed, 2 suites failed (1 test case
each; ~640 cases passed overall).** Reproduced identically across two full
runs. The failures:

1. `CloudAgents.SessionTests` #16 *"lastAgentMessageContent returns the most
   recent agent message"* — fails with the Lyric **runtime** error
   `unsupported method 'Message' on the receiver type` at the
   package-qualified record construction
   `CloudAgents.Repository.Message(...)` (`tests/session_tests.l:784-788`).
   This is the documented "qualified record construction" toolchain gotcha
   class (`docs/lyric/gotchas.md`), i.e. a compiler/runtime failure on
   lyric 0.4.36, not a wrong assertion — the function under test exists and
   is correct. It contradicts the repo docs' "24/24 green" claims, which
   date from v0.4.19; either a compiler regression since, or doc drift.
2. `CloudAgents.OAuthTests` #25 *"refreshOAuthToken returns refreshed token
   for authenticated user"* — genuine assertion failure: an unknown bearer
   on `POST /api/auth/github/refresh` is expected to yield **401**
   (`tests/oauth_tests.l:749-752`) but yields **404** ("no GITHUB_TOKEN in
   the credential vault", `src/handlers/oauth.l:477`), i.e. the
   unknown-token path falls through to a vault lookup instead of failing
   authentication first — either a real (mildly information-leaking) handler
   bug or an order-dependent test; both readings mean the suite is not
   asserting current behaviour.

Frontend (`npx vitest run`): **38 files, 312/312 tests pass** in ~21 s.

- The 36 backend suites (`lyric.toml [project.tests]`) are almost entirely
  **pure-logic unit tests**: validation, SQL string builders, SSE framing,
  state machine, crypto round-trips, policy resolution, plus live-SQLite
  suites for migrations/CRUD (e.g. `tests/groups_tests.l`,
  `tests/db_tests.l`).
- **Structurally untestable in-language** (documented, recurring): anything
  reaching the async `CloudAgents.Docker` package or needing a constructed
  `Web.Request` — i.e. the run loop, the route adapters, `AuthMiddleware`,
  the streaming handler (`src/handlers/sessions.l:409-421` NOTE;
  `src/network_policy.l:1-10`). Mitigations: pure-logic extraction into
  side packages (`CloudAgents.RunnerEnv`, `.NetworkPolicy`, `.ToolPolicy`,
  `.DockerPolicy`), `scripts/verify.sh` (24 runtime logic checks, in CI),
  and `scripts/e2e-http.sh` (route dispatch smoke test against a real
  server, in CI — no Docker).
- **Not tested anywhere automated**: the actual container run
  (create→clone→stream→persist), cancel-against-live-container, reaping
  against live containers, OAuth against real GitHub, webhook consumer flow.
  Shell-side tests exist for entrypoint fragments
  (`scripts/test-*.sh`: branch-policy injection, MCP registration, CA-bundle
  split, reconcile-repos, opencode entrypoint).
- **Tests asserting behaviour that does not exist**: one — OAuthTests #25
  above asserts a 401 the handler does not currently return. Otherwise the
  nearest hazard is the opposite: `listSessionsResponse`
  (`src/handlers/sessions.l:1136-1155`) is a typed handler that is *not*
  registered as a route (documented as such) — nothing tests it, and its doc
  comment records that a previous version of it silently corrupted IL for the
  whole bundle. Also note `tests/docker_client_tests.l` and
  `tests/tool_policy_tests.l` are thin (42/28 lines).
- CI (`.github/workflows/ci.yml`) runs the full backend build + `lyric test`
  + `verify.sh` + `e2e-http.sh` + frontend `tsc`/`vite build`/`vitest`, with
  a MIN_LYRIC_VERSION gate (0.4.34).

**Caveat on "clean checkout"**: the toolchain is nontrivial to obtain (the
lyric release tarball is proxied/gated in cloud sessions; .NET 10 SDK must be
installed separately). Nothing about the test suite itself is flaky in what I
observed.

---

## 4. Dependency and security posture

### 4.1 Dependencies

- **Backend**: exact-version pins in `lyric.toml [nuget]` (Lyric.Web /
  Lyric.Docker / Std.Logging 0.4.36, Microsoft.Data.Sqlite 10.0.9,
  SourceGear.sqlite3, SQLitePCLRaw.provider.dynamic_cdecl). No lockfile
  mechanism beyond the pins. `lyric restore` emits **NU1903: transitive
  `SQLitePCLRaw.lib.e_sqlite3` 2.1.11 has a known high-severity vulnerability
  (GHSA-2m69-gcr7-jv3q)** — unaddressed.
- **The compiler/framework itself is the biggest dependency risk**: Lyric is
  a single-maintainer experimental language. This project alone found and
  filed **eight upstream compiler/runtime bugs** (`AGENTS.md`,
  `docs/BUILD.md`), one still open (lyric-lang#6249 — an async local
  silently losing its value across two awaits) requiring source-level
  workarounds in production code (`src/docker_manager.l:571-577,811-841`,
  including replacing wall-clock timing with an approximating Int
  accumulator to dodge an uncatchable AccessViolationException). Any team
  absorbing this component inherits that toolchain exposure.
- **Frontend**: `package-lock.json` committed; small dependency set (react,
  react-router, ansi_up, dompurify, marked, highlight.js). npm warns on a
  deprecated transitive `glob@11.1.0`.

### 4.2 Secrets handling (the part that matters for a future credential broker)

Good, deliberate design at personal scale:

- **Write-only vault**: values can be stored/deleted and names listed; no
  endpoint ever returns a stored value (`src/handlers/credentials.l:1-14`;
  ADR-006 records the reasoning and the proxy migration that made
  browser-held keys optional).
- Encryption at rest: AES-256-CBC + HMAC-SHA256 encrypt-then-MAC, per-value
  random IV, constant-time tag check (`src/crypto/crypto.l:1-224`). GitHub
  refresh tokens encrypted the same way; token-validation cache keyed by
  SHA-256, never the token (`src/crypto/crypto.l:118-123`).
- Injection path: credentials flow **server→container only**, as plaintext
  env vars on container create, gated by the session's profile grants
  (`src/runner_env.l:60-83`, `profile_credentials`), with a reserved-name
  blocklist preventing PATH/LD_PRELOAD-class hijacks
  (`src/handlers/credentials.l:45-58`).
- Mid-run grants: `request_secret` → human approve/deny per request (no
  "always allow"), one-time value delivery on first poll after approval,
  decision row retained as audit (`src/handlers/callbacks.l:499-644`).

Gaps relative to a credential-broker future:

- **All secrets are long-lived static values.** Nothing issues short-lived
  or scoped tokens; an approved grant hands over the full stored credential
  (e.g. a PAT with whatever scopes it has). No TTL, no scope-down, no
  revocation short of deleting the credential.
- Single static `ENCRYPTION_KEY` in env; no rotation story (a rotated key
  makes old blobs undecryptable — handled as fail-closed empty delivery,
  `src/handlers/callbacks.l:585-592`, but there's no re-encrypt tool).
- The claude harness's whole authenticated `~/.claude` (subscription OAuth
  state) lives on shared/per-user Docker volumes and optionally as a vaulted
  base64 tarball (`docs/credentials.md`) — a high-value blob outside any
  scoping mechanism.
- Auth is **open by default** (§2.2), and the default session network policy
  is **full egress** (`src/handlers/sessions.l:62-66`: the SSRF check on repo
  URLs is hostname-string-only and is "the only control against
  metadata-endpoint SSRF via git clone today"). `restricted` fails closed to
  no-network unless the operator provisions an egress network
  (`src/network_policy.l:20-38`) — good design, but opt-in.
- ADR-007: cloned repos' `.mcp.json` is auto-trusted inside the runner
  (workspace trust pre-accepted; gemini runs `--yolo`) — the container is
  the only boundary.
- No device identity, no mTLS, no posture assertion anywhere.

---

## 5. Gap table (required by §5.2 + §4.1)

| Required capability | Current state | Gap | Notes |
|---|---|---|---|
| Session control surface (start/monitor/stop) | **Working** for self-hosted Docker sessions: create/list/stream/cancel/delete/restart + run history + reattach (`src/handlers/sessions.l`, `src/docker_manager.l`) | **S** | Solid core. Missing: managed-API sessions (see last row's dependency), background sweep (reap/jobs need an external poller), automated container e2e test. |
| Workspace profiles (zero ambient creds, egress allowlists, DNS logging) | **Partial**: profiles gate credential injection, network policy (none/restricted/full), tool enablement, skills/subagents/MCP servers (`src/handlers/profiles.l`, `src/network_policy.l`, `src/tool_policy.l`) | **M** | Default is full egress + all credentials-less-but-trusting; no DNS logging; egress allowlist requires operator-provisioned proxy network; tool enablement explicitly not a security boundary (`src/tool_policy.l` doc comment). |
| Credential-grant approval UX | **Partial**: per-request approve/deny with reason, SSE push to the open session view, pending panel, one-time delivery, audit rows (`src/handlers/callbacks.l:499-644`, `frontend/src/components/PendingCallbacksPanel.tsx`) | **M** | Approves release of *static long-lived* secrets, not issuance of scoped short-lived tokens (§5.2's broker model). No push notification when the app is closed, so approvals stall. No org/policy layer — every request prompts one human. |
| Kill switch | **Partial**: per-session cancel (`sessions.l:612`), per-session container restart/delete, idle reap | **M** | No global "stop everything / freeze tenant / refuse new runs" control, no panic disable of credential delivery, and cancel has a documented dead window before the container exists (`sessions.l:632-639`). 30-min run cap exists but is an *approximation* (compiler-bug workaround, `docker_manager.l:811-841`). |
| Event-history capture → checkpoint format (§4.1) | **Absent.** No Managed Agents API client (`sessions.events.list` appears nowhere; ADR-001 rejected that API). Harness output captured as one raw ANSI text blob per run (`sessions.l:565`); no structured tool-use events (`agent.mcp_tool_use` equivalent exists only for permission-gated calls via the shim); no step DAG, no hashes, no checkpoint format, no support for the Entire capture format (`entire/checkpoints/v1` — Entire is the third-party session-recording tool the architecture doc treats as a first-class capture source, §4.1) | **L** | This is the load-bearing §4.1 assumption and it is simply not there. The `runs` + `messages` + `permission_requests` tables are useful *inputs* to a future adapter, nothing more. |
| Posture signals (broker-conditional issuance, §5.2) | **Absent.** No device certs, no posture assertions, no OIDC federation. Nearest artifacts: whitelist auth, profile network policy, permission/secret audit rows | **L** | Everything here would be new build, not extension. |

---

## 6. Integration risks

1. **Stack mismatch is the first-order risk.** The architecture doc's §3.2
   ("All services TypeScript on the existing stack") and §5.2 ("PWA +
   Workers/KV… fit directly") do not describe this codebase. Absorbing
   cloud-agents as-is means the platform carries a Lyric/.NET service whose
   compiler has a live, workaround-requiring codegen bug (lyric-lang#6249)
   and a history of seven more; porting it means rewriting ~27k lines of
   backend Lyric (~23.6k `src/` + ~3.7k `shim/`) — at which point only the
   ~19k-line TypeScript frontend and the schema/UX design carry over
   directly. Either
   way, the "fits directly" claim in §5.2 should be struck; **the frontend
   and the interaction model are the reusable assets, the backend is a
   decision to make**.
2. **The §4.1 capture story needs a full adapter build, not a wire-up.**
   Distance from a durable capture pipeline:
   - *Source*: there is no structured event source. Either (a) build the
     Managed Agents API client the doc assumes (note ADR-001 rejected it for
     cost reasons — that conflict needs an explicit decision), or (b) capture
     from the self-hosted harnesses by switching to
     `--output-format stream-json` (claude) and equivalents and persisting
     per-event rows. Today's pipeline throws structure away at the
     entrypoint (`docker/entrypoint.sh:486`).
   - *Replay/pagination*: none. SSE frames are fire-and-forget to whoever is
     connected; a disconnected viewer falls back to polling a byte-offset log
     endpoint. There are no event sequence numbers, no consumer offsets.
   - *At-least-once*: explicitly not guaranteed — the callback-event cursors
     are strictly-greater timestamp comparisons documented as able to skip
     same-millisecond events ("benign by design" for UI refresh,
     `src/docker_manager.l:787-794` — the opposite of capture semantics).
     Webhook delivery is poll-and-ack but nothing consumes it in-repo.
   - *Storage/runtime*: single-file SQLite with a TEXT-only driver, WAL for
     single-VM concurrency (`src/db/sqlite_driver.l`,
     `docs/PROGRESS.md`), and full-container-log refetch on every poll tick.
     Fine for one user; a fleet-wide capture workload (per-event writes ×
     concurrent sessions × replay reads) needs the architecture doc's own
     answer — queue + Postgres — and the repo's authors already kept a
     `db_client`/`repository` seam for a PG swap (`docs/PROGRESS.md`).
     Verdict: **the current storage/runtime does not survive the capture
     workload; plan queue + PG from day one of the adapter.**
3. **Containment-plane posture is currently inverted from the platform's.**
   Open-by-default auth, full-egress default network policy, hostname-only
   SSRF checks, auto-trusted repo `.mcp.json` (ADR-007), pull-based
   maintenance with no scheduler in the box. All are documented, deliberate
   personal-scale trade-offs — but every one must flip to fail-closed before
   this fronts an enterprise containment plane.
4. **Approval latency**: with no server push (no Web Push, webhooks are
   poll-only), credential-grant and permission approvals only work while a
   human has the tab open; the shim's callback timeout then fails the tool
   call. For a control surface whose job is human-in-the-loop approvals,
   closed-app notification delivery is a functional gap, not polish.
5. **Operational single points**: one VM, one SQLite file, Docker socket
   access from the API process, `ENCRYPTION_KEY` in env. Backup script
   exists (`deploy/backup.sh`); no HA story (ADR-004 accepts this).

---

## 7. Recommended work packages (only what the assigned role needs)

Ordered; sizes S/M/L. 1–3 are decision-gating; 4–7 build the §4.1 adapter;
8–10 close the §5.2 gaps.

1. **(S) Strike/repair the architecture doc's cloud-agents claims.** Replace
   "PWA + Workers/KV" and "already consumes `sessions.events.list`" with this
   audit's findings; record the ADR-001 (managed API rejected for cost)
   vs §4.1 (managed API assumed) conflict as an open decision.
   *Acceptance: architecture doc §2/§4.1/§5.2 contain no claim this audit
   contradicts.*
2. **(M) Stack disposition ADR.** Decide: keep the Lyric backend as a
   supported non-TS service, or port the backend to TypeScript keeping the
   frontend + schemas. Include lyric-lang#6249 exposure and the toolchain
   bus-factor in the analysis.
   *Acceptance: ADR merged in `docs/DECISIONS.md` with a costed migration
   path; platform Phase-3 plan references it.*
3. **(S) Fail-closed auth default.** Require `CLOUD_AGENTS_API_TOKEN` or
   OAuth on all non-health/non-auth/non-callback routes; make open mode an
   explicit `CLOUD_AGENTS_ALLOW_UNAUTHENTICATED=1` opt-in.
   *Acceptance: on a clean deployment with no auth env vars,
   `GET /api/sessions` returns 401; e2e-http.sh covers it.*
4. **(M) Structured event capture from the harnesses.** Switch the claude
   entrypoint to `--output-format stream-json --include-partial-messages`
   (equivalents for codex/opencode/gemini where available), persist one row
   per event (`session_events`: run id, seq, type, payload JSON, hash of
   previous row) instead of/alongside the raw blob; keep the raw log for the
   UI.
   *Acceptance: after a real run, tool-use events (name + input) for that run
   are queryable in order via a new `GET /api/sessions/{id}/events?after=seq`
   with cursor pagination.*
5. **(M) Managed Agents API capture client** (if package 1's decision goes
   that way): poller for `sessions.events.list` with durable per-session
   cursor, pagination, retry with backoff, at-least-once spool writes
   deduped by event id — feeding the same `session_events` table as
   package 4 so downstream sees one shape.
   *Acceptance: against a recorded fixture stream, kill-and-restart of the
   poller yields every event exactly once in the spool.*
6. **(M) Checkpoint-format emitter.** Map `session_events` to the platform's
   `@platform/checkpoint-format` (Session → Step → Checkpoint, hash-chained),
   emitting per run; include cloud-agents' own audit rows
   (permission/secret decisions, profile, network policy) as step/session
   metadata — these are the posture signals §5.2 wants and they already
   exist as rows.
   *Acceptance: a fixture run round-trips through the checkpoint validator;
   the checkpoint references the run's permission decisions.*
7. **(M) Capture-grade storage path.** Move `session_events` + spool to
   Postgres (the repository seam exists) or, minimally, a dedicated
   append-only store with real integer columns and consumer offsets; keep
   SQLite for the personal-scale control-surface tables.
   *Acceptance: sustained ingest of N concurrent sessions × event stream
   with a lagging consumer replaying from offset 0, no loss, on the deploy
   topology.*
8. **(M) Global kill switch.** `POST /api/maintenance/freeze` (and per-tenant
   variant): terminate all running containers, refuse new runs and credential
   deliveries until unfrozen; surfaced as one button in the UI.
   *Acceptance: with two runs in flight, one call terminates both, subsequent
   `POST .../messages` returns 503, and pending secret polls return denied.*
9. **(M) Closed-app approval delivery.** Web Push (VAPID) from the server on
   `permission_request`/`secret_request`/`user_question` creation, wired to
   the existing service worker.
   *Acceptance: with the PWA installed and closed, creating a secret request
   shows an OS notification that deep-links to the approval panel.*
10. **(S) Default-deny egress option.** Config flag making `restricted` the
    default network policy for sessions without a profile.
    *Acceptance: with the flag set, a profile-less session's container gets
    the restricted network (or none), verified by the existing entrypoint
    tests plus a docker-level assertion in the manual e2e checklist.*

Explicitly **not** proposed (out of role scope): the broker itself (§5.2 says
cloud-agents is the broker *client*/control surface; the broker is a separate
new component), the policy MCP API (`check_package` etc. — new component),
devcontainer workspace profiles beyond what exists.
