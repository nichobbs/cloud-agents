# Phase Progress

Status of each phase against its deliverables. See `docs/phaseN-*.md` for the
design of each phase and `docs/BUILD.md` for build/verification notes.

> **Build status:** `scripts/verify.sh` now genuinely passes — all 24
> Phase 1–3 logic checks (SSE framing, state machine, recycling, SQL, auth)
> ran and succeeded for real for the first time in this project's history,
> against the v0.4.12 compiler. Every "✅ verified" label below is now
> backed by an actual successful compile and run, not just belief.
>
> The **full project build** (`lyric build` at the repo root, which needs
> `main.l`'s `Web.create()` call) is still blocked by a third upstream bug —
> not something wrong with this project's manifest or source. Two prior
> bugs are fixed: bug 1 (`buildProject` crash,
> [lyric-lang#4925](https://github.com/nichobbs/lyric-lang/issues/4925)),
> fixed in [v0.4.11](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.11),
> and bug 2 (`Std.Core`'s `Option`/`Result`/`Some`/`None`/`Ok`/`Err` never
> resolving, [lyric-lang#4980](https://github.com/nichobbs/lyric-lang/issues/4980)),
> fixed in [v0.4.12](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.12)
> — that's what let `scripts/verify.sh` succeed above. Bug 3, still open: a
> zero-argument function restored from a NuGet package (`Web.create()`) is
> rejected as `"expected 1 argument(s), got 0"` even though it genuinely
> takes zero parameters — filed as
> [lyric-lang#5004](https://github.com/nichobbs/lyric-lang/issues/5004).
> See `docs/BUILD.md` "Compiler notes" for full detail, evidence, and
> current release status before assuming a local CI failure here needs a
> local fix.
>
> The dependency/package structure itself is believed correct and was the
> last thing verified working before bug 1 was discovered: all 12 packages
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
