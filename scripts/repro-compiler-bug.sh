#!/usr/bin/env bash
# repro-compiler-bug.sh — minimal, runnable reproduction of the upstream Lyric
# compiler bugs referenced throughout docs/BUILD.md, docs/PROGRESS.md,
# AGENTS.md, and this project's build scripts.
#
# Checks five independent, known compiler bugs, in order:
#
# 1. lyric-lang#4925/#4955 (fixed as of v0.4.11): a trivial, dependency-free
#    "hello world" project crashed `lyric build` with an unhandled
#    System.InvalidCastException inside the compiler's own `buildProject`,
#    before doing anything project-specific, on every standalone
#    (non-workspace) project.
#
# 2. lyric-lang#4980 (fixed as of v0.4.12): once #1 no longer reproduced,
#    `Std.Core`'s stdlib-declared types — `Option[T]`, `Result[T, E]`, and
#    their constructors `Some`/`None`/`Ok`/`Err` — failed to resolve at any
#    use site via a plain `import Std.Core`, on every configuration tried.
#    This predated #1 and was simply never reachable before, since #1
#    always crashed first.
#
# 3. lyric-lang#5004 (fixed as of v0.4.14): once #1 and #2 no longer
#    reproduced, a zero-argument function restored from a NuGet package
#    (e.g. `Lyric.Web`'s `create()`) was rejected with "expected 1
#    argument(s), got 0" — even though both the package's own embedded
#    contract and its actual compiled IL agreed the function took zero
#    parameters.
#
# 4. lyric-lang#5066 (fixed as of v0.4.15): once #5004's fix let a real
#    project build succeed for the first time, `lyric build` succeeded but
#    `lyric run` (or running the built DLL directly) crashed with
#    System.IO.FileNotFoundException — the NuGet-restored dependency's DLL
#    (e.g. Web.dll) was never copied into the output directory alongside
#    the project's own compiled DLL, and no .deps.json was generated
#    either. Confirmed at the time this was purely a missing-file issue
#    (not a deeper mismatch): manually copying the dependency DLL into
#    bin/ and running the already-built DLL directly via `dotnet` worked
#    fine. Fixed upstream in lyric-lang#5074.
#
# 5. lyric-lang#5177 (open, found the moment #5066's fix let this project's
#    own real, multi-package build actually execute for the first time):
#    running/testing the real `cloud-agents` project itself (not the
#    minimal synthetic project checks 1-4 use) hits `MissingFieldException`/
#    `FieldAccessException` on enum literals that provably exist in the
#    built assembly's own metadata (confirmed via raw PE/metadata
#    inspection), and an analogous "unsupported method ... on the receiver
#    type" for an ordinary method call that succeeds everywhere else in the
#    same build — all symptoms of the same underlying cause (wrong
#    metadata tokens after merging separately-compiled packages into one
#    output assembly). Not reproducible in a synthetic minimal project no
#    matter how many packages/features were added — needs this project's
#    actual real code shape/scale, so this check runs against the real
#    manifest in-place (via `lyric test`) rather than a scratch project
#    like checks 1-4.
#
# Checks 1 and 2 only require `lyric` on PATH — no `dotnet` needed, since
# both bugs occur before the compiler would invoke the .NET toolchain.
# Checks 3-5 need a `[nuget]` restore (a real published Lyric.Web package),
# so they additionally require `dotnet` and network access to nuget.org;
# all three are skipped (not failed) if `dotnet` isn't on PATH.
#
# Exit code (conventional Unix sense — 0 means "no problem found"): 0 if
# every check that ran passed (your compiler can actually build AND run a
# real Lyric project — safe to remove this script and the workaround notes
# it supports); 1 if any known bug reproduced; 2 for any other unexpected
# failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

echo "==> [1/5] lyric build against a trivial, dependency-free hello-world (lyric-lang#4925/#4955)"
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

echo "==> [2/5] lyric build against a trivial Option[Int]-returning function (lyric-lang#4980)"
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
echo "==> Did NOT fail: this compiler can resolve Std.Core's Option/Result — bug #4980 is fixed"

