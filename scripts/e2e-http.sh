#!/usr/bin/env bash
# End-to-end HTTP smoke test: start the built server against Postgres on a
# local port, wait for it to answer, and curl a handful of routes — including a
# MULTI-PARAM route (/api/sessions/{id}/output/{offset}) and the proxy routes,
# which @test_module suites can't exercise because Lyric's Web.Request can't be
# constructed in a test (nichobbs/cloud-agents#354). This is the automated
# proof that multi-param route dispatch works, closing the verification gap #442
# tracks. None of the asserted endpoints touch Docker, so no daemon is needed.
#
# Assumes `scripts/build-full.sh` has already produced bin/CloudAgents.dll (CI
# runs it earlier in the same job); this script only runs it.
#
# Postgres (docs/phase11-postgres-tenancy.md): takes the DSNs from the
# environment and needs `psql` on PATH to seed and inspect rows.
#   LYRIC_CONFIG_DB_CONNECTION_URL     (required) cloudagents_app service DSN, a
#                                      postgres:// URI. The server exits at
#                                      startup without it.
#   CLOUD_AGENTS_MIGRATE_DATABASE_URL  (optional) cloudagents_owner DSN. When
#                                      set, `dotnet bin/CloudAgents.dll --migrate`
#                                      runs first; otherwise the database must
#                                      already be migrated.
# The rows this script seeds use fixed ids and are removed again on exit (and
# before seeding, in case an earlier run was killed), so it is safe to point at
# a scratch database, never at one holding real data.
#
# Exit 0 = all assertions passed. Non-zero = a failure (server log is dumped).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/bin/CloudAgents.dll"
PORT="${E2E_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"

command -v curl   >/dev/null || { echo "e2e-http: 'curl' not on PATH"   >&2; exit 1; }
command -v dotnet >/dev/null || { echo "e2e-http: 'dotnet' not on PATH" >&2; exit 1; }
[ -f "$OUT" ] || { echo "e2e-http: $OUT not found — run scripts/build-full.sh first" >&2; exit 1; }

if [ -z "${LYRIC_CONFIG_DB_CONNECTION_URL:-}" ]; then
  echo "e2e-http: LYRIC_CONFIG_DB_CONNECTION_URL is not set (the cloudagents_app Postgres DSN); the server cannot start without it" >&2
  exit 1
fi
command -v psql >/dev/null || { echo "e2e-http: 'psql' not on PATH (needed to seed and inspect Postgres rows)" >&2; exit 1; }
PGURL="$LYRIC_CONFIG_DB_CONNECTION_URL"

# Run SQL on stdin as cloudagents_app with a tenant/user scope (session-level
# GUCs, which the RLS policies read through current_setting). Usage:
#   pg_scoped <tenant-id> <user-id>  < sql
pg_scoped() {
  PGOPTIONS="-c app.current_tenant=$1 -c app.current_user=$2" \
    psql "$PGURL" -X -q -At -v ON_ERROR_STOP=1
}

# Fixed ids for every row this script seeds; the personal tenant of a user is
# `personal:<user id>` (CloudAgents.Pg.personalTenantId).
SEEDED_SESSION_ID="e2e-seeded-session"
SEEDED_USER="e2e-seeded-user"
LEDGER_SESSION_ID="e2e-ledger-session"
LEDGER_USER="default"

seed_cleanup() {
  psql "$PGURL" -X -q -At -c "DELETE FROM session_routes WHERE session_id IN ('${SEEDED_SESSION_ID}', '${LEDGER_SESSION_ID}')" >/dev/null 2>&1 || true
  local tbl
  for pair in "personal:${SEEDED_USER}|${SEEDED_USER}|${SEEDED_SESSION_ID}" "personal:${LEDGER_USER}|${LEDGER_USER}|${LEDGER_SESSION_ID}"; do
    IFS='|' read -r tenant user sid <<<"$pair"
    for tbl in permission_requests notifications ledger_entries ledger_items ledger_transitions ledger_sessions; do
      echo "DELETE FROM ${tbl} WHERE session_id = '${sid}';" | pg_scoped "$tenant" "$user" >/dev/null 2>&1 || true
    done
    echo "DELETE FROM sessions WHERE id = '${sid}';" | pg_scoped "$tenant" "$user" >/dev/null 2>&1 || true
  done
}

