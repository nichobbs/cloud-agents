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

**`lyric run` finally works against this real project as of v0.4.17 — six
upstream bugs found in sequence, five fixed, one still open.** Not specific
to this project. Bug 1 (`buildProject` crash,
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
for the first time in this project's history. Bug 6, still open:
`slice[T].append(x)` — the compiler's own documented idiom for building up
a slice — throws `"unsupported method 'append'"` at runtime unconditionally
(builds fine, fails only when actually called), filed as
[lyric-lang#5244](https://github.com/nichobbs/lyric-lang/issues/5244). Not
a regression and not specific to this project — it's been broken since at
least v0.4.15, just never runtime-exercised here until bugs 1-5 stopped
masking it; it's what's causing the remaining `lyric test` failures below.
Run `./scripts/repro-compiler-bug.sh` to check which bugs your compiler
still has before assuming a local failure needs a local fix. See
`docs/BUILD.md` "Compiler notes" for full detail.

**`lyric test` runs (as of v0.4.15) and mostly passes now (as of v0.4.17),
but two suites still fail on bug 6 above.** It no longer crashes as of
v0.4.11 (that was bug 1 above, which also hit this entry point), no longer
fails every test outright on a missing `Lyric.Stdlib.dll` as of v0.4.15
(the same underlying fix as bug 4), and no longer fails on cross-package
field corruption as of v0.4.17 (bug 5) — `CloudAgents.DbTests` is fully
green. `CloudAgents.SessionTests` and one `CloudAgents.AuthTests` case
still fail on bug 6's `slice[T].append()` runtime error, since both call
it directly — except one `SessionTests` case (`Test Handler createSession
validation`), which fails a different, distinct, not-yet-diagnosed way
(`Unable to cast object of type 'System.String' to type
'System.Collections.IList'.`); not attributable to any of the six bugs
above, and not yet filed upstream. `./scripts/verify.sh` remains useful as
a `lyric test`-free harness (it doesn't happen to call `.append()` either),
and **it genuinely passes**. See `docs/BUILD.md` "Running tests" for
detail.

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
