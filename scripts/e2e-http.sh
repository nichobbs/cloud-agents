#!/usr/bin/env bash
# End-to-end HTTP smoke test: start the built server against a throwaway DB on a
# local port, wait for it to answer, and curl a handful of routes — including a
# MULTI-PARAM route (/api/sessions/{id}/output/{offset}) and the proxy routes,
# which @test_module suites can't exercise because Lyric's Web.Request can't be
# constructed in a test (nichobbs/cloud-agents#354). This is the automated
# proof that multi-param route dispatch works, closing the verification gap #442
# tracks. None of the asserted endpoints touch Docker, so no daemon is needed.
#
# Assumes `scripts/build-full.sh` has already produced bin/CloudAgents.dll and
# bin/runtimes (CI runs it earlier in the same job); this script only runs it.
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

DB="$(mktemp -t cloud-agents-e2e-XXXXXX.db)"
LOG="$(mktemp -t cloud-agents-e2e-log-XXXXXX)"
export CLOUD_AGENTS_DB_PATH="$DB"

# The live-DB code opens real SQLite connections whose native libe_sqlite3.so is
# not resolved from the NuGet cache on its own — expose the runtimes build-full
# copied to bin/, exactly as the "Run lyric test" CI step does.
if [ -d "$REPO_ROOT/bin/runtimes/linux-x64/native" ]; then
  export LD_LIBRARY_PATH="$REPO_ROOT/bin/runtimes/linux-x64/native:${LD_LIBRARY_PATH:-}"
fi

SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$DB" "$DB-wal" "$DB-shm" "$LOG"
}
trap cleanup EXIT

echo "==> starting server on ${BASE} (db=${DB})"
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

ready=0
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
echo "==> server is healthy"

fails=0
# assert <desc> <method> <path> <auth:yes|no> <want-code> <want-substr> [body]
# Sends the bearer only when <auth> is "yes"; sends a JSON body when provided.
assert() {
  local desc="$1" method="$2" path="$3" auth="$4" want_code="$5" want_sub="$6" body="${7:-}"
  # --max-time bounds every request so a bug in the (brand-new) middleware ->
  # streaming-handler hand-off that hangs the response fails the job fast
  # instead of stalling CI for hours (#494). These endpoints all answer in
  # milliseconds; 20s is pure slack.
  local args=(-sS --connect-timeout 5 --max-time 20 -X "$method" -w $'\n%{http_code}')
  [ "$auth" = "yes" ] && args+=(-H "Authorization: Bearer ${TOKEN}")
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data "$body")
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

# ── cloud-agents-shim integration leg (#531) ─────────────────────────────────
# Drive the REAL shim binary (shim/bin, built by the CI step before this
# script) over genuine MCP stdio against the REAL server above: initialize
# handshake, then a tools/call request_permission whose HTTP POST hits the
# live callback endpoint with an invalid bearer token. The server answers
# 401, and the shim's fail-closed path must surface a deny payload — this
# exercises transport.l's actual HTTP boundary (URL handling, request
# write, response read) end to end, which the in-memory FakeTransport
# suites deliberately do not. The full allowed-path round trip (valid
# token, human answer) needs a seeded session and stays manual for now.
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
  *'deny'*) echo "ok   shim: real HTTP 401 from live server fails closed (deny)" ;;
  *) echo "FAIL shim: tools/call did not fail closed — got: ${shim_stdout}" >&2; fails=$((fails + 1)) ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "==> e2e-http: ${fails} assertion(s) failed" >&2
  echo "---- server log ----" >&2
  sed -e 's/^/  /' "$LOG" >&2
  exit 1
fi
echo "==> e2e-http: all assertions passed"
