# Phase Progress

Status of each phase against its deliverables. See `docs/phaseN-*.md` for the
design of each phase and `docs/BUILD.md` for build/verification notes.

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
| Session state machine | 🟡 enum + transitions | `src/db/db_client.l` (`SessionStatus`, `hasLiveContainer`) |
| SQLite schema | 🟡 DDL | `src/db/db_client.l` (`sessionsSchemaSql`) |
| Volume naming | 🟡 | `workspaceVolumeName`, `homeVolumeName` |
| Idle recycling / concurrency control | ⬜ pending | needs `Std.Concurrency` + background timer |

## Phase 3 — Multi-Tenancy & Security 🟡 started

| Deliverable | Status | Where |
|-------------|--------|-------|
| Bearer token extraction | 🟡 | `src/handlers/auth.l` (`extractBearerToken`) |
| Whitelist / ownership checks | 🟡 | `isWhitelisted`, `parseWhitelist` |
| Identity model | 🟡 | `GitHubUser`, `AuthError` |
| GitHub `/user` validation + cache | ⬜ pending | needs `Std.Http` header support |
| Encrypted credential upload | ⬜ pending | endpoint + encryption |

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
