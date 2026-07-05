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
# THIS NOW SUCCEEDS as of v0.4.14 — the first release where it ever has,
# after five sequential upstream compiler bugs (four now fixed). Bug 1
# (buildProject crash, https://github.com/nichobbs/lyric-lang/issues/4925)
# fixed in v0.4.11; bug 2 (Std.Core's Option/Result/Some/None/Ok/Err never
# resolving, https://github.com/nichobbs/lyric-lang/issues/4980) fixed in
# v0.4.12; bug 3 (NuGet-restored zero-arg functions rejected,
# https://github.com/nichobbs/lyric-lang/issues/5004) fixed in v0.4.14 —
# that's what let this succeed. Bug 4 (NuGet dependency DLLs not copied to
# the output directory, https://github.com/nichobbs/lyric-lang/issues/5066)
# fixed in v0.4.15. Bug 5, still open, blocks actually running the built
# server (wrong cross-package field/method metadata references at
# runtime): https://github.com/nichobbs/lyric-lang/issues/5177 — see
# scripts/run-api.sh and docs/BUILD.md "Compiler notes" for detail. None of
# the five was ever something this project's lyric.toml or source could
# work around. An earlier version of this comment described a
# `[nuget]`-stripping workaround based on a since-disproven theory (it
# didn't actually fix anything, though it was harmless) — removed once the
# real scope became clear.
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
