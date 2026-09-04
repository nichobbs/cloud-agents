# Phase Progress

Status of each phase against its deliverables. See `docs/phaseN-*.md` for the
design of each phase and `docs/BUILD.md` for build/verification notes.

> **Build status:** `lyric build` now succeeds for the full project — all
> 12 packages — for the first time in this project's history, as of the
> v0.4.14 compiler. `scripts/verify.sh` also genuinely passes: all 24
> Phase 1–3 logic checks (SSE framing, state machine, recycling, SQL, auth)
> ran and succeeded for real. Every "✅ verified" label below is now backed
> by an actual successful compile and run, not just belief.
>
> **The server actually starts now** (`lyric run`/`scripts/run-api.sh`), for
> the first time in this project's history, as of the v0.4.17 compiler —
> at that point it could not yet serve a real request: `Lyric.Web` crashed
> on the first one it answered, and even without that crash didn't dispatch
> to this project's handlers yet. Both were root-caused, upstream
> `Lyric.Web` gaps, not compiler bugs. **Both are fixed as of the
> `Lyric.Web` 0.4.26 pin** — real request dispatch and request-header access
> now exist, and `src/main.l` was migrated to the new `Handler`/`Middleware`
> model accordingly, wiring in auth enforcement — see `docs/BUILD.md`
> "Dependencies" for detail, including the important caveat that this is
> confirmed by compiling and `repro-web-bug.sh`'s diagnostic, not yet by an
> automated end-to-end HTTP test (nichobbs/cloud-agents#354).
> Five upstream *compiler* bugs are now fixed in sequence, each only reachable once the
> last one was: bug 1 (`buildProject` crash,
> [lyric-lang#4925](https://github.com/nichobbs/lyric-lang/issues/4925),
> fixed in [v0.4.11](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.11)),
> bug 2 (`Std.Core`'s `Option`/`Result`/`Some`/`None`/`Ok`/`Err` never
> resolving, [lyric-lang#4980](https://github.com/nichobbs/lyric-lang/issues/4980),
> fixed in [v0.4.12](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.12)),
> bug 3 (NuGet-restored zero-arg functions rejected,
> [lyric-lang#5004](https://github.com/nichobbs/lyric-lang/issues/5004),
> fixed in [v0.4.14](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.14)),
> bug 4 (NuGet dependency DLLs not copied to the output directory,
> [lyric-lang#5066](https://github.com/nichobbs/lyric-lang/issues/5066),
> fixed in [v0.4.15](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.15)),
> and bug 5 (wrong cross-package field/method metadata tokens —
> root-caused to an `async func` awaiting an unqualified call into a
> *later*-declared package, exactly this project's `CloudAgents.Docker` →
> `Lyric.Docker` shape, corrupting token bookkeeping for every package
> declared in between,
> [lyric-lang#5177](https://github.com/nichobbs/lyric-lang/issues/5177),
> fixed in [v0.4.17](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.17)).
> `CloudAgents.DbTests` (the suite that used to hit bug 5's corruption
> directly) now passes 11/11.
>
> **A sixth upstream bug, unrelated to bug 5's package-order mechanism, is
> now fixed**: `slice[T].append(x)` — the compiler's own documented idiom
> for building up a slice — used to throw `"unsupported method 'append'"`
> at runtime unconditionally, for any element type, in complete isolation
> (no packages, no async). Not a regression — it had been broken since at
> least v0.4.15 — just never runtime-exercised in this project until bugs
> 1-5 stopped masking it. Filed as
> [lyric-lang#5244](https://github.com/nichobbs/lyric-lang/issues/5244),
> **fixed in [v0.4.18](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.18)** —
> `CloudAgents.AuthTests` now passes 5/5.
>
> **A seventh upstream bug, found while diagnosing the one
> `CloudAgents.SessionTests` case bug 6's fix didn't clear (`Test Handler
> createSession validation`, previously indistinguishable from bug 6's
> symptoms), is now also fixed**: a package-scope (top-level) `val` with no
> explicit type annotation, initialized to a string literal, used to crash
> `.length` at runtime with `System.InvalidCastException: Unable to cast
> object of type 'System.String' to type 'System.Collections.IList'` —
> same-package, unqualified, no cross-package reference needed. Root-caused
> (with direct access to `nichobbs/lyric-lang`) to
> `lyric-compiler/msil/codegen.l`'s package-level val/const pre-scan
> defaulting an untyped declaration's MSIL type to `MObject` instead of
> inferring it from the initializer, which routed `.length` through a
> fallback that assumed any object-typed receiver is a List-backed slice.
> `src/handlers/sessions.l`'s `createSession` reads exactly such a `val`
> (`httpsPrefix`), which is why that one test case used to fail. Filed as
> [lyric-lang#5298](https://github.com/nichobbs/lyric-lang/issues/5298),
> **fixed in [v0.4.19](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.19)** —
> distinct from
> [lyric-lang#5258](https://github.com/nichobbs/lyric-lang/issues/5258) (a
> related but different MSIL bug, fixed a day earlier, about *cross*-package
> qualified `pub val` access; that fix didn't cover this same-package,
> untyped-inference gap). **All seven known upstream compiler bugs are now
> fixed** — `lyric test` is 24/24 across every suite for the first time in
> this project's history. See `docs/BUILD.md` "Compiler notes"/"Running
> tests" for full detail and evidence.
>
> Building the full project for the first time also surfaced one genuine
> bug in this project's own source: `vendor/lyric-docker/src/docker.l`
> called a nonexistent `unwrapResult(x)` function instead of the documented
> `x.unwrap()` method, at four call sites — never caught before because the
> compiler always crashed before type-checking this file. Fixed.
>
> The dependency/package structure itself is confirmed correct — all 12
> packages (API + Web + Docker) now compile together, with Lyric.Web/
> Std.Logging as published NuGet binaries and `vendor/lyric-docker`
> compiled as an ordinary local package (the published `Lyric.Docker`
> package lacks the container-lifecycle API this project needs — see
> `docs/BUILD.md`).

## Phase 1 — Core Loop ✅ complete

| Deliverable | Status | Where |
|-------------|--------|-------|
| API server (routes + handlers) | ✅ | `src/main.l`, `src/handlers/sessions.l` |
| Container management | ✅ | `src/docker_manager.l` |
| Session store | ✅ | `src/sessions/session_manager.l` |
| **SSE streaming** | ✅ added | `src/streaming/streaming.l` (runtime-verified), wired into `sendMessage` |
| **Base Docker image** | ✅ added | `docker/Dockerfile`, `docker/entrypoint.sh` |
| **Streaming web frontend** | ✅ added | `frontend/index.html` (fetch + SSE + ansi_up) |
| **Credential mount documented** | ✅ added | `docs/credentials.md` |

## Phase 2 — Session Management 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| Session state machine | ✅ verified | `db_client.l` (`SessionStatus`, `SessionEvent`, `Transition`, `nextStatus`) — exhaustive, runtime-tested |
| Idle recycling decision | ✅ verified | `db_client.l` (`recycleDecision`, warm 5min / cold 1h windows) |
| Persistence SQL (owner-scoped) | ✅ verified | `db_client.l` (`insert/select/list/update/touch/delete/recover…Sql`) |
| SQLite schema | ✅ | `db_client.l` (`sessionsSchemaSql`) |
| Volume naming | ✅ | `db_client.l` (`workspaceVolumeBindFor`, `homeVolumeBindFor`, `homeMountPathForHarness`; the never-wired Phase-3 draft helpers were removed as dead code, #443) |
| Background sweep + concurrency control | ⬜ pending | needs `Std.Concurrency` + lyric-db wiring (runtime) |
| Multi-repo sessions | ✅ added | `session_repos` table (migration 0008), `db_client.l`/`repository.l` CRUD, `sessions.l` (`list/add/deleteSessionRepoHandler`, `extraReposEnvValue`), routes `GET/POST /api/sessions/{id}/repos` + `DELETE …/{rid}`; `EXTRA_REPOS` threaded through `docker_manager.l` to all four entrypoints (clone into `/workspace/repos/<name>`); frontend `LinkedReposPanel` — an agent can work across several checkouts in one run |

## Phase 3 — Multi-Tenancy & Security 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| Bearer token extraction | ✅ verified | `auth.l` (`extractBearerToken`) |
| Whitelist access control | ✅ verified | `auth.l` (`isWhitelisted`, `parseWhitelist`) — not covered by `scripts/verify.sh`, but `lyric test`'s `auth_tests.l` now passes since [lyric-lang#5244](https://github.com/nichobbs/lyric-lang/issues/5244) (`slice[String].append()`) was fixed in v0.4.18 |
| Validation cache (TTL) | ✅ added | SQLite-backed, keyed by token SHA-256 — `github_token_cache` (migration 0007), `repository.l` (`cacheGitHubToken`/`cachedGitHubToken`), exercised by `oauth_tests.l` |
| Ownership enforcement | ✅ verified | `auth.l` (`ownsResource`) |
| GitHub `/user` response parsing | ✅ verified | `auth.l` (`parseJsonString/Number`, `indexOfFrom`) |
| Identity model | ✅ | `GitHubUser`, `AuthError` |
| Live `api.github.com/user` call | ✅ added | `github_api.l` (`httpGetWithBearer`) — direct `HttpWebRequest` externs; `Std.Http`'s documented surface has no request-header support, so the BCL binding route (the same one `crypto.l`/`nowMillis` use) unblocked this |
| GitHub OAuth login (web flow) | ✅ added | `oauth.l` (`exchangeCode` via `POST /api/auth/github/exchange`, config via `GET /api/auth/github/config`), frontend `lib/auth.ts` + `pages/AuthCallback.tsx` + Nav sign-in/out |
| Per-request identity | ✅ added | `AuthMiddleware` stamps the authenticated user id thread-locally (`Auth.setCurrentUserId`); the async Docker path takes the owner explicitly since thread-locals don't flow to worker threads |
| Per-user volumes | ✅ added | `db_client.l` (`workspaceVolumeBindFor`, `homeVolumeBindFor`) wired into `docker_manager.l` — OAuth tenants get `user-<id>-<harness>-home` + `session-<id>-<sessionId>-workspace`; the operator `default` identity keeps the legacy shared names (see `docs/credentials.md`) |
| Encrypted credential upload | ✅ added | write-only vault (`POST /api/credentials`, AES-256 at rest); `scripts/upload-credentials.sh` auto-detects keys, and `--claude-home` bundles the `~/.claude` subscription (OAuth) login as a base64 tar.gz credential (`CLAUDE_HOME_TARBALL_B64`) the claude entrypoint unpacks onto a fresh home volume — the one auth state an env-var key can't carry. See `docs/credentials.md` |

> "verified" = compiles **and** runtime-tested via `scripts/verify.sh` (CI runs
> it on every push). With the OAuth rows above, requests bearing a GitHub
> OAuth token now resolve a real per-tenant identity (`gh-<id>`), whitelisted
> via `CLOUD_AGENTS_WHITELIST`; the static `CLOUD_AGENTS_API_TOKEN` scheme
> remains the single-operator fallback and unauthenticated deployments stay
> open (credential routes excepted) exactly as before.

## Phase 4 — GitHub Tools & Tool Packs 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| GitHub MCP config | ✅ | `seed/mcp-servers/github.json` (disabled by default), gated by the Library's per-server `enabled` flag — supersedes the old always-on `docker/mcp.json.template` Phase-4 rendering, retired in #764/#765 for bypassing that gate. As of #768, this is a url-transport entry pointing at GitHub's hosted MCP endpoint (`https://api.githubcopilot.com/mcp/`) with an `Authorization: Bearer ${GITHUB_TOKEN}` header, not `npx @modelcontextprotocol/server-github` — that npm package is deprecated upstream. The new per-server `headers` field it needed is threaded through `src/handlers/library.l`/`src/db/repository.l`/`src/db/db_client.l` and rendered per-harness in `docker/inject-library.sh` |
| Auto-approval settings | 🟡 | `docker/settings.json.template` |
| Tool pack images | 🟡 | `docker/Dockerfile.rust`, `docker/Dockerfile.data` |
| Frontend GitHub panels | ✅ added | `frontend/src/components/GitHubPanel.tsx` (per-session repo/PR/CI status), `frontend/src/pages/Repos.tsx` (repo browser), `frontend/src/lib/github.ts` — browser-side calls to `api.github.com` with a locally-connected token (`frontend/src/pages/Integrations.tsx`), since the Lyric backend has no outbound HTTPS |

## Phase 5 — Deployment & Monitoring 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| Compose topology | 🟡 | `deploy/docker-compose.yml`, `deploy/api.Dockerfile` |
| Reverse proxy + TLS | 🟡 | `deploy/Caddyfile` |
| VM provisioning | 🟡 | `deploy/install-docker.sh` |
| Backups | 🟡 | `deploy/backup.sh` |
| Runbook | 🟡 | `deploy/RUNBOOK.md` |
| Automated e2e HTTP smoke test | ✅ added | `scripts/e2e-http.sh` (wired into `ci.yml`) starts the built server on a throwaway DB/port and curls a multi-param route (`/api/sessions/{id}/output/{offset}`) plus the proxy routes — the automated proof of multi-param dispatch that `@test_module` can't give (Web.Request isn't constructible in a test, #354), closing #442 |

## Phase 8 — Scheduled jobs 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| `scheduled_jobs` table + CRUD | ✅ added | migration `0027_scheduled_jobs` (`db_client.l`/`repository.l`), `CloudAgents.Jobs` (`src/handlers/jobs.l`) |
| Maintenance trigger endpoint | ✅ added | `POST /api/maintenance/trigger-jobs` (`CloudAgents.Jobs.triggerDueJobsHandler`) — same "external scheduler polls a maintenance endpoint" idiom as container reaping/webhook delivery, since Lyric.Web has no in-process timer |
| Blocking (non-SSE) job run | ✅ added | `CloudAgents.Docker.runSessionMessageBlocking` — a no-live-viewer sibling of `streamSessionMessage` |
| `schedule_job`/`list_jobs`/`update_job`/`cancel_job` MCP tools | ✅ added | `shim/src/v2_transport.l`/`v2_client.l`/`v2_tools.l`/`main.l`; `schedule_job` always attaches the calling session, so "if it triggers again, continue this session" holds by construction |
| Tests | ✅ added | `tests/jobs_tests.l` (validation, owner scoping, schedule transitions, due-job scan) |
| Frontend panel | ⬜ not started | host + shim only in this phase, matching phases 6/7's own sequencing |

See `docs/phase8-scheduling.md` for the full design, including why a
cron-expression DSL was deliberately not built and the "compile-time only"
verification caveat (no `lyric` toolchain in the authoring environment —
same caveat class as several entries above before their own first real
compile).

## Phase 9 — Full-text message search ✅ complete

| Deliverable | Status | Where |
|-------------|--------|-------|
| `messages_fts` FTS5 index + sync trigger + backfill | ✅ added | migration `0028_message_search` (`db_client.l`/`repository.l`) |
| Safe MATCH-expression builder | ✅ added | `CloudAgents.Search.buildFts5MatchExpr` (`src/handlers/search.l`) — quoted-prefix tokens neutralize FTS5 query syntax, verified against the real vaulted SQLite build |
| `GET /api/search/messages?q=...` | ✅ added | `CloudAgents.Search.searchMessagesHandler`, owner-scoped via a join through `sessions` |
| Frontend search page | ✅ added | `frontend/src/pages/Search.tsx`, `api.searchMessages()`, nav entry |
| Tests | ✅ added | `tests/search_tests.l` (tokenizer/escaping, validation, matching, prefix search, cross-user isolation) |

See `docs/phase9-message-search.md` for the full design, including the
external `ctypes`-based verification of FTS5 availability and the escaping
scheme. Merged as PR #905, genuinely run through CI's real `lyric build`/
`lyric test` gate (unlike several earlier phases, which shipped
compile-time-only from an authoring environment with no local `lyric`
toolchain) — CI caught one real bug (a wrong hand-computed expected value in
`tests/search_tests.l`'s multi-word tokenizer test), fixed in the same PR,
confirmed green before merge.

## Phase 10 — Open PR (opt-in) 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| `POST /api/sessions/{id}/open-pr` | ✅ added | `CloudAgents.OpenPr.openPrHandler` (`src/handlers/open_pr.l`) — compare-then-dedup-then-create against GitHub's own API, no local checkout inspection needed |
| Pure compare/dedup/create decision | ✅ added | `CloudAgents.OpenPr.decidePrAction` — a `PrDecision` union (`Reject`/`Reuse`/`Create`), unit-tested independent of any network call |
| Frontend "Open PR" button | ✅ added | `frontend/src/components/GitHubPanel.tsx`, `api.openPr()` — server-side only, no direct-browser fallback |
| Tests | ✅ added | `tests/open_pr_tests.l` (URL parsing, the pure decision logic, and every pre-network-call validation path) |
| Automatic PR-on-run-finish | ⬜ not started | deliberately deferred — see `docs/phase10-auto-open-pr.md` §2 |

See `docs/phase10-auto-open-pr.md` for the full design, including why this
first version is an opt-in button rather than automatic (no `docker exec`
capability to verify a run actually pushed anything, plus the noisy-PR risk
of firing on every run). An attempt to install the `lyric` toolchain locally
this session hit a known session-level MCP connection issue (`add_repo`
requiring approval with no prompt surfaced), so this relies on CI's `Build &
verify` job for its actual compile — and that job's first pass on this PR
genuinely failed with a real error (a `val` name colliding with an
already-imported function of the same name from `CloudAgents.OAuth`), fixed
in a follow-up commit alongside two real review findings (an unvalidated
branch name reaching raw GitHub API URLs, and two wasted API calls on the
already-on-default-branch path) — see §6 of the phase doc for detail.

## Recent hardening (2026-07)

- **Live output streaming.** `POST /api/sessions/{id}/messages` now streams the
  container's output as real SSE `data:` frames while the run executes, using
  `Lyric.Web 0.4.33`'s chunked-response API (`StreamingHandler` +
  `startStreaming`; the feature this project filed upstream — see
  `docs/upstream/lyric-web-streaming.md`). `CloudAgents.Handlers.streamSendMessage`
  drives the run lifecycle and hands the `ResponseWriter` to
  `CloudAgents.Docker.streamSessionMessage`, which polls the container's
  logs-so-far and writes each delta, stopping (and terminating the container)
  when `writeChunk` reports the client disconnected. The old buffer-the-whole-
  run handler is gone; the `/output` + `/output/{offset}` polling endpoints are
  kept only as a pre-first-chunk bridge and older-client fallback (the frontend
  hook drops to real chunks the instant they arrive). NOTE: compile-verified in
  CI; the live run loop itself isn't exercised by CI (no Docker), so it's
  runtime-verified manually — same class as the #354/#442 caveat.
- **Model-listing cache (#446).** The models proxy now caches each provider's
  raw listing per `(user, provider)` for 1h in `model_listing_cache` (migration
  0009), so the sequential provider fetch cost is paid at most once per window
  instead of on every call — `db_client.l`/`repository.l`
  (`cachedModelListing`/`cacheModelListing`), consumed in
  `proxy.l` (`cachedOrFetchedModelsBody`). Best-effort: a cache read/write
  failure falls back to a live fetch.
- **Multi-repo cleanup (#460).** Unlinking a repo now removes its checkout from
  `/workspace/repos` on the next run (the entrypoints reconcile — clone linked,
  prune unlinked — rather than only ever adding), and the UI's "Remove" makes
  the on-disk consequence explicit.
- **SQLite concurrency (WAL).** `sqlite_driver.l` now applies
  `PRAGMA journal_mode=WAL` + `busy_timeout=5000` on every connection
  (best-effort): readers and a writer no longer block each other, and a held
  write lock makes a connection wait rather than failing with `SQLITE_BUSY`.
  This is the cheap single-node win from the SQLite review — the store stays
  SQLite (single-VM/personal scale); the `db_client.l`/`repository.l` seam keeps
  a Postgres driver swap feasible if multi-node/HA is ever needed, and the
  TEXT-only driver (not SQLite itself) is the bigger constraint to revisit
  first.

Legend: ✅ done · 🟡 in progress / scaffolded · ⬜ not started
