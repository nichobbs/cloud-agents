#!/usr/bin/env bash
# build-full.sh — build the complete Cloud Agents server (API + web + docker).
#
# Lyric.Web/Lyric.Docker/Std.Logging/Microsoft.Data.Sqlite are all consumed
# as published NuGet binaries declared in `[nuget]` in lyric.toml (see
# docs/BUILD.md). No sibling lyric-lang checkout, source patching, or
# package inlining required. `lyric restore` fetches the NuGet packages,
# `lyric build` compiles everything else.
#
# THIS NOW SUCCEEDS as of v0.4.14 — the first release where it ever has,
# after seven sequential upstream compiler bugs, all now fixed. Bug 1
# (buildProject crash, https://github.com/nichobbs/lyric-lang/issues/4925)
# fixed in v0.4.11; bug 2 (Std.Core's Option/Result/Some/None/Ok/Err never
# resolving, https://github.com/nichobbs/lyric-lang/issues/4980) fixed in
# v0.4.12; bug 3 (NuGet-restored zero-arg functions rejected,
# https://github.com/nichobbs/lyric-lang/issues/5004) fixed in v0.4.14 —
# that's what let this succeed. Bug 4 (NuGet dependency DLLs not copied to
# the output directory, https://github.com/nichobbs/lyric-lang/issues/5066)
# fixed in v0.4.15; bug 5 (wrong cross-package field/method metadata
# tokens from an async func awaiting a later-declared package,
# https://github.com/nichobbs/lyric-lang/issues/5177) fixed in v0.4.17 —
# that's what let scripts/run-api.sh finally start the server. Bug 6
# (slice[T].append() throwing at runtime,
# https://github.com/nichobbs/lyric-lang/issues/5244) fixed in v0.4.18.
# Bug 7 (an untyped top-level String val's `.length` throwing an IList
# cast): https://github.com/nichobbs/lyric-lang/issues/5298, fixed in
# v0.4.19 — didn't affect this script, but did affect one `lyric test`
# case; see docs/BUILD.md "Compiler notes" for detail. None of the seven
# was ever something this project's lyric.toml or source could work
# around. An earlier version of this comment described a `[nuget]`-
# stripping workaround based on a since-disproven theory (it didn't
# actually fix anything, though it was harmless) — removed once the real
# scope became clear.
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

# Copy native SQLite binaries to bin/ if Microsoft.Data.Sqlite is restored
NUGET_DIR="${NUGET_PACKAGES:-$HOME/.nuget/packages}"
if [ -d "$NUGET_DIR/sqlitepclraw.lib.e_sqlite3" ]; then
  SQLITE_RUNTIMES_DIR=$(find "$NUGET_DIR/sqlitepclraw.lib.e_sqlite3" -maxdepth 2 -name "runtimes" | head -n 1)
  if [ -n "$SQLITE_RUNTIMES_DIR" ] && [ -d "$SQLITE_RUNTIMES_DIR" ]; then
    echo "==> copying native SQLite runtimes to bin/runtimes"
    mkdir -p "$REPO_ROOT/bin"
    cp -R "$SQLITE_RUNTIMES_DIR/" "$REPO_ROOT/bin/runtimes/"
    
    # On macOS, also copy the appropriate dylib to the root bin/ directory to ensure FFI loads it correctly
    ARCH="$(uname -m)"
    if [ "$ARCH" = "arm64" ] && [ -f "$SQLITE_RUNTIMES_DIR/osx-arm64/native/libe_sqlite3.dylib" ]; then
      cp "$SQLITE_RUNTIMES_DIR/osx-arm64/native/libe_sqlite3.dylib" "$REPO_ROOT/bin/libe_sqlite3.dylib"
    elif [ "$ARCH" = "x86_64" ] && [ -f "$SQLITE_RUNTIMES_DIR/osx-x64/native/libe_sqlite3.dylib" ]; then
      cp "$SQLITE_RUNTIMES_DIR/osx-x64/native/libe_sqlite3.dylib" "$REPO_ROOT/bin/libe_sqlite3.dylib"
    fi
  fi
fi

echo "==> Full build succeeded"

