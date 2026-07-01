# Upstream patches for `lyric-lang`

These patch the `lyric-lang` workspace this project depends on, for fixes that
live in the separate `nichobbs/lyric-lang` repo. Apply against a sibling clone
(see `docs/BUILD.md`); `scripts/build-full.sh` applies them automatically.

## The Docker library now lives in `vendor/lyric-docker`

The `lyric-docker` rewrite (proper syntax) **and** the new container operations
have been copied into this repo at `vendor/lyric-docker` so they can be
developed here, to be moved back into `lyric-lang` core later. That directory —
not a patch — is the source of truth for the Docker library.
`scripts/build-full.sh` drops it into the workspace's `lyric-docker` before
building. What the rewrite fixed:

- **Invalid syntax removed:** `pub val` record fields → `pub` fields; a
  `pub object { pub val … }` namespace → plain `pub func` accessors; the `|>`
  pipe operator (not a Lyric operator) → `match`/`unwrapResult`.
- **Wrong stdlib API → correct calls:** `Std.Environment.getOpt` → `getVar`;
  error cases from `Std.Errors`, not `Std.Http`; `ioErr.message` →
  `IOError.message(ioErr)`; `!x` → `not x`; removed an unsupported default param.
- **Boundary design:** the public API exposed the extern
  `System.Net.Http.HttpClient`. Wrapped it in an opaque `DockerClient` handle so
  no extern type crosses the package boundary.
- **New:** `defaultClient`, `createContainer`, `start`/`stop`/`removeContainer`,
  `getContainerLogs` — the container lifecycle `src/docker_manager.l` needs.

Two compiler bugs were worked around (compiler issues, not lib syntax; worth
reporting upstream): `await`ing a cross-package user-defined `async` function
crashes codegen (`emitPhaseBAwait`), and exposing an extern type in a public
signature breaks contract synthesis.

## `lyric-stdlib-datetimeoffset-leak.patch`

`Std.Time` exposes the extern types `DateTimeOffset` and `TimeZone` across its
public contract via the `dto*` / `findTimeZone` helpers, which breaks contract
synthesis for any package that restores `Lyric.Stdlib`
(`unknown type name 'DateTimeOffset'`). The patch demotes those four helpers to
package-private; the public epoch API (`fromEpochMillis` / `fromEpochSeconds`,
returning `Instant`) is unchanged. Required for `lyric-docker` (which depends on
`Lyric.Stdlib`) to build.

## `lyric-auth-contract-leak.patch`

`Auth.Aspects` exposes an `@inline_template pub aspect ValidateKey` that
triggers the same compiler contract-synthesis bug: the `@inline_template`
attribute causes the contract synthesizer to embed the raw template body in the
contract JSON, but the template body contains unescaped characters that produce
malformed JSON. The patch removes both `@inline_template` and the `pub`
visibility from `ValidateKey`. Additionally, `build-full.sh` uses a sed step to
demote `pub func tryExtractClaim` (which has an `out String` parameter — a
second edge case the synthesizer cannot serialise) to package-private. Both
fixes together produce a valid `Lyric.Contract.Auth` resource. `lyric-web`
imports the `Auth` package directly (not `Auth.Aspects`), so no dependent is
broken.
