#!/usr/bin/env bash
# repro-compiler-bug.sh — minimal, runnable reproduction of the upstream Lyric
# compiler crash referenced throughout docs/BUILD.md, docs/PROGRESS.md,
# AGENTS.md, and this project's build scripts.
#
# Builds a trivial, dependency-free "hello world" Lyric project (no
# [nuget]/[workspace]/anything project-specific) and runs `lyric build`
# against it. On every released compiler through 0.4.10 this crashes with an
# unhandled System.InvalidCastException inside the compiler's own
# `buildProject`, before it does anything project-specific — proving the
# crash is a property of the compiler, not of this repo's manifest or
# source. See https://github.com/nichobbs/lyric-lang/issues/4925 (closed,
# fixed by https://github.com/nichobbs/lyric-lang/pull/4955 — merged but not
# yet in a tagged release as of this writing).
#
# Only requires `lyric` on PATH — no `dotnet` needed, since the crash occurs
# before the compiler gets to invoking the .NET toolchain.
#
# Exit code: 0 if the crash reproduces (confirms you're still on a
# pre-#4955 compiler); 1 if `lyric build` succeeds (confirms your compiler
# already has the fix — safe to remove this script and the workaround notes
# it supports); 2 for any other unexpected failure.
set -uo pipefail

command -v lyric >/dev/null || { echo "repro: 'lyric' not on PATH" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/src"
cat > "$WORK/lyric.toml" <<'TOML'
[package]
name = "MinTest"
version = "0.1.0"
[project]
name = "MinTest"
output = "single"
output_assembly = "MinTest.dll"
[project.packages]
"MinTest" = "src/main.l"
TOML
cat > "$WORK/src/main.l" <<'LYRIC'
package MinTest
import Std.Core
func main(): Unit { println("hello") }
LYRIC

echo "==> lyric build against a trivial, dependency-free hello-world"
output="$(cd "$WORK" && lyric build 2>&1)"
status=$?
echo "$output"

if [ "$status" -ne 0 ] && echo "$output" | grep -q "System.InvalidCastException"; then
  echo "==> Reproduced: this compiler still has the workspace_builder.l bug (lyric-lang#4925/#4955)"
  exit 0
elif [ "$status" -eq 0 ]; then
  echo "==> Did NOT crash: this compiler build already includes the lyric-lang#4955 fix"
  exit 1
else
  echo "==> Unexpected failure (exit $status) — not the known crash signature, investigate separately" >&2
  exit 2
fi
