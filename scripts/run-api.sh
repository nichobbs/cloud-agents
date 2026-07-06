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

echo "==> starting server on ${BIND}:${PORT}"
# Secrets (ENCRYPTION_KEY, CLOUD_AGENTS_WHITELIST) are read from the environment
# by the .NET configuration system — do not pass them as CLI args where they
# would be visible in process listings.
exec dotnet "$OUT" --urls "http://${BIND}:${PORT}"
