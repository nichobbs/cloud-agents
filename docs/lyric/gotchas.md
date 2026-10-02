# Lyric Gotchas

Things that look like TypeScript/Kotlin/Java but aren't. Read before debugging compile errors.

**Re-verified 2026-09-30 against lyric 0.7.5** (installed fresh + empirically
re-tested every entry below with a real `lyric build`/`lyric run`, not just a
changelog read) — matching this project's current pin (`MIN_LYRIC_VERSION`,
`deploy/api.Dockerfile`), which moved to 0.7.5 in the same window. That bump
confirmed three more gotchas fixed since the previous (0.7.3) pass — the `&`
prefix-operator RHS-discard miscompile, `slice[Byte].toList()` not resolving
at runtime, and `Int.toNat()` not resolving at runtime — all removed outright
per this file's own convention below. Confirmed-fixed
entries are **deleted outright** rather than kept around with a "FIXED as of X"
marker — this file should only describe gotchas that still exist, so there's
less to read. If you're building against an older pin and hit something this
doc no longer mentions, it may still apply to you — the linked upstream issue
number (where one exists) will say which release actually fixed it.

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
```

**`record.copy(field = …)` compiles but fails at runtime** — `unsupported
method 'copy' on the receiver type at this call site` (confirmed on v0.4.36
while building the session ledger, `src/ledger/`). Same "compiles as a
dot-call, dies at runtime" family as the `Result`/`Option` convenience
methods below. Construct the new record explicitly with every field named
(see `CloudAgents.Ledger.Service.materialize` for the pattern: a small
function that builds the full record from a draft plus the changed fields).

**`entry`, `result` and `end` are reserved and cannot be field, parameter or
binding names** — `entry` (protected-type entries), `result` (the return
value in `ensures:`), `end`. A record field named `entry` or `result` fails
to parse at every construction site (`P0080 expected ')' to close call
argument list`), which points at the call, not the declaration. Pick another
name (`ledgerEntry`, `reply`, `last`).

**An untyped `[]`, or a `slice[T]` variable, passed where a record field is
`List[T]` compiles but fails at runtime** — `Unable to cast object of type
'List`1[System.Object]' to type 'List`1[JsonRpc.Json.JsonField]'` (confirmed
on the shim's `Lyric.Mcp` 0.4.34 `JObject(fields = …)` / `JArray(items = …)`).
Only a list literal written directly at the construction site is converted.
Build a real `List` (`val xs: List[T] = newList(); xs.add(…)`) and pass that;
see `shim/src/ledger_tools.l`'s `fieldList` / `stringValues`.

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

**`Std.Core`'s `unwrapResult`/`isOk`/`isSome`/`isNone` family: use the bare free-function form, not dot-call.** Confirmed directly on lyric 0.7.3:
```lyric
import Std.Core

val r: Result[Int, String] = Ok(42)
unwrapResult(r)      // OK   — bare call compiles AND runs, returns 42
r.unwrapResult()     // FAIL — dot-call compiles, then dies at runtime:
                      //   "unsupported method 'unwrapResult' on the receiver type"
