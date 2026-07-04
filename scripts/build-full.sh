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
# THIS CURRENTLY CANNOT SUCCEED with any released Lyric compiler — three
# independent upstream bugs found in sequence, two fixed, one open. Bug 1
# (buildProject crash, https://github.com/nichobbs/lyric-lang/issues/4925)
# is fixed as of v0.4.11; bug 2 (Std.Core's Option/Result/Some/None/Ok/Err
# never resolving, https://github.com/nichobbs/lyric-lang/issues/4980) is
# fixed as of v0.4.12. Bug 3, still open: a zero-arg function restored from
# a NuGet package (Web.create(), called directly in src/main.l) is rejected
# as "expected 1 argument(s), got 0" even though it takes zero parameters —
# filed as https://github.com/nichobbs/lyric-lang/issues/5004. None of the
# three is something this project's lyric.toml or source can work around;
# see docs/BUILD.md "Compiler notes" for full detail. An earlier version of
# this comment described a `[nuget]`-stripping workaround based on a
# since-disproven theory (it didn't actually fix anything, though it was
# harmless) — removed once the real scope became clear.
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
