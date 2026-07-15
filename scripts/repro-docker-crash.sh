#!/usr/bin/env bash
# repro-docker-crash.sh — minimal, runnable reproduction of the Lyric.Docker
# library bug documented in docs/BUILD.md's "Net effect" section: the
# published `Lyric.Docker` 0.4.29 NuGet package crashed with a bare
# `System.InvalidProgramException` ("Common Language Runtime detected an
# invalid program") on *any* live-daemon call (`ping`, `createContainer`,
# `getContainerLogs`, etc.) — confirmed to be a stale published artifact
# predating an unrelated async-codegen fix already on lyric-lang `main`,
# not a live source defect. Fixed for consumers by bumping the pin to
# `0.4.31` (already published).
#
# This is a Lyric.Docker (library) artifact-staleness bug, not one of the
# seven upstream Lyric *compiler* bugs tracked by
# scripts/repro-compiler-bug.sh, and distinct from the two *source* bugs
# (`ping()`'s wrong endpoint, `getContainerLogs`'s header-based TTY
# misdetection) fixed upstream in lyric-lang#5773 — kept as a separate,
# sibling script for that reason (see docs/BUILD.md).
#
# Reads the currently-pinned Lyric.Docker version straight out of this
# project's own lyric.toml, so bumping that pin and re-running this script
# is enough to check whether a given published version is affected — no
# separate version to keep in sync by hand.
#
# Requires a reachable Docker daemon over TCP (this bug only manifests on
# a *live* daemon call, not at compile time) — set
# CLOUD_AGENTS_DOCKER_TCP_HOST (host:port, e.g. 127.0.0.1:2375) to point at
# one; see docs/BUILD.md / src/docker_manager.l's dockerClient() doc
# comment for why TCP rather than the default Unix socket transport.
# Skipped (not failed) if no daemon is reachable, since that's an
# environment gap, not evidence about the library.
#
# Requirements: lyric on PATH, dotnet on PATH, network access to nuget.org
# (a real [nuget] restore is needed — this isn't reproducible without one,
# since it's Lyric.Docker's own compiled code that's at fault, not this
# project's source), and a reachable Docker daemon over TCP.
#
# Exit codes match scripts/repro-web-bug.sh's convention: 0 = did not
# reproduce (fixed, or skipped because no daemon/network was reachable),
# 1 = bug reproduced, 2 = couldn't run the check at all (missing tool,
# unexpected build failure) — distinct from 1 so a setup problem is never
# mistaken for a confirmed-still-broken result.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v lyric  >/dev/null || { echo "repro-docker-crash: 'lyric' not on PATH"  >&2; exit 2; }
command -v dotnet >/dev/null || { echo "repro-docker-crash: 'dotnet' not on PATH" >&2; exit 2; }
command -v curl   >/dev/null || { echo "repro-docker-crash: 'curl' not on PATH"   >&2; exit 2; }

DOCKER_HOST_PORT="${CLOUD_AGENTS_DOCKER_TCP_HOST:-}"
if [ -z "$DOCKER_HOST_PORT" ]; then
  echo "repro-docker-crash: CLOUD_AGENTS_DOCKER_TCP_HOST not set — no Docker daemon to test against" >&2
  echo "==> skipped: set CLOUD_AGENTS_DOCKER_TCP_HOST=host:port (e.g. 127.0.0.1:2375) to run this check" >&2
  exit 0
fi

if ! curl -fsS --connect-timeout 3 --max-time 5 "http://${DOCKER_HOST_PORT}/_ping" >/dev/null 2>&1; then
  echo "repro-docker-crash: no Docker daemon reachable at http://${DOCKER_HOST_PORT}/_ping" >&2
  echo "==> skipped: could not reach a live daemon, not evidence about the library" >&2
  exit 0
fi

DOCKER_VERSION="$(sed -n 's/^"Lyric\.Docker"[[:space:]]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' "$REPO_ROOT/lyric.toml" | head -1)"
[ -n "$DOCKER_VERSION" ] || { echo "repro-docker-crash: could not read Lyric.Docker version from lyric.toml" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/dockercrash/src"
cat > "$WORK/dockercrash/lyric.toml" <<TOML
[package]
name = "DockerCrashTest"
version = "0.1.0"
[project]
name = "DockerCrashTest"
output = "single"
output_assembly = "DockerCrashTest.dll"
[project.packages]
"DockerCrashTest" = "src/main.l"
[nuget]
"Lyric.Docker" = "$DOCKER_VERSION"
TOML

# listContainers is a side-effect-free live-daemon call Lyric.Docker
# exposes — the InvalidProgramException crash this script tracks
# reproduces on any live-daemon call (ping, createContainer,
# getContainerLogs, ...), but deliberately NOT ping() here: ping() has its
# own separate, still-open source bug (wrong /ping endpoint, fixed in
# lyric-lang#5773 but not yet in any published release) that would return
# a different Err unrelated to the crash this script isolates, muddying
# the signal. listContainers has no such confound.
cat > "$WORK/dockercrash/src/main.l" <<LYRIC
package DockerCrashTest

import Lyric.Docker
import Std.Core

pub func main(): Int {
  await run()
}

async func run(): Int {
  val client = makeDockerClientTcp("$DOCKER_HOST_PORT")
  match await listContainers(client) {
    case Ok(_) -> { println("listContainers ok"); 0 }
    case Err(e) -> { println("listContainers error: " + e.message); 1 }
  }
}
LYRIC

echo "==> Lyric.Docker $DOCKER_VERSION: live-daemon call against $DOCKER_HOST_PORT (nichobbs/cloud-agents, see docs/BUILD.md)"
restore_output="$(cd "$WORK/dockercrash" && lyric restore 2>&1)"
restore_status=$?
if [ "$restore_status" -ne 0 ]; then
  echo "$restore_output" >&2
  echo "==> skipped: 'lyric restore' failed (exit $restore_status) — likely no network access to nuget.org, not a library bug" >&2
  exit 0
fi

build_output="$(cd "$WORK/dockercrash" && lyric build 2>&1)"
build_status=$?
echo "$build_output"
if [ "$build_status" -ne 0 ]; then
  echo "==> Unexpected: build itself failed (exit $build_status) — not the known runtime-only signature, investigate separately" >&2
  exit 2
fi

run_output="$(cd "$WORK/dockercrash" && dotnet bin/DockerCrashTest.dll 2>&1)"
run_status=$?
echo "$run_output"

if [ "$run_status" -ne 0 ] && echo "$run_output" | grep -qi "InvalidProgramException"; then
  echo "==> Reproduced: Lyric.Docker $DOCKER_VERSION crashes on a live-daemon call with InvalidProgramException (nichobbs/cloud-agents, see docs/BUILD.md)"
  exit 1
elif [ "$run_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $run_status) — not the known signature, investigate separately" >&2
  exit 2
else
  echo "==> Did NOT reproduce: Lyric.Docker $DOCKER_VERSION handles a live-daemon call correctly"
  exit 0
fi
