#!/usr/bin/env bash
# verify.sh — build/verify the parts of Cloud Agents that compile under the
# published Lyric compiler.
#
# Why this is scoped: the full web+docker server depends on `lyric-docker`,
# which does not build under Lyric v0.1.x (see docs/BUILD.md). This script
# verifies the Docker-independent packages — CloudAgents.Streaming / Db / Auth —
# which compile cleanly, and runtime-checks the SSE framing in
# CloudAgents.Streaming.
#
# Requirements on PATH: `lyric`, `dotnet` (10.x).
# Env:
#   LYRIC_LANG   path to the lyric-lang workspace (default: ../lyric-lang,
#                cloned if absent).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LYRIC_LANG="${LYRIC_LANG:-$(cd "$REPO_ROOT/.." && pwd)/lyric-lang}"

command -v lyric  >/dev/null || { echo "verify: 'lyric' not on PATH"  >&2; exit 1; }
command -v dotnet >/dev/null || { echo "verify: 'dotnet' not on PATH" >&2; exit 1; }

# The compiler discovers the standard library sources by walking up to the
# lyric-lang workspace, so the verification project must live inside it.
if [ ! -d "$LYRIC_LANG/lyric-stdlib/std" ]; then
  echo "verify: cloning lyric-lang into $LYRIC_LANG"
  git clone --depth 1 https://github.com/nichobbs/lyric-lang.git "$LYRIC_LANG"
fi

WORK="$LYRIC_LANG/.cloud-agents-verify"
rm -rf "$WORK"
mkdir -p "$WORK/src/streaming" "$WORK/src/db" "$WORK/src/handlers"
cp "$REPO_ROOT/src/streaming/streaming.l"   "$WORK/src/streaming/"
cp "$REPO_ROOT/src/db/db_client.l"          "$WORK/src/db/"
cp "$REPO_ROOT/src/handlers/auth.l"         "$WORK/src/handlers/"

cat > "$WORK/lyric.toml" <<'TOML'
[package]
name = "CloudAgentsVerify"
version = "0.1.0"
[project]
name = "CloudAgentsVerify"
output = "single"
output_assembly = "CloudAgentsVerify.dll"
[project.packages]
"CloudAgents.Streaming" = "src/streaming/streaming.l"
"CloudAgents.Db"        = "src/db/db_client.l"
"CloudAgents.Auth"      = "src/handlers/auth.l"
"CloudAgentsVerify"     = "src/main.l"
[dependencies]
TOML

# Runtime harness — exercises the SSE framing (pure inlined primitives, so it
# runs without the per-package stdlib runtime DLLs).
cat > "$WORK/src/main.l" <<'LYRIC'
package CloudAgentsVerify
import Std.Core
import Std.Console as Console
import CloudAgents.Streaming

func eq(actual: in String, expected: in String, label: in String): Unit {
  if actual == expected {
    Console.println("ok   - " + label)
  } else {
    Console.println("FAIL - " + label)
    Console.println("  expected: [" + expected + "]")
    Console.println("  actual:   [" + actual + "]")
    panic("assertion failed: " + label)
  }
}

pub func main(): Int {
  eq(jsonEscape("x\"y\\z"), "x\\\"y\\\\z", "jsonEscape quotes + backslash")
  eq(jsonEscape("line\nbreak"), "line\\nbreak", "jsonEscape newline")
  eq(toSseChunk("hello"), "data: {\"chunk\":\"hello\"}\n\n", "toSseChunk basic")
  eq(formatLogsAsSse("a\r\nb\n"),
     "data: {\"chunk\":\"a\"}\n\n" + "data: {\"chunk\":\"b\"}\n\n" + "event: done\ndata: {}\n\n",
     "formatLogsAsSse CRLF + trailing newline")
  eq(formatLogsAsSse(""), "event: done\ndata: {}\n\n", "formatLogsAsSse empty")
  Console.println("ALL STREAMING CHECKS PASSED")
  0
}
LYRIC

echo "==> Compiling CloudAgents.Streaming / Db / Auth"
( cd "$WORK" && lyric build )

echo "==> Runtime-verifying SSE framing"
( cd "$WORK" && lyric run )

echo "==> Verification succeeded"
rm -rf "$WORK"
