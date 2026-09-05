#!/usr/bin/env bash
# LYRIC_CONFIG_* env-var-to-config-block smoke test (nichobbs/cloud-agents#678):
# boots the REAL compiled binary twice — once with neither the config-block
# nor the legacy env var set, once with ONLY the derived LYRIC_CONFIG_* names
# set (never the legacy CLOUD_AGENTS_GITHUB_CLIENT_ID/_SECRET fallback) — and
# asserts GET /api/auth/github/config actually reflects the config-block
# value end to end.
#
# This is the coverage gap #678 identified: `configOrEnv`'s own @test_module
# test (tests/oauth_tests.l) only calls the pure precedence function with a
# hand-supplied string, so nothing in CI ever set a real LYRIC_CONFIG_* env
# var, started the compiled binary, and confirmed the `config Github { ... }`
# block (src/handlers/oauth.l) actually picked it up. That gap is exactly why
# the wrong-env-var-name regression filed as #677 shipped unnoticed despite a
# green test plan: `lyric build`/`lyric test` can't catch a wrong derived name
# for a config-block field, only a real process boot can.
#
# `config` blocks are populated once from the environment at process startup
# (docs/lyric/gotchas.md "Config"; docs/lyric/reference.md "Env var naming"),
# so this cannot be a @test_module test and needs two separate server
# launches, one per env state — a single running process can't be made to
# re-read its config mid-test.
#
# Assumes scripts/build-full.sh has already produced bin/CloudAgents.dll (CI
# runs it earlier in the same job, immediately before scripts/e2e-http.sh);
# this script only runs it. Kept as a sibling to e2e-http.sh rather than
# folded into it: e2e-http.sh's single long-lived server backs a large,
# unrelated assertion list, and this check's whole point is two SEPARATE,
# short-lived server launches with deliberately different env states.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/bin/CloudAgents.dll"
PORT="${E2E_CONFIG_PORT:-18081}"
BASE="http://127.0.0.1:${PORT}"

command -v curl   >/dev/null || { echo "test-lyric-config-env: 'curl' not on PATH"   >&2; exit 1; }
command -v dotnet >/dev/null || { echo "test-lyric-config-env: 'dotnet' not on PATH" >&2; exit 1; }
[ -f "$OUT" ] || { echo "test-lyric-config-env: $OUT not found — run scripts/build-full.sh first" >&2; exit 1; }

# Same native-sqlite exposure as scripts/e2e-http.sh / the "Run lyric test" CI
# step: the live-DB code needs libe_sqlite3.so resolvable from bin/runtimes.
if [ -d "$REPO_ROOT/bin/runtimes/linux-x64/native" ]; then
  export LD_LIBRARY_PATH="$REPO_ROOT/bin/runtimes/linux-x64/native:${LD_LIBRARY_PATH:-}"
fi

DB=""
LOG=""
SERVER_PID=""
fails=0

cleanup() {
  # Every branch below is written to never itself return non-zero — this runs
  # as an EXIT trap, so its own exit status would otherwise clobber the
  # script's real one (e.g. `[ -n "$DB" ] && rm -f ...` evaluates to a
  # failing status, 1, once stop_server has already cleared DB to "").
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "$DB" ]; then
    rm -f "$DB" "$DB-wal" "$DB-shm"
  fi
  if [ -n "$LOG" ]; then
    rm -f "$LOG"
  fi
  return 0
}
trap cleanup EXIT

