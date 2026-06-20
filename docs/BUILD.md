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

## Workspace dependencies

`lyric.toml` depends on libraries from the **lyric-lang** workspace via relative
paths (`../lyric-lang/lyric-web`, `../lyric-lang/lyric-docker`,
`../lyric-lang/lyric-logging`). Clone it as a sibling of this repo:

```
parent/
├── cloud-agents/        # this repo
└── lyric-lang/          # git clone https://github.com/nichobbs/lyric-lang
```

Build the path dependencies first (their `bin/*.dll` must exist before this
project restores them):

```sh
for lib in lyric-stdlib lyric-logging lyric-auth lyric-resilience lyric-web lyric-docker; do
  (cd ../lyric-lang/$lib && lyric build)
done
```

Then build and test this project:

```sh
lyric build
lyric test
```

## Verified vs. pending (compiler v0.2.4)

The currently published Lyric compiler is early-stage. The following were
validated against **v0.2.4** (the v0.1.x findings below still hold — the v0.2.4
reassessment did not unblock anything for this project):

- **Pure-logic packages compile and run.** `CloudAgents.Streaming`,
  `CloudAgents.Db`, and `CloudAgents.Auth` build cleanly and are runtime-verified
  end-to-end by `scripts/verify.sh` (24 assertions: SSE framing, the Phase 2
  state machine + idle recycling + owner-scoped SQL, and the Phase 3 auth
  helpers). These use only enums/unions/records/primitives.
- **`String.split` is not available** — split manually with a character scan
  (`formatLogsAsSse` does this).
- **`String.indexOf` / `Option` are unreliable at runtime** in the standalone
  install: not-found does not yield `None`, and matching the result NREs in some
  contexts. The JSON extractors in `auth.l` use a hand-rolled `indexOfFrom`
  substring scan instead.
- **The stdlib runtime DLLs are not shipped** with the standalone binary, so any
  code that touches `Option`, `slice`, `@generate(Json)`, or `Std.Testing` at
  runtime fails to load `Lyric.Stdlib.Core` / `Lyric.Stdlib.Testing`. This is why
  the `@test_module` suites compile but cannot execute here; runtime checks go
  through the enum/record/primitive harness in `scripts/verify.sh`.
- **`out` is a reserved keyword** — it cannot be used as an identifier.
- **The full server now compiles.** `scripts/build-full.sh` builds all 7
  packages — API + `Lyric.Web` + the in-repo `Lyric.Docker` — inside the
  lyric-lang workspace (verified on v0.2.4 from a pristine clone). It runs the
  same in CI. Test *execution* still needs the stdlib runtime DLLs noted above,
  so it compiles rather than runs the suites.
- **The Docker library lives in `vendor/lyric-docker`** (to be moved back to
  `lyric-lang` core). It was rewritten from invalid syntax (`pub val` fields, a
  `pub object`, the non-existent `|>` operator, wrong stdlib API) to proper
  Lyric, given an opaque `DockerClient` so no extern type crosses the package
  boundary, and extended with the container lifecycle the runner needs
  (`defaultClient`, `createContainer`, `start`/`stop`/`removeContainer`,
  `getContainerLogs`). `src/docker_manager.l` compiles against it.
- The `dto*` / `findTimeZone` helpers in `lyric-stdlib`'s `Std.Time` leak extern
  types (`DateTimeOffset`, `TimeZone`) across the contract boundary, breaking
  downstream contract synthesis (`unknown type name 'DateTimeOffset'`) for any
  package that restores `Lyric.Stdlib`. Fixed by
  `patches/lyric-stdlib-datetimeoffset-leak.patch` (applied by `build-full.sh`).
- **Transport caveat:** `Std.Http.sendAsync` does not take a client, so the
  unix-socket client returned by `makeDockerClient` is not yet used for
  transport — the `DockerClient` is threaded through for API stability. Requests
  will route correctly once the stdlib exposes a client-aware send.
- **Two compiler bugs** surfaced while fixing the above (compiler issues, not
  library bugs): `await`ing a cross-package user-defined `async` function crashes
  codegen (`emitPhaseBAwait`), and exposing an extern type in a public signature
  breaks contract synthesis. Both are worked around in the Docker library.
