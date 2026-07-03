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
# `lyric build` crashes with an unhandled System.InvalidCastException when
# fed a manifest containing a `[project.tests]` section (confirmed against
# the real 0.4.10 compiler in CI — `lyric test`, which is documented
# separately in docs/BUILD.md, crashes the same way for the same reason).
# Feed it a copy of lyric.toml with that section stripped instead. Re-check
# this workaround whenever bumping the Lyric compiler version.
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
cp lyric.toml lyric.toml.bak
trap 'mv lyric.toml.bak lyric.toml' EXIT
awk '
  /^\[project\.tests\]/ { skip=1; next }
  /^\[/ && skip        { skip=0 }
  !skip                { print }
' lyric.toml.bak > lyric.toml
lyric build

echo "==> Full build succeeded"
