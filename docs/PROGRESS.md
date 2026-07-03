# Phase Progress

Status of each phase against its deliverables. See `docs/phaseN-*.md` for the
design of each phase and `docs/BUILD.md` for build/verification notes.

> **Build status:** currently cannot be verified at all — **every released
> Lyric compiler (0.4.7 through 0.4.10) crashes on `lyric build`/`run`/
> `check`/`test` for any project**, not just this one. This is an upstream
> compiler bug, not something wrong with this project's manifest or source.
> Root cause is found and fixed upstream
> ([lyric-lang#4955](https://github.com/nichobbs/lyric-lang/pull/4955),
> merged) but not released yet — see `docs/BUILD.md` "Compiler notes" for
> detail and current release status before assuming a local CI failure
> here needs a local fix.
>
> The dependency/package structure itself is believed correct and was the
> last thing verified working before this was discovered: all 12 packages
> (API + Web + Docker), with Lyric.Web/Std.Logging as published NuGet
> binaries and `vendor/lyric-docker` compiled as an ordinary local package
> (the published `Lyric.Docker` package lacks the container-lifecycle API
> this project needs — see `docs/BUILD.md`).

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
| Volume naming | ✅ | `workspaceVolumeName`, `homeVolumeName` |
| Background sweep + concurrency control | ⬜ pending | needs `Std.Concurrency` + lyric-db wiring (runtime) |

## Phase 3 — Multi-Tenancy & Security 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| Bearer token extraction | ✅ verified | `auth.l` (`extractBearerToken`) |
| Whitelist access control | ✅ verified | `auth.l` (`isWhitelisted`, `parseWhitelist`) |
| Validation cache (TTL) | ✅ verified | `auth.l` (`CachedToken`, `cacheExpiry`, `isCacheValid`) |
| Ownership enforcement | ✅ verified | `auth.l` (`ownsResource`) |
| GitHub `/user` response parsing | ✅ verified | `auth.l` (`parseJsonString/Number`, `indexOfFrom`) |
| Identity model | ✅ | `GitHubUser`, `AuthError` |
| Live `api.github.com/user` call | ⬜ pending | needs `Std.Http` header support (runtime) |
| Encrypted credential upload | ⬜ pending | endpoint + encryption |

> "verified" = compiles **and** runtime-tested via `scripts/verify.sh` (CI runs
> it on every push). The pending items are no longer blocked by the toolchain
> (Docker/Web/HTTP now build via NuGet — see `docs/BUILD.md`); they still need
> to be implemented and wired into the live HTTP handlers. **The route
> handlers in `src/handlers/sessions.l` and `src/handlers/interactions.l`
> currently call none of the `auth.l` helpers, so every endpoint is
> unauthenticated in the current codebase** — treat Phase 3 as not started
> from a security standpoint regardless of the table above.

## Phase 4 — GitHub Tools & Tool Packs 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| GitHub MCP config | 🟡 | `docker/mcp.json.template` + entrypoint rendering |
| Auto-approval settings | 🟡 | `docker/settings.json.template` |
| Tool pack images | 🟡 | `docker/Dockerfile.rust`, `docker/Dockerfile.data` |
| Frontend GitHub panels | ⬜ pending | frontend work |

## Phase 5 — Deployment & Monitoring 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| Compose topology | 🟡 | `deploy/docker-compose.yml`, `deploy/api.Dockerfile` |
| Reverse proxy + TLS | 🟡 | `deploy/Caddyfile` |
| VM provisioning | 🟡 | `deploy/install-docker.sh` |
| Backups | 🟡 | `deploy/backup.sh` |
| Runbook | 🟡 | `deploy/RUNBOOK.md` |

Legend: ✅ done · 🟡 in progress / scaffolded · ⬜ not started
