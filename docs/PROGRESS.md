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
| Volume naming | ✅ | `workspaceVolumeName`, `homeVolumeName` |
| Background sweep + concurrency control | ⬜ pending | needs `Std.Concurrency` + lyric-db wiring (runtime) |

## Phase 3 — Multi-Tenancy & Security 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| Bearer token extraction | ✅ verified | `auth.l` (`extractBearerToken`) |
| Whitelist access control | ✅ verified | `auth.l` (`isWhitelisted`, `parseWhitelist`) — not covered by `scripts/verify.sh`, but `lyric test`'s `auth_tests.l` now passes since [lyric-lang#5244](https://github.com/nichobbs/lyric-lang/issues/5244) (`slice[String].append()`) was fixed in v0.4.18 |
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
| Frontend GitHub panels | ✅ added | `frontend/src/components/GitHubPanel.tsx` (per-session repo/PR/CI status), `frontend/src/pages/Repos.tsx` (repo browser), `frontend/src/lib/github.ts` — browser-side calls to `api.github.com` with a locally-connected token (`frontend/src/pages/Integrations.tsx`), since the Lyric backend has no outbound HTTPS |

## Phase 5 — Deployment & Monitoring 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| Compose topology | 🟡 | `deploy/docker-compose.yml`, `deploy/api.Dockerfile` |
| Reverse proxy + TLS | 🟡 | `deploy/Caddyfile` |
| VM provisioning | 🟡 | `deploy/install-docker.sh` |
| Backups | 🟡 | `deploy/backup.sh` |
| Runbook | 🟡 | `deploy/RUNBOOK.md` |

Legend: ✅ done · 🟡 in progress / scaffolded · ⬜ not started
