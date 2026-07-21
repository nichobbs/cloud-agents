#!/usr/bin/env bash
# Regression test for the Lyric-version-resolution shell logic shared by
# ci.yml's "Resolve latest Lyric release" step and docker/Dockerfile's
# shim-builder stage (#654), plus the empty-vs-pinned ARG parsing added to
# ci.yml's "(if pinned)" floor/existence checks.
#
# This doesn't spin up a real HTTP call — it feeds representative sample text
# through the exact same sed/tr one-liners the real steps run, so a future
# edit to those patterns (or a GitHub response-format change this project
# happens to notice) is caught mechanically instead of only being verified by
# hand in a sandbox, per #660.
set -euo pipefail

fails=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $desc"
  else
    echo "FAIL $desc (expected '$expected', got '$actual')" >&2
    fails=$((fails + 1))
  fi
}

# ── Resolve-latest extraction: curl -sI .../releases/latest | sed | tr -d '\r' ──
# Real `curl -sI` output uses \r\n line endings; a redirect response looks
# like this (trimmed to the header this pattern actually cares about).
extract_latest() {
  printf '%s' "$1" | sed -n 's/.*tag\/v\([0-9.]*\).*/\1/p' | tr -d '\r'
}

check_eq "extracts version from a normal Location header" \
  "0.4.34" \
  "$(extract_latest $'HTTP/1.1 302 Found\r\nlocation: https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.34\r\n')"

check_eq "handles the capitalized 'Location:' header form" \
  "0.4.19" \
  "$(extract_latest $'HTTP/1.1 302 Found\r\nLocation: https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.19\r\n')"

check_eq "extracts nothing from a header with no tag/vX.Y.Z path" \
  "" \
  "$(extract_latest $'HTTP/1.1 200 OK\r\ncontent-type: text/html\r\n')"

# ── Pinned-ARG parsing: sed -n 's/^ARG LYRIC_VERSION=\(.*\)$/\1/p' | tr -d '"' ──
extract_pin() {
  printf '%s\n' "$1" | sed -n 's/^ARG LYRIC_VERSION=\(.*\)$/\1/p' | tr -d '"'
}

check_eq "empty-by-default ARG resolves to an empty string" \
  "" \
  "$(extract_pin 'ARG LYRIC_VERSION=""')"

check_eq "a quoted pin is extracted with quotes stripped" \
  "0.4.34" \
  "$(extract_pin 'ARG LYRIC_VERSION="0.4.34"')"

check_eq "an unquoted pin is extracted as-is" \
  "0.4.34" \
  "$(extract_pin 'ARG LYRIC_VERSION=0.4.34')"

check_eq "a non-matching line yields nothing" \
  "" \
  "$(extract_pin 'ARG SOME_OTHER_VAR=1')"

# ── sort -V floor comparison (used by both the resolve-latest and pinned paths) ──
lowest_of() { printf '%s\n%s\n' "$1" "$2" | sort -V | head -1; }

check_eq "a version above the floor sorts the floor as lowest" \
  "0.4.19" \
  "$(lowest_of "0.4.19" "0.4.34")"

check_eq "a version below the floor sorts itself as lowest" \
  "0.4.9" \
  "$(lowest_of "0.4.19" "0.4.9")"

check_eq "an equal version sorts as the floor (not a failure)" \
  "0.4.19" \
  "$(lowest_of "0.4.19" "0.4.19")"

if [ "$fails" -gt 0 ]; then
  echo "test-lyric-version-resolution: $fails check(s) failed" >&2
  exit 1
fi
echo "test-lyric-version-resolution: all checks passed"
