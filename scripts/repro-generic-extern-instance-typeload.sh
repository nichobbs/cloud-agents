#!/usr/bin/env bash
# repro-generic-extern-instance-typeload.sh: check that a `spawn` handle can be
# passed to a generic @externInstance binding of Task.Wait (the `taskWaitMs[T]`
# idiom src/docker_manager.l uses to bound a wait on an async call).
#
# Two things are involved, neither a regression of the idiom itself:
#  1. Since lyric 0.7.6 a DIRECT call to an `async func` awaits in place
#     (docs/01 §7.1), so `val t = work(cell)` is the awaited Unit, not a task.
#     Handing that to the generic Task.Wait binding builds, then dies at startup
#     with `TypeLoadException: The signature is incorrect.` (or an
#     AccessViolationException for a value-returning callee). The language
#     documents this; the compiler does not diagnose it. Only `spawn` keeps the
#     task: `val t = spawn work(cell)`.
#  2. 0.7.6 and 0.7.7 also specialised a generic over a `spawn` handle's result
#     type instead of its task, so even the `spawn` form failed. Fixed in 0.7.8
#     (nichobbs/lyric-lang#8026).
# So this script expects `done true n=42` on 0.7.8 and later, and fails on
# 0.7.6/0.7.7. A failure of the `val t = work(cell)` form is the documented
# behaviour, not a reason to reopen the compiler fix.
#
# Exit codes match the other repro-*.sh scripts: 0 = works (done true n=42),
# 1 = TypeLoadException / AccessViolationException, 2 = could not run the check.

set -uo pipefail

command -v lyric  >/dev/null || { echo "repro-generic-extern-instance-typeload: 'lyric' not on PATH"  >&2; exit 2; }
command -v dotnet >/dev/null || { echo "repro-generic-extern-instance-typeload: 'dotnet' not on PATH" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src"

cat > "$WORK/lyric.toml" <<'TOML'
[package]
name = "ExternTypeLoad"
version = "0.1.0"

[project]
name = "ExternTypeLoad"
output = "single"
output_assembly = "ExternTypeLoad.dll"

[project.packages]
"ExternTypeLoad" = "src/main.l"
TOML

cat > "$WORK/src/main.l" <<'LYRIC'
package ExternTypeLoad

import Std.Core
import Std.Task

@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWaitMs[T](t: in T, timeoutMs: in Int): Bool = false

record Cell {
  pub var n: Int = 0
}

async func work(cell: in Cell): Unit {
  cell.n = 42
}

func main(): Unit {
  println("start")
  val cell = Cell(n = 0)
  val t = spawn work(cell)
  val done = taskWaitMs(t, 5000)
  println("done " + toString(done) + " n=" + toString(cell.n))
}
LYRIC

echo "==> building with $(lyric --version 2>&1 | head -1)"
build_output="$(cd "$WORK" && lyric build 2>&1)"
if [ $? -ne 0 ]; then
  echo "$build_output" >&2
  echo "==> Unexpected: the build itself failed — not the known runtime-only signature" >&2
  exit 2
fi

out="$(cd "$WORK" && dotnet bin/ExternTypeLoad.dll 2>&1)"
echo "$out" | head -6
if echo "$out" | grep -q "done true n=42"; then
  echo "==> OK: a spawn handle works with the generic @externInstance Task.Wait binding."
  exit 0
elif echo "$out" | grep -aqE "TypeLoadException|AccessViolationException"; then
  echo "==> FAILED: the generic @externInstance Task.Wait binding builds but fails at runtime (TypeLoadException / AccessViolationException) even with spawn; expected on lyric 0.7.6/0.7.7 (fixed in 0.7.8, nichobbs/lyric-lang#8026)."
  exit 1
fi
echo "==> Unexpected output; investigate separately" >&2
exit 2
