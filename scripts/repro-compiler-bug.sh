#!/usr/bin/env bash
# repro-compiler-bug.sh — minimal, runnable reproduction of the upstream Lyric
# compiler bugs referenced throughout docs/BUILD.md, docs/PROGRESS.md,
# AGENTS.md, and this project's build scripts.
#
# Checks two independent, known compiler bugs, in order:
#
# 1. lyric-lang#4925/#4955 (fixed upstream, merged, not yet in a tagged
#    release as of the last time this was checked): a trivial, dependency-
#    free "hello world" project crashed `lyric build` with an unhandled
#    System.InvalidCastException inside the compiler's own `buildProject`,
#    before doing anything project-specific, on every standalone
#    (non-workspace) project.
#
# 2. lyric-lang#4980 (open, found while checking whether #4955 actually
#    unblocks real builds): once #1 no longer reproduces, `Std.Core`'s
#    stdlib-declared types — `Option[T]`, `Result[T, E]`, and their
#    constructors `Some`/`None`/`Ok`/`Err` — fail to resolve at any use site
#    via a plain `import Std.Core`, on every configuration tried (standalone,
#    multi-package, with/without [nuget], workspace-wrapped) and on both
#    0.4.10 (once routed around bug #1 via workspace-wrapping) and 0.4.11 —
#    so this bug predates #4925/#4955 and was simply never reachable before,
#    since bug #1 always crashed first. This blocks essentially any real
#    Lyric program: `docs/lyric/idioms.md`'s own canonical patterns (`Result`
#    propagation, `Option`-returning lookups) can't compile until this is
#    fixed, which is why this project's build stays red even past bug #1.
#
# Only requires `lyric` on PATH — no `dotnet` needed, since both bugs occur
# before the compiler would invoke the .NET toolchain.
#
# Exit code (conventional Unix sense — 0 means "no problem found"): 0 if
# both checks pass (your compiler can actually build a real Lyric project —
# safe to remove this script and the workaround notes it supports); 1 if
# either bug reproduces; 2 for any other unexpected failure.
set -uo pipefail

command -v lyric >/dev/null || { echo "repro: 'lyric' not on PATH" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Check 1: lyric-lang#4925/#4955 (buildProject crash) -------------------
mkdir -p "$WORK/crash/src"
cat > "$WORK/crash/lyric.toml" <<'TOML'
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
cat > "$WORK/crash/src/main.l" <<'LYRIC'
package MinTest
import Std.Core
func main(): Unit { println("hello") }
LYRIC

echo "==> [1/2] lyric build against a trivial, dependency-free hello-world (lyric-lang#4925/#4955)"
crash_output="$(cd "$WORK/crash" && lyric build 2>&1)"
crash_status=$?
echo "$crash_output"

if [ "$crash_status" -ne 0 ] && echo "$crash_output" | grep -q "System.InvalidCastException"; then
  echo "==> Reproduced: this compiler still has the workspace_builder.l crash (lyric-lang#4925/#4955)"
  exit 1
elif [ "$crash_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $crash_status) — not the known crash signature, investigate separately" >&2
  exit 2
fi
echo "==> Did NOT crash: this compiler build already includes the lyric-lang#4955 fix"

# --- Check 2: lyric-lang#4980 (Std.Core Option/Result resolution) ----------
mkdir -p "$WORK/stdcore/src"
cat > "$WORK/stdcore/lyric.toml" <<'TOML'
[package]
name = "StdCoreTest"
version = "0.1.0"
[project]
name = "StdCoreTest"
output = "single"
output_assembly = "StdCoreTest.dll"
[project.packages]
"StdCoreTest" = "src/main.l"
TOML
cat > "$WORK/stdcore/src/main.l" <<'LYRIC'
package StdCoreTest
import Std.Core

func find(x: in Int): Option[Int] {
  if x > 0 { return Some(value = x) }
  return None
}

func main(): Unit { println("hello") }
LYRIC

echo "==> [2/2] lyric build against a trivial Option[Int]-returning function (lyric-lang#4980)"
stdcore_output="$(cd "$WORK/stdcore" && lyric build 2>&1)"
stdcore_status=$?
echo "$stdcore_output"

if [ "$stdcore_status" -ne 0 ] && echo "$stdcore_output" | grep -q "unknown type name 'Option'"; then
  echo "==> Reproduced: this compiler still can't resolve Std.Core's Option/Result (lyric-lang#4980)"
  exit 1
elif [ "$stdcore_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $stdcore_status) — not the known signature, investigate separately" >&2
  exit 2
fi

echo "==> Did NOT fail: this compiler can resolve Std.Core's Option/Result — both known bugs are fixed"
exit 0