LOG="$(mktemp -t cloud-agents-e2e-log-XXXXXX)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  seed_cleanup
  rm -f "$LOG"
}
trap cleanup EXIT

if [ -n "${CLOUD_AGENTS_MIGRATE_DATABASE_URL:-}" ]; then
  echo "==> applying migrations (--migrate)"
  dotnet "$OUT" --migrate
fi
seed_cleanup

echo "==> starting server on ${BASE}"
# Run with a STATIC API token configured (auth-enforced mode) so this harness
# can prove AuthMiddleware protects every non-exempt route — including the
# STREAMING send route, which moved onto a separate StreamingRoutes table and
# whose middleware coverage was otherwise only asserted in a code comment
# (#482). Auth-exempt routes (/api/health, /api/auth/*) still answer without a
# token; everything else needs the bearer. The port is driven through main.l's
# own mechanism: it reads --port (and, belt-and-suspenders, the
# LYRIC_CONFIG_WEB_SERVER_PORT env it ultimately sets) — no --urls, which
# main.l's argument parser never reads (#467). The host defaults to all
# interfaces, which 127.0.0.1 below reaches.
TOKEN="e2e-smoke-token"
export CLOUD_AGENTS_API_TOKEN="$TOKEN"
export LYRIC_CONFIG_WEB_SERVER_PORT="$PORT"
dotnet "$OUT" --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!

wait_healthy() {
  local ready=0
  for _ in $(seq 1 60); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "e2e-http: server exited during startup" >&2
      sed -e 's/^/  /' "$LOG" >&2
      exit 1
    fi
    code=$(curl -sS --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "${BASE}/api/health" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then ready=1; break; fi
    sleep 1
  done
  if [ "$ready" != "1" ]; then
    echo "e2e-http: server did not become healthy within 60s" >&2
    sed -e 's/^/  /' "$LOG" >&2
    exit 1
  fi
}
wait_healthy
echo "==> server is healthy"

fails=0
# assert <desc> <method> <path> <auth:yes|no> <want-code> <want-substr> [body] [org]
# Sends the bearer only when <auth> is "yes"; sends a JSON body when provided,
# and the X-CloudAgents-Org header when <org> is given.
assert() {
  local desc="$1" method="$2" path="$3" auth="$4" want_code="$5" want_sub="$6" body="${7:-}" org="${8:-}"
  # --max-time bounds every request so a bug in the (brand-new) middleware ->
  # streaming-handler hand-off that hangs the response fails the job fast
  # instead of stalling CI for hours (#494). These endpoints all answer in
  # milliseconds; 20s is pure slack.
  local args=(-sS --connect-timeout 5 --max-time 20 -X "$method" -w $'\n%{http_code}')
  [ "$auth" = "yes" ] && args+=(-H "Authorization: Bearer ${TOKEN}")
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data "$body")
  [ -n "$org" ] && args+=(-H "X-CloudAgents-Org: ${org}")
  local out code out_body
  out=$(curl "${args[@]}" "${BASE}${path}" 2>/dev/null || printf '\n000')
  code="${out##*$'\n'}"
  out_body="${out%$'\n'*}"
  if [ "$code" != "$want_code" ]; then
    echo "FAIL ${desc}: expected HTTP ${want_code}, got ${code} — body: ${out_body}" >&2
    fails=$((fails + 1)); return
  fi
  case "$out_body" in
    *"$want_sub"*) echo "ok   ${desc} (HTTP ${code})" ;;
    *) echo "FAIL ${desc}: body missing '${want_sub}' — got: ${out_body}" >&2; fails=$((fails + 1)) ;;
  esac
}

