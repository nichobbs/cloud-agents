#!/usr/bin/env bash
# install-harness-cli.sh: installs the newest release of a harness CLI or of uv
# that is at least HARNESS_CLI_MIN_AGE_DAYS old (default 7), verified with
# check-harness-cli.sh, falling back to the last release known to work when
# that release fails the check.
#
# Usage: install-harness-cli.sh [--prefix DIR] [--latest-json FILE] TOOL
#        install-harness-cli.sh --package TOOL | --fallback TOOL
#   TOOL           claude | codex | gemini | opencode | uv
#   --prefix DIR   npm install prefix (default: npm's global prefix). Ignored
#                  for uv, which installs into UV_INSTALL_DIR.
#   --latest-json  the npm registry's `latest` metadata for the package (for
#                  uv, its installer script), which the Dockerfiles ADD so that
#                  Docker reruns the install layer when a new version is
#                  published. With HARNESS_CLI_MIN_AGE_DAYS=0 its version is
#                  installed directly; otherwise it only triggers the rerun.
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

# The cool-down: take the newest stable release published at least
# HARNESS_CLI_MIN_AGE_DAYS days ago (default 7). A compromised release is
# usually caught and pulled within days, so this keeps the images close to
# current without installing a release on the day it ships. 0 takes the
# newest release.
min_age="${HARNESS_CLI_MIN_AGE_DAYS:-7}"
if ! [[ "$min_age" =~ ^[0-9]+$ ]]; then
  echo "install-harness-cli: HARNESS_CLI_MIN_AGE_DAYS must be a whole number of days, not '$min_age'" >&2
  exit 2
fi

# settled_versions CUTOFF NEWEST: reads {"x.y.z": "publish time", ...} on stdin
# and prints, highest first, the three highest x.y.z published before CUTOFF
# and no higher than NEWEST (the `latest` tag, so a release kept off it, such
# as a pre-release line, is never chosen). Pre-releases are skipped.
settled_versions() {
  jq -r --arg cutoff "$1" --arg newest "$2" '
    def num: split(".") | map(tonumber);
    def stable: test("^[0-9]+\\.[0-9]+\\.[0-9]+$");
    (if ($newest | stable) then ($newest | num) else null end) as $max
    | [ to_entries[]
        | select((.key | stable) and (.value | type == "string") and .value < $cutoff)
        | .key | num
        | select($max == null or . <= $max) ]
    | sort | reverse | .[:3][] | map(tostring) | join(".")'
}

# release_times / newest_release: the publish time of every release that can
# still be installed, and the release the registry currently calls latest.
# npm keeps publish times for unpublished versions, so only versions it still
# lists count; on PyPI a release whose files are all yanked doesn't count.
release_times() {
  if [ "$tool" = uv ]; then
    curl -fsS --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 https://pypi.org/pypi/uv/json \
      | jq '.releases | with_entries(.value |= map(select(.yanked != true)) | select(.value | length > 0)
                                     | .value |= (map(.upload_time_iso_8601) | min))'
  else
    retry npm view "$pkg" time versions --json \
      | jq '(.versions | if type == "array" then . else [.] end) as $listed
            | .time | with_entries(select(.key as $k | $listed | index($k)))'
  fi
}
newest_release() {
  if [ "$tool" = uv ]; then
    curl -fsS --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 https://pypi.org/pypi/uv/json | jq -r '.info.version'
  else
    retry npm view "$pkg" dist-tags.latest
  fi
}

# candidates: the versions to try, best first.
if [ "$min_age" -eq 0 ]; then
  candidates="latest"
  if [ "$tool" != uv ] && [ -n "$latest_json" ]; then
    candidates="$(jq -r '.version // empty' "$latest_json" 2>/dev/null || true)"
    [ -n "$candidates" ] || candidates="latest"
  fi
else
  cutoff="$(date -u -d "@$(( $(date +%s) - min_age * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)"
  newest="$(newest_release 2>/dev/null || true)"
  candidates="$(release_times 2>/dev/null | settled_versions "$cutoff" "$newest" 2>/dev/null || true)"
  if [ -n "$candidates" ]; then
    echo "install-harness-cli: $pkg: newest release $newest; trying the newest at least $min_age days old: $(echo $candidates)" >&2
  else
    echo "install-harness-cli: WARNING: could not find a $pkg release at least $min_age days old" >&2
  fi
fi

# A candidate that fails to install or fails its check is followed by the next
# one, so one bad release doesn't drop all the way to the known-good fallback.
for version in $candidates; do
  if install_version "$version" && "$check" --bin "$(bin_path)" "$tool"; then
    exit 0
  fi
  echo "install-harness-cli: WARNING: $pkg@$version failed to install or failed its check" >&2
done

fb="$(fallback "$tool")"
echo "install-harness-cli: WARNING: installing the known-good $pkg@$fb" >&2
install_version "$fb"
"$check" --bin "$(bin_path)" "$tool"
