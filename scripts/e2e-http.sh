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
# No CLOUD_AGENTS_API_TOKEN and no GitHub OAuth config => open mode, so the
# non-exempt routes below dispatch (and hit their own not-found/empty-vault
# paths) without needing a token. --port is read by main.l; --urls mirrors
# scripts/run-api.sh.
dotnet "$OUT" --port "$PORT" --urls "$BASE" >"$LOG" 2>&1 &
SERVER_PID=$!

ready=0
for _ in $(seq 1 60); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "e2e-http: server exited during startup" >&2
    sed -e 's/^/  /' "$LOG" >&2
    exit 1
  fi
  code=$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/api/health" 2>/dev/null || echo 000)
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
# assert <description> <path> <expected-http-code> <expected-body-substring>
assert() {
  local desc="$1" path="$2" want_code="$3" want_sub="$4"
  local out code body
  out=$(curl -sS -w $'\n%{http_code}' "${BASE}${path}" 2>/dev/null || printf '\n000')
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  if [ "$code" != "$want_code" ]; then
    echo "FAIL ${desc}: expected HTTP ${want_code}, got ${code} — body: ${body}" >&2
    fails=$((fails + 1)); return
  fi
  case "$body" in
    *"$want_sub"*) echo "ok   ${desc} (HTTP ${code})" ;;
    *) echo "FAIL ${desc}: body missing '${want_sub}' — got: ${body}" >&2; fails=$((fails + 1)) ;;
  esac
}

# Health + an auth-exempt route.
assert "health"                       "/api/health"                          200 "status"
assert "oauth config (auth-exempt)"   "/api/auth/github/config"              200 "configured"
# THE point of this harness (#442/#354): a two-path-param route dispatching at
# all. Unknown session => 404 JSON. A 500, a blank body, or a route miss here
# would mean multi-param matching is broken.
assert "multi-param output route"     "/api/sessions/does-not-exist/output/0" 404 "Session"
# Proxy routes with an empty vault => 404 JSON (the frontend's fall-back signal),
# proving the proxy routes dispatch and short-circuit cleanly (no crash, no
# outbound call).
assert "github repos proxy (no token)" "/api/github/repos/1"                 404 "vault"
assert "models proxy (no keys)"        "/api/models/claude"                  404 "vault"

if [ "$fails" -ne 0 ]; then
  echo "==> e2e-http: ${fails} assertion(s) failed" >&2
  echo "---- server log ----" >&2
  sed -e 's/^/  /' "$LOG" >&2
  exit 1
fi
echo "==> e2e-http: all assertions passed"