# Auth-exempt routes answer without a bearer.
assert "health"                        GET  "/api/health"                           no  200 "status"
assert "oauth config (auth-exempt)"    GET  "/api/auth/github/config"               no  200 "configured"
# A non-exempt route with NO bearer must be rejected by AuthMiddleware (auth is
# configured) — proves the middleware is actually enforcing.
assert "output route rejects no-auth"  GET  "/api/sessions/x/output/0"              no  401 ""
# THE point of this harness (#442/#354): a two-path-param route dispatching at
# all. With a valid bearer, an unknown session => 404 JSON. A 500, blank body,
# or route miss would mean multi-param matching is broken.
assert "multi-param output route"      GET  "/api/sessions/does-not-exist/output/0" yes 404 "Session"
# Proxy routes with an empty vault => 404 JSON (the frontend's fall-back signal),
# proving they dispatch and short-circuit cleanly (no crash, no outbound call).
assert "github repos proxy (no vault)" GET  "/api/github/repos/1"                   yes 404 "vault"
assert "models proxy (no vault keys)"  GET  "/api/models/claude"                    yes 404 "vault"
# STREAMING send route (#482): it moved onto the StreamingRoutes table, so verify
# AuthMiddleware still runs for it (rejects no-auth) AND that a valid bearer
# dispatches THROUGH the middleware into the streaming handler (unknown session
# => the handler's pre-stream 404). Together these prove the middleware->
# streaming-handler hand-off works and the route is auth-enforced. No Docker is
# reached (the 404 is returned before any container work).
assert "streaming send rejects no-auth" POST "/api/sessions/x/messages"              no  401 ""                 '{"text":"hi"}'
assert "streaming send dispatches (auth)" POST "/api/sessions/does-not-exist/messages" yes 404 "Session" '{"text":"hi"}'

# Session container restart endpoint
assert "restart container rejects no-auth" POST "/api/sessions/x/restart"             no  401 ""
assert "restart container dispatches (auth)" POST "/api/sessions/does-not-exist/restart" yes 404 "Session"

# Organisations (docs/phase11-postgres-tenancy.md §5.2, §6.4): the active
# organisation comes from X-CloudAgents-Org and must be one the caller belongs to.
assert "orgs list (auth)"              GET  "/api/orgs"                             yes 200 '"personal":"personal:default"'
assert "orgs list rejects no-auth"     GET  "/api/orgs"                             no  401 ""
assert "unknown org header refused"    GET  "/api/prompts"                          yes 403 "organisation" "" "native:not-a-member"
org_body=$(curl -sS --connect-timeout 5 --max-time 20 -X POST -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" --data '{"name":"e2e org"}' "${BASE}/api/orgs" 2>/dev/null || true)
org_id=$(printf '%s' "$org_body" | sed -n 's/.*"id":"\(native:[^"]*\)".*/\1/p')
if [ -z "$org_id" ]; then
  echo "FAIL create org: no native organisation id in: ${org_body}" >&2
  fails=$((fails + 1))
else
  echo "ok   create org (${org_id})"
  assert "member org header accepted"  GET  "/api/prompts"                          yes 200 "prompts" "" "$org_id"
  assert "org members"                 GET  "/api/orgs/${org_id}/members"           yes 200 '"role":"owner"'
fi

# ── cloud-agents-shim integration leg (#531) ─────────────────────────────────
# Drive the REAL shim binary (shim/bin, built by the CI step before this
# script) over genuine MCP stdio against the REAL server above: initialize
# handshake, then a tools/call request_permission whose HTTP POST hits the
# live callback endpoint for a session that does not exist. The server
# rejects it (404 — the session-existence check runs before the bearer
# comparison, so the invalid token below is never what fires), and the
# shim's fail-closed path must surface a deny payload — this exercises
# transport.l's actual HTTP boundary (URL handling, request write, response
# read) end to end, which the in-memory FakeTransport suites deliberately do
# not. The two seeded-session legs below (#541) reach the other half of
# authorizeCallbackToken this 404 leg cannot: a session that DOES exist and
# DOES have a token. The full allowed-path round trip (a human answering the
# pending request) still needs a live UI interaction and stays manual.
SHIM_OUT="$REPO_ROOT/shim/bin/cloud-agents-shim.dll"
if [ ! -f "$SHIM_OUT" ]; then
  echo "e2e-http: $SHIM_OUT not found — run 'lyric build --manifest shim/lyric.toml' first" >&2
  exit 1
fi
shim_stdout="$(timeout 60 env \
    CLOUD_AGENTS_API_URL="$BASE" \
    CLOUD_AGENTS_CALLBACK_TOKEN="e2e-invalid-token" \
    CLOUD_AGENTS_SESSION_ID="e2e-session" \
    CLOUD_AGENTS_CALLBACK_TIMEOUT_MS=5000 \
    dotnet "$SHIM_OUT" <<'MCP' || true
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e-http","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_permission","arguments":{"tool_name":"Bash","input":{"command":"ls"}}}}
MCP
)"
case "$shim_stdout" in
  *'"protocolVersion"'*) echo "ok   shim: MCP initialize handshake over stdio" ;;
  *) echo "FAIL shim: no initialize response — got: ${shim_stdout}" >&2; fails=$((fails + 1)) ;;
