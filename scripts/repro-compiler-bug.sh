#!/usr/bin/env bash
# repro-compiler-bug.sh — minimal, runnable reproduction of the upstream Lyric
# compiler bugs referenced throughout docs/BUILD.md, docs/PROGRESS.md,
# AGENTS.md, and this project's build scripts.
#
# "Minimal" applies to checks 1-4 and 6-8, each a tiny scratch project in a
# mktemp'd workdir. Check 5 (lyric-lang#5177) is the one exception (#119):
# it needs this project's own real, multi-package build to reproduce at all
# (see that check's own comment), so it runs a full `lyric restore` + `lyric
# test` against REPO_ROOT in place — effectively duplicating the restore/
# build work the later "Build full server" step does and the `lyric test`
# run the later "Run lyric test" step does (not "Run tests", which runs
# scripts/verify.sh — a separate, dependency-free scratch harness that
# never touches the real manifest), moments later in the same job. That's
# an accepted, currently
# un-cached cost (not this script's own network/NuGet restore, so no
# `actions/cache` wiring shares it with those later steps) for catching a
# bug that genuinely can't be reproduced any smaller.
#
# Checks eight independent, known compiler bugs, in order:
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
# 5. lyric-lang#5177 (fixed as of v0.4.17): once #5066's fix let this
#    project's own real, multi-package build actually execute for the
#    first time, running/testing the real `cloud-agents` project itself
#    (not the minimal synthetic project checks 1-4 use) hit
#    `MissingFieldException`/`FieldAccessException` on enum literals that
#    provably exist in the built assembly's own metadata (confirmed via raw
#    PE/metadata inspection) — wrong metadata tokens after merging
#    separately-compiled packages into one output assembly. Root-caused
#    (after gaining direct access to nichobbs/lyric-lang) to an `async
#    func` awaiting an unqualified call into a package declared *later* in
#    `[project.packages]` (this project's `CloudAgents.Docker` → its
#    `import Lyric.Docker`, the last package in the bundle); a minimal
#    4-package repro is in this issue's history. Fixed upstream in
#    lyric-lang#5220. This check runs against the real manifest in place
#    (via `lyric test`) rather than a scratch project, since it was never
#    reproducible in an isolated synthetic project no matter how it was
#    scaled.
#
# 6. lyric-lang#5244 (fixed as of v0.4.18): `slice[T].append(x)` — the
#    compiler's own documented idiom for building up a slice — threw
#    `"unsupported method 'append'"` at runtime unconditionally, for any
#    element type, with no package structure or async code involved at all.
#    Built fine; failed only at runtime, meaning typecheck accepted the call
#    but MSIL codegen never actually lowered it. Not a regression — it
#    reproduced identically back to at least v0.4.15 — just never
#    runtime-exercised in this project until bugs 1-5 stopped masking it.
#    This was causing most of the `lyric test` failures in
#    `CloudAgents.SessionTests`/`AuthTests`, previously indistinguishable
#    from bug 5's symptoms until isolated to a standalone repro.
#
# 7. lyric-lang#5298 (fixed as of v0.4.19), found while diagnosing the one
#    `SessionTests` case that survived bug 6's fix: a package-scope
#    (top-level) `val` declared *without* an explicit type annotation, whose
#    initializer is a string literal, crashed at runtime with
#    `System.InvalidCastException: Unable to cast object of type
#    'System.String' to type 'System.Collections.IList'` when its `.length`
#    was read anywhere in the program — including same-package, unqualified,
#    no cross-package reference involved. Root-caused (after gaining direct
#    access to nichobbs/lyric-lang) to `lyric-compiler/msil/codegen.l`'s
#    package-level `val`/`const` pre-scan: it only recorded the declared
#    MSIL type when there was an explicit type annotation; when the type had
#    to be inferred from the initializer, it silently defaulted to
#    `MObject`, which routed `.length` through a fallback that assumed any
#    object-typed receiver is a List-backed slice and unconditionally cast
#    to `IList` — fine for slices, wrong for a boxed `System.String`.
#    Distinct from lyric-lang#5258 (a related but different MSIL bug,
#    *cross*-package qualified `pub val` access resolving to null, fixed a
#    day earlier): #5258's fix added qualified lookup keys but didn't touch
#    the untyped-inference gap this bug was about, so it didn't cover this
#    same-package case. `src/handlers/sessions.l`'s `createSession` reads
#    exactly such a top-level `val` (`httpsPrefix`), which is why
#    `CloudAgents.SessionTests`' "Test Handler createSession validation"
#    case used to fail `lyric test` even with bug 6 fixed — with bug 7 fixed
#    too, the full suite is 24/24 for the first time in this project's
#    history.
#
# 8. lyric-lang#6249 (open as of v0.4.35): in an `async func`, a local `val`
#    bound before one `await` and read again after a SECOND, different-
#    callee `await` in the same function silently loses its value — reads
#    back as the type's default ("" for String) instead of the value it was
#    bound to. No exception, no diagnostic. Contradicts the decision log's
#    own D088/D089 ("hoist all val bindings to SM fields"), which claims
#    exactly this was fixed and tested years ago — either a later async-
#    codegen refactor regressed it, or it's an edge case outside that
#    original test matrix (two DIFFERENT awaited callees specifically, not
#    the same callee awaited twice). This directly matches
#    `src/docker_manager.l`'s `runSessionMessageAsync` shape (a `client`/
#    `containerId` local needing to survive five sequential different-
#    callee awaits) and is the leading suspect for the recurring
#    `streamSessionMessage`/`AccessViolationException` production crash —
#    see `docs/lyric/gotchas.md` and PR #690's description for the full
#    analysis. Workaround: thread the value through a mutable record field
#    instead of a local `val` (confirmed to survive reliably across
#    multiple awaits, unlike a bare local).
#
# Checks 1 and 2 only require `lyric` on PATH — no `dotnet` needed, since
# both bugs occur before the compiler would invoke the .NET toolchain.
# Checks 3-8 all need `dotnet` on PATH (to run the built output); checks 3-5
# additionally need a `[nuget]` restore (a real published Lyric.Web
# package), so they also require network access to nuget.org. Checks 6-8
# need neither NuGet nor network — just `dotnet` to run a plain,
# dependency-free build. All are skipped (not failed) if `dotnet` isn't on
# PATH.
#
# Every check below always runs, regardless of what an earlier check found —
# one check hitting a known or unexpected failure must never prevent later,
# independent checks from running and reporting their own status.
#
# Exit code (conventional Unix sense — 0 means "no problem found"): 0 if
# every check that ran passed (your compiler can actually build AND run a
# real Lyric project — safe to remove this script and the workaround notes
# it supports); 1 if any known bug reproduced; 2 if any check hit an
# unexpected failure (not a bug signature this script knows about) — 2 wins
# over 1 if both occurred across different checks.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v lyric >/dev/null || { echo "repro: 'lyric' not on PATH" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Worst outcome seen across all checks so far: 0 = clean, 1 = a known bug
# reproduced, 2 = an unexpected failure. Only ever raised, never lowered,
# and only actually exited on at the very end of the script.
worst=0
note_reproduced() { [ "$worst" -lt 1 ] && worst=1; return 0; }
note_unexpected() { worst=2; return 0; }

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

