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

**`lyric build` finally succeeds for this project as of v0.4.14 — five
upstream bugs found in sequence, four fixed, one still open blocking
`lyric run`/most of `lyric test`.** Not specific to this project. Bug 1
(`buildProject` crash,
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
fixed in [v0.4.15](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.15)
— `lyric run` now works against a minimal project, which is exactly what
exposed bug 5: running/testing *this* real, multi-package project hits
wrong cross-package field/method metadata references at runtime (enum
literals and methods that provably exist in the built assembly resolve as
missing) — filed as
[lyric-lang#5177](https://github.com/nichobbs/lyric-lang/issues/5177)
(open), still blocking `lyric run`/`scripts/run-api.sh` and most of `lyric
test`. Run `./scripts/repro-compiler-bug.sh` to check which bugs your
compiler still has before assuming a local failure needs a local fix. See
`docs/BUILD.md` "Compiler notes" for full detail.

**`lyric test` now runs (as of v0.4.15) but most of it still fails, for the
same reason as bug 5 above.** It no longer crashes as of v0.4.11 (that was
bug 1 above, which also hit this entry point), and as of v0.4.15 it no
longer fails every test outright on a missing `Lyric.Stdlib.dll` either
(the same underlying fix as bug 4) — but most suites now fail on bug 5's
"field not found"/"unsupported method" errors instead. Use
`./scripts/verify.sh` instead — it avoids `lyric test` entirely via a
hand-rolled harness that doesn't happen to trigger bug 5, and **it
genuinely passes**. See `docs/BUILD.md` "Running tests" for detail.

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
