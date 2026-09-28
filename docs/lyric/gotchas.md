# Lyric Gotchas

Things that look like TypeScript/Kotlin/Java but aren't. Read before debugging compile errors.

**Re-verified 2026-09-28 against lyric 0.7.3** (installed fresh + empirically
re-tested every entry below with a real `lyric build`/`lyric run`, not just a
changelog read). This project currently pins Lyric ~0.4.34–0.4.36
(`MIN_LYRIC_VERSION`, `deploy/api.Dockerfile`) — **~30 releases behind
current** — and a large number of the "compiles but crashes at runtime"
entries that were true at that pin are now fixed upstream. Several stdlib
method names have also changed shape entirely (renamed, not just fixed).
Entries below are updated to reflect 0.7.3's actual behavior; anything
still marked as broken was independently reproduced today, not carried
forward from an old confirmation. If/when the project's pin is bumped,
re-run this doc's claims again — this file rots fast in either direction.

---

## Types

**`type` is distinct, not an alias.**
```lyric
type UserId = Long   // NOT interchangeable with Long or any other type wrapping Long
alias Millis = Long  // IS interchangeable with Long
```
`type X = Long` does not let you pass a `Long` where `X` is expected.

---

**No implicit numeric widening.**
```lyric
val i: Int = 42
val l: Long = i          // compile error
val l: Long = i.toLong() // correct
```

---

**Range subtypes cannot mix with their base type in arithmetic.**
```lyric
type Age = Int range 0 ..= 150
val a: Age = Age.from(25)
val b = a + 1     // compile error: Age + Int not defined
val b = a.toInt() + 1  // correct
```

---

**`derives` must be explicit — you get nothing by default.**
```lyric
type Tag = String
val t1 = Tag.from("foo")
val t2 = Tag.from("foo")
t1 == t2   // compile error: Equals not derived
```
Add `derives Equals, Hash` if you need equality.

---

**`Default` on a range type is a compile error if 0 is out of range.**
```lyric
type DiceRoll = Int range 1 ..= 6 derives Default  // compile error: 0 not in range
```

---

## Records

**Positional construction is a compile error.**
```lyric
Point(1.0, 2.0)              // compile error
Point(x = 1.0, y = 2.0)     // correct
```

---

**Records are immutable — no field assignment.**
```lyric
val p = Point(x = 1.0, y = 2.0)
p.x = 3.0   // compile error
val p2 = p.copy(x = 3.0)  // correct
```

---

**A `pub` record with private fields cannot be directly constructed outside the package.**
Provide a constructor function. Callers outside use the function; callers inside use record syntax.

---

