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

# Generates a random 32-byte value, base64-encoded, without depending on any
# one specific tool (#647: the previous 'openssl or a well-known hardcoded
# secret' fallback meant a box without openssl silently ran with a checked-
# into-git key/token any reader of this script could reproduce). Tries
# openssl, then python3, then /dev/urandom directly; if none of those are
# available there is no safe way to generate a secret, so the caller must
# fail rather than fall back to something predictable.
random_base64_32() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import base64, os; print(base64.b64encode(os.urandom(32)).decode())'
  elif [ -r /dev/urandom ]; then
    head -c 32 /dev/urandom | base64
  else
    return 1
  fi
}

# Ensure ENCRYPTION_KEY is configured with a valid 32-byte base64-encoded key.
# If not set in the environment, try to read from a local .encryption_key file to maintain
# persistence across server restarts. If that file doesn't exist, generate a new random 32-byte key
# and save it. There is no hardcoded fallback: a well-known key checked into
# this script would be a real credential exposure the moment this script ran
# anywhere but pure local dev (#647).
if [ -z "${ENCRYPTION_KEY:-}" ]; then
  KEY_FILE="$REPO_ROOT/.encryption_key"
  if [ -f "$KEY_FILE" ]; then
    ENCRYPTION_KEY="$(cat "$KEY_FILE")"
    echo "==> loaded ENCRYPTION_KEY from $KEY_FILE"
  else
    ENCRYPTION_KEY="$(random_base64_32)" || {
      echo "run-api: ENCRYPTION_KEY not set, no $KEY_FILE, and no way to generate a random key (need openssl, python3, or /dev/urandom); refusing to start with a predictable key" >&2
      exit 1
    }
    echo "$ENCRYPTION_KEY" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    echo "==> generated new 32-byte ENCRYPTION_KEY and saved to $KEY_FILE"
  fi
  export ENCRYPTION_KEY
fi

# Ensure CLOUD_AGENTS_API_TOKEN is configured.
# If not set in the environment, try to read from a local .api_token file to maintain
# persistence across server restarts. If that file doesn't exist, generate a new random API token
# and save it. Same no-hardcoded-fallback reasoning as ENCRYPTION_KEY above.
if [ -z "${CLOUD_AGENTS_API_TOKEN:-}" ]; then
  TOKEN_FILE="$REPO_ROOT/.api_token"
  if [ -f "$TOKEN_FILE" ]; then
    CLOUD_AGENTS_API_TOKEN="$(cat "$TOKEN_FILE")"
    echo "==> loaded CLOUD_AGENTS_API_TOKEN from $TOKEN_FILE"
  else
    CLOUD_AGENTS_API_TOKEN="$(random_base64_32)" || {
      echo "run-api: CLOUD_AGENTS_API_TOKEN not set, no $TOKEN_FILE, and no way to generate a random token (need openssl, python3, or /dev/urandom); refusing to start with a predictable token" >&2
      exit 1
    }
    echo "$CLOUD_AGENTS_API_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "==> generated new CLOUD_AGENTS_API_TOKEN and saved to $TOKEN_FILE"
  fi
  export CLOUD_AGENTS_API_TOKEN
fi

# Never print the live token: it's a real credential (bearer auth for every
# API route), and stdout here routinely ends up in shell history, a
# redirected log file, CI output, or a shared terminal screenshot (#647).
# Point at wherever it's actually configured instead — the env var, when the
# caller set one, or the token file this script itself manages otherwise.
if [ -f "$REPO_ROOT/.api_token" ]; then
  echo "==> CLOUD_AGENTS_API_TOKEN is configured (see $REPO_ROOT/.api_token, mode 600)"
else
  echo "==> CLOUD_AGENTS_API_TOKEN is configured (from the environment)"
fi

# Secrets (ENCRYPTION_KEY, CLOUD_AGENTS_API_TOKEN, CLOUD_AGENTS_WHITELIST) are read from the environment
# by the .NET configuration system — do not pass them as CLI args where they
# would be visible in process listings.
exec dotnet "$OUT" --urls "http://${BIND}:${PORT}"