esac
case "$shim_stdout" in
  *'deny'*) echo "ok   shim: live-server rejection (404 unknown session) fails closed (deny)" ;;
  *) echo "FAIL shim: tools/call did not fail closed — got: ${shim_stdout}" >&2; fails=$((fails + 1)) ;;
esac

# ── seeded-session legs (#541) ────────────────────────────────────────────────
# Seed a REAL session + callback token directly into Postgres (the schema is
# the migrated one, src/pg/schema.l). A session is a tenant-owned `sessions`
# row (RLS on app.current_tenant, so it is inserted under the owner's personal
# tenant scope) plus a global `session_routes` row, which is what the callback
# path reads before any tenant is known and where the token hash lives. Only
# the token's lowercase hex SHA-256 is stored (CloudAgents.Auth
# .hashCallbackToken); the shim presents the raw token and the server hashes
# it before a constant-time compare. So the seed computes the hash with
# sha256sum and INSERTs that, while the shim below is handed the raw token.
#
# This drives the other half of authorizeCallbackToken the 404 leg above
# can't reach:
#   (a) wrong bearer against a session that DOES have a token -> 401 -> deny,
#       and — the actual point — no permission_requests row is created,
#       because `authorizeCallbackToken(id, authHeaderValue)?` short-circuits
#       before createPermissionRequest ever runs.
#   (b) the RIGHT bearer -> the request genuinely gets created (a real
#       pending row), then nobody answers it, so it times out. This leg sets
#       CLOUD_AGENTS_CALLBACK_TIMEOUT_MS=1000 for the shim's own client-side
#       deadline; the #540 wall-clock fix in shim/src/callbacks_client.l is
#       what makes this leg fast (~1s) instead of ~25s — the shim's poll
#       cadence (main.l's defaultPollIntervalMs) is a hardcoded 25s, and the
#       pre-#540 iteration-count timeout logic would sleep a full interval in
#       REAL wall-clock time before ever re-checking a 1000ms budget.
# seed_session <session-id> <user-id> <repo-url> <status> <token-hash>
seed_session() {
  local sid="$1" user="$2" repo="$3" status="$4" hash="$5" tenant="personal:$2"
  psql "$PGURL" -X -q -At -v ON_ERROR_STOP=1 <<SQL
INSERT INTO tenants (id, name, kind) VALUES ('${tenant}', '${user}', 'personal') ON CONFLICT (id) DO NOTHING;
INSERT INTO session_routes (session_id, tenant_id, user_id, callback_token_hash)
VALUES ('${sid}', '${tenant}', '${user}', '${hash}');
SQL
  pg_scoped "$tenant" "$user" <<SQL
INSERT INTO sessions (
  id, user_id, repo_url, branch, container_id, harness, model,
  native_session_id, status, created_at, last_message_at
) VALUES (
  '${sid}', '${user}', '${repo}', 'main', '',
  'claude', 'claude-opus-4-8', '', '${status}', now(), now()
);
SQL
}

SEEDED_TOKEN="e2e-seeded-callback-token"
command -v sha256sum >/dev/null || { echo "e2e-http: 'sha256sum' not on PATH (needed to hash the seeded callback token)" >&2; exit 1; }
SEEDED_TOKEN_HASH="$(printf '%s' "$SEEDED_TOKEN" | sha256sum | cut -d' ' -f1)"
seed_session "$SEEDED_SESSION_ID" "$SEEDED_USER" 'https://example.com/repo.git' RUNNING "$SEEDED_TOKEN_HASH"

permission_request_count() {
  echo "SELECT COUNT(*) FROM permission_requests WHERE session_id = '${SEEDED_SESSION_ID}';" | pg_scoped "personal:${SEEDED_USER}" "$SEEDED_USER"
}

# (a) Wrong bearer.
wrong_bearer_stdout="$(timeout 60 env \
    CLOUD_AGENTS_API_URL="$BASE" \
    CLOUD_AGENTS_CALLBACK_TOKEN="wrong-token-entirely" \
    CLOUD_AGENTS_SESSION_ID="$SEEDED_SESSION_ID" \
    CLOUD_AGENTS_CALLBACK_TIMEOUT_MS=5000 \
    dotnet "$SHIM_OUT" <<'MCP' || true
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e-http","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_permission","arguments":{"tool_name":"Bash","input":{"command":"ls"}}}}
MCP
)"
case "$wrong_bearer_stdout" in
  *'deny'*) echo "ok   shim: wrong bearer against a known session fails closed (401 -> deny)" ;;
  *) echo "FAIL shim: wrong-bearer tools/call did not deny — got: ${wrong_bearer_stdout}" >&2; fails=$((fails + 1)) ;;