**FIXED as of lyric 0.7.3** ([lyric-lang#6322](https://github.com/nichobbs/lyric-lang/issues/6322), closed). `slice[SomeRecord].append(...)` inside a loop long enough to trigger OSR promotion used to miscompile under the optimizing JIT (`OverflowException`, `IndexOutOfRangeException`, or a fatal `AccessViolationException` in `StelemRef`, nondeterministically) on releases up through ~v0.4.35–0.4.36. Re-tested directly against 0.7.3 with the issue's own 50,000-iteration repro (`slice[PlanItem]` built via `.append()` in a `while` loop) — completes cleanly, no crash. If your pinned compiler is still in the 0.4.x range, the workaround below still applies; on a current toolchain it's unnecessary.

```lyric
// Only needed on lyric <= ~0.4.36. Accumulate parallel slice[String]s in the
// hot loop, then zip them into records in a separate, never-hot function
// (see planItemsOf in src/handlers/interactions.l for the historical pattern).
notesAcc = notesAcc.append(x)
statusAcc = statusAcc.append(y)
```

---

## Pattern matching

**Non-exhaustive match is a compile error (E0301), not a warning.**
You cannot ignore union cases. Either handle them or use `case _ ->`.

---

**Guarded arms do not count toward exhaustiveness.**
```lyric
match shape {
  case Circle(r) where r > 0.0 -> ...  // does NOT cover Circle(r <= 0)
  case Rectangle(w, h) -> ...
}
// compile error: Circle not fully covered
```
Add an unguarded `case Circle(r) ->` to close the gap.

---

**No `if let`.** Use full `match`:
```lyric
// wrong (doesn't exist)
if let Some(user) = maybeUser { ... }

// correct
match maybeUser {
  case Some(user) -> ...
  case None -> ...
}
```

---

**FIXED as of lyric 0.7.3** ([lyric-lang#6231](https://github.com/nichobbs/lyric-lang/issues/6231), closed via lyric-lang#6388). Storing a `Result[T,E]` in a record field used to panic `"match not exhaustive"` on read-back even though both cases were handled. Re-tested directly: a record with a `pub r: Result[Int, String]` field, constructed with `Ok(99)` and matched back via `match w.r { case Ok(v) -> ...; case Err(e) -> ... }`, now matches correctly. The `shim/tests/fakes.l` workaround (reconstructing `Ok`/`Err` fresh in an accessor) is no longer necessary on a current toolchain.

---

## Operators

**`&` is NOT bitwise-and — it's a unary reference/borrow prefix operator, and `x & y` silently compiles to something other than what it looks like.** Confirmed on lyric 0.7.3: `&` is a *prefix-only* operator in the grammar (`docs/grammar.ebnf`'s `PrefixExpr`, alongside `-`/`not`), never a binary one. `val z = x & y` does **not** raise a parse or type error — it parses as two adjacent expressions, `x` (which `z` actually binds to) and a separate, discarded `&y` reference expression. The RHS is still evaluated for its side effects (confirmed: `x & sideEffect()` really calls `sideEffect()`) but its value is silently thrown away and `z` ends up equal to `x`, unchanged. This is a landmine specifically because it doesn't error the way the older toolchain's flat "no bitwise operators, `&` is a compile error" behavior did — it silently produces a wrong value instead. `|`, `^`, `<<`, `>>` are still not supported at all (`^` isn't even a valid token; `|`/`<<`/`>>` are parse errors) — this miscompile is unique to `&`. Use `.and()`/`.or()`/`.xor()`/`.shl()`/`.shr()` for real bitwise ops, always:
```lyric
x.and(0xFF)  // correct, confirmed: 6.and(3) == 2
x & 0xFF     // WRONG: compiles, discards the RHS, evaluates to x unchanged
```

**Chained comparisons are a parse error.**
```lyric
a < b < c        // compile error
a < b and b < c  // correct
```

**No ternary `?:`.**
```lyric
val x = condition ? a : b   // compile error
val x = if condition then a else b  // correct
```

---

## Functions and parameters

**REVERSED as of lyric 0.7.3: bare-call now works and is correct; dot-call is what's broken.** The old guidance ("`Std.Core`'s `unwrapResult`/`unwrapResultOr`/`unwrapErrOr`/`unwrapResultStr` only resolve via dot-call, bare-call is `unknown name`") is now backwards. Re-tested directly on 0.7.3:
```lyric
import Std.Core

val r: Result[Int, String] = Ok(42)
unwrapResult(r)      // OK   — bare call now compiles AND runs, returns 42
r.unwrapResult()     // FAIL — dot-call compiles, then dies at runtime:
                      //   "unsupported method 'unwrapResult' on the receiver type"
```
Confirmed the same reversal for `isOk`/`isSome`/`isNone` (formerly documented as
either "fine" or "broken regardless of call form" — neither is accurate now):
`isOk(r)`/`isSome(o)`/`isNone(o)` as **bare calls** all work correctly; `r.isOk()`/
`o.isSome()`/`o.isNone()` as **dot-calls** all fail at runtime with the same
"unsupported method" error, even though they compile fine. **Prefer the bare
`Std.Core` free-function form for all of these now** (`unwrapResult(r)`,
`unwrapResultOr(r, default)`, `unwrapErrOr(r, default)`, `isOk(r)`, `isErr(r)`,
`isSome(o)`, `isNone(o)`) — a plain `match` on `Ok`/`Err`/`Some`/`None` is still
always safe too, just more verbose. The `?` operator remains confirmed working.

**Ambiguous names across whole-module imports are now a proper compile-time
error (T0123), not a silent import-order resolution.** Re-tested directly on
0.7.3: two imported packages exporting the same unqualified function name
(`updateThing`, one signature per package) now fails to build with
`error[T0123]: 'updateThing' is ambiguous: it is declared by 'Pkg.A', 'Pkg.B',
all imported here — qualify the reference`, rather than silently binding to
whichever package the import order happened to favor. Still worth fully
qualifying any name exported by more than one imported package, but a
collision is now caught at build time instead of silently miscompiling.

**FIXED as of lyric 0.7.3.** Package-qualified record construction
(`Pkg.SomeRecord(field = ...)`) used to compile but die at runtime with
`unsupported method 'SomeRecord' on the receiver type` on releases through
~v0.4.19–0.4.36. Re-tested directly: both `Pkg.A.Widget(id = 5)` (qualified)
and `Widget(id = 9)` (unqualified, after `import Pkg.A`) now construct
correctly. Qualified `pub val` reads and qualified function calls across a
package boundary were also re-tested and work fine.

**FIXED as of lyric 0.7.3.** Constructing a `Lyric.Web` `Request` record used
to crash with a bare `InvalidProgramException` even when every field held a
value of its documented type (tracked historically as
[nichobbs/cloud-agents#354](https://github.com/nichobbs/cloud-agents/issues/354),
confirmed against Lyric.Web 0.4.26/0.4.36). Re-tested directly against
**Lyric.Web 0.7.0** (the latest published version — check
`https://api.nuget.org/v3-flatcontainer/lyric.web/index.json` for newer):
constructing a `Request` with every field populated (`newMap()` for the map
fields — see the `Map.empty(...)` note below, that constructor name has also
changed) now succeeds and the constructed value's fields read back correctly.
`./scripts/repro-web-request-crash.sh` still pins the old `Lyric.Web` version
(0.4.36) from this project's `lyric.toml` and needs that pin bumped before it
will observe the fix — it currently fails for an unrelated reason instead
(the old Lyric.Web version's compiled contract references a `Map.empty`
static member that no longer resolves under the current compiler's stricter
auto-FFI, itself a symptom of the same `Map.empty` → `newMap()` rename noted
below).

**`slice[Byte].toList()` still does not resolve at runtime** — re-confirmed
directly on lyric 0.7.3: `unsupported method 'toList' on the receiver type
(no matching user method, extern binding, or built-in intrinsic)`. Despite
`lyric-stdlib/std/file.l`'s own module doc describing `slice[T].toList()` /
`List[T].toArray()` as the intended round-trip shuttle, only the
`List[T].toArray()` direction is confirmed working (re-tested, works fine).
Build the `List[Byte]` by hand instead: `val acc: List[Byte] = newList(); var
i = 0; while i < b.length { acc.add(b[i]); i = i + 1 }` — plain-`Int` slice
indexing is confirmed working. See `CloudAgents.Callbacks.sliceBytesToList`
for the worked pattern.

**REVERTED back to `slice[Byte]` as of a later release — no longer `List[Byte]`.**
The previously-documented "`Std.File.readBytes` returns `Result[List[Byte],
IOError]` as of Lyric v0.5.0, not `slice[Byte]`" entry described a real,
confirmed state at v0.5.0, but it did not last: current `lyric-stdlib/std/file.l`
(as shipped in lyric 0.7.3) has `readBytes(path): Result[slice[Byte], IOError]`
and `writeBytes(path, bytes: in slice[Byte]): Result[Unit, IOError]` again —
matching what `docs/lyric/stdlib.md`/`docs/lyric/reference.md` always
documented. Re-tested directly: round-tripping bytes through `writeBytes`/
`readBytes` with a `slice[Byte]` value works with no type error. **If your
code has a `.toArray()`/`sliceBytesToList()` shim added to work around the
v0.5.0-era `List[Byte]` signature (e.g. `src/handlers/sessions.l`'s
`sliceBytesToList(v.bytes)` call into `writeBytes`), it will now fail to
compile against a current toolchain** with `argument type List[Byte] does not
match parameter type slice[Byte]` — the shim needs removing, not adding to,
once the pin is bumped past whatever release reverted this.

**RENAMED, not broken, as of lyric 0.7.3.** `Std.File` has no `exists()`/
`delete()` methods under those names at all anymore (and never resolved as
dot-calls in the versions that had them) — the current free functions are
`Std.File.fileExists(path: in String): Bool` and `Std.File.deleteFile(path: in
String): Result[Unit, IOError]`. Re-tested directly: both work correctly as
bare calls (`Std.File.fileExists("/tmp")`, `Std.File.deleteFile(path)`) — no
runtime "unsupported method" failure, no need for a `System.IO.File.Delete`
extern workaround.

**RENAMED, not broken, as of lyric 0.7.3.** `String.toUpperCase()`/
`.toLowerCase()` don't exist under those names anymore — using them is now a
**compile-time** error (`error[T0120]: no method 'toUpperCase' on type
'String' at this call site`), not the old "compiles, crashes at runtime"
failure. The current dot-call methods are `.toUpper()`/`.toLower()`
(`lyric-stdlib/std/string.l`'s `toUpper`/`toLower`, case-folding without
locale tailoring per lyric-lang#7261/#5557 — safe under a Turkish locale
too). Re-tested directly: `"clientId".toUpper()` → `"CLIENTID"`, and
`.replace(from, to)` also works fine as a dot-call (`"hello
world".replace("world", "there")` → `"hello there"`) — no runtime failure
for either.

**`Int.toNat()` still does not resolve at runtime** — re-confirmed directly
on lyric 0.7.3: `unsupported method 'toNat' on the receiver type`. The
reverse, `Nat.toInt()`, still works fine. And you still can't dodge it with
`val n: Nat = 7` either: integer literals are typed `Int` with no implicit
Nat coercion, confirmed still a compile error (`error[T0060]: val binding
declared as Nat but initialiser has type Int`) — there is still no way to
produce a `Nat` value from a literal at all on this toolchain. Practical
consequence unchanged: prefer working over `String`/base64 (whose
`.length.toInt()` + `.substring` are known-good) when you need an
index-driven loop.

**`String.length` compared directly against an explicitly-`Nat`-typed value
is still a T0033 compile error** ("comparison operands must be matching
ordered types (got Int and Nat)") despite `String.length` being documented
`Nat` — re-confirmed directly on lyric 0.7.3 with the exact `s.length > max`
(`max: Nat` parameter) shape. Whichever side `.length` unifies to still
depends on the other operand.

**A `Nat`-typed function argument crossing a package boundary crashing the
caller with a bare `InvalidProgramException`: not independently
re-verified this pass — treat with caution rather than as confirmed-fixed
or confirmed-still-broken.** The neighboring bugs this entry's "same
`InvalidProgramException` family" reasoning leaned on
(`docs/lyric/gotchas.md`'s old package-qualified-record-construction and
`Web.Request`-construction entries, plus lyric-lang#6133/#6134/#6232) are
now all independently confirmed fixed as of 0.7.3 (see above and the
Imports section below), which makes it plausible this one is stale too —
but there is currently no way to even construct a bare `Nat` value to pass
across a package boundary without hitting an unrelated compile error first
(`Int.toNat()` doesn't resolve; a `Nat`-typed parameter fed a
`String.length` read hits the T0033 gotcha above), so the exact original
repro shape couldn't be re-run. Re-verify with a real `Nat`-returning
call (e.g. an actual `slice[T].length` read into a `Nat`-typed cross-package
parameter, sidestepping both blockers) if you hit anything like it again.
`Int` remains the safer choice for cross-package parameters/returns in the
meantime.

**FIXED as of lyric 0.7.3.** `Std.Time.now()` (the doc's original entry
named it `Std.Time.Instant.now()`, but the actual API has always been the
free function `Std.Time.now(): Instant`) used to fail at runtime with
`Method not found: 'Void System.DateTime.now()'`. Re-tested directly:
`Std.Time.now()` and `Std.Time.nowEpochMillis()` both work correctly now —
the `System.DateTimeOffset.get_UtcNow` extern workaround in
`CloudAgents.Repository.nowMillis` is no longer necessary on a current
toolchain (though harmless to leave in place).

**`out` parameters must be assigned on ALL control flow paths before return.**
The compiler will reject a function that might return without assigning an `out` param.

**Async functions: no `out`/`inout` across `await` points.**
Return a tuple or record from async functions instead.

**`?` only works in functions returning `Result` or `Option`.**
Using `?` in a function returning a plain value is a compile error.

---

## Imports

**No wildcard imports.**
```lyric
import Money.*             // compile error
import Money.{Amount, Cents}  // correct
```

**`//!` for module docs, `///` for item docs.**
```lyric
/// This before `package` is a compile error (P0020)
package Foo

//! This is correct module-level doc — goes before `package`
package Foo
```

---

**FIXED as of lyric 0.7.3** ([lyric-lang#6232](https://github.com/nichobbs/lyric-lang/issues/6232), [#6134](https://github.com/nichobbs/lyric-lang/issues/6134), [#6133](https://github.com/nichobbs/lyric-lang/issues/6133), all closed). A cross-package `pub val` used to construct several record types in one function used to crash the whole function at JIT with a bare `System.InvalidProgramException`, with no compile error; a qualified constant read inside an `impl` method body crashed the same way (#6134); and a read through a *restored-DLL* dependency could silently produce `0`/null instead (#6133). Re-tested #6232's exact shape directly on 0.7.3: a `pub val` in one package, read to construct three different record types in a single function in another package, now compiles and runs correctly with no crash. #6134/#6133 weren't independently re-run (they need an `impl` block / a separate restored-DLL dependency to set up) but were closed via merged fixes in the same PR batch as #6133 (lyric-lang#6345) around the same time as #6232 — treat as fixed, but re-verify if you hit either shape again. The old workaround (have the consuming package own such constants as its own literals) is no longer necessary on a current toolchain.

---

**FIXED as of lyric 0.7.3 — now a real compile-time error instead of a silent JIT-time crash.** Two related "the type checker silently accepts something structurally wrong, then the JIT can't survive it" failure modes used to exist, both re-tested directly and both now caught at compile time:

- A type-invalid record-field **assignment** (e.g. assigning a `Result[slice[T], E]` straight into a `slice[T]`-typed field, instead of `match`-unwrapping it first) used to compile clean (`lyric build`/`lyric check` both silent) and then corrupt JIT codegen bundle-wide with a bare `InvalidProgramException` — confirmed historically on v0.4.36 (PR #739), where it took out ~24 unrelated tests across multiple packages compiled into the same `output = "single"` bundle. Re-tested the exact shape (a function returning `Result[slice[Item], String]` assigned directly into a `Response` record's `slice[Item]` field): now a normal, immediate `error[T0104]: argument for field 'items' has type Result[slice[Item], String] but field expects slice[Item]` at build time. No bundle-wide corruption possible anymore since it never reaches the JIT.

- The same failure mode for field **access** on the wrong (but similarly-shaped) record type — e.g. reading `.nextRunAt` on a `JobSummary` that only has `.nextRunAtEpochMillis` (that field name exists on a different, similarly-shaped `ScheduledJob` record) — used to silently type-check and only crash at test runtime with the same `InvalidProgramException` signature. Re-tested the exact shape: now `error[T0113]: no member 'nextRunAt' on type 'JobSummary'` at build time.

Both were real, narrow type-checker gaps specific to the v0.4.x-era compiler — not general JIT fragility — and both are closed off now. Still worth double-checking field names/types on any diff that touches two similarly-shaped records if you're on an older pinned compiler, but this class of bug can no longer reach a JIT crash on 0.7.3: the type checker rejects it up front.

---

## Enums

**No integer-to-enum cast.**
```lyric
val c: Color = 1   // compile error
// Use Color.fromNat(1) which returns Option[Color] (not yet fully shipped in v1.0)
// Until then, use an explicit match
```

---

## `Nat`

**Reach for `Nat` instead of `Int` for non-negative quantities.**
Lengths, counts, indices, loop counters — all should be `Nat`. It's in every stdlib API.

---

## Contracts

**Contract violations are `Bug`, not errors — do not catch them.**
`PreconditionViolated`, `PostconditionViolated`, `InvariantViolated` are programming mistakes. Do not put them in `Result`, do not catch them. Fix the bug.

**`requires:` on `pub` functions is always checked, even in release builds.**
Internal (`non-pub`) `requires:` is elided in release. `ensures:` is elided in release by default.

**`assert` ≠ `requires:`.** `assert` is an internal sanity check, not part of the API contract, not visible in docs, not reasoned about by the prover the same way. Wrong choice produces confusing diagnostics.

**`forall`/`exists` in `ensures:` iterate at runtime** — they are not free. A `forall` over a million-element slice in an `ensures:` clause runs on every return.

**`requires:` and `ensures:` clauses follow the parameter list, before the body.**
```lyric
pub func sqrt(x: in Double): Double
  requires: x >= 0.0
  ensures: result >= 0.0
{
  ...
}
```
`result` in `ensures:` refers to the return value.

---

## Misc

**`val` = immutable, `var` = mutable, `let` = lazy.**
`let` uses .NET `Lazy<T>` — thread-safe, evaluated once on first use.

**File names don't matter to the compiler.** Only the `package` declaration matters.

**`Unit` is not `void`.** It's a real type with one value `()`. Can be stored, returned explicitly, used as a generic type argument.

**Adding a case to a `pub` union is a breaking change.** Every downstream `match` breaks. Use an interface instead if you expect extension.

**A literal `${...}` inside a plain double-quoted string is interpolation, not text.** `"Authorization=Bearer ${GITHUB_TOKEN}"` tries to resolve `GITHUB_TOKEN` as a name in scope and fails to compile (`T0115: cannot resolve name ... to a value here`) if nothing by that name exists — it does NOT produce the literal four characters `$`, `{`, `...`, `}`. This bites test fixtures for a value that is itself a `${VAR}`-style placeholder meant for something else to expand later (e.g. an MCP server env/header entry docker/inject-library.sh's `envsubst` pass expands at container-injection time, not at Lyric compile time) — use a raw string instead: `r"Authorization=Bearer ${GITHUB_TOKEN}"`. Not an issue for the same text sitting in a data file (JSON, `seed/mcp-servers/*.json`) or in a `//`/`///`/`//!` comment — only inside a live, compiled string literal.

---

## Async

**`await` is an expression, not a statement.** You can use it inline.

**Calling async does not auto-await.** `fetchUser(id)` returns a task. `await fetchUser(id)` awaits it.

**No fire-and-forget.** Tasks spawned in a `scope` block cannot outlive the scope.

**Cancellation token is implicit.** Do not declare it, do not pass it. Use `cancellation.checkOrThrow()` for cooperative cancellation points. It propagates automatically to all callees.

**Async functions cannot have `out`/`inout` params crossing `await` points.** Return a tuple or record instead.

**FIXED as of lyric 0.7.3** ([lyric-lang#6249](https://github.com/nichobbs/lyric-lang/issues/6249), closed via lyric-lang#6514). A `val` bound before one `await` used to silently lose its value after a SECOND, different-callee `await` in the same async function — reading back as the type's default (`""` for `String`) with no exception, no diagnostic. Re-tested the issue's own exact repro directly on 0.7.3 (a `val id = "hello"` bound before `await stepA()`, then `await stepB()`, then `cell.output = id`): now correctly produces `actual=[hello]`, matching what was always expected. **This was also the leading suspect behind `src/docker_manager.l`'s recurring `streamSessionMessage` `AccessViolationException` production crash** — see the "`Long` (Int64) subtract-and-compare" entry below: that crash was root-caused to a *second*, distinct bug and still reproduces today, so #6249's fix alone does not mean `docker_manager.l`'s workarounds (the `cell`-style mutable-field-carrier pattern in `runSessionMessageAsync`, the parameter-carrying-recursion pattern in `waitForContainer`/`waitForContainerAttempt`) can be safely reverted — they're cheap, still correct, and worth keeping regardless of which compiler version ends up building this project.

**`Std.Task.delay(ms): Task` exists and works, but is undocumented in `docs/lyric/stdlib.md`.** `await Std.Task.delay(ms)` really suspends for approximately `ms` milliseconds without blocking the underlying worker thread the way `Thread.Sleep` does. One wrinkle re-confirmed directly on lyric 0.7.3: `async func f(): Unit { await Std.Task.delay(ms) }` as the ONLY statement in the body still fails to compile with `error[T0070]: function body trailing expression has type Task but declared return type is Unit` — still add an explicit `return ()` after the await; this is not an issue when the `await Std.Task.delay(...)` line is followed by more statements, only when it is the sole/trailing statement. (The second wrinkle this entry used to describe — putting `await Std.Task.delay(...)` as the second, different-callee await in a retry loop hitting the lyric-lang#6249 shape — no longer applies; see the entry above, now fixed.)

**A `Long` (Int64) subtract-and-compare inside a large/complex function can crash the process with an `AccessViolationException` — STILL REPRODUCES as of lyric 0.7.3, re-confirmed today.** `Unbox`'s `toTypeHnd` resolves to `System.Int64`; its `obj` is not a valid object reference ("this object has an invalid CLASS field"). This is a second, distinct bug from the #6249 fix above — `nowMs - startMs > timeoutMs` (three `Long`s) done once per poll tick still crashes every time, whether inline or via the pure, cross-package `CloudAgents.DockerPolicy.hasExceededRunTimeout` call `streamSessionMessage` originally used. Re-ran `./scripts/repro-crosspkg-long-crash.sh` directly against a freshly-installed lyric 0.7.3 today (2026-09-28): it still reproduces the exact same crash signature (`System.AccessViolationException` in `System.Runtime.CompilerServices.CastHelpers.Unbox`, same call stack through `CloudAgents.Docker.Program.streamSessionMessage`). Note the script's fixture pins old `Lyric.Web`/`Lyric.Docker` NuGet versions from its own frozen `lyric.toml` snapshot (not this project's current pins) — the compiler itself is current, but the library dependency versions are not, so this doesn't rule out the crash being in how the old library IL interacts with new compiler-emitted IL rather than a still-open compiler codegen defect in isolation. Five independent from-scratch standalone repro attempts (matching local-variable count, a real cross-package `Long` call, the real project's package count/declaration order, real NuGet deps, a real streaming HTTP handler) never reproduced it in isolation; only the actual, unmodified `docker_manager.l`/`docker_policy.l` source does — see `scripts/repro-crosspkg-long-crash.sh` and `docs/BUILD.md`'s ninth compiler-note entry for the full narrative. Still not root-caused to a specific compiler codegen defect or filed upstream. Workaround unchanged and still necessary: avoid `Long` arithmetic entirely in this package — `src/docker_manager.l`'s `streamSessionMessage` approximates elapsed time with an `Int` accumulator of each tick's `pollMs` instead of a `Long` epoch-millisecond subtraction, and `waitForContainer`'s analogous check uses `Int` `System.Environment.TickCount` (`tickCountMs()`) instead of `Long` epoch milliseconds. If you bump this project's `Lyric.Web`/`Lyric.Docker` pins, re-run the repro script — bumping the fixture's own pinned versions (per the script's header comment) is the way to check whether a newer library release clears it.

**`protected type` entries are mutually exclusive.** Only one `entry` runs at a time. `when:` blocks the caller (not spins) until condition is true. `invariant:` violation on entry exit = terminates the program.

**`defer` runs on ALL exits** — normal return, early return, bug/exception. Multiple defers execute in reverse declaration order.

---

## Interfaces and DI

**`impl Interface for Type` is the syntax** — not `Type implements Interface` or `Type: Interface`.

**Synchronous impl of async interface method is auto-lifted.** No `Task.fromValue(...)` needed in stubs.

**`singleton` cannot depend on `scoped[X]`.** Captive dependency = compile error, not a runtime error.

**`bind` target must structurally implement the interface.** Checked at compile time.

**Missing `bind` = compile error**, not a startup exception. The error names the unsatisfied dependency.

**`bootstrap()` takes `@provided` values as parameters** — in declaration order.

**`expose` is required** to access a wire value from outside the wire instance.

---

## Contracts

**Contract violations are `Bug`, not errors.** Do not catch `PreconditionViolated`/`PostconditionViolated`/`InvariantViolated`. Fix the bug.

**Contract expressions must be `@pure`.** Calling a non-`@pure` function in `requires:`/`ensures:` is a compile error.

**`@proof_required` packages cannot call `@runtime_checked` packages** — compile error V0002. Use `@axiom` boundaries or upgrade the callee.

**`forall`/`exists` in `ensures:` iterate at runtime** — not free for large collections.

**`old(expr)` only valid in `ensures:`**, not in `requires:` or `invariant:`.

**`implies` is an operator: `a implies b`** — not a keyword, not a function call.

---

## Config

**Config fields without a default are required.** Process panics at startup if the env var is absent — not a `Result`, not a graceful error.

**Range constraints on config fields are enforced at startup.** Out-of-range = treated same as missing required field.

**Config is read via `BlockName.fieldName` in the same package.** Not injected through `wire` — the two mechanisms are separate. Config is for env-var scalars; wire is for constructed objects.

**Env var name is `LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD>` in all caps.** `camelCase` field names are uppercased verbatim — `poolSize` → `POOLSIZE`.

---

## FFI

**All BCL interop requires an explicit `extern package` or `extern type` declaration.** No implicit access to platform types.

**`@axiom` string is not a comment.** It appears in `.lyric-contract` metadata and generated docs. It is a trust commitment reviewed in PRs.

**Wrong axioms produce wrong proofs.** Conservative `ensures:`, precise `requires:`.

**`try { } catch Bug as b` is the exception conversion pattern at extern boundaries.** Catching `Bug` in normal application code is a smell; at extern boundaries it is the intended pattern.

**No reflection.** `Type.GetField`, `Activator.CreateInstance` etc. are not available. Use source generators (`@generate`) for code that would otherwise use reflection.

**`@externInstance` + `@externTarget("System.Object.GetType")` on a boxed value-type argument (e.g. `Byte`) crashes the process with `AccessViolationException`, not a catchable exception.** Confirmed in production: `getByteType(b: in Byte): Type` (an instance-bound call to `b.GetType()`, used only to feed `Array.CreateInstance` when assembling a typed array) took down the entire server — the crash's own stack trace showed the compiled call site's parameter type as `Int32`, not `Byte`, meaning the boxed instance actually passed doesn't match what the generated call expects. If you need a `Type` value (e.g. for `Array.CreateInstance`), bind the plain static `System.Type.GetType(string)` instead — no instance/boxing involved, so this miscompilation path never triggers:
```
@externTarget("System.Type.GetType")
func typeFromName(name: in String): Type = ()
...
val byteType = typeFromName("System.Byte")
```
More generally: treat any `@externInstance` call whose target is itself reflection (`GetType`, and by extension anything `Array.CreateInstance`-adjacent) as suspect for value-type arguments specifically — this is the same "no reflection" territory as the item above, just reachable through an instance-method extern binding rather than a direct `Type.GetField`/`Activator.CreateInstance` call.

**`@externInstance` must be explicit for instance methods.** Default is static. Forgetting it on an instance method = wrong call instruction emitted.

**Unresolvable `@externTarget` on .NET = compile-time error.** On JVM = `NoClassDefFoundError` at runtime.

---

## Aspects

**Aspects are package-private by default.** They weave over functions in the same package only.

**Guarded arms don't count, and neither do `@no_aspect` functions.** A function with `@no_aspect` is completely invisible to aspect matching.

**`call.caller` is not implemented.** References to it produce an A0043 diagnostic. Don't use it.

**`call.elapsed` is wired but only available after `proceed(args)` returns.** `call.elapsed` is `None` before `proceed` runs.

**Aspect `config {}` injection for fields without defaults produces A0044 and a panic stub.** Either give the field a literal default or don't reference it.

**Aspects cannot weaken or remove a function's existing contracts.** Contract augmentation is additive only.

---

## Opaque types

**Direct construction is a compile error outside the package.** `Account(id = ..., balance = ...)` only works inside the `Account` package. Provide a constructor function.

**Fields are inaccessible outside the package.** No `account.balance` from outside — compile error. Also not accessible via .NET reflection — the emitted type has no public properties.

**`exposed record` cannot have `invariant:`.** External code constructs exposed records; you cannot guarantee invariants. Convert to opaque type at the boundary if you need invariants.

**`@projectionBoundary(asId)` is required for mutually-referential `@projectable` types.** Without it, the compiler reports E0501 and refuses to guess a default. Don't try to work around it — add the annotation.

**`toView()` is always safe; `tryInto()` returns `Result`.** Never assume round-tripping is lossless — `tryInto()` re-runs the invariant.

---

## Stubs and test wires

**`@stubbable` is for interfaces only.** Not records, not opaque types, not functions.

**Unmatched stub call raises `Bug` immediately.** Add a wildcard `it.method(_) -> default` case or the test fails at the first unmatched call.

**`.recording()` alone raises `Bug` on any call.** Use it when you want to assert a method is never called. Add `.returning { ... }` to configure return values.

**`.recorded("name")` returns an empty slice if never called — it does not fail.** Write an `assertEqualInt(calls.length, 0, ...)` if you want to assert no calls.

**Each `bootstrap(...)` call produces a fresh, independent wire instance.** Stubs do not share state between bootstrap calls. No need to reset.

**`calls[0].args[0] as T` cast is required and checked at runtime.** The compiler cannot verify the cast statically. Wrong cast raises `Bug`.

**Interface signature change = compile error in stub config.** This is a feature. If your stub config stops compiling after a refactor, that's the test telling you it needs updating.

**`await` works in test blocks with no extra setup.** The test runner initialises an async runtime automatically.

**A `@test_module` cannot invoke *any* function it reaches by `import`-ing a package that contains `async func`s — even a pure, non-async one.** The call fails at runtime with `The signature is incorrect.` (not a compile error — the suite builds, then the test fails when it runs). This bit `CloudAgents.Handlers` handlers that reference `CloudAgents.Docker` (`cancelRun`, `getRunOutput`) and, confirmed in CI, a plain `pub func` like `networkModeForPolicy` when a test did `import CloudAgents.Docker` directly. Importing a package that *transitively* pulls in such a package is fine (e.g. `main_tests` imports `CloudAgents` and calls its pure funcs) — it's the direct import of the async-bearing package that breaks. To unit-test pure logic that currently lives in an async package, **extract it into its own package with no `async func`** and import that instead (see `CloudAgents.NetworkPolicy`, split out of `CloudAgents.Docker` for exactly this reason).
