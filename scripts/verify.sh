#!/usr/bin/env bash
# verify.sh — runtime-verify the Docker-independent logic.
#
# THIS CURRENTLY CANNOT SUCCEED with any released Lyric compiler, same as
# scripts/build-full.sh — `lyric build`/`run`/`check`/`test` all crash with
# an unhandled System.InvalidCastException on EVERY standalone Lyric
# project (not just this one's). Root cause found and fixed upstream
# (https://github.com/nichobbs/lyric-lang/pull/4955, merged), not released
# yet — see https://github.com/nichobbs/lyric-lang/issues/4925.
#
# This script compiles a small hand-rolled `main()` harness and runs it with
# `lyric build` + `lyric run` rather than `lyric test`, on the theory that
# `lyric test` (cmdTestManifest) was the specific thing crashing. That
# theory turned out to be wrong — `lyric build`/`run` hit the identical
# crash, inside the compiler itself, before touching anything harness- or
# manifest-specific — but the approach is kept because it's still the
# right shape once the compiler is fixed: no lyric-lang checkout, no NuGet
# deps in the scratch manifest, nothing else to go wrong on our side.
#
# `tests/*.l` (the real `@test_module` suites) remain the source of truth
# for intended behaviour and should still be read/maintained — they just
# can't be executed by any current `lyric` command.
#
# Requirements on PATH: `lyric`, `dotnet` (10.x).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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
TOML

# Runtime harness — exercises the Docker-independent logic (streaming, the
# Phase 2 state machine / recycling / SQL, and the Phase 3 auth helpers). These
# use only enums, unions, records and primitives, so they run without any
# external dependency.
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

command -v lyric  >/dev/null || { echo "verify: 'lyric' not on PATH"  >&2; exit 1; }
command -v dotnet >/dev/null || { echo "verify: 'dotnet' not on PATH" >&2; exit 1; }

echo "==> Compiling CloudAgents.Streaming / Db / Auth"
( cd "$WORK" && lyric build )

echo "==> Runtime-verifying streaming + Phase 2/3 logic"
( cd "$WORK" && lyric run )

echo "==> Verification succeeded"
