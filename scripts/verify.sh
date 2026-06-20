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

# Runtime harness — exercises the Docker-independent logic (streaming, the
# Phase 2 state machine / recycling / SQL, and the Phase 3 auth helpers). These
# use only enums, unions, records and primitives, so they run without the
# per-package stdlib runtime DLLs.
cat > "$WORK/src/main.l" <<'LYRIC'
package CloudAgentsVerify
import Std.Core
import Std.Console as Console
import CloudAgents.Streaming
import CloudAgents.Db
import CloudAgents.Auth

func eqs(a: in String, e: in String, l: in String): Unit {
  if a == e { Console.println("ok   - " + l) }
  else { Console.println("FAIL - " + l + " got [" + a + "]"); panic(l) }
}
func eqb(a: in Bool, e: in Bool, l: in String): Unit {
  if a == e { Console.println("ok   - " + l) } else { Console.println("FAIL - " + l); panic(l) }
}
func tshow(t: in Transition): String { return match t { case To(s) -> statusToString(s); case Invalid -> "INVALID" } }
func rshow(r: in RecycleAction): String { return match r { case StopAndIdle -> "STOP"; case EvictCold -> "EVICT"; case NoAction -> "NONE" } }

pub func main(): Int {
  // Phase 1 — SSE framing
  eqs(toSseChunk("hello"), "data: {\"chunk\":\"hello\"}\n\n", "toSseChunk basic")
  eqs(jsonEscape("x\"y\\z"), "x\\\"y\\\\z", "jsonEscape quotes + backslash")
  eqs(formatLogsAsSse("a\r\nb\n"),
      "data: {\"chunk\":\"a\"}\n\n" + "data: {\"chunk\":\"b\"}\n\n" + "event: done\ndata: {}\n\n",
      "formatLogsAsSse CRLF + trailing")
  eqs(formatLogsAsSse(""), "event: done\ndata: {}\n\n", "formatLogsAsSse empty")

  // Phase 2 — state machine
  eqs(tshow(nextStatus(Created, CloneStarted)), "CLONING", "Created+CloneStarted")
  eqs(tshow(nextStatus(Idle, MessageReceived)), "RUNNING", "Idle+MessageReceived")
  eqs(tshow(nextStatus(Running, ProcessExited)), "WARM", "Running+ProcessExited")
  eqs(tshow(nextStatus(Warm, IdleTimeout)), "IDLE", "Warm+IdleTimeout")
  eqs(tshow(nextStatus(Running, MessageReceived)), "INVALID", "illegal transition")
  eqs(tshow(nextStatus(Destroyed, MessageReceived)), "INVALID", "terminal state")

  // Phase 2 — idle recycling
  eqs(rshow(recycleDecision(Warm, 300000.toLong())), "STOP", "Warm at 5min")
  eqs(rshow(recycleDecision(Idle, 3600000.toLong())), "EVICT", "Idle at 1h")
  eqs(rshow(recycleDecision(Running, 9999999.toLong())), "NONE", "Running not swept")

  // Phase 2 — SQL (ownership-scoped)
  eqb(deleteSessionSql() == "DELETE FROM sessions WHERE id = ? AND github_user_id = ?", true, "delete sql")
  eqb(selectSessionByIdSql().endsWith("AND github_user_id = ?"), true, "select scoped by owner")

  // Phase 3 — token cache + ownership
  val entry = CachedToken(userId = "42", login = "octocat", expiresAtMillis = 1000.toLong())
  eqb(isCacheValid(entry, 999.toLong()), true, "cache valid before expiry")
  eqb(isCacheValid(entry, 1000.toLong()), false, "cache invalid at expiry")
  eqs(toString(cacheExpiry(1000.toLong(), 3600.toLong())), "3601000", "cacheExpiry now+ttl")
  eqb(ownsResource("42", "42"), true, "owns own resource")
  eqb(ownsResource("42", "7"), false, "rejects other's resource")

  // Phase 3 — GitHub /user parsing
  val body = "{\"login\":\"octocat\",\"id\":583231,\"type\":\"User\"}"
  eqs(parseJsonString(body, "login"), "octocat", "parse login")
  eqs(parseJsonNumber(body, "id"), "583231", "parse id number")
  eqs(parseJsonString(body, "missing"), "", "missing field -> empty")
  eqs(parseJsonNumber("{\"id\": 42 }", "id"), "42", "parse id with spaces")

  Console.println("ALL CLOUD-AGENTS LOGIC CHECKS PASSED")
  0
}
LYRIC

echo "==> Compiling CloudAgents.Streaming / Db / Auth"
( cd "$WORK" && lyric build )

echo "==> Runtime-verifying streaming + Phase 2/3 logic"
( cd "$WORK" && lyric run )

echo "==> Verification succeeded"
rm -rf "$WORK"
