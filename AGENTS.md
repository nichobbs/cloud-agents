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

**No released Lyric compiler can build, run, check, or test this project (or
any Lyric project using `Option`/`Result`) — two independent upstream bugs,
one fixed, one open.** Not specific to this project. The v0.4.10 crash in
`buildProject` ([lyric-lang#4925](https://github.com/nichobbs/lyric-lang/issues/4925),
fixed by merged [lyric-lang#4955](https://github.com/nichobbs/lyric-lang/pull/4955))
is confirmed fixed in the
[v0.4.11 release](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.11)
— but upgrading immediately exposes a second, apparently pre-existing bug:
`Std.Core`'s `Option`/`Result`/`Some`/`None`/`Ok`/`Err` never resolve at any
use site, on every compiler version and project configuration tried. Filed
as [lyric-lang#4980](https://github.com/nichobbs/lyric-lang/issues/4980)
(open). Run `./scripts/repro-compiler-bug.sh` (needs only `lyric` on PATH)
to check whether your compiler still has either bug before assuming a
local build failure needs a local fix. See `docs/BUILD.md` "Compiler
notes" for full detail.

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
