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
# `lyric build` (and `lyric test`) crash with an unhandled
# System.InvalidCastException on ANY manifest with a populated `[nuget]`
# table, confirmed against the real 0.4.10 compiler in CI. Root cause (see
# https://github.com/nichobbs/lyric-lang/issues/4925): both commands match
# `manifest.nuget: Option[NugetSection]` directly, which hits the same
# "bootstrap-emitter match quirk" the compiler's own source documents (and
# already works around) for the structurally identical `Option[FeaturesSection]`
# field — just not yet for `.nuget`. This is not specific to this project's
# manifest shape; it would hit any project with NuGet deps.
#
# Work around it by stripping `[nuget]` from the manifest fed to `lyric
# build` only. This is safe: `resolveNugetAssets` (which actually locates the
# restored DLLs for linking) reads `obj/project.assets.json` from disk,
# independent of the manifest's `[nuget]` table at build time — `[nuget]` is
# only consulted here to decide whether to print an "unresolved nuget deps"
# warning, which is exactly the code path that crashes. `lyric restore` still
# runs against the real manifest first, so the packages are on disk before
# the stripped copy is used.
#
# Re-check this workaround (and file it as closed) once
# https://github.com/nichobbs/lyric-lang/issues/4925 ships a fix upstream.
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
  /^\[nuget\]/ { skip=1; next }
  /^\[/ && skip { skip=0 }
  !skip         { print }
' lyric.toml.bak > lyric.toml
lyric build

echo "==> Full build succeeded"
