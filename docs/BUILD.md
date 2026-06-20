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
- **`lyric-docker` does not build with v0.1.x or v0.2.4.** Its source uses a
  `val` field name (P0051) and pipe syntax `|>` (P0080) that the published
  compiler rejects — the library is ahead of releases. Until it (or the compiler)
  is updated, the full web+docker server cannot be compiled end-to-end here; the
  Docker-independent packages above are verified in isolation. `lyric-web` itself
  builds fine. Track this when bumping the `lyric-lang` pin.
- The `dto*` / `findTimeZone` helpers in `lyric-stdlib`'s `Std.Time` leak extern
  types (`DateTimeOffset`, `TimeZone`) across the contract boundary, which still
  breaks downstream contract synthesis under v0.2.4; demote them to
  package-private locally if you hit `unknown type name 'DateTimeOffset'`.
