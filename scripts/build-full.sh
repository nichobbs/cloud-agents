#!/usr/bin/env bash
# build-full.sh — build the complete Cloud Agents server (API + web + docker).
#
# Lyric.Web/Std.Logging/Microsoft.Data.Sqlite are consumed as published NuGet
# binaries declared in `[nuget]` in lyric.toml; Lyric.Docker compiles from
# vendor/lyric-docker as an ordinary local package (see docs/BUILD.md for
# why). No sibling lyric-lang checkout, source patching, or package inlining
# required. `lyric restore` fetches the NuGet packages, `lyric build`
# compiles everything else.
#
# THIS CURRENTLY CANNOT SUCCEED with any released Lyric compiler. Confirmed
# locally (not just from CI logs): `lyric build`/`run`/`check`/`test` all
# crash with an unhandled System.InvalidCastException on EVERY Lyric
# project, including a trivial one-file hello-world with no dependencies at
# all — reproduced identically across all 4 currently-released compiler
# versions (0.4.7 through 0.4.10). This is not something this project's
# lyric.toml or source can work around; the crash is inside the compiler's
# own `buildProject` before it does anything project-specific. Filed as
# https://github.com/nichobbs/lyric-lang/issues/4925 — check that issue
# before assuming a local build failure is something to fix here. An
# earlier version of this comment described a `[nuget]`-stripping
# workaround based on a since-disproven theory (it didn't actually fix
# anything, though it was harmless) — removed once the real scope became
# clear.
#
# Requirements on PATH: lyric, dotnet (10.x).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v lyric  >/dev/null || { echo "build-full: 'lyric' not on PATH"  >&2; exit 1; }
command -v dotnet >/dev/null || { echo "build-full: 'dotnet' not on PATH" >&2; exit 1; }

cd "$REPO_ROOT"
echo "==> restoring NuGet dependencies"
lyric restore

echo "==> building the full Cloud Agents project"
lyric build

echo "==> Full build succeeded"