esac

wrong_bearer_count="$(permission_request_count)"
if [ "$wrong_bearer_count" = "0" ]; then
  echo "ok   shim: wrong bearer created no permission_requests row (count=0)"
else
  echo "FAIL shim: wrong bearer unexpectedly created a permission_requests row (count=${wrong_bearer_count})" >&2
  fails=$((fails + 1))
fi

# (b) Right bearer, short client-side timeout.
right_bearer_stdout="$(timeout 60 env \
    CLOUD_AGENTS_API_URL="$BASE" \
    CLOUD_AGENTS_CALLBACK_TOKEN="$SEEDED_TOKEN" \
    CLOUD_AGENTS_SESSION_ID="$SEEDED_SESSION_ID" \
    CLOUD_AGENTS_CALLBACK_TIMEOUT_MS=1000 \
    dotnet "$SHIM_OUT" <<'MCP' || true
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e-http","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_permission","arguments":{"tool_name":"Bash","input":{"command":"ls"}}}}
MCP
)"
case "$right_bearer_stdout" in
  *'timed out'*) echo "ok   shim: right bearer creates the request, then times out (deny) once nothing answers it" ;;
  *) echo "FAIL shim: right-bearer tools/call did not report a timeout deny — got: ${right_bearer_stdout}" >&2; fails=$((fails + 1)) ;;
esac

right_bearer_count="$(permission_request_count)"
if [ "$right_bearer_count" = "1" ]; then
  echo "ok   shim: right bearer created exactly one permission_requests row (count=1)"
else
  echo "FAIL shim: right bearer did not create exactly one permission_requests row (count=${right_bearer_count})" >&2
  fails=$((fails + 1))
fi

# ── Session ledger leg (docs/session-ledger.md) ──────────────────────────────
# The agent side through the REAL shim (ledger_* tools -> the callback route
# -> tolerant argument decoding -> the {ok,error,reply} envelope), then the
# owner side over HTTP (snapshot, owner scoping, a rejection), then the agent
# collecting that rejection exactly once. The session is owned by "default",
# the identity the operator bearer ($TOKEN) resolves to.
LEDGER_TOKEN="e2e-ledger-callback-token"
LEDGER_TOKEN_HASH="$(printf '%s' "$LEDGER_TOKEN" | sha256sum | cut -d' ' -f1)"
seed_session "$LEDGER_SESSION_ID" "$LEDGER_USER" 'https://github.com/acme/shop' IDLE "$LEDGER_TOKEN_HASH"

ledger_shim() {
  timeout 60 env \
    CLOUD_AGENTS_API_URL="$BASE" \
    CLOUD_AGENTS_CALLBACK_TOKEN="$LEDGER_TOKEN" \
    CLOUD_AGENTS_SESSION_ID="$LEDGER_SESSION_ID" \
    dotnet "$SHIM_OUT" || true
}

ledger_stdout="$(ledger_shim <<'MCP'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e-http","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ledger_register_items","arguments":{"items":["#1",{"id":"acme/shop#2","title":"Use the schema"}]}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ledger_set_item_status","arguments":{"item":"#1","state":"in_progress"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ledger_record_deviation","arguments":{"kind":"shortcut","summary":"Skipped a flaky test","reversible":true,"item":"#1","recommendation":"Quarantine it"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ledger_set_item_status","arguments":{"item":"#2","state":"blocked","reason":"Needs #1","blockedBy":"#1"}}}
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ledger_set_item_status","arguments":{"item":"#2","state":"done"}}}
MCP
)"
case "$ledger_stdout" in
  *'\"registered\":\"2\"'*) echo "ok   ledger: register_items via the shim" ;;
  *) echo "FAIL ledger: register_items — got: ${ledger_stdout}" >&2; fails=$((fails + 1)) ;;
esac
case "$ledger_stdout" in
  *'\"severity\":\"review\"'*) echo "ok   ledger: a shortcut is raised to review" ;;
  *) echo "FAIL ledger: shortcut severity — got: ${ledger_stdout}" >&2; fails=$((fails + 1)) ;;
