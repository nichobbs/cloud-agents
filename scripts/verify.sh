#!/usr/bin/env bash
# verify.sh — runtime-verify the Docker-independent logic.
#
# AS OF v0.4.12, THIS ACTUALLY SUCCEEDS — the first time in this project's
# history. Two upstream compiler bugs blocked it before: bug 1 (buildProject
# crash, https://github.com/nichobbs/lyric-lang/issues/4925, fixed in
# v0.4.11) and bug 2 (Std.Core's Option/Result/Some/None/Ok/Err never
# resolving, https://github.com/nichobbs/lyric-lang/issues/4980, fixed in
# v0.4.12 — this harness uses Option directly, e.g. CachedToken/
# statusFromString, so it hit bug 2 head-on). Bugs 3, 4, and 5 (see
# docs/BUILD.md "Compiler notes") don't affect this harness either — it has
# no [nuget] table at all, so it never hits the NuGet-specific bugs that
# block the *full* project build (scripts/build-full.sh), and its single,
# small, self-contained `main()` doesn't happen to trigger bug 5's
# (now-fixed) cross-package metadata-token corruption either, unlike the
# real project's `lyric run` (scripts/run-api.sh) and `lyric test`. Bug 6
# (`slice[T].append()` throwing at runtime, fixed in v0.4.18) never
# affected it either, since this harness never calls `.append()`. Bug 7
# (an untyped top-level String val's `.length` throwing an IList cast,
# fixed in v0.4.19, lyric-lang#5298) never affected it either, since this
# harness has no such top-level val.
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

mkdir -p "$WORK/src/pg" "$WORK/src/streaming" "$WORK/src/db" "$WORK/src/handlers" "$WORK/src/crypto" "$WORK/src/ledger"
cp "$REPO_ROOT/src/streaming/streaming.l"   "$WORK/src/streaming/"
cp "$REPO_ROOT/src/db/db_client.l"          "$WORK/src/db/"
# db_client.l builds the session list's ledger-attention column from it.
cp "$REPO_ROOT/src/ledger/schema.l"         "$WORK/src/ledger/"
cp "$REPO_ROOT/src/handlers/auth.l"         "$WORK/src/handlers/"
# streaming.l and auth.l call into CloudAgents.Text (isControlChar /
# indexOfFrom), so the shared package must be part of this scratch build too —
# otherwise those cross-package calls link to nothing and the CLR rejects the
# method at runtime (InvalidProgramException in jsonEscape).
cp "$REPO_ROOT/src/text.l"                  "$WORK/src/"
# auth.l hashes callback tokens with CloudAgents.Crypto.sha256Hex, so Crypto
# (itself only Std.Core + CloudAgents.Text) must be in the build as well.
cp "$REPO_ROOT/src/crypto/crypto.l"         "$WORK/src/crypto/"
# auth.l builds the request's tenant scope (CloudAgents.Scope, Std.Core only).
cp "$REPO_ROOT/src/pg/scope.l"              "$WORK/src/pg/"

cat > "$WORK/lyric.toml" <<'TOML'
[package]
name = "CloudAgentsVerify"
version = "0.1.0"
[project]
name = "CloudAgentsVerify"
output = "single"
output_assembly = "CloudAgentsVerify.dll"
[project.packages]
"CloudAgents.Text"      = "src/text.l"
"CloudAgents.Crypto"    = "src/crypto/crypto.l"
"CloudAgents.Scope"     = "src/pg/scope.l"
"CloudAgents.Streaming" = "src/streaming/streaming.l"
"CloudAgents.Ledger.Schema" = "src/ledger/schema.l"
"CloudAgents.Db"        = "src/db/db_client.l"
"CloudAgents.Auth"      = "src/handlers/auth.l"
"CloudAgentsVerify"     = "src/main.l"
TOML

# Runtime harness — exercises the Docker-independent logic (streaming, the
# Phase 3 auth helpers). These
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

pub func main(): Int {
  // Phase 1 — SSE framing
  eqs(toSseChunk("hello"), "data: {\"chunk\":\"hello\"}\n\n", "toSseChunk basic")
  eqs(jsonEscape("x\"y\\z"), "x\\\"y\\\\z", "jsonEscape quotes + backslash")
  eqs(outputDelta("hello world", 6), "world", "outputDelta past offset")
  eqs(outputDelta("abc", 3), "", "outputDelta caught up")
  eqs(sseError("boom"), "event: error\ndata: {\"error\":\"boom\"}\n\n", "sseError frame")
  eqs(toString(nextPollMs(1000, 5000)), "2000", "nextPollMs doubles below cap")
  eqs(toString(nextPollMs(4000, 5000)), "5000", "nextPollMs caps the doubling")
  eqs(sseKeepalive(), ": keepalive\n\n", "sseKeepalive comment frame")

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

  // Phase 6 — callback token stored as its SHA-256 hash
  eqs(hashCallbackToken("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "callback token hash (SHA-256 test vector)")
  eqb(authorizeCallback("Bearer tok", hashCallbackToken("tok")), true, "callback bearer matches stored hash")
  eqb(authorizeCallback("Bearer wrong", hashCallbackToken("tok")), false, "wrong callback bearer rejected")
  eqb(authorizeCallback("Bearer tok", ""), false, "empty stored hash fails closed")

  Console.println("ALL CLOUD-AGENTS LOGIC CHECKS PASSED")
  0
}
LYRIC

command -v lyric  >/dev/null || { echo "verify: 'lyric' not on PATH"  >&2; exit 1; }
command -v dotnet >/dev/null || { echo "verify: 'dotnet' not on PATH" >&2; exit 1; }

echo "==> Compiling CloudAgents.Streaming / Db / Auth"
( cd "$WORK" && lyric build )

echo "==> Runtime-verifying streaming + Phase 3 logic"
( cd "$WORK" && lyric run )

echo "==> Verification succeeded"
