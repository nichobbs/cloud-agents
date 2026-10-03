#!/usr/bin/env bash
# repro-crosspkg-long-crash.sh — minimal, runnable reproduction of the
# `streamSessionMessage` `AccessViolationException` that used to crash the
# whole server process on every message sent in a session (arm64 macOS,
# confirmed via a real `dotnet-dump` crash dump: `Unbox` targets
# `System.Int64` against a garbage, non-object pointer — "this object has
# an invalid CLASS field").
#
# ROOT CAUSE (lyric-lang#8022, fixed in lyric v0.7.7): an untyped module-level
# `val` initialised by a call or numeric conversion
# (`val runWallClockCapMs = 1800000.toLong()`) had its type predicted as
# `object` while its static field was `int64`; copying it into a local
# (`val runTimeoutMs = runWallClockCapMs` in `streamSessionMessage`) stored a
# raw `int64` into an `object` local, and the next use did `unbox.any Int64`.
# The fixture is a snapshot of `docker_manager.l`/`docker_policy.l` from
# before the workaround (see `scripts/repro-fixtures/crosspkg-long-crash/
# NOTE.md`), ported to the Lyric.Docker 0.7 API and pinned to the same
# `Lyric.Web`/`Lyric.Docker` versions as this project.
#
# The crash needs NO real Docker daemon, NO database, NO auth, NO real
# session — this script hits a bare streaming route that calls
# `streamSessionMessage` directly with a made-up session id against an
# unreachable Docker host, deterministically, in about two seconds.
#
# Expected: on lyric < 0.7.7 this reports "Reproduced" (exit 1); on 0.7.7+ the
# server survives AND the handler reports the Docker connection error, proving
# the run-timeout loop (where the `Long` subtract-and-compare lives) actually
# executed. A survived-but-never-got-there run is "unexpected" (exit 2), not a
# pass. The script is kept as a regression check for the fix.
#
# Exit codes match this project's other repro-*.sh scripts: 0 = did not
# reproduce (fixed upstream, or skipped because a tool/network was
# unavailable), 1 = bug reproduced, 2 = couldn't run the check at all
# (missing tool, unexpected build failure, the handler never reached the
# run loop).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/scripts/repro-fixtures/crosspkg-long-crash"

command -v lyric  >/dev/null || { echo "repro-crosspkg-long-crash: 'lyric' not on PATH"  >&2; exit 2; }
command -v dotnet >/dev/null || { echo "repro-crosspkg-long-crash: 'dotnet' not on PATH" >&2; exit 2; }
command -v curl   >/dev/null || { echo "repro-crosspkg-long-crash: 'curl' not on PATH"   >&2; exit 2; }

[ -d "$FIXTURE_DIR" ] || { echo "repro-crosspkg-long-crash: fixture dir missing: $FIXTURE_DIR" >&2; exit 2; }

WORK="$(mktemp -d)"
SERVER_LOG="$WORK/server.log"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

cp -R "$FIXTURE_DIR" "$WORK/proj"

echo "==> restoring NuGet dependencies (frozen docker_manager.l/docker_policy.l snapshot, stub packages for everything else)"
restore_output="$(cd "$WORK/proj" && lyric restore 2>&1)"
restore_status=$?
if [ "$restore_status" -ne 0 ]; then
  echo "$restore_output" >&2
  echo "==> skipped: 'lyric restore' failed (exit $restore_status) — likely no network access to nuget.org, not evidence about the bug" >&2
  exit 0
fi

echo "==> building"
build_output="$(cd "$WORK/proj" && lyric build 2>&1)"
build_status=$?
echo "$build_output"
if [ "$build_status" -ne 0 ]; then
  echo "==> Unexpected: build itself failed (exit $build_status) — not the known runtime-only signature, investigate separately" >&2
  exit 2
fi

PORT=8097
echo "==> starting server on 127.0.0.1:$PORT"
( cd "$WORK/proj" && dotnet bin/CrossPkgLongCrash.dll > "$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!

# Wait for the server to report it's listening (or crash before it gets that
# far, which would itself be unexpected and worth surfacing separately).
waited=0
while ! grep -qE "Listening|Fatal error" "$SERVER_LOG" 2>/dev/null; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    break
  fi
  sleep 0.5
  waited=$((waited + 1))
  if [ "$waited" -ge 40 ]; then
    echo "==> Unexpected: server never reported 'Listening' within 20s" >&2
    cat "$SERVER_LOG" >&2
    exit 2
  fi
done

if ! grep -q "Listening" "$SERVER_LOG" 2>/dev/null; then
  echo "==> Unexpected: server exited before reporting 'Listening'" >&2
  cat "$SERVER_LOG" >&2
  exit 2
fi

echo "==> POSTing to /run (unreachable Docker host, made-up session id)"
curl -N -sS -X POST "http://127.0.0.1:$PORT/run" -d '{}' --max-time 15 >/dev/null 2>&1

# Give createdump/the runtime a moment to flush the crash trace if it fired.
sleep 1

echo "--- server output ---"
cat "$SERVER_LOG"
echo "---------------------"

if grep -q "AccessViolationException" "$SERVER_LOG" 2>/dev/null && grep -q "streamSessionMessage" "$SERVER_LOG" 2>/dev/null; then
  echo "==> Reproduced: streamSessionMessage's Long-subtract-and-compare run-timeout check still crashes the process with AccessViolationException (nichobbs/cloud-agents, see docs/BUILD.md)"
  SERVER_PID=""
  exit 1
elif kill -0 "$SERVER_PID" 2>/dev/null; then
  if grep -q "container creation failed" "$SERVER_LOG" 2>/dev/null; then
    echo "==> Did NOT reproduce: the server survived a request that ran streamSessionMessage's poll loop (lyric $(lyric --version 2>/dev/null | awk '{print $2}'))."
    exit 0
  fi
  echo "==> Unexpected: the server survived but the request never reached the run loop — investigate separately" >&2
  exit 2
else
  echo "==> Unexpected: server exited without the AccessViolationException signature — investigate separately" >&2
  exit 2
fi