esac
case "$ledger_stdout" in
  *'cannot move gh:acme/shop#2 from blocked to done'*'"isError":true'*) echo "ok   ledger: an illegal move is an in-band tool error" ;;
  *) echo "FAIL ledger: illegal move — got: ${ledger_stdout}" >&2; fails=$((fails + 1)) ;;
esac

BLOCKER_NOTES="$(echo "SELECT COUNT(*) FROM notifications WHERE session_id = '${LEDGER_SESSION_ID}' AND level = 'blocked' AND summary LIKE '%Needs #1%';" | pg_scoped "personal:${LEDGER_USER}" "$LEDGER_USER")"
if [ "$BLOCKER_NOTES" = "1" ]; then
  echo "ok   ledger: a blocker notifies the owner"
else
  echo "FAIL ledger: blocker notification — found ${BLOCKER_NOTES} matching notification rows" >&2; fails=$((fails + 1))
fi

assert "ledger snapshot (owner)"       GET  "/api/sessions/${LEDGER_SESSION_ID}/ledger"       yes 200 '"blockingCount":"1"'
assert "ledger rejects no-auth"        GET  "/api/sessions/${LEDGER_SESSION_ID}/ledger"       no  401 ""
assert "ledger is owner-scoped"        GET  "/api/sessions/${SEEDED_SESSION_ID}/ledger"       yes 404 "Session"
assert "ledger inbox"                  GET  "/api/ledger/inbox"                               yes 200 "Skipped a flaky test"
# GitHub sync (Phase 3): the owner here has no connected GitHub account, so
# both routes reach the token lookup and report it without calling GitHub.
assert "ledger sync is owner-scoped"   POST "/api/sessions/${SEEDED_SESSION_ID}/ledger/sync"  yes 404 "Session"
assert "ledger sync needs GitHub"      POST "/api/sessions/${LEDGER_SESSION_ID}/ledger/sync"  yes 400 "reconnect GitHub"
assert "ledger maintenance sync"       POST "/api/maintenance/ledger-sync"                    yes 200 "reconnect GitHub"
assert "ledger maintenance sync auth"  POST "/api/maintenance/ledger-sync"                    no  401 ""
# Observer (Phase 4): this session's profile has no observer, so it reports
# disabled and refuses Observe now; the sweep runs (nothing due); a callback
# with a non-observer session's own token is refused as not an observer.
assert "observer status (not observed)" GET  "/api/sessions/${LEDGER_SESSION_ID}/ledger/observer" yes 200 '"enabled":"false"'
assert "observe now needs an observer"  POST "/api/sessions/${LEDGER_SESSION_ID}/ledger/observe"  yes 400 "no observer"
assert "observer status is owner-scoped" GET "/api/sessions/${SEEDED_SESSION_ID}/ledger/observer" yes 404 "Session"
assert "observer maintenance sweep"     POST "/api/maintenance/observe"                        yes 200 '"passes":"0"'
assert "observer maintenance auth"      POST "/api/maintenance/observe"                        no  401 ""
OBS_CODE="$(curl -sS --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer ${LEDGER_TOKEN}" -H 'Content-Type: application/json' --data '{}' "${BASE}/api/sessions/${LEDGER_SESSION_ID}/callbacks/observer/window" || true)"
if [ "$OBS_CODE" = "404" ]; then
  echo "ok   observer callbacks refuse a session that observes nothing (HTTP 404)"
else
  echo "FAIL observer callback on a non-observer: expected 404, got ${OBS_CODE}" >&2; fails=$((fails + 1))
fi
SHORTCUT_ID="$(echo "SELECT id FROM ledger_entries WHERE session_id = '${LEDGER_SESSION_ID}' AND kind = 'shortcut';" | pg_scoped "personal:${LEDGER_USER}" "$LEDGER_USER")"
assert "ledger reject needs a body"    POST "/api/sessions/${LEDGER_SESSION_ID}/ledger/entries/${SHORTCUT_ID}/review" yes 400 "body is required" '{"kind":"reject","body":""}'
assert "ledger reject"                 POST "/api/sessions/${LEDGER_SESSION_ID}/ledger/entries/${SHORTCUT_ID}/review" yes 200 '"kind":"reject"' '{"kind":"reject","body":"Do not skip it"}'

