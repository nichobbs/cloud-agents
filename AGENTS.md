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

**No released Lyric compiler can do a full `lyric build` of this project yet
— three independent upstream bugs found in sequence, two fixed, one open.**
Not specific to this project. Bug 1 (`buildProject` crash,
[lyric-lang#4925](https://github.com/nichobbs/lyric-lang/issues/4925)) is
fixed in [v0.4.11](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.11);
bug 2 (`Std.Core`'s `Option`/`Result`/`Some`/`None`/`Ok`/`Err` never
resolving, [lyric-lang#4980](https://github.com/nichobbs/lyric-lang/issues/4980))
is fixed in [v0.4.12](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.12)
— **and with both fixed, `scripts/verify.sh` now genuinely passes for the
first time**, confirming the Phase 1–3 logic for real. Bug 3, still open:
a zero-arg function restored from a NuGet package (`Web.create()`) is
rejected as `"expected 1 argument(s), got 0"` even though it takes zero
parameters, blocking the full project build (`main.l` calls it directly).
Filed as [lyric-lang#5004](https://github.com/nichobbs/lyric-lang/issues/5004)
(open). Run `./scripts/repro-compiler-bug.sh` to check which bugs your
compiler still has before assuming a local build failure needs a local
fix. See `docs/BUILD.md` "Compiler notes" for full detail.

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
