# Lyric Gotchas

Things that look like TypeScript/Kotlin/Java but aren't. Read before debugging compile errors.

**Re-verified 2026-09-28 against lyric 0.7.3** (installed fresh + empirically
re-tested every entry below with a real `lyric build`/`lyric run`, not just a
changelog read). **This project currently pins Lyric ~0.4.34–0.4.36**
(`MIN_LYRIC_VERSION`, `deploy/api.Dockerfile`) **and does not build at all
against 0.7.3 as-is** (a `src/handlers/sessions.l` call site still assumes a
`List[Byte]` signature that reverted back to `slice[Byte]` upstream — see
the `readBytes`/`writeBytes` entry below) — so 0.7.3 is not yet what this
project actually runs. A large number of the "compiles but crashes at
runtime" entries that were true at the pinned range are fixed on 0.7.3, and
this pass re-tested every one directly rather than trusting old
confirmations or a changelog read — but **every entry below keeps both
halves**: what still applies on this project's actual pinned toolchain
today (do not remove a workaround from production code on the strength of
this doc alone) and what changes once the pin is eventually bumped past
whatever release fixed it. Where an entry doesn't say otherwise, assume the
originally-documented pinned-toolchain behavior is unchanged. If/when the
project's pin is bumped, re-run this doc's claims again — this file rots
fast in either direction.

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

