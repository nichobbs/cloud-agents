# Lyric Gotchas

Things that look like TypeScript/Kotlin/Java but aren't. Read before debugging compile errors.

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

## Operators

**No bitwise operators.**
```lyric
x & 0xFF    // compile error
x.and(0xFF) // correct
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

---

## Async

**`await` is an expression, not a statement.** You can use it inline.

**Calling async does not auto-await.** `fetchUser(id)` returns a task. `await fetchUser(id)` awaits it.

**No fire-and-forget.** Tasks spawned in a `scope` block cannot outlive the scope.

**Cancellation token is implicit.** Do not declare it, do not pass it. Use `cancellation.checkOrThrow()` for cooperative cancellation points. It propagates automatically to all callees.

**Async functions cannot have `out`/`inout` params crossing `await` points.** Return a tuple or record instead.

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
