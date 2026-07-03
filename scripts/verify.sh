#!/usr/bin/env bash
# verify.sh — run the project's @test_module suites.
#
# Historically this re-implemented a Docker-independent subset of the test
# suite by hand, because the Docker/web-dependent packages could not compile
# without a sibling lyric-lang source checkout (see git history before the
# NuGet dependency migration). Now that Lyric.Web, Lyric.Docker, Std.Logging
# and Microsoft.Data.Sqlite are all restored as ordinary NuGet binaries, the
# whole project builds and tests standalone, so this is just `lyric test`.
#
# Requirements on PATH: `lyric`, `dotnet` (10.x).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v lyric  >/dev/null || { echo "verify: 'lyric' not on PATH"  >&2; exit 1; }
command -v dotnet >/dev/null || { echo "verify: 'dotnet' not on PATH" >&2; exit 1; }

cd "$REPO_ROOT"
echo "==> restoring NuGet dependencies"
lyric restore
echo "==> running @test_module suites"
lyric test
