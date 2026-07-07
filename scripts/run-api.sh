#!/usr/bin/env bash
# Build the full server and run it locally.
#
# THIS NOW SUCCEEDS as of v0.4.17 — the first release where it ever has.
# `lyric build` works (fixed as of v0.4.14, see docs/BUILD.md); v0.4.15
# fixed `lyric run` not finding NuGet-restored dependencies at runtime
# (lyric-lang#5066); v0.4.17 fixed this real, multi-package server's
# cross-package field/method metadata references, which used to crash
# immediately on startup (lyric-lang#5177). See docs/BUILD.md "Compiler
# notes" for full detail and current release status.
#
# Not yet investigated: this may not stay running indefinitely under
# normal use in every environment — see the "Not yet investigated"
# paragraph under docs/BUILD.md's "## Dependencies" heading for what's
# been observed and what hasn't been ruled out yet.
#
# Requirements: lyric 0.4.17+, dotnet 10.x, Docker (for runner containers)
# Env:
#   CLOUD_AGENTS_PORT        HTTP listen port (default: 8080)
#   CLOUD_AGENTS_BIND        interface to bind (default: 127.0.0.1; set 0.0.0.0 for LAN)
#   ENCRYPTION_KEY           (secret) key for session data encryption — read from env by .NET
#   CLOUD_AGENTS_WHITELIST   (secret) comma-separated GitHub user IDs allowed access

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${CLOUD_AGENTS_PORT:-8080}"
BIND="${CLOUD_AGENTS_BIND:-127.0.0.1}"
OUT="$REPO_ROOT/bin/CloudAgents.dll"

command -v lyric  >/dev/null || { echo "run-api: 'lyric' not on PATH"  >&2; exit 1; }
command -v dotnet >/dev/null || { echo "run-api: 'dotnet' not on PATH" >&2; exit 1; }

echo "==> restoring NuGet dependencies"
( cd "$REPO_ROOT" && lyric restore )

echo "==> compiling CloudAgents"
( cd "$REPO_ROOT" && lyric build )

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

echo "==> starting server on ${BIND}:${PORT}"
# Secrets (ENCRYPTION_KEY, CLOUD_AGENTS_WHITELIST) are read from the environment
# by the .NET configuration system — do not pass them as CLI args where they
# would be visible in process listings.
exec dotnet "$OUT" --urls "http://${BIND}:${PORT}"

