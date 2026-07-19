# Building & Verifying

## Toolchain

The project compiles with the Lyric compiler (targets .NET 10).

```sh
# Lyric compiler (installs to ~/.lyric/bin)
curl -fsSL https://raw.githubusercontent.com/nichobbs/lyric-lang/main/scripts/install.sh | sh

# .NET 10 SDK (required to run the compiled output and tests)
curl -fsSL https://dotnet.microsoft.com/download/dotnet/scripts/v1/dotnet-install.sh | sh -s -- --channel 10.0
export PATH="$HOME/.lyric/bin:$HOME/.dotnet:$PATH"
export DOTNET_ROOT="$HOME/.dotnet"
```

If `api.github.com` is blocked on your network, the installer's "resolve latest
release" step fails. Resolve the tag from `github.com` instead and install
directly:

```sh
ver=$(curl -sI https://github.com/nichobbs/lyric-lang/releases/latest \
        | sed -n 's/.*tag\/v\([0-9.]*\).*/\1/p' | tr -d '\r')
curl -fsSL -o /tmp/lyric.tgz \
  "https://github.com/nichobbs/lyric-lang/releases/download/v${ver}/lyric-${ver}-linux-x64.tar.gz"
mkdir -p ~/.lyric/bin && tar -xzf /tmp/lyric.tgz -C ~/.lyric/bin
```

## Dependencies

`Lyric.Web`, `Lyric.Docker`, `Std.Logging`, and `Microsoft.Data.Sqlite` are
declared under `[nuget]` in `lyric.toml` and resolved as ordinary prebuilt
binary packages — no sibling checkout, no source patching:

```toml
[nuget]
"Lyric.Web"             = "0.4.34"
"Lyric.Docker"          = "0.4.34"
"Std.Logging"           = "0.4.20"
"Microsoft.Data.Sqlite" = "10.0.9"
```

