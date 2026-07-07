#!/usr/bin/env bash
# repro-web-bug.sh — minimal, runnable reproduction of the Lyric.Web library
# bug documented in docs/BUILD.md's "Dependencies" section: the HTTP server
# crashes while attempting to answer its first request.
#
# This is a Lyric.Web (library) bug, not one of the seven upstream Lyric
# *compiler* bugs tracked by scripts/repro-compiler-bug.sh — kept as a
# separate, sibling script for that reason (see docs/BUILD.md).
#
# Root cause: Lyric.Web's serve() builds its HTTP response body via an
# @externTarget-wrapped call equivalent to Encoding.GetBytes(payload). That
# call fails at runtime with "Method not found: 'Byte[]
# System.Text.Encoding.GetBytes(System.Text.Encoding, System.String)'" — the
# compiler's extern-instance-method binding mis-generates the call, treating
# the Encoding receiver as an ordinary first argument instead of the implicit
# `this`. Already tracked upstream as part of lyric-lang#3887 ("BCL
# @externTarget metadata resolution"), which explicitly lists
# Encoding.GetBytes as an affected instance method — this script exists to
# mechanically detect when that's eventually fixed for this specific call,
# rather than needing this project's own re-investigation each time
# Lyric.Web's pinned version bumps.
#
# Reads the currently-pinned Lyric.Web version straight out of this
# project's own lyric.toml, so bumping that pin and re-running this script
# is enough to check whether the fix has landed — no separate version to
# keep in sync by hand.
#
# NOTE for anyone tempted to add @externInstance to the encodingGetBytes
# declaration below: don't. Lyric.Web's own real source doesn't have it
# either (confirmed at both the pinned v0.4.11 tag and current main), and
# adding it makes this specific call resolve correctly on every compiler
# version tried so far — including ones that provably still crash inside
# Lyric.Web's actual compiled serve() at runtime. This script exists to
# model the exact unannotated shape Lyric.Web ships, not "best practice"
# Lyric written from scratch — see the inline comment at the declaration
# for the full reasoning.
#
# Requirements: lyric on PATH, dotnet on PATH, network access to nuget.org
# (a real [nuget] restore is needed — this isn't reproducible without one,
# since it's Lyric.Web's own compiled code that's at fault, not this
# project's source).
#
# Exit codes match scripts/repro-compiler-bug.sh's convention: 0 = did not
# reproduce (fixed, or skipped because nuget.org wasn't reachable), 1 = bug
# reproduced, 2 = couldn't run the check at all (missing tool, unexpected
# build failure) — distinct from 1 so a setup problem is never mistaken for
# a confirmed-still-broken result.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v lyric  >/dev/null || { echo "repro-web-bug: 'lyric' not on PATH"  >&2; exit 2; }
command -v dotnet >/dev/null || { echo "repro-web-bug: 'dotnet' not on PATH" >&2; exit 2; }

WEB_VERSION="$(sed -n 's/^"Lyric\.Web"[[:space:]]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' "$REPO_ROOT/lyric.toml" | head -1)"
[ -n "$WEB_VERSION" ] || { echo "repro-web-bug: could not read Lyric.Web version from lyric.toml" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/webbug/src"
cat > "$WORK/webbug/lyric.toml" <<TOML
[package]
name = "WebBugTest"
version = "0.1.0"
[project]
name = "WebBugTest"
output = "single"
output_assembly = "WebBugTest.dll"
[project.packages]
"WebBugTest" = "src/main.l"
[nuget]
"Lyric.Web" = "$WEB_VERSION"
TOML

# Replicates Lyric.Web's own serve()-loop extern-binding sequence directly
# (rather than starting a real listener), isolating the failure to the single
# GetBytes call — mirrors the minimal repro built during this bug's original
# investigation.
cat > "$WORK/webbug/src/main.l" <<'LYRIC'
package WebBugTest

import Std.Core

extern type Encoding = "System.Text.Encoding"

@externTarget("System.Text.Encoding.get_UTF8")
func encodingUtf8(): Encoding = ()

// Deliberately NOT @externInstance, matching Lyric.Web's own real source
// exactly (lyric-web/src/web.l, both the pinned v0.4.11 tag and current
// main both declare this identically): adding @externInstance here makes
// this call resolve correctly on every compiler version tried so far,
// including the ones that provably still crash inside Lyric.Web's actual
// compiled serve() at runtime — annotating it would make this script
// silently stop testing the thing it exists to test. This is intentionally
// modeling the unannotated shape Lyric.Web actually ships (which relies on
// the compiler inferring instance-vs-static without a hint — lyric-lang#3887's
// own remaining-work section is specifically about making that inference
// correct), not "best practice" Lyric written from scratch.
@externTarget("System.Text.Encoding.GetBytes")
func encodingGetBytes(enc: in Encoding, str: in String): slice[Byte] = ()

func main(): Unit {
  val utf8 = encodingUtf8()
  val bytes = encodingGetBytes(utf8, "{\"hello\":\"world\"}")
  println("bytes.length=" + bytes.length.toString())
}
LYRIC

echo "==> Lyric.Web $WEB_VERSION: Encoding.GetBytes extern-binding against a trivial single-file project (lyric-lang#3887)"
restore_output="$(cd "$WORK/webbug" && lyric restore 2>&1)"
restore_status=$?
if [ "$restore_status" -ne 0 ]; then
  echo "$restore_output" >&2
  echo "==> skipped: 'lyric restore' failed (exit $restore_status) — likely no network access to nuget.org, not a library bug" >&2
  exit 0
fi

build_output="$(cd "$WORK/webbug" && lyric build 2>&1)"
build_status=$?
echo "$build_output"
if [ "$build_status" -ne 0 ]; then
  echo "==> Unexpected: build itself failed (exit $build_status) — not the known runtime-only signature, investigate separately" >&2
  exit 2
fi

run_output="$(cd "$WORK/webbug" && dotnet bin/WebBugTest.dll 2>&1)"
run_status=$?
echo "$run_output"

if [ "$run_status" -ne 0 ] && echo "$run_output" | grep -q "Method not found: 'Byte\[\] System.Text.Encoding.GetBytes"; then
  echo "==> Reproduced: Lyric.Web $WEB_VERSION still can't call Encoding.GetBytes via @externTarget at runtime (lyric-lang#3887)"
  exit 1
elif [ "$run_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $run_status) — not the known signature, investigate separately" >&2
  exit 2
else
  echo "==> Did NOT fail: Lyric.Web $WEB_VERSION resolves Encoding.GetBytes at runtime — lyric-lang#3887 is fixed for this call"
  exit 0
fi
