#!/usr/bin/env bash
# ci-test-shard.sh — run one shard of the root project's `lyric test` suites.
#
# Usage: scripts/ci-test-shard.sh <shard-index> <shard-count>   (index is 0-based)
#
# `lyric test` compiles the whole project into a separate assembly for every
# [project.tests] entry (cmdTestManifest in lyric-lang's cli_test.l), so the
# run is dominated by ~70 full compiles, not by the tests themselves. CI splits
# the suites across a job matrix: this writes lyric.shard.toml beside
# lyric.toml, a copy with [project.tests] cut down to every <count>-th entry
# starting at <index>, and runs `lyric test` against it. Round-robin covers
# every suite exactly once for a given count, so a suite added to lyric.toml
# is picked up with no change here. NuGet assets resolve from the manifest's
# directory, so a prior `lyric restore` of lyric.toml serves the shard too.
#
# Requirements on PATH: lyric, dotnet (10.x).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ $# -eq 2 ] || { echo "usage: $0 <shard-index> <shard-count>" >&2; exit 2; }
index="$1"
count="$2"
case "$index$count" in *[!0-9]*) echo "ci-test-shard: index and count must be integers" >&2; exit 2 ;; esac
[ "$count" -ge 1 ] && [ "$index" -lt "$count" ] || { echo "ci-test-shard: need 0 <= index < count" >&2; exit 2; }

command -v lyric >/dev/null || { echo "ci-test-shard: 'lyric' not on PATH" >&2; exit 1; }

cd "$REPO_ROOT"
SHARD="lyric.shard.toml"

awk -v idx="$index" -v n="$count" '
  /^\[/ { in_tests = ($0 == "[project.tests]") }
  in_tests && /^"/ {
    if (seen++ % n != idx) next
    kept++
  }
  { print }
  END { if (kept == 0) exit 3 }
' lyric.toml > "$SHARD" || { echo "ci-test-shard: shard $index/$count selected no suites" >&2; exit 1; }

echo "==> shard $index/$count runs:"
sed -n '/^\[project.tests\]/,/^\[/p' "$SHARD" | grep '^"' | sed 's/^/    /'

lyric test --manifest "$SHARD"
