#!/usr/bin/env bash
# install.sh — one-command setup for Cloud Agents development.
#
# Installs the Lyric compiler (if not already on PATH), the .NET 10 SDK (if
# not already on PATH), and restores this project's NuGet dependencies.
# Docker is required separately (for running actual sessions) but is not
# installed by this script — see deploy/install-docker.sh for that.
#
# Usage:
#   ./scripts/install.sh
#   curl -fsSL https://raw.githubusercontent.com/nichobbs/cloud-agents/main/scripts/install.sh | bash
#
# Env overrides:
#   LYRIC_VERSION   Pin a specific Lyric release instead of latest (e.g. 0.4.31).
#   LYRIC_DIR       Lyric install directory (default: ~/.lyric/bin).
#   SKIP_DOTNET     Set (any value) to skip the .NET SDK install step entirely.
#   SKIP_RESTORE    Set (any value) to skip the final `lyric restore` step.
#
# Requirements: curl, tar (bash itself is required; this is not a POSIX sh
# script like lyric-lang's own installer, since it composes two installers
# and needs bash's arrays for that cleanly).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LYRIC_DIR="${LYRIC_DIR:-$HOME/.lyric/bin}"
DOTNET_DIR="${DOTNET_DIR:-$HOME/.dotnet}"
MIN_LYRIC_VERSION="$(cat "$REPO_ROOT/MIN_LYRIC_VERSION" 2>/dev/null || echo "0.4.19")"

say() { printf '==> %s\n' "$*"; }
err() { printf 'install: error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || err "curl is required"

# ── Lyric compiler ───────────────────────────────────────────────────────────
#
# Delegates to lyric-lang's own installer first (same one docker/Dockerfile
# and deploy/api.Dockerfile already use) — it handles platform detection and
# PATH setup. Its "resolve latest via api.github.com" step is known to fail
# on networks where that host is rate-limited or blocked (see docs/BUILD.md);
# when it does, fall back to resolving the release tag from the unauthenticated
# github.com/releases/latest redirect instead (the same fallback CI uses) and
# download the matching archive directly.
install_lyric() {
  if command -v lyric >/dev/null 2>&1; then
    say "lyric already on PATH ($(command -v lyric)) — skipping install."
    say "   This project requires Lyric >= $MIN_LYRIC_VERSION (see MIN_LYRIC_VERSION)."
    say "   Note: 'lyric --version' is known to always print 0.1.0 regardless of the"
    say "   actual installed release (see docs/BUILD.md), so this can't be verified"
    say "   automatically — if you're not sure your install is recent enough, remove"
    say "   it from PATH and re-run this script, or set LYRIC_VERSION explicitly."
    return
  fi

  say "Installing Lyric compiler to $LYRIC_DIR"
  mkdir -p "$LYRIC_DIR"

  local version_args=()
  if [ -n "${LYRIC_VERSION:-}" ]; then
    version_args=(--version "$LYRIC_VERSION")
  fi

  if curl -fsSL https://raw.githubusercontent.com/nichobbs/lyric-lang/main/scripts/install.sh \
       | sh -s -- --dir "$LYRIC_DIR" --no-path "${version_args[@]}"; then
    say "Lyric installed via the upstream installer."
  else
    say "Upstream installer failed (often api.github.com being rate-limited/blocked"
    say "for the 'latest' lookup) — falling back to resolving the release directly"
    say "from github.com, the same way this project's CI does."
    install_lyric_fallback
  fi
}

install_lyric_fallback() {
  local ver="${LYRIC_VERSION:-}"
  if [ -z "$ver" ]; then
    local attempt
    for attempt in 1 2 3; do
      ver="$(curl -sI --connect-timeout 10 --max-time 30 https://github.com/nichobbs/lyric-lang/releases/latest \
               | sed -n 's/.*tag\/v\([0-9.]*\).*/\1/p' | tr -d '\r')"
      [ -n "$ver" ] && break
      say "  attempt $attempt: could not resolve latest Lyric release tag, retrying..."
      sleep 3
    done
  fi
  [ -n "$ver" ] || err "could not resolve a Lyric release version (tried the upstream installer and the github.com redirect)"

  local os arch rid
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux)
      case "$arch" in
        x86_64) rid=linux-x64 ;;
        aarch64) rid=linux-arm64 ;;
        *) err "unsupported Linux architecture: $arch" ;;
      esac
      ;;
    Darwin)
      case "$arch" in
        arm64) rid=osx-arm64 ;;
        x86_64) rid=osx-x64 ;;
        *) err "unsupported macOS architecture: $arch" ;;
      esac
      ;;
    *)
      err "unsupported OS for this fallback: $os (on Windows, run the upstream installer directly: see docs/BUILD.md)"
      ;;
  esac

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  say "Downloading lyric-${ver}-${rid}.tar.gz"
  curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 \
    -o "$tmp/lyric.tgz" \
    "https://github.com/nichobbs/lyric-lang/releases/download/v${ver}/lyric-${ver}-${rid}.tar.gz"

  mkdir -p "$LYRIC_DIR"
  tar -xzf "$tmp/lyric.tgz" -C "$LYRIC_DIR"
  chmod +x "$LYRIC_DIR/lyric" 2>/dev/null || true
  say "Lyric $ver installed to $LYRIC_DIR"
}

# ── .NET SDK ──────────────────────────────────────────────────────────────────
#
# Required to run the compiled output and tests (lyric build emits a .NET
# assembly; lyric itself only needs its own bundled runtime). See
# docs/BUILD.md "Toolchain".
install_dotnet() {
  if [ -n "${SKIP_DOTNET:-}" ]; then
    say "SKIP_DOTNET set — skipping .NET SDK install."
    return
  fi
  if command -v dotnet >/dev/null 2>&1; then
    say "dotnet already on PATH ($(command -v dotnet)) — skipping install."
    return
  fi

  say "Installing .NET 10 SDK to $DOTNET_DIR"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL https://dotnet.microsoft.com/download/dotnet/scripts/v1/dotnet-install.sh -o "$tmp/dotnet-install.sh"
  bash "$tmp/dotnet-install.sh" --channel 10.0 --install-dir "$DOTNET_DIR"
}

install_lyric
install_dotnet

export PATH="$LYRIC_DIR:$DOTNET_DIR:$PATH"
export DOTNET_ROOT="$DOTNET_DIR"

command -v lyric >/dev/null 2>&1 || err "lyric is still not on PATH after install — check $LYRIC_DIR"
command -v dotnet >/dev/null 2>&1 || err "dotnet is still not on PATH after install — check $DOTNET_DIR (or re-run with SKIP_DOTNET unset)"

if [ -z "${SKIP_RESTORE:-}" ]; then
  say "Restoring NuGet dependencies for Cloud Agents"
  (cd "$REPO_ROOT" && lyric restore)
fi

say "Done."
say ""
say "Add these to your shell profile (or export them in this shell) if not already present:"
say "  export PATH=\"$LYRIC_DIR:$DOTNET_DIR:\$PATH\""
say "  export DOTNET_ROOT=\"$DOTNET_DIR\""
say ""
say "Next steps:"
say "  ./scripts/run-api.sh    # build + run the server locally"
say "  ./scripts/verify.sh     # run the test harness"
say "  lyric test              # run the @test_module suites (see docs/BUILD.md for native-SQLite setup)"
