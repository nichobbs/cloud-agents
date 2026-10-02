#!/usr/bin/env bash
# repro-generic-extern-instance-typeload.sh: minimal, runnable reproduction of
# a Lyric 0.7.6 regression: a generic function bound with @externInstance (the
# `taskWaitMs[T]` idiom src/docker_manager.l uses to wait on an async call)
# builds, then the program dies at startup with
#   System.TypeLoadException: The signature is incorrect.
# (or an AccessViolationException in CastHelpers.IsInstanceOfClass when the
# async function returns a value). The same program prints `done true n=42` on
# 0.7.5. In this project it makes every call into CloudAgents.Docker fail
# (reapContainers, streamSessionMessage, terminateSessionContainer ...) even
# though `lyric build` and every @test_module suite but two pass.
#
# Exit codes match the other repro-*.sh scripts: 0 = did not reproduce (fixed,
# or skipped because a tool was unavailable), 1 = reproduced, 2 = could not
# run the check at all.

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
  val t = work(cell)
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
  echo "==> Did NOT reproduce: the generic @externInstance binding works."
  exit 0
elif echo "$out" | grep -aqE "TypeLoadException|AccessViolationException"; then
  echo "==> Reproduced: generic @externInstance binding builds but fails at runtime (TypeLoadException / AccessViolationException)."
  exit 1
fi
echo "==> Unexpected output; investigate separately" >&2
exit 2
