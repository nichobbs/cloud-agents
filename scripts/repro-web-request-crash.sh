#!/usr/bin/env bash
# repro-web-request-crash.sh — minimal, runnable reproduction of a second,
# distinct Lyric.Web library bug from the one scripts/repro-web-bug.sh
# tracks: constructing a Web.Request record crashes at runtime with a bare
# System.InvalidProgramException ("Common Language Runtime detected an
# invalid program"), even when every field is supplied with a value of the
# documented type.
#
# Discovered while adding test coverage for src/main.l's Handler/Middleware
# adapters (PR #342, tracked as nichobbs/cloud-agents#354): a test that
# hand-constructed a Web.Request to call HealthHandler.handle(req)/
# AuthMiddleware.wrap(req, ...) crashed even when the handler under test
# never read a single field off req — isolating the failure to the
# construction of the record itself, not any downstream logic.
#
# Distinct from lyric-lang#3887 (repro-web-bug.sh): that bug is inside
# Lyric.Web's own compiled serve() loop (an @externTarget Encoding.GetBytes
# call). This one is triggered entirely from ordinary calling code — no
# Lyric.Web internals are on the stack — by constructing one of Lyric.Web's
# published record types.
#
# Also distinct from docs/lyric/gotchas.md's "package-qualified record
# construction fails at runtime" entry: that failure mode is "unsupported
# method on the receiver type" and is dodged by constructing unqualified
# after importing the package. This construction is already unqualified
# (`Request(...)` after `import Web`) and still crashes, with a different,
# lower-level CLR error (InvalidProgramException, not a Lyric "unsupported
# method" runtime shim failure) — pointing at a codegen defect in how the
# compiler emits the constructor for this specific record, not a Lyric
# dispatch-layer gap.
#
# Does NOT prove the live server itself is broken: production code (this
# project's src/main.l Handler/Middleware adapters) only ever RECEIVES a
# Request as a parameter from the framework and reads/queries it via
# Web.header()/Web.pathParam() — it never constructs one. This script
# exists to isolate and mechanically track the construction-specific
# failure, not to claim the server is down.
#
# Requirements: lyric on PATH, dotnet on PATH, network access to nuget.org
# (a real [nuget] restore is needed since this is Lyric.Web's own compiled
# record type at fault, not this project's source).
#
# Exit codes match scripts/repro-web-bug.sh's convention: 0 = did not
# reproduce (fixed, or skipped because nuget.org wasn't reachable), 1 = bug
# reproduced, 2 = couldn't run the check at all (missing tool, unexpected
# build failure) — distinct from 1 so a setup problem is never mistaken for
# a confirmed-still-broken result.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v lyric  >/dev/null || { echo "repro-web-request-crash: 'lyric' not on PATH"  >&2; exit 2; }
command -v dotnet >/dev/null || { echo "repro-web-request-crash: 'dotnet' not on PATH" >&2; exit 2; }

WEB_VERSION="$(sed -n 's/^"Lyric\.Web"[[:space:]]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' "$REPO_ROOT/lyric.toml" | head -1)"
[ -n "$WEB_VERSION" ] || { echo "repro-web-request-crash: could not read Lyric.Web version from lyric.toml" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/reqcrash/src"
cat > "$WORK/reqcrash/lyric.toml" <<TOML
[package]
name = "ReqCrashTest"
version = "0.1.0"
[project]
name = "ReqCrashTest"
output = "single"
output_assembly = "ReqCrashTest.dll"
[project.packages]
"ReqCrashTest" = "src/main.l"
[nuget]
"Lyric.Web" = "$WEB_VERSION"
TOML

# Mirrors the exact construction that crashed in the reverted
# CloudAgents.MainTests test harness (tests/main_tests.l's comment block
# has the full narrative): every Request field populated with a value of
# its documented type, unqualified constructor after `import Web`.
cat > "$WORK/reqcrash/src/main.l" <<'LYRIC'
package ReqCrashTest

import Std.Core
import Std.Collections
import Web

func main(): Unit {
  val req = Request(
    method = "GET",
    path = "/api/health",
    pathParams = Map.empty[String, String](),
    queryParams = Map.empty[String, String](),
    headers = Map.empty[String, String](),
    body = ""
  )
  println("constructed ok, path=" + req.path)
}
LYRIC

echo "==> Lyric.Web $WEB_VERSION: constructing a Web.Request record (nichobbs/cloud-agents#354)"
restore_output="$(cd "$WORK/reqcrash" && lyric restore 2>&1)"
restore_status=$?
if [ "$restore_status" -ne 0 ]; then
  echo "$restore_output" >&2
  echo "==> skipped: 'lyric restore' failed (exit $restore_status) — likely no network access to nuget.org, not a library bug" >&2
  exit 0
fi

build_output="$(cd "$WORK/reqcrash" && lyric build 2>&1)"
build_status=$?
echo "$build_output"
if [ "$build_status" -ne 0 ]; then
  echo "==> Unexpected: build itself failed (exit $build_status) — not the known runtime-only signature, investigate separately" >&2
  exit 2
fi

run_output="$(cd "$WORK/reqcrash" && dotnet bin/ReqCrashTest.dll 2>&1)"
run_status=$?
echo "$run_output"

if [ "$run_status" -ne 0 ] && echo "$run_output" | grep -qi "InvalidProgramException"; then
  echo "==> Reproduced: Lyric.Web $WEB_VERSION still crashes constructing a Request record (nichobbs/cloud-agents#354)"
  exit 1
elif [ "$run_status" -ne 0 ]; then
  echo "==> Unexpected failure (exit $run_status) — not the known signature, investigate separately" >&2
  exit 2
else
  echo "==> Did NOT fail: Lyric.Web $WEB_VERSION can construct a Request record at runtime — nichobbs/cloud-agents#354 is fixed"
  exit 0
fi
