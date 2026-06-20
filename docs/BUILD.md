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

## Verified vs. pending (compiler v0.1.x)

The currently published Lyric compiler is early-stage; the following are known
and were validated while building this phase:

- **Pure-logic packages compile and run.** `CloudAgents.Streaming`,
  `CloudAgents.Db`, and `CloudAgents.Auth` build cleanly with the toolchain
  above, and the SSE framing in `CloudAgents.Streaming` is runtime-verified
  (frame format, JSON escaping, CRLF/trailing-line handling, empty input).
- **`String.split` is not available** in v0.1.x — split manually with a
  character scan (`formatLogsAsSse` does this).
- **`out` is a reserved keyword** — it cannot be used as an identifier.
- **`lyric-docker` does not build with v0.1.x.** Its source uses pipe syntax
  (`|>`) that the published compiler rejects (P0080). Until that library (or the
  compiler) is updated, the full web+docker server cannot be compiled end-to-end
  in this environment; the Docker-independent packages above are verified in
  isolation. Track this when bumping the `lyric-lang` pin.
- The `dto*` / `findTimeZone` helpers in `lyric-stdlib`'s `Std.Time` leak extern
  types (`DateTimeOffset`, `TimeZone`) across the contract boundary, which breaks
  downstream contract synthesis; demote them to package-private locally if you
  hit `unknown type name 'DateTimeOffset'`.
