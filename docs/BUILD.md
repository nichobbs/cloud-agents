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
"Lyric.Web"             = "0.4.10"
"Std.Logging"           = "0.4.10"
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
lyric build   # see "Compiler notes" below — this cannot currently succeed
              # at all, with any released compiler version, on any project
```

`scripts/build-full.sh` wraps `lyric restore`/`lyric build`. `scripts/verify.sh`
is the test entry point — see "Running tests" below for why it isn't `lyric
test`. `scripts/run-api.sh` builds the same way, then runs the compiled
server. **None of these can currently succeed** — see "Compiler notes".

### Bumping a NuGet dependency version

Edit the version string in `[nuget]` and re-run `lyric restore`. Before
bumping `Lyric.Docker` back onto NuGet, re-check that the published package's
API actually covers what `docker_manager.l` calls (see above) — don't assume
it's caught up without checking, the way this project's own history did once.

## Running tests

`lyric test` (the `cmdTestManifest` CLI path) crashes with an unhandled
`System.InvalidCastException`. `scripts/verify.sh` avoids it by compiling a
hand-rolled `main()` harness and running it via `lyric build && lyric run`
instead — **but as of this writing that doesn't work either**; see
"Compiler notes" below. `scripts/verify.sh` is still the right entry point
to use (`./scripts/verify.sh`) — the approach is correct, it's just blocked
on an external bug, not something to route around differently. It exercises
the Docker/Web-independent logic (SSE framing, the Phase 2 state machine +
idle recycling + SQL builders, the Phase 3 auth helpers) — the same code
the `@test_module` suites in `tests/*.l` describe. Those `tests/*.l` files
remain the readable source of truth for intended behavior and should still
be kept up to date.

## Compiler notes

**Three independent upstream compiler bugs have blocked `lyric build`/
`run`/`check`/`test` for this project, discovered one at a time as each
prior one got fixed — two are now fixed (v0.4.11, v0.4.12), one is still
open.** None is a characteristic of this project's manifest, dependencies,
or source.

**This is checked into the repo as a runnable reproduction, not just
prose**: `scripts/repro-compiler-bug.sh` checks all three bugs against
trivial scratch projects. Checks 1–2 need only `lyric` on PATH (both bugs
occur before the compiler would invoke the .NET toolchain); check 3 needs
a real `[nuget]` restore, so it additionally needs `dotnet` and network
access, and is skipped (not failed) without `dotnet`. Run it yourself; exit
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

### Bug 3 — NuGet-restored zero-arg functions rejected (lyric-lang#5004) — **open, currently blocking**

Upgrading to v0.4.12 to pick up the bug 2 fix immediately exposed a third
bug: calling a **zero-argument function restored from a NuGet package**
fails type-checking with `"expected 1 argument(s), got 0"` — even though
the function genuinely takes zero parameters, confirmed two independent
ways:

- The package's own embedded `Lyric.Contract.Web` manifest resource says
  `{"kind":"func","name":"create","repr":"pub func create(): Router"}`.
- The actual compiled IL, inspected via .NET reflection
  (`MethodInfo.GetParameters()`), also shows zero parameters.

```
$ lyric build
WebTest: error[T0042] 6:16: expected 1 argument(s), got 0
B0001 error [1:1]: project build failed (see stderr)
```

This hits `src/main.l`'s very first NuGet-consumed call —
`var router = Web.create()` — immediately after bug 2's fix let the build
get that far; every other `Web.addGet`/`addPost`/`addDelete` call (3–4 args
each, same package, same file) type-checks fine, and a project-local
(source-compiled, non-NuGet) zero-arg cross-package call type-checks fine
too. So this looks specific to how the compiler derives an expected
argument count from a NuGet package's serialized contract — plausibly a
naive comma-count parse of a `repr` string like `"pub func create(): Router"`
that doesn't special-case a genuinely-empty `()` parameter list. Filed as
[lyric-lang#5004](https://github.com/nichobbs/lyric-lang/issues/5004)
(open).

**There is nothing to fix on this project's side for any of the three
bugs** — `lyric build`/`test` failing in CI is expected until a release
fixing [lyric-lang#5004](https://github.com/nichobbs/lyric-lang/issues/5004)
ships. Check that issue for status before assuming a local build failure
needs a local fix.

Other compiler-level characteristics, independent of the above:

- **`String.indexOf` / `Option` were historically unreliable at runtime** in
  early standalone installs (not-found did not yield `None` in some
  contexts). The JSON extractors in `auth.l` and `session_manager.l` use a
  hand-rolled `indexOfFrom` substring scan instead of `String.indexOf` as a
  defensive measure; revisit if a later compiler release confirms the stdlib
  path is reliable.
- **`out` is a reserved keyword** — it cannot be used as an identifier.
