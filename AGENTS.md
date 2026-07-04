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

**`lyric build` finally succeeds for this project as of v0.4.14 — four
upstream bugs found in sequence, three fixed, one still open blocking
`lyric run`.** Not specific to this project. Bug 1 (`buildProject` crash,
[lyric-lang#4925](https://github.com/nichobbs/lyric-lang/issues/4925)) is
fixed in [v0.4.11](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.11);
bug 2 (`Std.Core`'s `Option`/`Result`/`Some`/`None`/`Ok`/`Err` never
resolving, [lyric-lang#4980](https://github.com/nichobbs/lyric-lang/issues/4980))
is fixed in [v0.4.12](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.12);
bug 3 (NuGet-restored zero-arg functions rejected,
[lyric-lang#5004](https://github.com/nichobbs/lyric-lang/issues/5004)) is
fixed in [v0.4.14](https://github.com/nichobbs/lyric-lang/releases/tag/v0.4.14)
— **and with all three fixed, the full project (all 12 packages) builds
successfully, and `scripts/verify.sh` genuinely passes**, both for the
first time. Bug 4, still open: `lyric run` can't find NuGet-restored
dependency DLLs at runtime even though the build succeeded — filed as
[lyric-lang#5066](https://github.com/nichobbs/lyric-lang/issues/5066)
(open), blocking `lyric run`/`scripts/run-api.sh`. Run
`./scripts/repro-compiler-bug.sh` to check which bugs your compiler still
has before assuming a local failure needs a local fix. See `docs/BUILD.md`
"Compiler notes" for full detail.

**`lyric test` doesn't work either, for a separate reason.** It no longer
crashes as of v0.4.11 (that was bug 1 above, which also hit this entry
point), but every test now fails with `Could not load file or assembly
'Lyric.Stdlib, ...'` — the same class of missing-assembly problem as bug 4,
just for the compiler's own bundled stdlib instead of a NuGet dependency.
Use `./scripts/verify.sh` instead — it avoids `lyric test` entirely via a
hand-rolled harness, and **it genuinely passes**. See `docs/BUILD.md`
"Running tests" for detail.

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
