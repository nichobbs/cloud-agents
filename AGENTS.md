# Agent Instructions

This is the canonical file — keep everything here, don't fork the content
into `CLAUDE.md` too. `CLAUDE.md` is a one-line pointer to this file (not a
symlink: symlinks aren't resolved by GitHub's raw-file/contents-API
endpoints or by checkouts without symlink support, so a symlinked
`CLAUDE.md` can silently serve the literal text "AGENTS.md" instead of real
content). This fixes the drift that happened before: `AGENTS.md` was a
separate copy of `CLAUDE.md` and silently fell out of sync when only one
got edited.

## What this repo is

A Lyric application. Lyric is a safety-oriented language targeting .NET 10 (primary) and JVM (Java 21). Syntax is Kotlin/C#/TypeScript-adjacent. It is not TypeScript or Kotlin — read the docs before writing code.

## Build and run

```sh
lyric restore        # fetch [nuget] dependencies (run before build/test)
lyric build          # compile (discovers lyric.toml from any subdir)
lyric run            # build + execute
lyric test           # run all @test_module files
lyric fmt --write    # format in place (opinionated, no config)
lyric lint           # style checks
lyric check          # type-check without emitting artifacts
lyric prove          # SMT verification on @proof_required packages
```

All commands discover `lyric.toml` by walking up from the working directory. No arguments needed from any subdir.

**`lyric run` finally works against this real project as of v0.4.17 — all
seven upstream bugs found in sequence are now fixed, as of v0.4.19.** Not
specific to this project. Bug 1 (`buildProject` crash,
[lyric-lang#4925](https://github.com/nichobbs/lyric-lang/issues/4925)) is
fixed in [v0.4.11](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.11);
bug 2 (`Std.Core`'s `Option`/`Result`/`Some`/`None`/`Ok`/`Err` never
resolving, [lyric-lang#4980](https://github.com/nichobbs/lyric-lang/issues/4980))
is fixed in [v0.4.12](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.12);
bug 3 (NuGet-restored zero-arg functions rejected,
[lyric-lang#5004](https://github.com/nichobbs/lyric-lang/issues/5004)) is
fixed in [v0.4.14](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.14)
— **and with those fixed, the full project (all 12 packages) builds
successfully, and `scripts/verify.sh` genuinely passes**, both for the
first time. Bug 4 (NuGet dependency DLLs not copied to the output
directory,
[lyric-lang#5066](https://github.com/nichobbs/lyric-lang/issues/5066)) is
fixed in [v0.4.15](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.15);
bug 5 (wrong cross-package field/method metadata tokens — an `async func`
awaiting an unqualified call into a *later*-declared package, this
project's `CloudAgents.Docker` → `Lyric.Docker`, corrupted token
bookkeeping for every package in between,
[lyric-lang#5177](https://github.com/nichobbs/lyric-lang/issues/5177)) is
fixed in [v0.4.17](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.17)
— **`scripts/run-api.sh`/`lyric run` now actually starts the API server**,
for the first time in this project's history. At that point it could not
yet survive or correctly answer a real HTTP request — two root-caused
`Lyric.Web` gaps. **Both are now fixed as of the `Lyric.Web` 0.4.26 pin**
(real request dispatch + header access), and `src/main.l` was migrated to
the resulting `Handler`/`Middleware` model, wiring in auth enforcement; see
`docs/BUILD.md` "Dependencies" for detail, including the caveat that this
is confirmed by compiling and `repro-web-bug.sh`'s diagnostic, not yet by
an automated end-to-end HTTP test (nichobbs/cloud-agents#354). Bug 6
(`slice[T].append(x)` — the compiler's own documented idiom for building up
a slice — threw `"unsupported method 'append'"` at runtime unconditionally,
builds fine, failed only when actually called,
[lyric-lang#5244](https://github.com/nichobbs/lyric-lang/issues/5244)) is
fixed in [v0.4.18](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.18).
Bug 7 (found while diagnosing the one test case bug 6's fix didn't clear —
a package-scope (top-level) `val` with no explicit type annotation,
initialized to a string literal, crashed `.length` at runtime with
`System.InvalidCastException: Unable to cast object of type 'System.String'
to type 'System.Collections.IList'` — same-package, unqualified, no
cross-package reference needed; root-caused to
`lyric-compiler/msil/codegen.l`'s package-level val/const pre-scan
defaulting an untyped declaration's MSIL type to `MObject` instead of
inferring it from the initializer; filed as
[lyric-lang#5298](https://github.com/nichobbs/lyric-lang/issues/5298); not
a regression, not specific to this project, and distinct from
[lyric-lang#5258](https://github.com/nichobbs/lyric-lang/issues/5258), a
related but different MSIL bug about *cross*-package qualified `pub val`
access) is **fixed in [v0.4.19](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.19)**.
Run `./scripts/repro-compiler-bug.sh` to check which bugs your compiler
still has before assuming a local failure needs a local fix. See
`docs/BUILD.md` "Compiler notes" for full detail.

**`lyric test` runs (as of v0.4.15) and fully passes as of v0.4.19 — every
suite in `lyric.toml`'s `[project.tests]` (the authoritative roster; counts
here would go stale as suites are added).** It no longer crashes as of
v0.4.11 (that was bug 1 above, which also hit this entry point), no longer
fails every test outright on a missing `Lyric.Stdlib.dll` as of v0.4.15
(the same underlying fix as bug 4), no longer fails on cross-package field
corruption as of v0.4.17 (bug 5), no longer fails on `slice[T].append()`
as of v0.4.18 (bug 6), and no longer fails on the top-level untyped
`val`'s `.length` as of v0.4.19 (bug 7 — the previously-failing `Test
Handler createSession validation` case read a top-level `val httpsPrefix =
"https://"` via `.length`, exactly bug 7's trigger).
`./scripts/verify.sh` also still genuinely passes. The live-database
suites additionally need the native SQLite library on the loader path —
see `docs/BUILD.md` "Running tests". More runtime gotchas found since
(broken `Instant.now()`, `unwrapResult`-family methods, qualified record
construction) are catalogued in `docs/lyric/gotchas.md` — read it before
writing runtime-executed code.

Source files use `.l` extension. Entry point is `func main(): Unit` in the appropriate package.

## Before writing any Lyric code

Read `docs/lyric/reference.md`. It covers syntax, type system semantics, and the things that look like TypeScript/Kotlin but aren't.

Read `docs/lyric/gotchas.md` before making assumptions.

## Key doc files

| File | When to read |
|------|-------------|
| `docs/lyric/reference.md` | Before writing any Lyric |
| `docs/lyric/stdlib.md` | Before using Std.* imports |
| `docs/lyric/idioms.md` | Canonical patterns — follow these |
| `docs/lyric/gotchas.md` | If something won't compile |
| `src/` | Working code to pattern-match from |

## Project layout

```
src/          # application source (.l files)
tests/        # @test_module files
docs/lyric/   # agent reference docs
lyric.toml    # project manifest
```
