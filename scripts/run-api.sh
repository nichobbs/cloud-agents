#!/usr/bin/env bash
# Build the full server and run it locally.
#
# THIS CURRENTLY CANNOT SUCCEED: `lyric build` works (see docs/BUILD.md —
# fixed as of v0.4.14), but the built bin/CloudAgents.dll can't find its
# NuGet-restored dependencies (Web.dll, etc.) at runtime — an open upstream
# bug, https://github.com/nichobbs/lyric-lang/issues/5066. Not something
# this script or lyric.toml can work around; see docs/BUILD.md "Compiler
# notes" for detail and current release status.
#
# Requirements: lyric 0.4.14+, dotnet 10.x, Docker (for runner containers)
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