feedback_stdout="$(ledger_shim <<'MCP'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e-http","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ledger_check_feedback","arguments":{}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ledger_check_feedback","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ledger_set_item_status","arguments":{"item":"#1","state":"done"}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ledger_get_state"}}
MCP
)"
case "$feedback_stdout" in
  *'Do not skip it'*'\"feedback\":[]'*) echo "ok   ledger: feedback is delivered to the agent exactly once" ;;
  *) echo "FAIL ledger: feedback delivery — got: ${feedback_stdout}" >&2; fails=$((fails + 1)) ;;
esac
case "$feedback_stdout" in
  *'"id":5'*'\"openForReview\"'*) echo "ok   ledger: a tool call with no arguments works through the real MCP server" ;;
  *) echo "FAIL ledger: no-arguments call — got: ${feedback_stdout}" >&2; fails=$((fails + 1)) ;;
esac
case "$feedback_stdout" in
  *'\"unblocked\":[\"gh:acme/shop#2\"]'*) echo "ok   ledger: finishing #1 auto-unblocks #2" ;;
  *) echo "FAIL ledger: auto-unblock — got: ${feedback_stdout}" >&2; fails=$((fails + 1)) ;;
esac

# ── Auth modes without a static token (docs/CAPABILITY_AUDIT.md §2.2) ───────
# Restart the server with CLOUD_AGENTS_API_TOKEN unset in each remaining mode.
# No request below carries a bearer, so none reaches GitHub: the OAuth client
# id/secret are placeholders that only make oauthConfigured() true.
# restart_server VAR=VALUE... — the given variables are set for the new
# server process only; CLOUD_AGENTS_API_TOKEN is always unset.
restart_server() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  (
    unset CLOUD_AGENTS_API_TOKEN
    for kv in "$@"; do export "$kv"; done
    exec dotnet "$OUT" --port "$PORT"
  ) >"$LOG" 2>&1 &
  SERVER_PID=$!
  wait_healthy
}

# GitHub OAuth configured, no static token: a request with no bearer is
# refused on every checked route instead of running as the operator — even
# with the open-access opt-in set, which only applies when nothing is
# configured.
restart_server CLOUD_AGENTS_GITHUB_CLIENT_ID=e2e-client-id CLOUD_AGENTS_GITHUB_CLIENT_SECRET=e2e-client-secret CLOUD_AGENTS_ALLOW_UNAUTHENTICATED=1
echo "==> restarted: GitHub OAuth configured, no static token"
assert "oauth: health stays open"              GET  "/api/health"               no 200 "status"
assert "oauth: auth config stays open"         GET  "/api/auth/github/config"   no 200 '"configured":"true"'
assert "oauth: session list needs a bearer"    GET  "/api/sessions"             no 401 "missing Authorization bearer token"
assert "oauth: session creation needs a bearer" POST "/api/sessions"            no 401 "missing Authorization bearer token" '{}'
assert "oauth: reap needs a bearer"            POST "/api/maintenance/reap"     no 401 "missing Authorization bearer token"
assert "oauth: trigger-jobs needs a bearer"    POST "/api/maintenance/trigger-jobs" no 401 "missing Authorization bearer token"
assert "oauth: credentials need a bearer"      GET  "/api/credentials"          no 401 "missing Authorization bearer token"

# Nothing configured: refused unless the operator opts in.
restart_server
echo "==> restarted: no static token, no OAuth, no opt-in"
assert "unconfigured: health stays open"       GET  "/api/health"               no 200 "status"
assert "unconfigured: session list refused"    GET  "/api/sessions"             no 401 "authentication is not configured"
assert "unconfigured: reap refused"            POST "/api/maintenance/reap"     no 401 "authentication is not configured"

restart_server CLOUD_AGENTS_ALLOW_UNAUTHENTICATED=1
echo "==> restarted: no static token, no OAuth, CLOUD_AGENTS_ALLOW_UNAUTHENTICATED=1"
assert "opted in: session list open"           GET  "/api/sessions"             no 200 ""
assert "opted in: credentials still refused"   GET  "/api/credentials"          no 401 "authentication is not configured"

if [ "$fails" -ne 0 ]; then
  echo "==> e2e-http: ${fails} assertion(s) failed" >&2
  echo "---- server log ----" >&2
  sed -e 's/^/  /' "$LOG" >&2
  exit 1
fi
echo "==> e2e-http: all assertions passed"