echo "==> [1/8] lyric build against a trivial, dependency-free hello-world (lyric-lang#4925/#4955)"
crash_output="$(cd "$WORK/crash" && lyric build 2>&1)"
crash_status=$?
echo "$crash_output"

if [ "$crash_status" -ne 0 ] && echo "$crash_output" | grep -q "System.InvalidCastException"; then
  echo "==> Reproduced: this compiler still has the workspace_builder.l crash (lyric-lang#4925/#4955)"
  note_reproduced
elif [ "$crash_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $crash_status) — not the known crash signature, investigate separately" >&2
  note_unexpected
else
  echo "==> Did NOT crash: this compiler build already includes the lyric-lang#4955 fix"
fi

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

echo "==> [2/8] lyric build against a trivial Option[Int]-returning function (lyric-lang#4980)"
stdcore_output="$(cd "$WORK/stdcore" && lyric build 2>&1)"
stdcore_status=$?
echo "$stdcore_output"

if [ "$stdcore_status" -ne 0 ] && echo "$stdcore_output" | grep -q "unknown type name 'Option'"; then
  echo "==> Reproduced: this compiler still can't resolve Std.Core's Option/Result (lyric-lang#4980)"
  note_reproduced
elif [ "$stdcore_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $stdcore_status) — not the known signature, investigate separately" >&2
  note_unexpected
else
  echo "==> Did NOT fail: this compiler can resolve Std.Core's Option/Result — bug #4980 is fixed"
fi

# --- Checks 3-8 need dotnet (3-5 also need a real [nuget] restore) ---------
if ! command -v dotnet >/dev/null; then
  echo "==> [3-8/8] skipped (lyric-lang#5004/#5066/#5177/#5244/#5298/#6249): 'dotnet' not on PATH"
  exit "$worst"
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

echo "==> [3/8] lyric build calling a zero-arg NuGet-restored function, Web.create() (lyric-lang#5004)"
restore_output="$(cd "$WORK/nugetzero" && lyric restore 2>&1)"
restore_status=$?
if [ "$restore_status" -ne 0 ]; then
  echo "$restore_output" >&2
  echo "==> [3-4/8] skipped (lyric-lang#5004/#5066): 'lyric restore' failed (exit $restore_status)" \
       "— likely no network access to nuget.org, not a compiler bug" >&2
else
  nugetzero_output="$(cd "$WORK/nugetzero" && lyric build 2>&1)"
  nugetzero_status=$?
  echo "$nugetzero_output"

  if [ "$nugetzero_status" -ne 0 ] && echo "$nugetzero_output" | grep -q "expected 1 argument(s), got 0"; then
    echo "==> Reproduced: this compiler still miscounts NuGet-restored zero-arg functions (lyric-lang#5004)"
    note_reproduced
  elif [ "$nugetzero_status" -ne 0 ]; then
    echo "==> Unexpected failure (exit $nugetzero_status) — not the known signature, investigate separately" >&2
    note_unexpected
    echo "==> [4/8] skipped: check 3's build didn't succeed, nothing to run" >&2
  else
    echo "==> Did NOT fail: this compiler resolves NuGet-restored zero-arg functions — bug #5004 is fixed"

    echo "==> [4/8] lyric run against the same project — does it find Web.dll at runtime? (lyric-lang#5066)"
    run_output="$(cd "$WORK/nugetzero" && lyric run 2>&1)"
    run_status=$?
    echo "$run_output"

    if [ "$run_status" -ne 0 ] && echo "$run_output" | grep -q "FileNotFoundException"; then
      echo "==> Reproduced: this compiler still doesn't copy NuGet dependency DLLs to the output dir (lyric-lang#5066)"
      note_reproduced
    elif [ "$run_status" -ne 0 ]; then
      echo "==> Unexpected failure (exit $run_status) — not the known signature, investigate separately" >&2
      note_unexpected
    else
      echo "==> Did NOT fail: this compiler copies NuGet dependency DLLs to the output dir — bug #5066 is fixed"
    fi
  fi
fi

# --- Check 5: lyric-lang#5177 (cross-package metadata token corruption) ----
# Not reproducible in a synthetic project like checks 1-4 no matter how many
# packages/features were added — needs this project's own real, multi-package
# build, so this runs against the real manifest in place via `lyric test`
# rather than a scratch project. Always runs regardless of checks 3-4's
# outcome — its own restore/build is entirely independent of the synthetic
# nugetzero project those checks use, so a failure there (or `dotnet` itself
# being unavailable, already checked above) must not skip this one too.
echo "==> [5/8] lyric test against this project's own real manifest (lyric-lang#5177)"
real_restore_output="$(cd "$REPO_ROOT" && lyric restore 2>&1)"
real_restore_status=$?
if [ "$real_restore_status" -ne 0 ]; then
  echo "$real_restore_output" >&2
  echo "==> [5/8] skipped (lyric-lang#5177): 'lyric restore' failed (exit $real_restore_status)" \
       "— likely no network access to nuget.org, not a compiler bug" >&2
else
  real_test_output="$(cd "$REPO_ROOT" && lyric test 2>&1)"
  real_test_status=$?
  echo "$real_test_output"

  not_ok_count="$(echo "$real_test_output" | grep -c '^not ok')"
  # Positional pairing, not a raw count comparison: for each `not ok` line,
  # look at the very next line (this harness's TAP-like output always prints
  # exactly one indented failure-detail line right after `not ok`) and
  # require it to match a KNOWN signature — either #5244's or #5298's (both
  # now fixed upstream, kept here to catch a regression). A count comparison
  # alone would be
  # fooled if either substring ever appeared more than once for a single
  # failing test; this can't be, since it checks each failure's own detail
  # line individually. Resets `detail` before each `getline` and checks its
  # return value AND content explicitly: `getline` returns <= 0 only on true
  # EOF (a trailing `not ok` with nothing after it) — it does NOT fail on
  # two back-to-back `not ok` lines, since reading the next `not ok` line
  # into `detail` is a perfectly normal successful read. Also reject that
  # case explicitly (`detail` itself starting with `not ok`), rather than
  # relying on it happening to fail the signature match below by accident.
  unmatched_failure_detail="$(echo "$real_test_output" | awk '
    /^not ok/ {
      detail = ""
      got = getline detail
      if (got <= 0 || detail ~ /^not ok/) { print "(no detail line found after: " $0 ")"; next }
      if (detail !~ /unsupported method .append. on the receiver type/ && detail !~ /Unable to cast object of type .System.String. to type .System.Collections.IList./) print detail
    }
  ')"

  if echo "$real_test_output" | grep -qE "Field not found:|to access field '.*' failed"; then
    echo "==> Reproduced: this compiler still corrupts cross-package field/method metadata tokens in real multi-package builds (lyric-lang#5177)"
    note_reproduced
  elif [ "$real_test_status" -ne 0 ] && [ "$not_ok_count" -gt 0 ] && [ -z "$unmatched_failure_detail" ]; then
    # lyric test may still fail on a regression of lyric-lang#5244 (checked
    # separately by check 6) and/or #5298 (checked by check 7), not #5177's
    # signature. Every failing test's own detail line must match one of
    # those known signatures for this branch — if even one doesn't (e.g.
    # some other, unrelated failure), that's a mismatch and falls through to
    # the unexpected-failure branch below, rather than being silently masked
    # by the known failures alongside it.
    echo "==> Did NOT reproduce: this compiler no longer corrupts cross-package metadata tokens — bug #5177 is fixed (remaining failures are lyric-lang#5244/#5298, see checks 6-7)"
  elif [ "$real_test_status" -ne 0 ]; then
    echo "==> Unexpected failure (exit $real_test_status) — not a known signature, investigate separately" >&2
    note_unexpected
  else
    echo "==> Did NOT reproduce: this compiler no longer corrupts cross-package metadata tokens — bug #5177 is fixed"
  fi
fi

# --- Check 6: lyric-lang#5244 (slice[T].append() unsupported at runtime) ---
# The compiler's own documented idiom for building up a slice, verbatim.
# Reproduces in complete isolation — no packages, no NuGet, no async — so
# unlike check 5 this runs against a trivial scratch project like checks 1-2.
# Always runs, regardless of what checks 3-5 found — this bug is completely
# independent of NuGet/network availability and of anything checks 3-5 hit.
# Fixed as of v0.4.18 — kept here so this script still catches a regression
# or flags an older compiler that hasn't picked up the fix yet.
mkdir -p "$WORK/appendtest/src"
cat > "$WORK/appendtest/lyric.toml" <<'TOML'
[package]
name = "AppendTest"
version = "0.1.0"
[project]
name = "AppendTest"
output = "single"
output_assembly = "AppendTest.dll"
[project.packages]
"AppendTest" = "src/main.l"
TOML
cat > "$WORK/appendtest/src/main.l" <<'LYRIC'
package AppendTest
import Std.Core

func main(): Unit {
  val dynamic: slice[Int] = [1, 2, 3]
  val ys = dynamic.append(42)
  println(ys.length)
}
LYRIC

echo "==> [6/8] slice[Int].append() against a trivial single-file project (lyric-lang#5244)"
append_build_output="$(cd "$WORK/appendtest" && lyric build 2>&1)"
append_build_status=$?
echo "$append_build_output"

if [ "$append_build_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $append_build_status) — expected this to build fine, investigate separately" >&2
  note_unexpected
else
  append_run_output="$(cd "$WORK/appendtest" && dotnet bin/AppendTest.dll 2>&1)"
  append_run_status=$?
  echo "$append_run_output"

  if [ "$append_run_status" -ne 0 ] && echo "$append_run_output" | grep -q "unsupported method 'append' on the receiver type"; then
    echo "==> Reproduced: this compiler still can't lower slice[T].append() to real IL at runtime (lyric-lang#5244)"
    note_reproduced
  elif [ "$append_run_status" -ne 0 ]; then
    echo "==> Unexpected failure (exit $append_run_status) — not the known signature, investigate separately" >&2
    note_unexpected
  else
    echo "==> Did NOT fail: this compiler resolves slice[T].append() at runtime — bug #5244 is fixed"
  fi
fi

# --- Check 7: lyric-lang#5298 (top-level untyped String val .length) -------
# A package-scope `val` with no explicit type annotation, initialized to a
# string literal, crashes `.length` with an IList cast at runtime — same
# package, unqualified, no NuGet/async/multi-package structure needed.
# Reproduces in complete isolation, just like check 6, so it runs the same
# way regardless of what checks 3-6 found.
mkdir -p "$WORK/topval/src"
cat > "$WORK/topval/lyric.toml" <<'TOML'
[package]
name = "TopValTest"
version = "0.1.0"
[project]
name = "TopValTest"
output = "single"
output_assembly = "TopValTest.dll"
[project.packages]
"TopValTest" = "src/main.l"
TOML
cat > "$WORK/topval/src/main.l" <<'LYRIC'
package TopValTest
import Std.Core

val prefix = "https://"

func main(): Unit {
  println("n=" + prefix.length.toString())
}
LYRIC

echo "==> [7/8] untyped top-level String val's .length against a trivial single-file project (lyric-lang#5298)"
topval_build_output="$(cd "$WORK/topval" && lyric build 2>&1)"
topval_build_status=$?
echo "$topval_build_output"

if [ "$topval_build_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $topval_build_status) — expected this to build fine, investigate separately" >&2
  note_unexpected
else
  topval_run_output="$(cd "$WORK/topval" && dotnet bin/TopValTest.dll 2>&1)"
  topval_run_status=$?
  echo "$topval_run_output"

  if [ "$topval_run_status" -ne 0 ] && echo "$topval_run_output" | grep -q "Unable to cast object of type 'System.String' to type 'System.Collections.IList'"; then
    echo "==> Reproduced: this compiler still crashes an untyped top-level String val's .length (lyric-lang#5298)"
    note_reproduced
  elif [ "$topval_run_status" -ne 0 ]; then
    echo "==> Unexpected failure (exit $topval_run_status) — not the known signature, investigate separately" >&2
    note_unexpected
  else
    echo "==> Did NOT fail: this compiler resolves an untyped top-level String val's .length — bug #5298 is fixed"
  fi
fi

# --- Check 8: lyric-lang#6249 (val loses value across 2+ different-callee
# awaits) ---------------------------------------------------------------
# A local `val` bound before one `await` and read again after a SECOND,
# different-callee `await` in the same async function silently loses its
# value — reads back as "" instead of "hello". No match, no Result type, no
# parameters involved: the plainest possible trigger. Reproduces in complete
# isolation, just like checks 6-7.
mkdir -p "$WORK/asyncval/src"
cat > "$WORK/asyncval/lyric.toml" <<'TOML'
[package]
name = "AsyncValTest"
version = "0.1.0"
[project]
name = "AsyncValTest"
output = "single"
output_assembly = "AsyncValTest.dll"
[project.packages]
"AsyncValTest" = "src/main.l"
TOML
cat > "$WORK/asyncval/src/main.l" <<'LYRIC'
package AsyncValTest

import Std.Core
import Std.Task

async func stepA(): Unit {
  await Std.Task.delay(20)
}

async func stepB(): Unit {
  await Std.Task.delay(20)
}

pub record Cell {
  pub var output: String = ""
}

async func repro(cell: in Cell): Unit {
  val id = "hello"
  await stepA()
  await stepB()
  cell.output = id
}

@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWaitMs[T](t: in T, timeoutMs: in Int): Bool = false

func main(): Unit {
  val cell = Cell(output = "")
  val t = repro(cell)
  val _done = taskWaitMs(t, 5000)
  println("actual=[" + cell.output + "]")
}
LYRIC

echo "==> [8/8] a val surviving two different-callee awaits in one async func (lyric-lang#6249)"
asyncval_build_output="$(cd "$WORK/asyncval" && lyric build 2>&1)"
asyncval_build_status=$?
echo "$asyncval_build_output"

if [ "$asyncval_build_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $asyncval_build_status) — expected this to build fine, investigate separately" >&2
  note_unexpected
else
  asyncval_run_output="$(cd "$WORK/asyncval" && dotnet bin/AsyncValTest.dll 2>&1)"
  asyncval_run_status=$?
  echo "$asyncval_run_output"

  if [ "$asyncval_run_status" -eq 0 ] && echo "$asyncval_run_output" | grep -q "actual=\[\]"; then
    echo "==> Reproduced: this compiler still silently loses a val across a second different-callee await (lyric-lang#6249)"
    note_reproduced
  elif [ "$asyncval_run_status" -eq 0 ] && echo "$asyncval_run_output" | grep -q "actual=\[hello\]"; then
    echo "==> Did NOT fail: this compiler correctly preserves the val across both awaits — bug #6249 is fixed"
  else
    echo "==> Unexpected output/exit ($asyncval_run_status) — not either known signature, investigate separately" >&2
    note_unexpected
  fi
fi

case "$worst" in
  0) echo "==> Did NOT reproduce: all eight known bugs are fixed on this compiler — full build, run, and test all work" ;;
  1) echo "==> At least one known bug reproduced — see above for which" >&2 ;;
  2) echo "==> At least one check hit an unexpected failure — see above for which, investigate separately" >&2 ;;
esac
exit "$worst"
