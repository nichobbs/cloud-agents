#!/usr/bin/env bash
# build-full.sh — build the complete Cloud Agents server (API + web + docker).
#
# All library dependencies (Lyric.Web, Lyric.Docker, Std.Logging,
# Microsoft.Data.Sqlite) are consumed as published NuGet binaries declared in
# `[nuget]` in lyric.toml — no sibling lyric-lang checkout, source patching, or
# package inlining required. `lyric restore` fetches them, `lyric build`
# compiles the project against the prebuilt DLLs.
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
