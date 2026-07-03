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

**No currently-released Lyric compiler (0.4.7 through 0.4.10) can build,
run, check, or test any Lyric project — including a trivial one-file
hello-world with no dependencies.** This is not a characteristic of this
project's manifest, dependencies, or source; it's a crash inside the
compiler's own `buildProject`, before it does anything project-specific.

**This is checked into the repo as a runnable reproduction, not just
prose**: `scripts/repro-compiler-bug.sh` builds a trivial, dependency-free
`lyric.toml`/`main.l` in a scratch directory and runs `lyric build` against
it — no `[nuget]`, no `[workspace]`, nothing project-specific, and no
`dotnet` required (the crash happens before the compiler would invoke the
.NET toolchain). Run it yourself against any environment with `lyric` on
PATH:

```
$ ./scripts/repro-compiler-bug.sh
==> lyric build against a trivial, dependency-free hello-world
Unhandled exception. System.InvalidCastException: Specified cast is not valid.
   at Lyric.Cli.Program.buildProject(String, Option`1, CompileTarget, List`1, Boolean, Boolean, Boolean, Option`1) + 0x12c7
   at Lyric.Cli.Program.cmdBuild(String[]) + 0x115c
   at Lyric.Cli.Program.main(String[]) + 0x564
   at Lyric.Cli.Aot.Program.Main(String[] args) + 0x6
==> Reproduced: this compiler still has the workspace_builder.l bug (lyric-lang#4925/#4955)
```

Exit code 0 means it reproduced (you're still on a pre-#4955 compiler);
exit code 1 means `lyric build` succeeded (your compiler already has the
fix — safe to remove this script and the workaround notes below). Run
above is from this session's own sandbox, where `lyric` (but not `dotnet`)
is on PATH — sufficient to reproduce this specific crash, though not to do
a full `lyric restore`/build of this project's actual dependency graph.

`lyric build`, `lyric run`, and `lyric check` all hit it (they all call into
`buildProject`); `lyric test` crashes the same way via a different entry
point.

**Root cause is found and a fix has been merged upstream — but not released
yet.** [lyric-lang#4925](https://github.com/nichobbs/lyric-lang/issues/4925)
is closed, fixed by
[lyric-lang#4955](https://github.com/nichobbs/lyric-lang/pull/4955): the
actual trigger is any project with **no `[workspace]` ancestor manifest** —
`cli/workspace_builder.l`'s `buildWorkspaceDeps` constructed a bare `None`
tuple element on its not-in-a-workspace path, which loses its type
argument under the bootstrap emitter and fails to cast back to
`Option[Ws.WorkspaceContext]` when `buildProject`/`cmdTestManifest`
destructure it. Unrelated to `[nuget]` (see below) — this project, and any
other standalone (non-workspace) Lyric project, hits it unconditionally.
As of this writing the fix is merged to `main` but the latest tagged
release is still `v0.4.10`, published *before* the fix merged, so every
currently-downloadable binary still crashes exactly as shown above. Check
[lyric-lang#4925](https://github.com/nichobbs/lyric-lang/issues/4925) for
whether a release containing the fix has shipped before assuming a local
build failure needs a local fix.

Restructuring this project as a workspace member purely to dodge the bug on
the *current* binary was considered and rejected: the fix is already merged
upstream, a standalone (non-workspace) layout is a normal, fully-supported
configuration per Lyric's own workspace design doc, and adding a workspace
wrapper now would just be a new workaround to strip back out once a fixed
release ships — the churn this section exists to avoid repeating.

An earlier version of this project's build scripts described a `[nuget]`-
stripping workaround based on a theory that turned out to be wrong (that
`manifest.nuget: Option[NugetSection]` was the specific trigger) — it was
harmless but didn't actually fix anything, since the crash reproduces even
with no `[nuget]` section at all, and the real trigger (above) is unrelated
to `[nuget]`. Removed once the real scope became clear; `scripts/build-full.sh`
and `scripts/verify.sh` are back to their straightforward form. **There is
nothing to fix on this project's side** — `lyric build`/`test` failing in
CI is expected until a release containing
[lyric-lang#4955](https://github.com/nichobbs/lyric-lang/pull/4955) ships.

Other compiler-level characteristics, independent of the above:

- **`String.indexOf` / `Option` were historically unreliable at runtime** in
  early standalone installs (not-found did not yield `None` in some
  contexts). The JSON extractors in `auth.l` and `session_manager.l` use a
  hand-rolled `indexOfFrom` substring scan instead of `String.indexOf` as a
  defensive measure; revisit if a later compiler release confirms the stdlib
  path is reliable.
- **`out` is a reserved keyword** — it cannot be used as an identifier.
