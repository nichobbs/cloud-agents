# Upstream patches for `lyric-lang`

These patches fix the `lyric-lang` workspace libraries this project depends on.
They are kept here because the fixes live in the separate `nichobbs/lyric-lang`
repository; apply them there (as a sibling clone — see `docs/BUILD.md`).

Apply from the root of a `lyric-lang` checkout:

```sh
cd ../lyric-lang
git apply ../cloud-agents/patches/lyric-stdlib-datetimeoffset-leak.patch
git apply ../cloud-agents/patches/lyric-docker-proper-syntax.patch
```

Then rebuild the dependency chain (see `docs/BUILD.md`).

## `lyric-docker-proper-syntax.patch`

Rewrites `lyric-docker` (packages `Lyric.Docker`, `Lyric.Docker.Api`,
`Lyric.Docker.Sockets`) from invalid syntax to proper Lyric so it builds and its
contract synthesises for downstream consumers. Verified with `lyric build` on
compiler v0.2.4.

- **Invalid syntax removed:** `pub val` record fields → `pub` fields; a
  `pub object { pub val … }` namespace → plain `pub func` accessors; the `|>`
  pipe operator (12 sites, not a Lyric operator) → `match`/`unwrapResult`.
- **Wrong stdlib API → correct calls:** `Std.Environment.getOpt` → `getVar`
  (`Result`); error cases (`ConnectionFailed`/`BadStatus`/`InvalidUrl`/
  `HttpError`) imported from `Std.Errors`, not `Std.Http`; `ioErr.message` →
  `IOError.message(ioErr)`; `!x` → `not x`; removed an unsupported default
  parameter value.
- **Boundary design:** the public API exposed the extern
  `System.Net.Http.HttpClient`, which breaks downstream contract synthesis.
  Wrapped it in an opaque `DockerClient` handle so no extern type crosses the
  package boundary.

Two compiler bugs were worked around (these are compiler issues, not lib syntax;
worth reporting upstream):

1. `await`ing a cross-package user-defined `async` function crashes codegen
   (`emitPhaseBAwait`). Worked around by inlining `systemInfo`'s HTTP call so
   every `await` targets a stdlib async function.
2. Exposing an extern type in a public signature breaks contract synthesis
   (same class as the `DateTimeOffset` leak below).

## `lyric-stdlib-datetimeoffset-leak.patch`

`Std.Time` exposes the extern types `DateTimeOffset` and `TimeZone` across its
public contract via the `dto*` / `findTimeZone` helpers, which breaks contract
synthesis for any package that restores `Lyric.Stdlib`
(`unknown type name 'DateTimeOffset'`). The patch demotes those four helpers to
package-private; the public epoch API (`fromEpochMillis` / `fromEpochSeconds`,
returning `Instant`) is unchanged. Required for `lyric-docker` (which depends on
`Lyric.Stdlib`) to build.
