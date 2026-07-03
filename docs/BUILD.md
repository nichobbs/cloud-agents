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

All library dependencies are declared under `[nuget]` in `lyric.toml` and
resolved as ordinary prebuilt binary packages — no sibling checkout, no
source patching, no vendoring:

```toml
[nuget]
"Lyric.Web"             = "1.4.0"
"Lyric.Docker"          = "1.3.0"
"Std.Logging"           = "1.0.2"
"Microsoft.Data.Sqlite" = "8.0.0"
```

Build and test from the repo root — no other setup required:

```sh
lyric restore
lyric build
lyric test
```

`scripts/build-full.sh`, `scripts/verify.sh`, and `scripts/run-api.sh` are
thin wrappers around these three commands for CI and local development.

### Bumping a dependency version

Edit the version string in `[nuget]` and re-run `lyric restore`. Because
these are published binary packages (not source checkouts), there is nothing
else to keep in sync — no patches to reapply, no vendored copy to update.

## Compiler notes

The following are compiler-level characteristics of the current Lyric
toolchain, independent of how dependencies are packaged:

- **`String.indexOf` / `Option` were historically unreliable at runtime** in
  early standalone installs (not-found did not yield `None` in some
  contexts). The JSON extractors in `auth.l` and `session_manager.l` use a
  hand-rolled `indexOfFrom` substring scan instead of `String.indexOf` as a
  defensive measure; revisit if a later compiler release confirms the stdlib
  path is reliable.
- **`out` is a reserved keyword** — it cannot be used as an identifier.
- All packages (`CloudAgents`, `CloudAgents.SessionStore`, `CloudAgents.Handlers`,
  `CloudAgents.Interactions`, `CloudAgents.Docker`, `CloudAgents.Db`,
  `CloudAgents.Sqlite`, `CloudAgents.Repository`, `CloudAgents.Auth`,
  `CloudAgents.Streaming`) build and their `@test_module` suites run via
  `lyric test`.