```
Same for `isOk`/`isErr`/`isSome`/`isNone`: `isOk(r)`/`isErr(r)`/`isSome(o)`/
`isNone(o)` as bare calls all work correctly; `r.isOk()`/`r.isErr()`/
`o.isSome()`/`o.isNone()` as dot-calls all fail at runtime with the same
"unsupported method" error, even though they compile fine. **Prefer the
bare `Std.Core` free-function form for all of these** (`unwrapResult(r)`,
`unwrapResultOr(r, default)`, `unwrapErrOr(r, default)`, `isOk(r)`,
`isErr(r)`, `isSome(o)`, `isNone(o)`) — a plain `match` on
`Ok`/`Err`/`Some`/`None` is always safe too, just more verbose. The `?`
operator is confirmed working at runtime and is fine.

**`.unwrap()`/`.unwrapOr()` (as opposed to `.unwrapResult()`/`.unwrapResultOr()` above) have no working bare-call replacement under the same literal name.** `r.unwrap()`/`r.unwrapOr(default)`/`o.unwrap()` all fail as dot-calls the same way, but `unwrap(r)`/`unwrap(o)` bare is `unknown name` (there's no `Std.Core` function literally named `unwrap` for `Result`), and a bare `unwrapOr(r, default)` resolves to the wrong overload (`argument type Result[...] does not match parameter type Option[T]` — `unwrapOr` bare is `Option`-only). Use `unwrapResult(r)` in place of `r.unwrap()`, `unwrapResultOr(r, default)` in place of `r.unwrapOr(default)`, and `unwrapOption(o)` (confirmed working as a bare call) in place of `o.unwrap()`.

**`String.length` compared directly against an explicitly-`Nat`-typed value
is a T0033 compile error** ("comparison operands must be matching
ordered types (got Int and Nat)") despite `String.length` being documented
`Nat` — confirmed directly on lyric 0.7.3 with the exact `s.length > max`
(`max: Nat` parameter) shape. Whichever side `.length` unifies to
depends on the other operand.

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

**A literal `${...}` inside a plain double-quoted string is interpolation, not text.** `"Authorization=Bearer ${GITHUB_TOKEN}"` tries to resolve `GITHUB_TOKEN` as a name in scope and fails to compile (`T0115: cannot resolve name ... to a value here`) if nothing by that name exists — it does NOT produce the literal four characters `$`, `{`, `...`, `}`. This bites test fixtures for a value that is itself a `${VAR}`-style placeholder meant for something else to expand later (e.g. an MCP server env/header entry docker/inject-library.sh's `envsubst` pass expands at container-injection time, not at Lyric compile time) — use a raw string instead: `r"Authorization=Bearer ${GITHUB_TOKEN}"`. Not an issue for the same text sitting in a data file (JSON, `seed/mcp-servers/*.json`) or in a `//`/`///`/`//!` comment — only inside a live, compiled string literal.

---

## Async

**`await` is an expression, not a statement.** You can use it inline.

**A direct call to an `async func` awaits in place (lyric 0.7.6+).** `val u = fetchUser(id)` is the awaited result, not a task; `await` only makes the wait explicit. In a sync function that is a blocking wait. To keep the task, use `spawn`: `val t = spawn fetchUser(id)`, then `await t` later.

**To bound a wait on a task, pass the `spawn` handle to a generic `@externInstance` binding of `Task.Wait`** (`taskWaitMs[T](t: in T, ms: in Int): Bool` in `src/docker_manager.l`). Passing the result of a direct call instead hands `Task.Wait` the awaited value, and the build succeeds but the program dies at startup: `TypeLoadException: The signature is incorrect.` for a `Unit`-returning callee (the specialisation has a `void` receiver), `AccessViolationException` for a value-returning one. A `spawn` handle only specialises correctly from the lyric release that includes nichobbs/lyric-lang#8026 (0.7.6 and earlier specialise it over the callee's result type and fail the same way).

**No fire-and-forget.** Tasks spawned in a `scope` block cannot outlive the scope.

**Cancellation token is implicit.** Do not declare it, do not pass it. Use `cancellation.checkOrThrow()` for cooperative cancellation points. It propagates automatically to all callees.

**Async functions cannot have `out`/`inout` params crossing `await` points.** Return a tuple or record instead.

**`Std.Task.delay(ms): Task` exists and works, but is undocumented in `docs/lyric/stdlib.md`.** `await Std.Task.delay(ms)` really suspends for approximately `ms` milliseconds (measured, not simulated: a 500ms delay measured back ~508ms via `System.Environment.TickCount`) without blocking the underlying worker thread the way `Thread.Sleep` does. One wrinkle, confirmed directly on lyric 0.7.3: putting it in an `async func` whose body is otherwise trailing-expression-only — `async func f(): Unit { await Std.Task.delay(ms) }` as the ONLY statement fails to compile with `error[T0070]: function body trailing expression has type Task but declared return type is Unit` — add an explicit `return ()` after the await; not an issue when the line is followed by more statements.

**A `Long` (Int64) subtract-and-compare inside a large/complex function can crash the process with an `AccessViolationException` — STILL REPRODUCES as of lyric 0.7.5, re-confirmed today.** `Unbox`'s `toTypeHnd` resolves to `System.Int64`; its `obj` is not a valid object reference ("this object has an invalid CLASS field"). `nowMs - startMs > timeoutMs` (three `Long`s) done once per poll tick still crashes every time, whether inline or via the pure, cross-package `CloudAgents.DockerPolicy.hasExceededRunTimeout` call `streamSessionMessage` originally used. Re-ran `./scripts/repro-crosspkg-long-crash.sh` directly against a freshly-installed lyric 0.7.5 today (2026-09-30): it still reproduces the exact same crash signature (`System.AccessViolationException` in `System.Runtime.CompilerServices.CastHelpers.Unbox`, same call stack through `CloudAgents.Docker.Program.streamSessionMessage`). Note the script's fixture pins old `Lyric.Web`/`Lyric.Docker` NuGet versions from its own frozen `lyric.toml` snapshot (not this project's current pins) — the compiler itself is current, but the library dependency versions are not, so this doesn't rule out the crash being in how the old library IL interacts with new compiler-emitted IL rather than a still-open compiler codegen defect in isolation. Five independent from-scratch standalone repro attempts (matching local-variable count, a real cross-package `Long` call, the real project's package count/declaration order, real NuGet deps, a real streaming HTTP handler) never reproduced it in isolation; only the actual, unmodified `docker_manager.l`/`docker_policy.l` source does — see `scripts/repro-crosspkg-long-crash.sh` and `docs/BUILD.md`'s ninth compiler-note entry for the full narrative. Still not root-caused to a specific compiler codegen defect or filed upstream. Workaround unchanged and still necessary: avoid `Long` arithmetic entirely in this package — `src/docker_manager.l`'s `streamSessionMessage` approximates elapsed time with an `Int` accumulator of each tick's `pollMs` instead of a `Long` epoch-millisecond subtraction, and `waitForContainer`'s analogous check uses `Int` `System.Environment.TickCount` (`tickCountMs()`) instead of `Long` epoch milliseconds. If you bump this project's `Lyric.Web`/`Lyric.Docker` pins, re-run the repro script — bumping the fixture's own pinned versions (per the script's header comment) is the way to check whether a newer library release clears it.

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

**Hint-less `@externTarget` whose convention can't be verified is a build error (F0027) as of Lyric 0.7.0.** If the compiler can't confirm from .NET metadata whether the target is static or instance, add `@externStatic` or `@externInstance`. This repo's `System.Array.Copy` bindings carry `@externStatic` for this reason. 0.7.0 also miscompiles an `@externTarget` taking an array extern alias (`extern type StringArray = "System.String[]"`; lyric-lang#7610): it builds but throws `MissingMethodException` at runtime. 0.7.1 fixes that, but a release-installed 0.7.1 or 0.7.2 rejects `List`/`newList` even with `import Std.Collections` (lyric-lang#7617). Use 0.7.3 or later.

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