These track the latest published versions as of each package's own release
cadence — `Lyric.Web`/`Lyric.Docker` and the compiler (`MIN_LYRIC_VERSION`)
are independent version numbers on separate release schedules; they will not
generally match, and `Lyric.Web` is intentionally ahead of the
0.4.19 compiler floor (see "Root-caused" below for why). **`Lyric.Web` was
bumped 0.4.26 → 0.4.33 for the chunked-response streaming API (lyric-lang
PR #5983): `POST /api/sessions/{id}/messages` now streams container output
live via `startStreaming`/`StreamingHandler` instead of buffering the whole
run — see `docs/upstream/lyric-web-streaming.md`.** `Std.Logging`
stays at 0.4.20 — nothing in `src/` imports it (the project logs via
`println`), so there's no reason to chase its latest.
`Microsoft.Data.Sqlite` stays at 10.0.9 — the newest *stable*; the 11.0.0
line is preview-only. The two SQLite-native packages
(`SourceGear.sqlite3` 3.53.3, `SQLitePCLRaw.provider.dynamic_cdecl` 3.0.3)
are likewise already at their latest stable.

`Lyric.Docker` used to be vendored (`vendor/lyric-docker`) rather than
consumed from NuGet. Three gaps blocked switching to the published package,
all now closed upstream:

1. The published 0.4.10 package required an explicit `client: DockerClient`
   argument on every call and had no `waitContainer` function — a materially
   different API from what the vendored fork exposed. `waitContainer` shipped
   in a later release; the `client: DockerClient`-threaded call convention was
   never changed (it's the correct design — the vendored fork's implicit
   per-call socket resolution was a workaround, not an improvement) and is
   what `src/docker_manager.l` now uses directly.
2. `createContainer` had no way to pin a container's `NetworkMode`, which
   this project's network-policy enforcement (`none`/`restricted`/full
   egress, see `CloudAgents.NetworkPolicy`) depends on. Closed in
   [lyric-docker#5697](https://github.com/nichobbs/lyric-lang/pull/5697) via
   `createContainerWithNetwork(client, image, env, binds, networkMode)`.
3. The published package was, separately, broken at runtime: `jsonEscapeValue`
   (called by every `createContainer`/`createContainerWithNetwork`) called a
   nonexistent `String.codePointAt` method that compiled cleanly but crashed
   unconditionally on first use — undetected for ~4 releases because
   `lyric-docker` was never wired into CI. Closed in
   [lyric-lang#5705](https://github.com/nichobbs/lyric-lang/pull/5705).

With all three fixed (published as `Lyric.Docker` 0.4.28; bumped to 0.4.29 to
pick up `makeDockerClientTcp`, an opt-in TCP-transport constructor used by
`dockerClient()` in `src/docker_manager.l`), `src/docker_manager.l`
consumes the published package directly, calling its `Lyric.Docker.*`
functions unqualified (`makeDockerClient()`, `createContainerWithNetwork(client, ...)`,
etc. — the names are unqualified because `import Lyric.Docker` brings them
into scope) and threading the resulting `DockerClient` through each call.
The vendor directory has been removed.

**Gotcha:** every `await` into `Lyric.Docker` in `src/docker_manager.l` must
call the imported names unqualified, not as `Lyric.Docker.foo(...)`. A
fully-qualified cross-package `await` hits a real, currently-open compiler
bug ([lyric-lang#5222](https://github.com/nichobbs/lyric-lang/issues/5222):
`emitPhaseBAwait: await index N exceeds pre-allocated resume labels` — a
mismatch between the await pre-scan and the actual codegen for the
qualified-path form) that crashes `lyric build` outright. Non-`await` calls
(e.g. the pure `createContainerBodyWithNetwork`/`extractJsonField` helpers
used in `tests/docker_client_tests.l`) are unaffected and can stay qualified.

Build from the repo root:

```sh
lyric restore
lyric build   # succeeds as of v0.4.14 — see "Compiler notes" below for history
```

`scripts/build-full.sh` wraps `lyric restore`/`lyric build` — **this now
succeeds** against v0.4.14+ (the first release where it ever has). `scripts/verify.sh`
is the test entry point — see "Running tests" below for why it isn't `lyric
test` — and **genuinely passes**. `scripts/run-api.sh` builds the same way,
then runs the compiled server — **this now works**, for the first time in
this project's history: `lyric build` succeeds, `lyric run` finds its
NuGet-restored dependencies at runtime (`lyric-lang#5066`, fixed in
v0.4.15), and the real project's own cross-package field/method tokens now
resolve correctly too (`lyric-lang#5177`, fixed in v0.4.17) — see "Compiler
notes" for both. `slice[T].append()`
([lyric-lang#5244](https://github.com/nichobbs/lyric-lang/issues/5244)) is
fixed as of v0.4.18. An untyped top-level `String val`'s `.length` throwing
an `IList` cast exception at runtime
([lyric-lang#5298](https://github.com/nichobbs/lyric-lang/issues/5298)) is
fixed as of v0.4.19 — all seven known upstream compiler bugs are now fixed.

**Both previously-blocking `Lyric.Web` gaps are fixed as of the 0.4.26
pin — the server now has the machinery to dispatch requests to this
project's handlers, and auth enforcement (#78/#211/#76) is wired in
(`src/main.l`'s `AuthMiddleware`).** Kept here as history, since both were
100% reproducible and cost real investigation time. See "Net effect"
below for the important caveat on how much of this is actually confirmed
by an automated test versus believed from the code compiling:

1. **Crash on first request — fixed.** `Lyric.Web` (0.4.11 through 0.4.19)
   built its HTTP response body via an `@externTarget`-wrapped call
   equivalent to `Encoding.GetBytes(payload)`, which failed at runtime with
   `unresolved extern instance method 'GetBytes' ...: no matching instance
   method found in .NET metadata` — the compiler's extern-instance-method
   binding mis-generated the call, treating the `Encoding` receiver as an
   ordinary first argument instead of the implicit `this`. Tracked as part
   of the still-open upstream defect class
   [lyric-lang#3887](https://github.com/nichobbs/lyric-lang/issues/3887)
   ("BCL `@externTarget` metadata resolution"), which explicitly lists
   `Encoding.GetBytes` as one of the affected instance methods — still
   reproduced against the 0.4.19 pin (see `repro-web-bug.sh`'s own header
   comment for that history), but is genuinely fixed as of the 0.4.26 pin:
   CI's `repro-web-bug.sh` diagnostic step, which reads whichever version is
   *currently* pinned in `lyric.toml` rather than a hardcoded number,
   reports "Lyric.Web 0.4.26 resolves `Encoding.GetBytes` at runtime —
   lyric-lang#3887 is fixed for this call". `./scripts/repro-web-bug.sh`
   remains checked in to mechanically re-check this against whatever
   version is currently pinned, should a future bump ever regress it.
2. **No real request dispatch — fixed as of `Lyric.Web` 0.4.26.** Earlier
   `Lyric.Web` releases (through 0.4.19) returned an identical hardcoded
   diagnostic JSON payload for every request regardless of method or path —
   confirmed by reading `lyric-web/src/web.l`'s own doc comment at the time:
   `Stability: @experimental — ... the end-to-end pipeline ... has not been
   exercised against a live HTTP client in CI` and `Discovery via DLL
   reflection is planned once Lyric's annotation reflection ships`. 0.4.26
   replaced the old name-string route registration
   (`addGet(router, pattern, "Package.handlerName")`) with a `Handler`-
   interface model (`addGet(router, pattern, handler: Handler)`,
   `dispatch(router, req): Response`) that genuinely dispatches to the
   registered handler, and added request-header access
   (`header(req, name): Option[String]`) and a `Middleware` interface. This
   project's route registration in `src/main.l` was migrated accordingly —
   see the "Handler-adapter plumbing" comment block there for the pattern:
   one small stateless adapter record per route that decodes the request,
   calls the (unchanged) existing handler function, and encodes the
   response, plus an `AuthMiddleware` that finally calls
   `CloudAgents.Auth.enforce` on every request.

One `Lyric.Web` gap remains by design of its current API — a handler can
only return a single complete `Web.Response`, so live run output has to be
polled (`getRunOutput`, and the incremental `getRunOutputFrom`) instead of
streamed — written up as a ready-to-file upstream feature request in
`docs/upstream/lyric-web-streaming.md`.

**Net effect, now genuinely confirmed end-to-end (2026-07-15), not just
believed from compiling.** `scripts/run-api.sh` builds and starts, and a
real running server was driven with real `curl` requests against
`--urls http://127.0.0.1:<port>`: `GET /api/health`, `GET /api/sessions`,
`GET /api/prompts` all returned correct `200` responses with real JSON
bodies, dispatched through the actual `Handler`/`Middleware`/
`AuthMiddleware` chain over a real socket — not a diagnostic script, an
actual client hitting the actual listener. This resolves the "believed,
not confirmed" gap #354 left open (the `Web.Request`-construction crash
that blocked writing an *automated* end-to-end test is unrelated to
whether the server itself works, and `repro-web-request-crash.sh` still
tracks that specific construction bug on its own terms).

**Container creation was also verified genuinely end-to-end against a
real Docker daemon**, including the full production path: `POST
/api/sessions` followed by `POST /api/sessions/{id}/messages` spawned a
real `claude-code:base` container via `CloudAgents.Docker`, which cloned
a real GitHub repo and streamed real output back through the session's
SSE endpoint. Two real bugs in the `Lyric.Docker` library were found and
fixed doing this (neither is a cloud-agents defect):

1. `Lyric.Docker` 0.4.29 (the previously-pinned NuGet version) crashed
   with `InvalidProgramException` on *any* live-daemon call
   (`ping`/`createContainerWithNetwork`/etc.) — confirmed to be a stale
   published artifact predating an unrelated async-codegen fix already on
   `lyric-lang` `main`; rebuilding from source reproduced nothing. Fixed
   here by bumping the pin to `0.4.31` (already published, contains the
   fix) — see the `[nuget]` table above. `./scripts/repro-docker-crash.sh`
   is checked in as a runnable reproduction (mirroring
   `repro-web-bug.sh`'s convention): point it at a live daemon via
   `CLOUD_AGENTS_DOCKER_TCP_HOST` and it mechanically re-checks whichever
   `Lyric.Docker` version is currently pinned, should a future bump ever
   regress it. Not wired into CI (no Docker daemon there); run manually.
2. `getContainerLogs` misdetected raw-vs-multiplexed log streams (the
   `/logs` response's own `Content-Type` header is not a reliable signal
   for this — it reports `application/vnd.docker.raw-stream`
   unconditionally regardless of the container's actual TTY setting),
   causing every non-TTY container's log read to fail with `"Failed to
   decode container logs as UTF-8"`. Fix submitted upstream in
   [lyric-lang#5773](https://github.com/nichobbs/lyric-lang/pull/5773)
   (open, not yet merged as of this writing); **not yet in any published
   `Lyric.Docker` release either way** — bump the pin again once a
   release containing that fix ships (check
   https://www.nuget.org/packages/Lyric.Docker for a version newer than
   0.4.31, or re-run `./scripts/repro-compiler-bug.sh`-style verification
   against a live daemon after bumping).

Two separate, narrower gaps surfaced during this verification and remain
open, both `src/` / `docker/entrypoint.sh` concerns, not `Lyric.Docker`/
compiler issues: the container's own `entrypoint.sh`/CLI invocation
errored on a first-run session (`--resume requires a valid session ID
or session title`), tracked as
[#386](https://github.com/nichobbs/cloud-agents/issues/386); and the
session's polled `GET /api/sessions/{id}/output` endpoint returned an
empty `output` even though the SSE stream carried real chunks during
the run, tracked as
[#387](https://github.com/nichobbs/cloud-agents/issues/387). Neither is
explored past the point of filing; tracked as follow-ups rather than
blocking this verification pass.

### Bumping a NuGet dependency version

Edit the version string in `[nuget]` and re-run `lyric restore`. Before
bumping `Lyric.Docker` back onto NuGet, re-check that the published package's
API actually covers what `docker_manager.l` calls (see above) — don't assume
it's caught up without checking, the way this project's own history did once.

## Running tests

`lyric test` (the `cmdTestManifest` CLI path) no longer crashes with
`System.InvalidCastException` as of v0.4.11 (bug 1 below hit this entry
point too), no longer fails every test outright on a missing
`Lyric.Stdlib.dll` as of v0.4.15 (that was the same underlying bug as bug
4 below), no longer corrupts cross-package field/method tokens as of
v0.4.17 (bug 5 below, `lyric-lang#5177`), no longer fails on
`slice[T].append()` as of v0.4.18 (bug 6 below, `lyric-lang#5244`), and no
longer crashes an untyped top-level `String val`'s `.length` as of v0.4.19
(bug 7 below, `lyric-lang#5298`) — `CloudAgents.SessionTests`,
`CloudAgents.StreamingTests`, `CloudAgents.DbTests`, and
`CloudAgents.AuthTests` are now **all fully green**, for the first
time in this project's history. `src/handlers/sessions.l`'s top-level `val
httpsPrefix = "https://"` (no type annotation) — read via `.length` in
`createSession` — was exactly bug 7's trigger; see bug 7 below for the
compiler-side root cause. `scripts/verify.sh` remains a useful,
`lyric test`-free harness (a hand-rolled `main()` run via
`lyric build && lyric run`) and still genuinely passes all 24 checks, but
`lyric test` is now the right entry point again — both agree.

**Live-database suites need the native SQLite library on the loader path.**
`tests/prompt_tests.l` (and later suites) open real `Microsoft.Data.Sqlite`
connections against a temp file; `SqliteConnection`'s type initializer loads
the native `libe_sqlite3.so`, which the test runner does not resolve from
the NuGet cache by itself. Run `./scripts/build-full.sh` once (it copies the
native runtimes to `bin/runtimes/`), then:

```sh
export LD_LIBRARY_PATH="$PWD/bin/runtimes/linux-x64/native:$LD_LIBRARY_PATH"
lyric test
```

CI's "Run lyric test" step does exactly this. Without it the live-DB tests
fail with `The type initializer for 'Microsoft.Data.Sqlite.SqliteConnection'
threw an exception` while every non-DB suite still passes.

## Compiler notes

**Seven independent upstream compiler bugs blocked this project's
build/run/test pipeline in sequence, each one only reachable once the
previous one was fixed — all seven are now fixed (v0.4.11, v0.4.12,
v0.4.14, v0.4.15, v0.4.17, v0.4.18, v0.4.19).** `lyric build` **finally
succeeds as of v0.4.14** — the full project, all 12 packages, for the
first time in this project's history. `lyric run` **actually starts this
real, multi-package server as of v0.4.17** — also for the first time.
`lyric test` **passes every case as of v0.4.19** — also for the
first time. None of the seven is a characteristic of this project's
manifest, dependencies, or source — each was found and root-caused using
this project as the real-world test case that first got far enough to hit
it.

**CI enforces a version floor matching this status**, read from the single
checked-in [`MIN_LYRIC_VERSION`](../MIN_LYRIC_VERSION) file (currently
`0.4.19`) rather than duplicated as a literal here and in
`.github/workflows/ci.yml` — the "Verify minimum Lyric version" step fails
fast with a clear diagnostic if a future release ever resolves to
something older than that file's contents, rather than the `lyric test`
step below failing opaquely on an unrelated application PR (see
nichobbs/cloud-agents#140). Bump `MIN_LYRIC_VERSION` if a new bug is ever
found and fixed — this section's prose above will need updating too, but
the CI floor itself only needs the one file changed.

**This is checked into the repo as a runnable reproduction, not just
prose**: `scripts/repro-compiler-bug.sh` checks all seven bugs — checks 1-4
and 6-7 against trivial scratch projects, check 5 (which needed this
project's own real scale/shape to reproduce — see below) against the real
manifest in place via `lyric test`. Checks 1–2 need only `lyric` on PATH
(both bugs occur before the compiler would invoke the .NET toolchain);
checks 3–7 need `dotnet` (3–5 additionally need a real `[nuget]` restore),
and are skipped (not failed) without it. Run it yourself; exit 0 means
every bug that could be checked is fixed on your compiler and it's safe to
remove this script and the workaround notes below.

### Bug 1 — `buildProject` crash (lyric-lang#4925/#4955) — **fixed in v0.4.11**

Every compiler through 0.4.10 crashed with an unhandled
`System.InvalidCastException` inside `buildProject`, before it did anything
project-specific, on any standalone (non-workspace) Lyric project:

```
Unhandled exception. System.InvalidCastException: Specified cast is not valid.
   at Lyric.Cli.Program.buildProject(String, Option`1, CompileTarget, List`1, Boolean, Boolean, Boolean, Option`1) + 0x12c7
   at Lyric.Cli.Program.cmdBuild(String[]) + 0x115c
   at Lyric.Cli.Program.main(String[]) + 0x564
   at Lyric.Cli.Aot.Program.Main(String[] args) + 0x6
```

[lyric-lang#4925](https://github.com/nichobbs/lyric-lang/issues/4925) is
closed, fixed by
[lyric-lang#4955](https://github.com/nichobbs/lyric-lang/pull/4955):
`cli/workspace_builder.l`'s `buildWorkspaceDeps` constructed a bare `None`
tuple element on its not-in-a-workspace path, which loses its type argument
under the bootstrap emitter and fails to cast back to
`Option[Ws.WorkspaceContext]` when `buildProject`/`cmdTestManifest`
destructure it — unrelated to `[nuget]` (see below). **Confirmed fixed in
the [v0.4.11 release](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.11)**
— `lyric build` against a trivial hello-world no longer crashes on that
binary.

An earlier version of this project's build scripts described a `[nuget]`-
stripping workaround based on a theory that turned out to be wrong (that
`manifest.nuget: Option[NugetSection]` was the specific trigger) — it was
harmless but didn't actually fix anything, since the crash reproduced even
with no `[nuget]` section at all, and the real trigger (above) is unrelated
to `[nuget]`. Removed once the real scope became clear.

### Bug 2 — `Std.Core`'s Option/Result never resolve (lyric-lang#4980) — **fixed in v0.4.12**

Upgrading to v0.4.11 to pick up the bug 1 fix immediately exposed a second,
apparently pre-existing bug: `Option[T]`, `Result[T, E]`, and their
constructors `Some`/`None`/`Ok`/`Err` — declared in `lyric-stdlib/std/core.l`
and documented in `docs/lyric/stdlib.md` as available via a plain
`import Std.Core` — fail to resolve at every use site:

```
error[T0010] 4:23: unknown type name 'Option'
error[T0020] 5:21: unknown name 'Some'
error[T0020] 6:10: unknown name 'None'
```

The `import Std.Core` line itself never errors, and even a fully-qualified
`Std.Core.Result` reference fails the same way (`'Result' not found in
scope`) — so this isn't an import-form issue. It reproduces in every
configuration tried (standalone, multi-package, with/without `[nuget]`,
workspace-wrapped), and on **both** 0.4.10 (once routed around bug 1 via
workspace-wrapping) and 0.4.11 — meaning it predates bug 1 entirely and was
simply never reachable before, since bug 1 always crashed first. True
compiler builtins (`println`, `slice[T]` indexing/`.length`, `String`
methods) resolve fine; only the stdlib's actually-*declared* non-builtin
types fail. (`slice[T].append()` specifically does *not* resolve, at
runtime — that's an unrelated, separate bug, see bug 6 below.)
This affects this project's real source (`db_client.l`, `auth.l`,
`session_manager.l` all use `Option`/`Some`/`None`) and its own test
harness (`scripts/verify.sh`), and blocks the canonical `Result`/`Option`
patterns `docs/lyric/idioms.md` itself recommends — i.e. no Lyric compiler
had apparently ever been able to build a project using these idioms, since
bug 1 always masked bug 2 until v0.4.11. Filed as
[lyric-lang#4980](https://github.com/nichobbs/lyric-lang/issues/4980),
closed as fixed shortly before the
[v0.4.12 release](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.12)
— **confirmed fixed against that binary**: `Option[T]`/`Some`/`None` now
resolve in a trivial scratch project.

### Bug 3 — NuGet-restored zero-arg functions rejected (lyric-lang#5004) — **fixed in v0.4.14**

Upgrading to v0.4.12 to pick up the bug 2 fix exposed a third bug: calling
a **zero-argument function restored from a NuGet package** failed
type-checking with `"expected 1 argument(s), got 0"` — even though the
function genuinely took zero parameters, confirmed two independent ways:

- The package's own embedded `Lyric.Contract.Web` manifest resource said
  `{"kind":"func","name":"create","repr":"pub func create(): Router"}`.
- The actual compiled IL, inspected via .NET reflection
  (`MethodInfo.GetParameters()`), also showed zero parameters.

```
$ lyric build
WebTest: error[T0042] 6:16: expected 1 argument(s), got 0
B0001 error [1:1]: project build failed (see stderr)
```

This hit `src/main.l`'s very first NuGet-consumed call —
`var router = Web.create()` — immediately after bug 2's fix let the build
get that far; every other `Web.addGet`/`addPost`/`addDelete` call (3–4 args
each, same package, same file) type-checked fine, and a project-local
(source-compiled, non-NuGet) zero-arg cross-package call type-checked fine
too — specific to how the compiler derived an expected argument count from
a NuGet package's serialized contract. Filed as
[lyric-lang#5004](https://github.com/nichobbs/lyric-lang/issues/5004),
closed as fixed — **confirmed fixed in the
[v0.4.14 release](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.14)**:
`Web.create()` now resolves and the full project — all 12 packages —
builds successfully for the first time in this project's history.

(A separate, unrelated crash on the `dotnet tool install -g lyric` install
path — `System.MissingFieldException` during NuGet asset resolution, filed
as [lyric-lang#5010](https://github.com/nichobbs/lyric-lang/issues/5010) —
could make bug 3 look unreproducible if tried that way; the release-tarball
install path, what CI actually uses, is what gets far enough to hit it.)

### Bug 4 — NuGet dependency DLLs not copied to the output directory (lyric-lang#5066) — **fixed in v0.4.15**

Bug 3's fix let the full project build succeed — but running the built
server used to fail immediately:

```
$ lyric run
built .../bin/CloudAgents.dll (12 package(s), ...)
Unhandled exception. System.IO.FileNotFoundException: Could not load file or assembly 'Web, Version=0.4.0.0, Culture=neutral, PublicKeyToken=null'. The system cannot find the file specified.
   at CloudAgents.Program.main()
```

`bin/` after a build only contained `CloudAgents.dll`, `Lyric.Stdlib.dll`,
and a `runtimeconfig.json` — no `Web.dll` (or any other NuGet-restored
dependency), and no `.deps.json` either. Confirmed this was purely a
missing-file issue, not a deeper mismatch: manually copying the restored
`Web.dll` from the NuGet cache into `bin/` and running the *already-built*
DLL directly via `dotnet bin/CloudAgents.dll` worked. Reproduced on a
minimal single-dependency project too, so this wasn't specific to
`Lyric.Web` or to this project. Filed as
[lyric-lang#5066](https://github.com/nichobbs/lyric-lang/issues/5066),
fixed upstream in [lyric-lang#5074](https://github.com/nichobbs/lyric-lang/pull/5074)
(two independent root causes sharing the symptom — see that PR's
description) — **confirmed fixed in the
[v0.4.15 release](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.15)**:
`bin/` now contains every NuGet-restored dependency DLL and the stdlib
bundle, and the minimal `Web.create()` repro's `lyric run` prints `hi`
instead of crashing.

### Bug 5 — cross-package field/method metadata tokens resolve to the wrong member on real, multi-package builds (lyric-lang#5177) — **fixed in v0.4.17**

Bug 4's fix let `lyric run` succeed against a minimal project for the first
time — which is what exposed this: running (or testing) *this* real,
12-package project used to hit `MissingFieldException`/`FieldAccessException`
on enum literals that provably existed in the built assembly, e.g.:

```
$ dotnet bin/CloudAgents.dll --urls http://127.0.0.1:8080
Unhandled exception. System.MissingFieldException: Field not found: 'CloudAgents.Db.RecycleAction.StopAndIdle'.
   at CloudAgents.Sqlite.Program.dbErrorMessage(DbError)
   at CloudAgents.Program.main()
```

Inspected the built DLL's raw metadata directly with
`System.Reflection.Metadata.PEReader` (bypassing normal type-loading) to
rule out the field actually being absent — it was there, `public static
Literal`, exactly as expected. `dbErrorMessage`'s own source has no
reference to `RecycleAction` at all — it only pattern-matches an unrelated
`DbError` union in a different file/package. `lyric test` hit the same
class of error against two more types (`SessionEvent.CloneFinished`,
`AuthError.value__`).

Could **not** reproduce this in an isolated synthetic project no matter how
it was scaled — until gaining direct access to `nichobbs/lyric-lang` itself
made it possible to root-cause properly: **an `async func` that `await`s a
call to a function only *defined* in a later-declared `[project.packages]`
entry corrupts field/method tokens for every package declared in
between**, in an `output = "single"` bundle. This project's
`CloudAgents.Docker` package has several `async func`s that `await`
(unqualified, via `import Lyric.Docker`) functions actually defined in
`Lyric.Docker` — the very last package in the bundle — so every package
declared between them (`Db`, `Sqlite`, `Repository`, `Auth`, `Streaming`)
was exactly where the corruption showed up. A minimal 4-package repro
(one `async func` in package A awaiting an unqualified call into package
C, with an unrelated package B declared in between that crashes on a
completely unrelated function) reproduces it in isolation — see the issue
thread for the full repro and ablation. Filed as
[lyric-lang#5177](https://github.com/nichobbs/lyric-lang/issues/5177),
fixed upstream in [lyric-lang#5220](https://github.com/nichobbs/lyric-lang/pull/5220)
— **confirmed fixed in the
[v0.4.17 release](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.17)**:
`scripts/run-api.sh` starts the server for the first time in this
project's history, and `CloudAgents.DbTests` passes 11/11.

### Bug 6 — `slice[T].append()` threw "unsupported method 'append'" at runtime (lyric-lang#5244) — **fixed in v0.4.18**

Re-verifying bug 5 against v0.4.17 surfaced this: `slice[T].append(x)` —
the compiler's own documented idiom for building up a slice (see
`docs/lyric/reference.md`'s own "Arrays and slices" section, which mirrors
the compiler's own docs verbatim) — threw at runtime, unconditionally, for
any element type:

```
$ lyric build   # succeeded — this only failed at runtime
$ dotnet bin/Test.dll
Unhandled exception. System.Exception: unsupported method 'append' on the receiver type at this call site (no matching user method, extern binding, or built-in intrinsic)
```

Reproduced in complete isolation — a single package, a single function,
`val dynamic: slice[Int] = [1, 2, 3]; val ys = dynamic.append(42)`, no
`[project.packages]`, no NuGet, no async involved at all. Confirmed the
same for `slice[String]` and a plain 2-field `record` element type.
Read-only slice operations (`.length`, indexing) were unaffected — this was
scoped specifically to the mutation-style methods. **Not a regression** —
reproduced identically on v0.4.15 and v0.4.17 both, so it had been broken at
least that long; it was simply never runtime-exercised in this project
until bugs 1–5 stopped masking it (every earlier blocker crashed before
`lyric test` ever got far enough to execute a function that calls
`.append()`). `src/handlers/auth.l`'s `parseWhitelist` and
`src/sessions/session_manager.l`'s session-list helpers both call it, which
is why `CloudAgents.SessionTests` and one `CloudAgents.AuthTests` case
(`Whitelist access control`) used to fail `lyric test`. Filed as
[lyric-lang#5244](https://github.com/nichobbs/lyric-lang/issues/5244) —
**confirmed fixed in the
[v0.4.18 release](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.18)**:
`slice[T].append()` now resolves at runtime for `Int`/`String`/record
element types, and `CloudAgents.AuthTests` passes 5/5.

### Bug 7 — untyped top-level `val` of inferred String type crashes `.length` with an IList cast (lyric-lang#5298) — **fixed in v0.4.19**

Diagnosing the one `CloudAgents.SessionTests` case bug 6's fix didn't
clear (`Test Handler createSession validation`) surfaced a seventh,
distinct bug: a package-scope (top-level) `val` declared **without an
explicit type annotation**, whose initializer is a string literal, crashes
at runtime with `System.InvalidCastException: Unable to cast object of
type 'System.String' to type 'System.Collections.IList'` when its
`.length` is read — anywhere in the program, including same-package,
unqualified, no cross-package reference involved:

```
$ lyric build   # succeeds — this only fails at runtime
$ dotnet bin/Test.dll
Unhandled exception. System.InvalidCastException: Unable to cast object of type 'System.String' to type 'System.Collections.IList'.
   at Test.Program.main()
```

Reproduces in complete isolation — a single package, a single file:
`val prefix = "https://"; func main(): Unit { println(prefix.length.toString()) }`
— no `@post`/`@body`/`@generate(Json)`, no NuGet, no multi-package
structure, no `lyric test` harness needed at all (a plain `main()` run via
`dotnet` reproduces it directly). Confirmed the same holds for `pub val`
and plain `val`; confirmed a top-level `val` with an *explicit* type
annotation (e.g. `slice[String]`) and a top-level `Int` literal `val` are
both unaffected — the bug is specific to an untyped declaration whose
inferred type is `String`. Root-caused (with direct access to
`nichobbs/lyric-lang`) to `lyric-compiler/msil/codegen.l`'s package-level
`val`/`const` pre-scan: it only records a declaration's MSIL type when
there's an explicit type annotation (`decl.ty = Some(...)`); when the type
must be inferred from the initializer, it silently defaults to `MObject`.
A later read site's `.length` dispatch has a fallback that assumes any
`MObject`-typed receiver reaching `.length` is a `List`-backed slice
(correct for slices, whose static type also often erases to `MObject`) and
unconditionally casts to `IList` — wrong for a boxed `System.String`, hence
the `InvalidCastException`. **Not a regression** — this is a longstanding
gap in the pre-scan, independent of (though similarly-shaped to)
[lyric-lang#5258](https://github.com/nichobbs/lyric-lang/issues/5258) (a
related but different MSIL bug — *cross*-package qualified `pub val`
access resolving to null — fixed the same day; its fix added qualified
lookup keys but didn't touch this same-package, untyped-inference gap).
`src/handlers/sessions.l`'s `createSession` reads exactly such a top-level
`val` (`httpsPrefix = "https://"`, no annotation) via `.length`, which is
why `CloudAgents.SessionTests`' "Test Handler createSession validation"
case used to fail `lyric test` even with bug 6 fixed —
`scripts/verify.sh`'s own harness doesn't happen to read that val's
`.length`, so it was unaffected and still genuinely passed throughout.
Filed as
[lyric-lang#5298](https://github.com/nichobbs/lyric-lang/issues/5298) —
**confirmed fixed in the
[v0.4.19 release](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.19)**:
an untyped top-level `String val`'s `.length` now resolves correctly at
runtime, and `CloudAgents.SessionTests` passes 4/4 — the full `lyric test`
suite passes fully for the first time in this project's history. (The suite roster lives in lyric.toml's [project.tests]; per-suite counts aren't duplicated here.)

**All seven known upstream compiler bugs are now fixed.** Nothing on this
project's manifest, build config, or source needs to change for bug 7 —
check `./scripts/repro-compiler-bug.sh` if a future `lyric` release
regresses any of the seven.

### A real bug this *did* surface in this project's own source

Building the full project for the first time (past bug 3) found a genuine,
previously-undetectable bug in `vendor/lyric-docker/src/docker.l`: four
call sites used a nonexistent bare function `unwrapResult(x)` instead of
the documented `Result`/`Option` method `x.unwrap()` (see
`docs/lyric/stdlib.md`). This was never caught because the compiler always
crashed before ever type-checking this file. Fixed by replacing all four
call sites with `.unwrap()`.

Other compiler-level characteristics, independent of the above:

- **`String.indexOf` / `Option` were historically unreliable at runtime** in
  early standalone installs (not-found did not yield `None` in some
  contexts). The JSON extractors in `auth.l` and `session_manager.l` use a
  hand-rolled `indexOfFrom` substring scan instead of `String.indexOf` as a
  defensive measure; revisit if a later compiler release confirms the stdlib
  path is reliable.
- **`out` is a reserved keyword** — it cannot be used as an identifier.

## Distribution

Two ways to get a runnable Cloud Agents build:

- **Development**: `./scripts/install.sh` installs Lyric (if not already on
  `PATH`) and the .NET 10 SDK (if not already on `PATH`, skippable with
  `SKIP_DOTNET`), then runs `lyric restore`. See the script's own header
  comment for env overrides (`LYRIC_VERSION`, `LYRIC_DIR`, `SKIP_RESTORE`).
- **Release**: `.github/workflows/release.yml` (triggered by pushing a
  `vX.Y.Z` tag, or manually via `workflow_dispatch`) builds a self-contained
  native executable per target platform and attaches it to a GitHub Release,
  the same way lyric-lang's own `publish.yml` does for the `lyric` binary.

### Why self-contained, not true Native AOT

`dist/CloudAgents.Native/` is a thin C# trampoline project (`Program.cs`
calling straight into the Lyric-emitted `CloudAgents.Program.main()`) whose
only job is to let `dotnet publish` turn the already-compiled
`bin/CloudAgents.dll` (plus its full NuGet-restored dependency closure —
`Lyric.Web`, `Lyric.Docker`, the `Lyric.Stdlib.*` closure,
`Microsoft.Data.Sqlite` + `SQLitePCLRaw`) into one deployable artifact per
platform, mirroring the pattern `bootstrap/src/Lyric.Cli.Aot/` already uses
to publish the `lyric` compiler itself.

The obvious next step — `PublishAot=true`, a genuine ahead-of-time-compiled
native binary — publishes cleanly with **zero ILC warnings**, but the
resulting executable **crashes on startup**:

```
Unhandled exception. System.IndexOutOfRangeException: Index was outside the bounds of the array.
   at System.Array.GetFlattenedIndex(Int32) + 0x1f
   at CloudAgents.Repository.Program.runMigrations() + ...
```

This was tracked down to a general, project-independent bug in the
self-hosted Lyric compiler's Native-AOT compatibility, reproduced with a
minimal `slice[Record]` array literal iterated by a `for...in` loop (no
Docker, no async, no I/O — just that shape) — filed upstream as
[lyric-lang#5781](https://github.com/nichobbs/lyric-lang/issues/5781). Until
that's fixed, `dist/CloudAgents.Native/CloudAgents.Native.csproj` pins
`PublishAot` to `false` and `SelfContained` to `true`: the .NET runtime is
still bundled into the published output (no separate `dotnet` install
needed on the target machine), but the assemblies stay managed IL (JIT'd at
startup) rather than ahead-of-time compiled. Verified to behave identically
to a normal `dotnet bin/CloudAgents.dll` run, including serving a real
`/api/health` request correctly (the release workflow's smoke-test step
checks this on every build). Re-enable `PublishAot` once lyric-lang#5781 is
fixed — no other change to this project should be needed.

### The SQLite native-library wrapper script

The trampoline project references `bin/*.dll` via a loose-file glob rather
than a real project/package reference, so `dotnet publish` has no runtime-
asset metadata telling it to copy `Microsoft.Data.Sqlite`'s native
`libe_sqlite3.so` alongside the executable — and a bare
`runtimes/<rid>/native/` directory placed next to the published executable
was verified NOT to be auto-discovered in this project's publish shape
(confirmed by direct experiment: the server starts but every SQLite call
fails with `SqliteConnection`'s type initializer throwing). The release
workflow works around this by staging the native library into
`runtimes/<rid>/native/` next to the executable and renaming the real
executable to `cloud-agents.bin`, then generating a `cloud-agents` wrapper
shell script that sets `LD_LIBRARY_PATH` to that directory before `exec`-ing
the real binary — verified working end-to-end (a real HTTP request against
a real SQLite-backed endpoint succeeds through the wrapper, fails without
it). Released archives should always be run via the `cloud-agents` wrapper,
not `cloud-agents.bin` directly.

### Scope: Linux only

The release workflow currently builds `linux-x64` and `linux-arm64` only.
This project orchestrates Docker containers server-side — macOS/Windows
are not realistic deployment targets for this workload — so the smaller,
fully-verified Linux-only slice was chosen over a broader but untested
multi-platform matrix. `linux-arm64` is cross-published from an x64 runner
(self-contained non-AOT publish needs no cross-compilation toolchain, just
the target RID's runtime pack) and is not executed by the workflow's smoke
test (no arm64 execution environment available in CI); its correctness
rests on the identical `linux-x64` leg passing through the same
RID-parameterized steps.
