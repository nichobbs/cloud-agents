#!/usr/bin/env bash
# install-harness-cli.sh: installs the newest release of a harness CLI or of uv,
# verified with check-harness-cli.sh, falling back to the last release known to
# work when the newest one fails the check.
#
# Usage: install-harness-cli.sh [--prefix DIR] [--latest-json FILE] TOOL
#        install-harness-cli.sh --package TOOL | --fallback TOOL
#   TOOL           claude | codex | gemini | opencode | uv
#   --prefix DIR   npm install prefix (default: npm's global prefix). Ignored
#                  for uv, which installs into UV_INSTALL_DIR.
#   --latest-json  the npm registry's `latest` metadata for the package, which
#                  the Dockerfiles ADD so that Docker reruns the install layer
#                  exactly when a new version is published. Without it, the
#                  `latest` dist-tag is resolved by npm. For uv this is the
#                  installer script instead.
#   --package / --fallback  print TOOL's package name / known-good version.
#
# Used by every runner image at build time and by delegate-task.sh for workers
# it installs on demand.
#
# Why a fallback rather than a failed build: Coolify builds all five runner
# images in one `docker compose build`, so one broken image would also block
# the API and frontend deploy (deploy/docker-compose.coolify.yml). A release
# that fails the check instead produces a loud warning and the known-good
# version. Bump a FALLBACK version once a newer release has passed the check.
set -euo pipefail

prefix=""
latest_json=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) prefix="$2"; shift 2 ;;
    --latest-json) latest_json="$2"; shift 2 ;;
    *) break ;;
  esac
done
tool="${1:-}"

# package TOOL / fallback TOOL
package() {
  case "$1" in
    claude)   echo "@anthropic-ai/claude-code" ;;
    codex)    echo "@openai/codex" ;;
    gemini)   echo "@google/gemini-cli" ;;
    opencode) echo "opencode-ai" ;;
    uv)       echo "uv" ;;
    *) return 1 ;;
  esac
}
fallback() {
  case "$1" in
    claude)   echo "2.1.304" ;;
    codex)    echo "0.145.0" ;;
    gemini)   echo "0.51.0" ;;
    opencode) echo "1.18.4" ;;
    uv)       echo "0.12.0" ;;
  esac
}

case "$tool" in
  --package)  package "${2:-}"; exit ;;
  --fallback) fallback "${2:-}"; exit ;;
esac
pkg="$(package "$tool")" || { echo "usage: install-harness-cli.sh [--prefix DIR] [--latest-json FILE] TOOL" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/check-harness-cli.sh"
[ -x "$check" ] || check="$(command -v check-harness-cli.sh)"

# retry CMD...: three attempts, five seconds apart (transient registry errors).
retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    [ "$n" -lt 3 ] || return 1
    echo "install-harness-cli: '$*' failed (attempt $n/3), retrying in 5s..." >&2
    sleep 5
  done
}

npm_install() {
  if [ -n "$prefix" ]; then
    retry npm install -g --prefix "$prefix" "$pkg@$1"
  else
    retry npm install -g "$pkg@$1"
  fi
}

bin_path() {
  if [ "$tool" = uv ]; then
    echo "${UV_INSTALL_DIR:-$HOME/.local/bin}/uv"
  elif [ -n "$prefix" ]; then
    echo "$prefix/bin/$tool"
  else
    echo "$(npm prefix -g)/bin/$tool"
  fi
}

uv_install() {
  if [ "$1" = latest ] && [ -n "$latest_json" ]; then
    sh "$latest_json"
  elif [ "$1" = latest ]; then
    curl -LsSf --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 https://astral.sh/uv/install.sh | sh
  else
    curl -LsSf --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 "https://astral.sh/uv/$1/install.sh" | sh
  fi
}

install_version() {
  if [ "$tool" = uv ]; then uv_install "$1"; else npm_install "$1"; fi
}

latest="latest"
if [ "$tool" != uv ] && [ -n "$latest_json" ]; then
  latest="$(jq -r '.version // empty' "$latest_json" 2>/dev/null || true)"
  [ -n "$latest" ] || latest="latest"
fi

if install_version "$latest" && "$check" --bin "$(bin_path)" "$tool"; then
  exit 0
fi

fb="$(fallback "$tool")"
echo "install-harness-cli: WARNING: $pkg@$latest failed to install or failed its check; installing the known-good $fb" >&2
install_version "$fb"
"$check" --bin "$(bin_path)" "$tool"