# start_server <label> — launches the binary against a fresh throwaway DB
# under whatever env the caller has already exported/unset (config blocks
# only read the environment once, at process start, so the caller must set
# up its LYRIC_CONFIG_*/CLOUD_AGENTS_* state BEFORE calling this), and waits
# for /api/health. Leaves SERVER_PID/DB/LOG set for stop_server.
start_server() {
  local label="$1"
  DB="$(mktemp -t cloud-agents-config-e2e-XXXXXX.db)"
  LOG="$(mktemp -t cloud-agents-config-e2e-log-XXXXXX)"
  export CLOUD_AGENTS_DB_PATH="$DB"
  export LYRIC_CONFIG_WEB_SERVER_PORT="$PORT"
  echo "==> starting server (${label}) on ${BASE} (db=${DB})"
  dotnet "$OUT" --port "$PORT" >"$LOG" 2>&1 &
  SERVER_PID=$!
  local ready=0 code
  for _ in $(seq 1 60); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "test-lyric-config-env: server (${label}) exited during startup" >&2
      sed -e 's/^/  /' "$LOG" >&2
      exit 1
    fi
    code=$(curl -sS --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "${BASE}/api/health" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then ready=1; break; fi
    sleep 1
  done
  if [ "$ready" != "1" ]; then
    echo "test-lyric-config-env: server (${label}) did not become healthy within 60s" >&2
    sed -e 's/^/  /' "$LOG" >&2
    exit 1
  fi
}

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  rm -f "$DB" "$DB-wal" "$DB-shm" "$LOG"
  DB=""
  LOG=""
}

# assert_config <desc> <want-exact-body> — /api/auth/github/config is
# auth-exempt (scripts/e2e-http.sh's own comment confirms this route class),
# so no bearer is sent. Exact-match, not substring: the whole point here is
# pinning both fields (configured AND clientId), not just that the route
# answers.
assert_config() {
  local desc="$1" want="$2" body
  body=$(curl -sS --connect-timeout 5 --max-time 10 "${BASE}/api/auth/github/config" 2>/dev/null || echo "")
  if [ "$body" = "$want" ]; then
    echo "ok   ${desc}"
  else
    echo "FAIL ${desc}: expected '${want}', got '${body}'" >&2
    fails=$((fails + 1))
  fi
}

# ── Leg 1: neither the config-block-derived var nor the legacy fallback is
# set. Explicitly cleared (not just relying on an inherited-clean env) so a
# leaked var in the calling shell can't turn this leg into a false negative.
unset LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENTID || true
unset LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENTSECRET || true
unset CLOUD_AGENTS_GITHUB_CLIENT_ID || true
unset CLOUD_AGENTS_GITHUB_CLIENT_SECRET || true
start_server "unconfigured"
assert_config "neither var set -> configured=false, empty clientId" \
  '{"configured":"false","clientId":""}'
stop_server

# ── Leg 2 (#678's actual point): set ONLY the correctly-derived LYRIC_CONFIG_*
# names — never the legacy CLOUD_AGENTS_GITHUB_CLIENT_ID/_SECRET fallback —
# and confirm the config block itself carries the value through. Per
# docs/lyric/reference.md "Env var naming" (LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>,
# all-caps, camelCase boundaries NOT split) and src/handlers/oauth.l's `config
# Github { clientId: String = "" }` living in package CloudAgents.OAuth, the
# derived name is LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENTID — NOT
# ..._CLIENT_ID, which is precisely the wrong shape #677 shipped (see
# tests/oauth_tests.l's regression test for the same locked-in constant).
# Leaving the legacy names unset means a pass here can ONLY come from the
# config-block path itself; the fallback can't mask a wrong derived name.
TEST_CLIENT_ID="e2e-config-block-client-id"
export LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENTID="$TEST_CLIENT_ID"
export LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENTSECRET="e2e-config-block-client-secret"
start_server "config-block"
assert_config "LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENTID wired through -> configured=true" \
  "{\"configured\":\"true\",\"clientId\":\"${TEST_CLIENT_ID}\"}"
stop_server
unset LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENTID
unset LYRIC_CONFIG_CLOUDAGENTS_OAUTH_GITHUB_CLIENTSECRET

if [ "$fails" -ne 0 ]; then
  echo "==> test-lyric-config-env: ${fails} assertion(s) failed" >&2
  exit 1
fi
echo "==> test-lyric-config-env: all assertions passed"
