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
# Was crashing the whole process with an AccessViolationException on every
# message sent (root-caused and worked around as of v0.4.36) — see
# docs/BUILD.md "Compiler notes" (ninth entry) and
# scripts/repro-crosspkg-long-crash.sh.
#
# Requirements: lyric 0.4.19+ (see docs/BUILD.md for the full bug history —
# this script itself only needed 0.4.17+), dotnet 10.x, Docker (for runner
# containers)
# Env:
#   CLOUD_AGENTS_PORT        HTTP listen port (default: 8080)
#   CLOUD_AGENTS_BIND        interface to bind (default: 127.0.0.1; set 0.0.0.0 for LAN)
#   ENCRYPTION_KEY           (secret) key for session data encryption — read from env by .NET
#   CLOUD_AGENTS_WHITELIST   (secret) comma-separated GitHub user IDs allowed access

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env configuration file if it exists. Already-exported environment variables
# in the active shell override values defined in the .env file.
if [ -f "$REPO_ROOT/.env" ]; then
  echo "==> loading configuration from $REPO_ROOT/.env"
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    
    # Match name=value pair
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      # Trim whitespace and strip enclosing quotes
      name=$(echo "$name" | xargs)
      value=$(echo "$value" | xargs | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
      
      # Export only if the variable is not already defined in the shell environment
      if [ -z "${!name:-}" ]; then
        export "$name"="$value"
      fi
    fi
  done < "$REPO_ROOT/.env"
fi

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
# Ensure ENCRYPTION_KEY is configured with a valid 32-byte base64-encoded key.
# If not set in the environment, try to read from a local .encryption_key file to maintain
# persistence across server restarts. If that file doesn't exist, generate a new random 32-byte key
# using openssl and save it, or fall back to a valid 32-byte development key.
if [ -z "${ENCRYPTION_KEY:-}" ]; then
  KEY_FILE="$REPO_ROOT/.encryption_key"
  if [ -f "$KEY_FILE" ]; then
    ENCRYPTION_KEY="$(cat "$KEY_FILE")"
    echo "==> loaded ENCRYPTION_KEY from $KEY_FILE"
  elif command -v openssl >/dev/null; then
    ENCRYPTION_KEY="$(openssl rand -base64 32)"
    echo "$ENCRYPTION_KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    echo "==> generated new 32-byte ENCRYPTION_KEY and saved to $KEY_FILE"
  else
    # Fallback to a valid 32-byte key (base64 of 32 zero bytes) so it passes validation
    ENCRYPTION_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    echo "==> ENCRYPTION_KEY not set and 'openssl' not found; using fallback development key"
  fi
  export ENCRYPTION_KEY
fi

# Ensure CLOUD_AGENTS_API_TOKEN is configured.
# If not set in the environment, try to read from a local .api_token file to maintain
# persistence across server restarts. If that file doesn't exist, generate a new random API token
# using openssl and save it, or fall back to a default development token.
if [ -z "${CLOUD_AGENTS_API_TOKEN:-}" ]; then
  TOKEN_FILE="$REPO_ROOT/.api_token"
  if [ -f "$TOKEN_FILE" ]; then
    CLOUD_AGENTS_API_TOKEN="$(cat "$TOKEN_FILE")"
    echo "==> loaded CLOUD_AGENTS_API_TOKEN from $TOKEN_FILE"
  elif command -v openssl >/dev/null; then
    CLOUD_AGENTS_API_TOKEN="$(openssl rand -base64 32)"
    echo "$CLOUD_AGENTS_API_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "==> generated new CLOUD_AGENTS_API_TOKEN and saved to $TOKEN_FILE"
  else
    CLOUD_AGENTS_API_TOKEN="dev-token-123456"
    echo "==> CLOUD_AGENTS_API_TOKEN not set and 'openssl' not found; using fallback development token"
  fi
  export CLOUD_AGENTS_API_TOKEN
fi

# Print the active API token so the user/clients can easily copy and use it to authenticate
echo "==> active CLOUD_AGENTS_API_TOKEN: $CLOUD_AGENTS_API_TOKEN"

# Secrets (ENCRYPTION_KEY, CLOUD_AGENTS_API_TOKEN, CLOUD_AGENTS_WHITELIST) are read from the environment
# by the .NET configuration system — do not pass them as CLI args where they
# would be visible in process listings.
exec dotnet "$OUT" --urls "http://${BIND}:${PORT}"

