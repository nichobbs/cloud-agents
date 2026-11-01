#!/usr/bin/env bash
# write-build-info.sh — record WHICH toolchain and libraries a build resolved.
#
# The compiler and the NuGet libraries float to the latest release (AGENTS.md
# "Toolchain policy"), so a built image no longer names the versions it was built
# with by construction. This writes them to bin/build-info.txt (copied into the
# runtime image next to CloudAgents.dll, and printed by the API at startup), so an
# operator can see what a deployed image actually runs and reproduce it with
# `--build-arg LYRIC_VERSION=...` plus the library versions listed here.
#
# Run after `lyric restore`/`lyric build` (scripts/build-full.sh). Needs only
# bash, grep, sort, sed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$REPO_ROOT/bin}"
ASSETS="${BUILD_INFO_ASSETS:-$REPO_ROOT/obj/project.assets.json}"

command -v lyric >/dev/null || { echo "write-build-info: 'lyric' not on PATH" >&2; exit 1; }
[ -f "$ASSETS" ] || { echo "write-build-info: $ASSETS not found - run lyric restore first" >&2; exit 1; }
mkdir -p "$OUT_DIR"

{
  echo "lyric: $(lyric --version | awk '{print $NF}')"
  echo "dotnet: $(dotnet --version)"
  echo "min_lyric_version: $(tr -d '[:space:]' < "$REPO_ROOT/MIN_LYRIC_VERSION")"
  echo "nuget:"
  # Resolved packages are the "<Name>/<version>" keys of the lockless assets file.
  grep -oE '"[A-Za-z0-9._-]+/[0-9][0-9A-Za-z.+-]*": \{' "$ASSETS" \
    | sed -E 's/^"([^/]+)\/([^"]+)": \{/\1 \2/' | sort -u | sed 's/^/  /'
} > "$OUT_DIR/build-info.txt"

echo "write-build-info: wrote $OUT_DIR/build-info.txt ($(wc -l < "$OUT_DIR/build-info.txt") lines)"