**Still broken on this project's pinned Lyric (~0.4.34–0.4.36): storing a `Result[T,E]` in a record field breaks `match` on read-back (upstream, lyric-lang#6231).**
Reading the field and matching panics `"match not exhaustive"` at runtime
even though both cases are handled. Reconstruct `Ok`/`Err` fresh in an
accessor instead of storing/returning a `Result`-typed field — see
`shim/tests/fakes.l` for the worked pattern. **Keep this workaround** —
don't remove it on the strength of the next sentence. **FIXED as of lyric
0.7.3** (closed via lyric-lang#6388, well past this project's pin):
re-tested directly, a record with a `pub r: Result[Int, String]` field,
constructed with `Ok(99)` and matched back via `match w.r { case Ok(v) ->
...; case Err(e) -> ... }`, now matches correctly. Only drop the
`shim/tests/fakes.l` workaround once the project's pin is actually bumped
past whatever release carries the fix.

---

## Operators

**On this project's pinned Lyric (~0.4.34–0.4.36): `x & 0xFF` is a compile error, as originally documented — not independently re-verified against that exact pin in this pass, but no evidence found to the contrary.** Use `.and()`/`.or()`/`.xor()`/`.shl()`/`.shr()` for real bitwise ops regardless of pin — that part hasn't changed and is confirmed working on both.

**On lyric 0.7.3, `&` no longer raises that compile error — it's actually a unary reference/borrow prefix operator, and `x & y` silently compiles to something other than what it looks like.** Confirmed directly on 0.7.3: `&` is a *prefix-only* operator in the upstream `nichobbs/lyric-lang` repo's grammar (its `docs/grammar.ebnf`'s `PrefixExpr` production, alongside `-`/`not` — not a file present in this repo). `val z = x & y` does **not** raise a parse or type error on 0.7.3 — it parses as two adjacent expressions, `x` (which `z` actually binds to) and a separate, discarded `&y` reference expression. The RHS is still evaluated for its side effects (confirmed: `x & sideEffect()` really calls `sideEffect()`) but its value is silently thrown away and `z` ends up equal to `x`, unchanged. This is a landmine specifically because it doesn't error the way the pinned toolchain's flat "no bitwise operators, `&` is a compile error" behavior does — it would silently produce a wrong value instead, if this project's pin ever moves onto a release with this behavior. `|`, `^`, `<<`, `>>` are still not supported at all on 0.7.3 either (`^` isn't even a valid token; `|`/`<<`/`>>` are parse errors) — this miscompile is unique to `&`.
```lyric
x.and(0xFF)  // correct on any pin, confirmed: 6.and(3) == 2
x & 0xFF     // pinned toolchain: compile error. lyric 0.7.3: compiles, discards the RHS, evaluates to x unchanged
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

**On this project's pinned Lyric (~0.4.34–0.4.36), the original guidance still holds — this is the behavior production code and this doc's own workarounds are written against.**
```lyric
import Std.Core
// Std.Core declares: pub func unwrapResult[T, E](r: in Result[T, E]): T

val bare = unwrapResult(someResult)        // compile error: unknown name 'unwrapResult'
val ufcs = someResult.unwrapResult()       // correct — but see below, still crashes at runtime
```
Confirmed for `Std.Core`'s `unwrapResult`/`unwrapResultOr`/`unwrapErrOr`/
`unwrapResultStr`: bare-call is a compile error, dot-call is required to even
compile. But **compiling via dot-call does not mean it runs**: `r.unwrapResult()`
(and `.unwrapResultOr()`, `.unwrapErrOr()`, `.isOk()`, `.isSome()`, `.isNone()`)
compiles as a dot-call and then fails at runtime with `unsupported method
'unwrapResult' on the receiver type`. `Std.Testing`'s `assertTrue`/
`assertEqual`/`isOk` (a different, non-generic `isOk` — see
`docs/lyric/reference.md`'s Testing section) resolve fine as bare calls, so
this isn't "every imported free function needs dot-call," just `Std.Core`'s
generic helpers specifically. **Match on the union instead** — that's the
only form confirmed reliable at this pin. The `?` operator is confirmed
working at runtime and is fine.

**REVERSED on lyric 0.7.3 — do not apply this to code targeting the pinned toolchain above.** Re-tested directly on 0.7.3: bare-call now compiles AND runs correctly (`unwrapResult(r)` returns the value), while dot-call compiles but fails at runtime with the same "unsupported method" error the pinned toolchain's dot-call form has always had.
```lyric
// lyric 0.7.3 only — NOT this project's pinned toolchain:
unwrapResult(r)      // OK   — bare call now compiles AND runs, returns 42
r.unwrapResult()     // FAIL — dot-call compiles, then dies at runtime
```
Confirmed the same reversal for `isOk`/`isSome`/`isNone` on 0.7.3: bare calls
(`isOk(r)`, `isSome(o)`, `isNone(o)`) all work correctly; dot-calls (`r.isOk()`,
`o.isSome()`, `o.isNone()`) all fail at runtime with "unsupported method",
even though they compile fine. A plain `match` on `Ok`/`Err`/`Some`/`None`
remains safe on *either* toolchain, just more verbose — when in doubt, or
when code needs to work across both, prefer `match`.

**On this project's pinned Lyric (~0.4.34–0.4.36): ambiguous names across whole-module imports still resolve silently by import
order — no compile error, no argument type-check.** If two imported packages
both export `updateSessionModel`, an unqualified call binds to one of them
based on import order; if the chosen one has a different parameter type, the
call still compiles and fails at runtime with an invalid-cast (confirmed on
v0.4.19: reordering `import CloudAgents.Handlers`/`import
CloudAgents.SessionStore` alphabetically flipped which `updateSessionModel` a
test called). Fully qualify any name exported by more than one imported
package — this is still the only safe practice on the pinned toolchain.

**FIXED on lyric 0.7.3 — a proper compile-time error (T0123) instead.** Re-tested directly: two imported packages exporting the same unqualified function name (`updateThing`, one signature per package) now fails to build with `error[T0123]: 'updateThing' is ambiguous: it is declared by 'Pkg.A', 'Pkg.B', all imported here — qualify the reference`, rather than silently binding to whichever package the import order happened to favor. Still fully qualify any such name regardless of pin — it's just no longer a silent miscompile risk once the pin catches up.

**Still broken on this project's pinned Lyric (~0.4.34–0.4.36): package-qualified record construction fails at runtime.**
`CloudAgents.Prompts.SavePromptRequest(name = ..., body = ...)` compiles but
dies with `unsupported method 'SavePromptRequest' on the receiver type`
(confirmed on v0.4.19 by CloudAgents.PromptTests). Import the module and
construct with the unqualified name — `SavePromptRequest(...)`. Qualified
*function* calls (`CloudAgents.Sqlite.execute(...)`) work fine; it is only
record constructors that must be unqualified. **FIXED on lyric 0.7.3**
(re-tested directly: both `Pkg.A.Widget(id = 5)` qualified and `Widget(id =
9)` unqualified now construct correctly; qualified `pub val` reads and
qualified function calls were also re-tested and work fine) — but don't
switch this project's code to qualified construction until the pin is
actually bumped.

**A specific unqualified, imported record type crashed on construction
with a bare `InvalidProgramException` on this project's pinned Lyric,
while structurally-identical siblings from the same package constructed
fine — not independently re-tested this pass (no minimal repro exists to
re-run).** Confirmed on v0.4.34 by `CloudAgents.MainTests`:
`Comment(id = ..., messageId = ..., sessionId = ..., body = ...,
createdAt = ...)` — a plain, unqualified construction of a
`CloudAgents.Repository` record after `import CloudAgents.Repository` —
crashed with "Common Language Runtime detected an invalid program", while
`Todo`/`Message`/`MessageList`/`CommentList`/`TodoList` from the exact same
package, constructed the same unqualified way in adjacent tests in the same
file, all worked. No trigger condition was ever identified. Given the
broader family of record-construction `InvalidProgramException`s in this
doc (package-qualified construction above, `Web.Request` below, the
cross-package `pub val` entries in Imports) are all confirmed fixed
upstream by lyric 0.7.3, this specific one is plausibly fixed too — but
that's a guess, not a re-test, since there's no isolated repro to run
against 0.7.3. If a record construction you'd expect to work throws this
exact error on the pinned toolchain, don't assume the whole type/pattern is
broken — isolate to a single minimal test first. This never affected
production (`Comment` is only constructed in `repository.l`'s own
`rowToComment`/`addComment`; check with a grep for `TypeName(` outside a
type's home package before assuming a given construction is at risk).

**Still broken on this project's pinned Lyric (~0.4.34–0.4.36): constructing a `Lyric.Web` `Request` record crashes with a bare
`InvalidProgramException`.** Unlike the package-qualified-construction entry
above, this is already unqualified (`Request(...)` after `import Web`) and
still crashes — with a different, lower-level CLR error ("Common Language
Runtime detected an invalid program") — even when every field is a value of
the documented type. Confirmed on Lyric.Web 0.4.26/0.4.36 by
`CloudAgents.MainTests`, isolated to the construction itself: a handler that
never reads a single field off `req` still crashed when the test harness
built the `req` it was passed. Tracked historically as
[nichobbs/cloud-agents#354](https://github.com/nichobbs/cloud-agents/issues/354).
Does not affect production code — this project's `src/main.l`
Handler/Middleware adapters only ever *receive* a `Request` from the
framework (reading it via `Web.header()`/`Web.pathParam()`), never construct
one — so it only blocks constructing a `Request` yourself, e.g. in a test
harness, on the pinned Lyric.Web version.

**FIXED as of Lyric.Web 0.7.0 — but this project pins Lyric.Web 0.4.36, well below that.** Re-tested directly against **Lyric.Web 0.7.0**
(the latest published version — check
`https://api.nuget.org/v3-flatcontainer/lyric.web/index.json` for newer):
constructing a `Request` with every field populated (`newMap()` for the map
fields — that constructor name has also changed from the `Map.empty(...)`
form the pinned toolchain uses) now succeeds and the constructed value's
fields read back correctly. `./scripts/repro-web-request-crash.sh` still
pins the old `Lyric.Web` version (0.4.36) from this project's `lyric.toml`
and needs that pin bumped before it will observe the fix — it currently
fails for an unrelated reason instead (the old Lyric.Web version's compiled
contract references a `Map.empty` static member that no longer resolves
under lyric 0.7.3's stricter auto-FFI, itself a symptom of the same
`Map.empty` → `newMap()` rename).

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

**On this project's pinned Lyric (~0.4.34–0.4.36): `Std.File.readBytes` returns `Result[List[Byte], IOError]`
as of Lyric v0.5.0, not the `Result[slice[Byte], IoError]` both docs/lyric/stdlib.md and
docs/lyric/reference.md document** — confirmed against the actual
`lyric-stdlib` v0.5.0 source (`std/file.l`'s `readBytes`), and this is still
what the pinned toolchain does. This is a compile-time type error, not a
runtime surprise: `T0043 argument type List[Byte] does not match parameter
type slice[Byte]` at every call site that passes a `readBytes` result
straight to a `slice[Byte]`-typed function/extern binding (hit in this repo
at `CloudAgents.McpServerSeed.readSeedMcpServer` and
`CloudAgents.LibrarySeed.readSeedSubagent`/`readSeedSkill`, and `writeBytes`
similarly wants `List[Byte]` — `src/handlers/sessions.l`'s
`sliceBytesToList(v.bytes)` call exists for exactly this). Fix at call
sites with `.toArray()` (the confirmed-working `List[T].toArray()`
direction) — **keep these shims in place**, they are load-bearing for the
pinned toolchain, not legacy cruft to clean up.

**REVERTED back to `slice[Byte]` on some release after v0.5.0 — CONFIRMED via lyric 0.7.3, well ahead of this project's pin.**
Current `lyric-stdlib/std/file.l` (as shipped in lyric 0.7.3) has
`readBytes(path): Result[slice[Byte], IOError]` and `writeBytes(path, bytes:
in slice[Byte]): Result[Unit, IOError]` again — matching what
`docs/lyric/stdlib.md`/`docs/lyric/reference.md` always documented, and the
opposite of the pinned toolchain's `List[Byte]` convention above. Re-tested
directly: round-tripping bytes through `writeBytes`/`readBytes` with a
`slice[Byte]` value works with no type error on 0.7.3. **This is exactly why
this project doesn't currently build against 0.7.3**: `sessions.l:942`'s
`sliceBytesToList(v.bytes)` call into `writeBytes` now fails with `argument
type List[Byte] does not match parameter type slice[Byte]` on 0.7.3, the
mirror image of the pinned-toolchain error above. **Do not touch these call
sites until the project's pin is actually bumped** — at that point the
`.toArray()`/`sliceBytesToList()` shims need removing, not adding to.

**Still broken on this project's pinned Lyric (~0.4.34–0.4.36): `Std.File.exists()` and `Std.File.delete()` do not resolve at runtime** —
`unsupported method 'exists' on the receiver type (no matching user method,
extern binding, or built-in intrinsic)` (confirmed on v0.4.36 while building
the chat-attachment rollback in `CloudAgents.Handlers.cleanupPartialAttachmentBatch`,
nichobbs/cloud-agents#1003). Both are documented in `docs/lyric/stdlib.md`
and both compile at this pin, so this is the same "compiles as a dot-call,
dies at runtime" family as the entries above. For deletion bind
`System.IO.File.Delete` directly (an `@externStatic` binding, wrapped in
`try`/`catch` since it throws on a missing path) — see
`cleanupPartialAttachmentBatch` for the worked pattern; for an existence
check at test time, use `Std.File.readBytes`'s `Ok`/`Err` outcome instead.
**Keep this workaround on the pinned toolchain.**

**RENAMED (and working) on lyric 0.7.3.** `Std.File` has no `exists()`/
`delete()` methods under those names at all anymore — the free functions are
`Std.File.fileExists(path: in String): Bool` and `Std.File.deleteFile(path: in
String): Result[Unit, IOError]`. Re-tested directly: both work correctly as
bare calls (`Std.File.fileExists("/tmp")`, `Std.File.deleteFile(path)`) — no
runtime "unsupported method" failure, no need for the `System.IO.File.Delete`
extern workaround. Not useful for this project until the pin catches up,
since these names don't exist at all on the pinned 0.4.34–0.4.36 range.

**Still broken on this project's pinned Lyric (~0.4.34–0.4.36): `String.toUpperCase()` and `String.replace()` do not resolve at runtime** —
`unsupported method 'toUpperCase' on the receiver type (no matching user
method, extern binding, or built-in intrinsic)` (confirmed on v0.4.35 with a
standalone repro: `"clientId".toUpperCase()` compiles fine, crashes the
instant `main()` runs it). Same "compiles as a dot-call, dies at runtime"
family as the `Result`/`Option` convenience methods above, despite both
being documented in `docs/lyric/stdlib.md` (`s.toUpperCase(): String`,
`s.replace(from: String, to: String): String`). If you need case-folding or
substring replacement at runtime, do it by hand character-by-character
(the same `.substring(i, 1)` + comparison-chain pattern this repo already
uses for `digitValue`/`isAsciiLetter` in `src/handlers/proxy.l`) rather than
reaching for either method — or, if you only need to assert something
*about* a literal string shape at test time (not actually transform a
runtime value), prefer literal string constants + `.contains()` checks,
which are confirmed working. **Keep this workaround on the pinned toolchain.**

**RENAMED (and working) on lyric 0.7.3.** `String.toUpperCase()`/
`.toLowerCase()` don't exist under those names at all on 0.7.3 — using them
is now a **compile-time** error (`error[T0120]: no method 'toUpperCase' on
type 'String' at this call site`), not the pinned toolchain's "compiles,
crashes at runtime" failure. The 0.7.3 dot-call methods are
`.toUpper()`/`.toLower()` (`lyric-stdlib/std/string.l`'s `toUpper`/`toLower`,
case-folding without locale tailoring per lyric-lang#7261/#5557 — safe under
a Turkish locale too). Re-tested directly on 0.7.3: `"clientId".toUpper()` →
`"CLIENTID"`, and `.replace(from, to)` also works fine as a dot-call (`"hello
world".replace("world", "there")` → `"hello there"`) — no runtime failure
for either. None of this is reachable on the pinned toolchain: `.toUpper()`/
`.toLower()` don't exist there either (only the broken `.toUpperCase()`/
`.toLowerCase()` do), so the character-by-character workaround above is
still what production code should use today.

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

**Assume still broken on this project's pinned Lyric (~0.4.34–0.4.36): a `Nat`-typed function argument crossing a package boundary can crash the
*caller* at runtime with a bare `InvalidProgramException`, with no compile
error at all.** Confirmed on Lyric.Web 0.4.26 (within the pinned range):
`CloudAgents.Interactions` calling `CloudAgents.Text.withinMaxLength(s, max)`
with `max: Nat` compiled cleanly but crashed every
`CloudAgents.InteractionsTests` case that reached it — the same
`InvalidProgramException` family as the `Web.Request`/package-qualified
record construction entries above, but with no `Web` involved anywhere on
this call path. **Prefer `Int` for cross-package function parameters and
return types even where `Nat` would be the more "correct" documented type**,
normalizing via `.toInt()` at the boundary — this is still the safe default
on the pinned toolchain. Not independently re-verified this pass against
lyric 0.7.3: there is currently no way to even construct a bare `Nat` value
to pass across a package boundary without hitting an unrelated compile error
first on 0.7.3 (`Int.toNat()` doesn't resolve there either; a `Nat`-typed
parameter fed a `String.length` read hits the T0033 gotcha above on both
toolchains), so the exact original repro shape couldn't be re-run on
current upstream. Given the neighboring bugs in this same
`InvalidProgramException` family are now confirmed fixed on 0.7.3, this one
is plausibly fixed too there — but that's a guess, not a re-test, and
irrelevant to this project until the pin moves. Re-verify with a real
`Nat`-returning call (e.g. an actual `slice[T].length` read into a
`Nat`-typed cross-package parameter, sidestepping both blockers) if you hit
anything like it again on either toolchain.

**Still broken on this project's pinned Lyric (~0.4.34–0.4.36): `Std.Time.now()` is broken at runtime** (the original entry in this doc
named it `Std.Time.Instant.now()`, but the actual API has always been the
free function `Std.Time.now(): Instant`) — it compiles, then fails with
`Method not found: 'Void System.DateTime.now()'` (a lowercase `now`
MemberRef the BCL has never had; confirmed on v0.4.19 by this repo's
live-DB tests). Work around with a direct BCL binding
(`System.DateTimeOffset.get_UtcNow` + `ToUnixTimeMilliseconds`) — see
`CloudAgents.Repository.nowMillis`. **Keep this workaround on the pinned
toolchain.**

**FIXED on lyric 0.7.3.** Re-tested directly: `Std.Time.now()` and
`Std.Time.nowEpochMillis()` both work correctly on 0.7.3 — the
`System.DateTimeOffset.get_UtcNow` extern workaround would no longer be
necessary there, but keep it in `CloudAgents.Repository.nowMillis` until
this project's pin is actually bumped (it's harmless to leave in place
either way).

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

**Assume still broken on this project's pinned Lyric (~0.4.34–0.4.36): a cross-package `pub val` used to construct several record types in one function crashes at JIT (upstream, lyric-lang#6232).**
`System.InvalidProgramException` for the whole function, at runtime, no
compile error. Related: a qualified constant read inside an `impl` method
body crashes the same way (lyric-lang#6134), and reads through a
*restored-DLL* dependency can silently produce `0`/null instead
(lyric-lang#6133). Have the consuming package own such constants as its
own literals — see `shim/src/main.l`'s header note. **Keep this workaround**
on the pinned toolchain; these issues were filed and fixed in the
2026-07-18–07-31 window, and this project's pin predates that fix landing
in a release this project actually uses.

**FIXED as of lyric 0.7.3** (#6232/#6134/#6133 all closed). Re-tested #6232's exact shape directly on 0.7.3: a `pub val` in one package, read to construct three different record types in a single function in another package, now compiles and runs correctly with no crash. #6134/#6133 weren't independently re-run (they need an `impl` block / a separate restored-DLL dependency to set up) but were closed via merged fixes in the same PR batch as #6133 (lyric-lang#6345) around the same time as #6232 — treat as fixed upstream, but re-verify if you hit either shape again. Only drop the `shim/src/main.l` workaround once this project's pin is actually bumped past whatever release carries the fix.

---

**Assume still broken on this project's pinned Lyric (~0.4.34–0.4.36): a type-invalid record-field assignment that the type checker silently
accepts can corrupt JIT codegen for unrelated methods across the entire
`output = "single"` bundle.** Confirmed on v0.4.36 by PR #739
(`sessions.l` assigning a `Result[AgentSessionArray, DbError]` straight into
a `slice[AgentSession]` field): `lyric build`/`lyric check` both accepted it
with no error, 27/27 packages "built" cleanly, and at runtime it corrupted
JIT codegen broadly enough to crash ~24 unrelated tests with a bare
`InvalidProgramException` across multiple packages compiled into the same
bundle — even packages the broken function doesn't call into. Fixed
source-side by properly `match`-unwrapping the `Result` and hand-rolling
the array-to-slice copy (see `CloudAgents.SessionStore.getSessionArrayLength`/
`getSessionArrayValue`) — that fix stays in place regardless of compiler
version, since it's a real logic bug, not a workaround for a compiler
defect. **Lesson, still applicable on the pinned toolchain**: when a
from-scratch `InvalidProgramException` regression appears with no
async/await anywhere in the diff, check every new record construction in
the diff for a field type that doesn't structurally match its assigned
expression — the type checker may silently accept it at this pin, but the
JIT will not survive it, and the blast radius is bundle-wide.

The same silently-accepted-then-`InvalidProgramException` failure mode also
happened for field **access** on the wrong record type on the pinned
toolchain — e.g. reading `.nextRunAt` on a `JobSummary` (fields include
`nextRunAtEpochMillis`, no `nextRunAt`) where that field name exists on the
*similarly-shaped* `CloudAgents.Repository.ScheduledJob` record instead.
This compiled with no error and only crashed at test runtime with the same
signature, isolated to just the tests that exercised the bad access. Fix is
the same as always: use the field that actually exists. **Still worth
double-checking field names/types on any diff that touches two
similarly-shaped records on this project's pinned compiler** — don't trust
it to catch this.

**FIXED as of lyric 0.7.3 — now a real compile-time error instead of a silent JIT-time crash, for both failure modes above.** Re-tested both exact shapes directly:

- The field-**assignment** shape (a function returning `Result[slice[Item], String]` assigned directly into a `Response` record's `slice[Item]` field) now produces a normal, immediate `error[T0104]: argument for field 'items' has type Result[slice[Item], String] but field expects slice[Item]` at build time. No bundle-wide corruption possible anymore since it never reaches the JIT.

- The field-**access** shape (`JobSummary`/`ScheduledJob`) now produces `error[T0113]: no member 'nextRunAt' on type 'JobSummary'` at build time.

Both were real, narrow type-checker gaps specific to the v0.4.x-era
compiler this project pins — not general JIT fragility — and both are
closed off on 0.7.3. This class of bug can no longer reach a JIT crash once
the pin catches up: the type checker rejects it up front. Until then, the
"check field names/types by hand" discipline above is still load-bearing.

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

**Still very much present on this project's pinned Lyric (~0.4.34–0.4.36) — this is exactly why `src/docker_manager.l`'s async workarounds exist: a `val` bound before one `await` can silently lose its value after a SECOND, different-callee `await` in the same async function** (lyric-lang#6249, confirmed on v0.4.35 — `./scripts/repro-compiler-bug.sh` check 8). It reads back as the type's default (`""` for `String`) instead of the value it was bound to — no exception, no diagnostic. A `val` bound before exactly one `await` and read immediately after that same await is fine; a function *parameter* (not a `val`) or a `var`-mutated loop counter read across a loop that repeatedly awaits the *same* callee is also fine. The risk is specifically: bind a value, `await` something, `await` something ELSE, then read the value. Workaround: thread the value through a mutable record field (e.g. an existing `cell`-style carrier record already passed into the function) instead of a bare local — a field survives reliably across multiple awaits. See `src/docker_manager.l`'s `runSessionMessageAsync` for the pattern (fixed in PR #690 after this bug was root-caused as the leading suspect behind a recurring `streamSessionMessage` `AccessViolationException` crash). **Do not remove this workaround** — the pinned toolchain still needs it.

**FIXED as of lyric 0.7.3** ([lyric-lang#6249](https://github.com/nichobbs/lyric-lang/issues/6249), closed via lyric-lang#6514). Re-tested the issue's own exact repro directly on 0.7.3 (a `val id = "hello"` bound before `await stepA()`, then `await stepB()`, then `cell.output = id`): now correctly produces `actual=[hello]`, matching what was always expected. This does not mean `docker_manager.l`'s workarounds above (the `cell`-style mutable-field-carrier pattern in `runSessionMessageAsync`, the parameter-carrying-recursion pattern in `waitForContainer`/`waitForContainerAttempt`) can be removed even after the pin is bumped: see the "`Long` (Int64) subtract-and-compare" entry below — the production `AccessViolationException` this fix was originally suspected of causing was actually root-caused to a *second*, distinct bug that still reproduces on 0.7.3 today. The workarounds are cheap, still correct on either toolchain, and worth keeping regardless of which compiler version ends up building this project.

**`Std.Task.delay(ms): Task` exists and works, but is undocumented in `docs/lyric/stdlib.md`.** `await Std.Task.delay(ms)` really suspends for approximately `ms` milliseconds (measured, not simulated: a 500ms delay measured back ~508ms via `System.Environment.TickCount`) without blocking the underlying worker thread the way `Thread.Sleep` does — confirmed on this project's pinned toolchain in a scratch project and in `scripts/repro-compiler-bug.sh` check 8's own repro, and re-confirmed directly on lyric 0.7.3 too. Two wrinkles, on the pinned toolchain, putting it in an `async func` whose body is otherwise trailing-expression-only: (1) `async func f(): Unit { await Std.Task.delay(ms) }` as the ONLY statement fails to compile with `error[T0070]: function body trailing expression has type Task but declared return type is Unit` — add an explicit `return ()` after the await; not an issue when the line is followed by more statements. **Re-confirmed this wrinkle still applies on lyric 0.7.3 too** — this part of the entry holds on both toolchains. (2) putting `await Std.Task.delay(...)` as the SECOND, different-callee await in a loop/retry step is exactly the lyric-lang#6249 shape from the entry above — **on this project's pinned toolchain that is still broken**, so see `waitForContainer`/`waitForContainerAttempt` in `src/docker_manager.l` (#635) for the safe pattern: recurse instead of loop, carrying every value that must survive the delay as a function PARAMETER of the recursive call, never as a `val`/`var` local read after it. Keep that recursion pattern regardless of pin — it costs nothing and is #6249-safe on any compiler version, unlike a plain loop which is only safe once the pin is bumped past whatever release fixed #6249 (confirmed lyric 0.7.3, not confirmed exactly which earlier release first carried the fix).

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