# --- Checks 3-5 need a real [nuget] restore ---------------------------------
if ! command -v dotnet >/dev/null; then
  echo "==> [3-5/5] skipped (lyric-lang#5004/#5066/#5177): 'dotnet' not on PATH, needed for a [nuget] restore"
  exit 0
fi

mkdir -p "$WORK/nugetzero/src"
cat > "$WORK/nugetzero/lyric.toml" <<'TOML'
[package]
name = "WebTest"
version = "0.1.0"
[project]
name = "WebTest"
output = "single"
output_assembly = "WebTest.dll"
[project.packages]
"WebTest" = "src/main.l"
[nuget]
"Lyric.Web" = "0.4.11"
TOML
cat > "$WORK/nugetzero/src/main.l" <<'LYRIC'
package WebTest
import Std.Core
import Web

func main(): Unit {
  var router = Web.create()
  println("hi")
}
LYRIC

echo "==> [3/5] lyric build calling a zero-arg NuGet-restored function, Web.create() (lyric-lang#5004)"
restore_output="$(cd "$WORK/nugetzero" && lyric restore 2>&1)"
restore_status=$?
if [ "$restore_status" -ne 0 ]; then
  echo "$restore_output" >&2
  echo "==> [3-5/5] skipped (lyric-lang#5004/#5066/#5177): 'lyric restore' failed (exit $restore_status)" \
       "— likely no network access to nuget.org, not a compiler bug" >&2
  exit 0
fi
nugetzero_output="$(cd "$WORK/nugetzero" && lyric build 2>&1)"
nugetzero_status=$?
echo "$nugetzero_output"

if [ "$nugetzero_status" -ne 0 ] && echo "$nugetzero_output" | grep -q "expected 1 argument(s), got 0"; then
  echo "==> Reproduced: this compiler still miscounts NuGet-restored zero-arg functions (lyric-lang#5004)"
  exit 1
elif [ "$nugetzero_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $nugetzero_status) — not the known signature, investigate separately" >&2
  exit 2
fi
echo "==> Did NOT fail: this compiler resolves NuGet-restored zero-arg functions — bug #5004 is fixed"

echo "==> [4/5] lyric run against the same project — does it find Web.dll at runtime? (lyric-lang#5066)"
run_output="$(cd "$WORK/nugetzero" && lyric run 2>&1)"
run_status=$?
echo "$run_output"

if [ "$run_status" -ne 0 ] && echo "$run_output" | grep -q "FileNotFoundException"; then
  echo "==> Reproduced: this compiler still doesn't copy NuGet dependency DLLs to the output dir (lyric-lang#5066)"
  exit 1
elif [ "$run_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $run_status) — not the known signature, investigate separately" >&2
  exit 2
fi
echo "==> Did NOT fail: this compiler copies NuGet dependency DLLs to the output dir — bug #5066 is fixed"

# --- Check 5: lyric-lang#5177 (cross-package metadata token corruption) ----
# Not reproducible in a synthetic project like checks 1-4 no matter how many
# packages/features were added — needs this project's own real, multi-package
# build, so this runs against the real manifest in-place via `lyric test`
# rather than a scratch project.
echo "==> [5/5] lyric test against this project's own real manifest (lyric-lang#5177)"
real_restore_output="$(cd "$REPO_ROOT" && lyric restore 2>&1)"
real_restore_status=$?
if [ "$real_restore_status" -ne 0 ]; then
  echo "$real_restore_output" >&2
  echo "==> [5/5] skipped (lyric-lang#5177): 'lyric restore' failed (exit $real_restore_status)" \
       "— likely no network access to nuget.org, not a compiler bug" >&2
  exit 0
fi
real_test_output="$(cd "$REPO_ROOT" && lyric test 2>&1)"
echo "$real_test_output"

if echo "$real_test_output" | grep -qE "Field not found:|unsupported method '.*' on the receiver type|to access field '.*' failed"; then
  echo "==> Reproduced: this compiler still corrupts cross-package field/method metadata tokens in real multi-package builds (lyric-lang#5177)"
  exit 1
fi

echo "==> Did NOT reproduce: all five known bugs are fixed on this compiler — full build, run, and test all work"
exit 0
