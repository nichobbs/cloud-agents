#!/usr/bin/env bash
# repro-compiler-bug.sh — minimal, runnable reproduction of the upstream Lyric
# compiler bugs referenced throughout docs/BUILD.md, docs/PROGRESS.md,
# AGENTS.md, and this project's build scripts.
#
# Checks three independent, known compiler bugs, in order:
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
# 3. lyric-lang#5004 (open, found while checking whether #4980's fix
#    actually unblocks real builds): once #1 and #2 no longer reproduce, a
#    zero-argument function restored from a NuGet package (e.g. `Lyric.Web`'s
#    `create()`) is rejected with "expected 1 argument(s), got 0" — even
#    though both the package's own embedded contract and its actual compiled
#    IL agree the function takes zero parameters. A project-local
#    (source-compiled, non-NuGet) zero-arg cross-package call is unaffected,
#    so this looks specific to how the compiler derives an argument count
#    from a NuGet package's serialized contract.
#
# Checks 1 and 2 only require `lyric` on PATH — no `dotnet` needed, since
# both bugs occur before the compiler would invoke the .NET toolchain. Check
# 3 needs a `[nuget]` restore (a real published Lyric.Web package), so it
# additionally requires `dotnet` and network access to nuget.org; it's
# skipped (not failed) if `dotnet` isn't on PATH.
#
# Exit code (conventional Unix sense — 0 means "no problem found"): 0 if
# every check that ran passed (your compiler can actually build a real
# Lyric project — safe to remove this script and the workaround notes it
# supports); 1 if any known bug reproduced; 2 for any other unexpected
# failure.
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

echo "==> [1/3] lyric build against a trivial, dependency-free hello-world (lyric-lang#4925/#4955)"
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

echo "==> [2/3] lyric build against a trivial Option[Int]-returning function (lyric-lang#4980)"
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

# --- Check 3: lyric-lang#5004 (NuGet-contract zero-arg arg-count bug) ------
if ! command -v dotnet >/dev/null; then
  echo "==> [3/3] skipped (lyric-lang#5004): 'dotnet' not on PATH, needed for a [nuget] restore"
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

echo "==> [3/3] lyric build calling a zero-arg NuGet-restored function, Web.create() (lyric-lang#5004)"
( cd "$WORK/nugetzero" && lyric restore ) >/dev/null 2>&1
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

echo "==> Did NOT fail: all three known bugs are fixed on this compiler"
exit 0
