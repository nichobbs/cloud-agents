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

`Lyric.Web`, `Std.Logging`, and `Microsoft.Data.Sqlite` are declared under
`[nuget]` in `lyric.toml` and resolved as ordinary prebuilt binary packages —
no sibling checkout, no source patching:

```toml
[nuget]
"Lyric.Web"             = "0.4.11"
"Std.Logging"           = "0.4.11"
"Microsoft.Data.Sqlite" = "10.0.9"
```

`Lyric.Docker` is **not** on that list. The published `Lyric.Docker` 0.4.10
package (confirmed by extracting the `.nupkg` from nuget.org and inspecting
`Docker.dll`'s embedded contract) requires an explicit `client: DockerClient`
argument on every call and has no `waitContainer` function at all — a
materially different, incompatible API from what `src/docker_manager.l`
depends on. `vendor/lyric-docker` is a local fork with the container-lifecycle
operations this project needs (`createContainer`, `start/stop/removeContainer`,
`waitContainer`, `getContainerLogs`), pending upstreaming. It's compiled as an
ordinary local package via `[project.packages]` in the root `lyric.toml` —
not a separate dependency, no restore-path workaround, no patching:

```toml
[project.packages]
"Lyric.Docker"         = "vendor/lyric-docker/src/docker.l"
"Lyric.Docker.Sockets" = "vendor/lyric-docker/src/sockets.l"
```

Build from the repo root:

```sh
lyric restore
lyric build   # succeeds as of v0.4.14 — see "Compiler notes" below for history
```

`scripts/build-full.sh` wraps `lyric restore`/`lyric build` — **this now
succeeds** against v0.4.14+ (the first release where it ever has). `scripts/verify.sh`
is the test entry point — see "Running tests" below for why it isn't `lyric
test` — and **genuinely passes**. `scripts/run-api.sh` builds the same way,
then runs the compiled server — this is still blocked, but not by the same
bug it used to be: `lyric build` succeeds and, as of v0.4.15, `lyric run`
correctly finds its NuGet-restored dependencies at runtime
(`lyric-lang#5066`, fixed) — but the real project now hits a *different*,
newly-exposed bug at runtime (`lyric-lang#5177`, open) — see "Compiler
notes".

### Bumping a NuGet dependency version

Edit the version string in `[nuget]` and re-run `lyric restore`. Before
bumping `Lyric.Docker` back onto NuGet, re-check that the published package's
API actually covers what `docker_manager.l` calls (see above) — don't assume
it's caught up without checking, the way this project's own history did once.

## Running tests

`lyric test` (the `cmdTestManifest` CLI path) no longer crashes with
`System.InvalidCastException` as of v0.4.11 (bug 1 below hit this entry
point too), and as of v0.4.15 it no longer fails every test outright on a
missing `Lyric.Stdlib.dll` either (that was the same underlying bug as bug
4 below, just hitting the compiler's own bundled stdlib instead of a NuGet
dependency — fixed by the same release). `lyric test` now genuinely
*runs* — but most of it still fails, hitting bug 5 below (`lyric-lang#5177`)
on real cross-package field/method access: `not ok ... Field not found:
'CloudAgents.Db.SessionEvent.CloneFinished'.` and similar. `scripts/verify.sh`
avoids `lyric test` entirely by compiling a hand-rolled `main()` harness and
running it via `lyric build && lyric run` instead, and **that still
genuinely succeeds** — all 24 checks pass for real, unaffected by bug 5
(its harness doesn't happen to trigger the cross-package pattern that
does). `scripts/verify.sh` is still the right entry point to use
(`./scripts/verify.sh`); it exercises the Docker/Web-independent logic
(SSE framing, the Phase 2 state machine + idle recycling + SQL builders,
the Phase 3 auth helpers) — the same code
the `@test_module` suites in `tests/*.l` describe. Those `tests/*.l` files
remain the readable source of truth for intended behavior and should still
be kept up to date; once bug 5 is fixed upstream, `lyric test` should become
the right entry point again.

## Compiler notes

**Five independent upstream compiler bugs have blocked this project's
build/run/test pipeline in sequence, each one only reachable once the
previous one was fixed — four are now fixed (v0.4.11, v0.4.12, v0.4.14,
v0.4.15), one is still open.** `lyric build` **finally succeeds as of
v0.4.14** — the full project, all 12 packages, for the first time in this
project's history. `lyric run` **also succeeds against a minimal project as
of v0.4.15** — but actually starting *this* real, multi-package server (or
running most of its `lyric test` suites) is still blocked by the remaining
open bug. None of the five is a characteristic of this project's manifest,
dependencies, or source — each was found and root-caused using this
project as the real-world test case that first got far enough to hit it.

**This is checked into the repo as a runnable reproduction, not just
prose**: `scripts/repro-compiler-bug.sh` checks all five bugs — checks 1-4
against trivial scratch projects, check 5 (which needs this project's own
real scale/shape to reproduce — see below) against the real manifest in
place via `lyric test`. Checks 1–2 need only `lyric` on PATH (both bugs
occur before the compiler would invoke the .NET toolchain); checks 3–5 need
a real `[nuget]` restore, so they additionally need `dotnet` and network
access, and are skipped (not failed) without `dotnet`. Run it yourself; exit
0 means every bug that could be checked is fixed on your compiler and it's
safe to remove this script and the workaround notes below.

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
compiler builtins (`println`, `slice[T]`/`.append()`, `String` methods)
resolve fine; only the stdlib's actually-*declared* non-builtin types fail.
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

### Bug 5 — cross-package field/method metadata tokens resolve to the wrong member on real, multi-package builds (lyric-lang#5177) — **open, currently blocking `lyric run`/most of `lyric test`**

Bug 4's fix let `lyric run` succeed against a minimal project for the first
time — which is what exposed this: running (or testing) *this* real,
12-package project hits `MissingFieldException`/`FieldAccessException` on
enum literals that provably exist in the built assembly, e.g.:

```
$ dotnet bin/CloudAgents.dll --urls http://127.0.0.1:8080
Unhandled exception. System.MissingFieldException: Field not found: 'CloudAgents.Db.RecycleAction.StopAndIdle'.
   at CloudAgents.Sqlite.Program.dbErrorMessage(DbError)
   at CloudAgents.Program.main()
```

Inspected the built DLL's raw metadata directly with
`System.Reflection.Metadata.PEReader` (bypassing normal type-loading) to
rule out the field actually being absent — it's there, `public static
Literal`, exactly as expected. `dbErrorMessage`'s own source has no
reference to `RecycleAction` at all — it only pattern-matches an unrelated
`DbError` union in a different file/package. `lyric test` hits the same
class of error against two more types (`SessionEvent.CloneFinished`,
`AuthError.value__`), plus an analogous wrong-*method*-token variant
(`"unsupported method 'append' on the receiver type"` for a `slice[T]`
method that succeeds dozens of other times in the exact same build) — all
consistent with one underlying cause: wrong metadata tokens after merging
separately-compiled packages into a single output assembly, not something
specific to enums, `Microsoft.Data.Sqlite`, or FFI.

Could **not** reproduce this in an isolated synthetic project — tried
scaling one up to 9 packages (short of this project's real 12, but no
change in outcome as the count increased), a `[project.tests]` section, the
`@runtime_checked` attribute, and real `[nuget]`/FFI bindings to
`Microsoft.Data.Sqlite`, all in isolation and combined, with no luck. Needs
this project's actual real code shape/scale to trigger, so it's filed
against the real project itself (100% reliably reproducible, unlike a
distilled minimal case) as
[lyric-lang#5177](https://github.com/nichobbs/lyric-lang/issues/5177)
(open).

**There is nothing to fix on this project's manifest or build config for
any of the five bugs** — `lyric run`/`scripts/run-api.sh` failing, and most
of `lyric test` failing, is expected until a release fixing
[lyric-lang#5177](https://github.com/nichobbs/lyric-lang/issues/5177)
ships. Check that issue for status before assuming a local failure needs a
local fix.

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
