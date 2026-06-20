# Lyric Language Reference

Full tutorial: https://nichobbs.github.io/lyric-lang/

---

## File structure

Every `.l` file:

```lyric
//! Module doc (optional, before package)
package MyPackage
import Std.Core
import OtherPkg.{SomeName, AnotherName}

// declarations...
```

- `package` declaration is required, first non-comment line.
- Package = directory. All `.l` files in the same directory share the same package name.
- File names are irrelevant to the compiler.
- No wildcard imports (`import Foo.*` is a compile error). Every imported name must be explicit.
- Imports are alphabetically ordered (formatter enforces this).

---

## Primitive types

| Type | Description |
|------|-------------|
| `Bool` | `true` / `false` |
| `Byte` | u8, 0..=255 |
| `Int` | i32 |
| `Long` | i64 |
| `UInt` | u32 |
| `ULong` | u64 |
| `Nat` | non-negative i64 (0..=2^63-1) — use this for counts, lengths, indices |
| `Float` | f32 |
| `Double` | f64 |
| `Char` | Unicode scalar value |
| `String` | immutable UTF-8 |
| `Unit` | single value `()` — not void; is a real type |
| `Never` | bottom type, uninhabited — return type of `panic` and diverging functions |

**No implicit widening.** `Int` → `Long` requires `.toLong()`. `Int` → `Nat` requires `.toNat()` (panics if negative) or `.tryToNat()` (returns `Result`).

**Overflow:** debug builds panic on integer overflow; release builds wrap on unconstrained types. Range subtypes always panic.

---

## Range subtypes

```lyric
type Age      = Int range 0 ..= 150
type DiceRoll = Int range 1 ..= 6
type Cents    = Long range 0 ..= 100_000_000_000 derives Add, Sub, Compare
```

- These are **distinct nominal types**, not aliases.
- Construction: `Age.tryFrom(n)` → `Result[Age, ContractViolation]` (idiomatic), or `Age.from(n)` (panics).
- Conversion back: `.toInt()`, `.toLong()` etc.
- Cannot mix in arithmetic with base type: `age + 1` is a compile error. Use `age.toInt() + 1`.
- Range syntax: `a ..= b` (closed), `a .. b` (half-open, b excluded), `..= b`, `a ..`.

---

## Distinct types and aliases

```lyric
type UserId  = Long derives Compare, Hash   // distinct — NOT interchangeable with Long
type OrderId = Long derives Compare, Hash   // distinct — NOT interchangeable with UserId
alias Millis = Long                          // structural synonym — interchangeable with Long
```

- `type` = distinct nominal type. Default. Use for domain types.
- `alias` = structural synonym. Use only to shorten long generic signatures.
- `derives` controls available operations. Without `derives`, you get nothing — no `==`, no `<`.

| Marker | Enables |
|--------|---------|
| `Add` | `T + T -> T` |
| `Sub` | `T - T -> T` |
| `Mul` | `T * T -> T` |
| `Div` | `T / T -> T` |
| `Mod` | `T % T -> T` |
| `Compare` | `<`, `<=`, `>`, `>=`, `IComparable<T>` |
| `Hash` | hash code (implies Equals) |
| `Equals` | `==`, `!=`, `IEquatable<T>` |
| `Default` | `T.default()` — rejected if default value is out of range |

---

## Records

```lyric
pub record Customer {
  pub id: CustomerId
  pub email: Email
  joinedAt: Instant       // package-private
  isActive: Bool          // package-private
}
```

- Named construction only — positional is a compile error: `Customer(id = ..., email = ..., joinedAt = ..., isActive = ...)`
- Non-destructive update: `c.copy(isActive = false)` — original unchanged
- Structural equality automatic — no `equals`/`hashCode` to write
- Immutable: no field reassignment. Use `.copy()` or `opaque type` for mutation
- `@valueType` annotation → .NET `readonly struct` (use for small, allocation-hot records like `Vec2`)
- A `pub` record with private fields cannot be directly constructed outside the package — provide a constructor function

---

## Unions (sum types)

```lyric
union Shape {
  case Circle(radius: Double)
  case Rectangle(width: Double, height: Double)
  case Triangle(base: Double, height: Double)
}
```

- Constructed by case name: `Circle(radius = 5.0)`
- Access only via `match` — no direct field access
- `match` is exhaustive — every case must be handled or there must be `case _ ->`
- Adding a case to a `pub` union is a breaking change — every match in callers fails to compile
- `Result[T, E]` and `Option[T]` are ordinary generic unions

```lyric
union Result[T, E] {
  case Ok(value: T)
  case Err(error: E)
}

union Option[T] {
  case Some(value: T)
  case None
}
```

---

## Enums

```lyric
enum Direction { case North; case South; case East; case West }
```

- Unions with no payload
- No implicit integer conversion (unlike C#/Java)
- `toNat()` / `fromNat()` planned for v1.0; use explicit `match` for now

---

## Tuples

```lyric
val pair: (Int, String) = (42, "hello")
val (n, s) = pair        // destructuring
```

- No positional indexing (`.0`, `.1` not supported — use destructuring or a named record)
- Use for 2-3 closely related values from a function; use records for anything crossing package boundaries

---

## Arrays and slices

```lyric
val fixed: array[16, Byte]          // length in type; stack/inline; value type
val dynamic: slice[Int] = [1, 2, 3] // heap-allocated; reference type

// slice ops (all return new slice, no in-place mutation)
xs.length       // Nat
xs[2]           // panics if OOB
xs.append(42)
xs.concat(ys)
xs.slice(1, 3)  // [1,3)
```

- Array indexing with `Int range 0 ..= N-1` elides bounds check entirely
- Slice literal `[1, 2, 3]` inferred as `slice[Int]`

---

## Functions

```lyric
func add(x: Int, y: Int): Int = x + y   // expression form

pub func greet(name: in String): String {
  return "Hello, ${name}!"
}
```

- Return type required on `pub` functions; inferred on private
- `Unit` return = no useful value (omit `return`)
- `Never` return = function never returns (diverges or panics)

### Parameter modes

| Mode | Meaning |
|------|---------|
| `in` (default) | read-only; compiler may pass by value or ref internally |
| `out` | function must assign exactly once on all paths before return; caller passes `var` |
| `inout` | read + write; assignments visible in caller after return |

- `in` is the default and can be omitted, but formatter always inserts it
- Async functions cannot have `out`/`inout` parameters that cross `await` points — use tuple/record return instead

### Closures

```lyric
val double = { x: Int -> x * 2 }
val evens = numbers.filter { x -> x % 2 == 0 }  // trailing lambda syntax

func makeAdder(n: Int): {Int -> Int} = { x -> x + n }

// Closure type syntax:
// {Int -> Bool}
// {Int, String -> Unit}
```

- `val` captures: by value (snapshot at closure creation)
- `var` captures: by reference (sees current value at call time)

---

## Pattern matching

```lyric
val result = match shape {
  case Circle(r)           -> 3.14159 * r * r
  case Rectangle(w, h)     -> w * h
  case Triangle(b, h)      -> 0.5 * b * h
}
```

- `match` is an expression producing a value
- Arms: `case Pattern -> expression` — no fall-through, no `break`
- All arms must produce the same type
- **Exhaustiveness is enforced** — missing cases are compile errors (E0301)
- Guarded arms (`where`/`if`) do NOT count toward exhaustiveness

Pattern kinds:
```lyric
case 0           -> ...    // literal
case Some(value) -> ...    // binding (value in scope in arm body)
case _           -> ...    // wildcard
case Point { x = 0.0, y } -> ...   // record destructuring
case 0 ..= 17    -> ...    // range pattern
case (true, 200) -> ...    // tuple pattern
case Circle(r) where r > 100.0 -> ...  // guard (where or if)
```

- No `if let` — use full `match`
- Nested patterns compose freely

---

## Control flow

```lyric
// if is an expression
val label = if score >= 60 then "pass" else "fail"

// block form
if condition {
  doThis()
} else {
  doThat()
}

// loops
for i in 0 ..< n { ... }      // half-open [0, n)
for i in 0 ..= n { ... }      // closed [0, n]
for item in collection { ... }

while condition { ... }

// labelled break
outer: for row in matrix {
  for cell in row {
    if cell == target { break outer }
  }
}
```

- No ternary `?:` — use `if expr then a else b`
- No `do...while` — use `while true { ... if done { break } }`
- Chained comparisons are a parse error: write `a < b and b < c`

---

## Bindings

```lyric
val x = 42          // immutable
var y = 42          // mutable
let z = expensive() // lazy, evaluated on first use, .NET Lazy<T> semantics
```

---

## Operators

- No bitwise operators (`&`, `|`, `^`, `<<`, `>>`). Use `.and()`, `.or()`, `.xor()`, `.shl()`, `.shr()`
- Logical: `and`, `or`, `xor`, `not`
- Error propagation: `?` (postfix, highest precedence after `.` and `[]`)
- Nil-coalescing: `??` (right-associative)

---

## Error handling

```lyric
// ? on Result — propagates Err early, unwraps Ok
func processAge(raw: String): Result[Age, ParseError] {
  val n = tryParseInt(raw)?   // returns Err early if parse fails
  return Age.tryFrom(n)?      // returns Err early if out of range
}

// ? on Option — propagates None early
```

- Enclosing function must return `Result` or `Option` for `?` to be valid
- `panic(msg)` for unrecoverable bugs (returns `Never`)
- `assert(condition)` for invariant checking in dev

---

## Contracts

```lyric
pub func divide(n: in Int, d: in Int): Int
  requires: d != 0
  ensures: result * d + (n % d) == n
{
  return n / d
}
```

- `requires:` — preconditions. Evaluated on entry in source order. First false clause raises `PreconditionViolated` bug. Caller's fault.
- `ensures:` — postconditions. Evaluated just before return. `result` refers to the return value. Raises `PostconditionViolated` bug. Function's fault.
- `invariant:` — on opaque/record types. Checked at every public boundary crossing. Raises `InvariantViolated` bug.
- Multiple `requires:` clauses are conjoined. All must hold. First false one fires.
- `old(expr)` in `ensures:` — evaluates `expr` against the pre-call state (after `requires:`, before body). Only captures fields actually read — not a deep copy.

```lyric
func push(s: inout Stack[T], x: in T): Unit
  ensures: s.depth == old(s.depth) + 1
  ensures: s.top() == x
{ ... }
```

### Contract expression sublanguage

Contracts must be **pure** — no side effects, no I/O, no mutation. Compiler enforces this statically.

Allowed:
- Arithmetic, comparison, logical operators
- Field access: `a.balance`, `s.depth`
- Calls to `@pure`-annotated functions
- `result`, `old(expr)` in `ensures:`
- `implies` operator: `a implies b` ≡ `not a or b`
- Quantifiers over finite collections:

```lyric
ensures: forall (x: T) where xs.contains(x) implies result.contains(x)
ensures: exists (x: T) where result.contains(x) and x > 0
```

Not allowed: non-`@pure` calls, side effects, allocation, mutation, `?`, body-local variables.

`forall`/`exists` iterate at runtime in `@runtime_checked` mode; become SMT formulae in `@proof_required`.

### What belongs in `requires:` vs `Result`

- `requires:` — conditions only a **buggy caller** would violate. Programming errors.
- `Result[T, E]` — conditions a **reasonable caller** could encounter: bad user input, missing file, network timeout.

### Violation output

```
division.l:4:3: bug PreconditionViolated: divide — d != 0
  at Division.main (division.l:9)
counterexample values at violation:
  n = 10
  d = 0
```

Postcondition violations include `result` in the counterexample. All violations are `Bug` — do not catch them, do not put in `Result`. Fix the bug.

### `assert` vs `requires:`

- `requires:` — caller obligation. In API surface, docs, reasoned about by prover. Fires as `PreconditionViolated`.
- `assert(cond, msg)` — internal sanity check. Not in API surface. Fires as `AssertionFailed`. Blame falls on implementation.

### Verification modes

| Annotation | Behaviour |
|-----------|-----------|
| `@runtime_checked` | Default. Contracts evaluated at runtime. |
| `@runtime_checked(release_contracts = full)` | Full checking in release builds (financial/safety-critical). |
| `@proof_required` | SMT-backed static proof before compilation. `lyric prove`. |

### Debug vs release

| Contract | Debug | Release |
|----------|-------|---------|
| `requires:` on `pub` functions | checked | **always checked** |
| `requires:` on non-`pub` functions | checked | elided |
| `ensures:` | checked | elided (use `--release-contracts` flag to keep) |
| Range subtype bounds | checked | **always checked** |

### `@proof_required`

```lyric
@proof_required
package Money
```

- Compiler feeds contracts to Z3 SMT solver. Rejects build if any obligation cannot be proved.
- May **only call**: other `@proof_required` packages, primitives, `@axiom` extern boundaries.
- Calling `@runtime_checked` code is a **compile error** (V0002) — proof would be unsound.
- `@runtime_checked` packages can call `@proof_required` freely.
- `@proof_required(checked_arithmetic)` — adds overflow VCs to every arithmetic op. For financial packages.
- `@proof_required(unsafe_blocks_allowed)` — allows `unsafe { }` blocks that skip proof obligations.

```lyric
// extern code the prover trusts without checking
@axiom("BCL spec")
extern func mathAbs(n: in Int): Int
  ensures: result >= 0
  ensures: result == n or result == -n
```

`lyric prove` / `lyric prove --explain --goal N` / `lyric prove --json`

---

## Opaque types

```lyric
pub opaque type Account {
  id: AccountId
  balance: Cents
  invariant: balance >= 0 and balance <= 1_000_000_000_00

  pub func make(id: in AccountId, initial: in Cents): Result[Account, AccountError]
    requires: initial >= 0
  {
    return Ok(Account(id = id, balance = initial))
  }
}
```

- Body (fields + invariant) visible only inside the declaring package
- Outside the package: can declare variables, pass values, store in collections — cannot read fields, write fields, or construct directly
- `.NET` reflection cannot enumerate fields — the emitted type has no public properties and no accessible constructor
- Every value in existence was created through your constructor function — invariant holds structurally, not by convention
- Inside the package: fields accessible like an ordinary record

### `exposed record`

Where opaque hides everything, `exposed` reveals everything. Compiles to a plain .NET `record class` with public properties:

```lyric
pub exposed record TransferRequest @generate(Json) {
  fromId: Guid
  toId: Guid
  amountCents: Long
}
```

- Use for DTOs, wire formats (HTTP request/response bodies), log payloads, config records
- Cannot have `invariant:` clauses — external code constructs these, you cannot guarantee invariants hold
- `@generate(Json)` emits a compile-time JSON serializer (no reflection)

### Domain boundary pattern

```
JSON / HTTP → exposed record (unconstrained)
                  ↓  validate once in load() / parse()
              opaque type (all fields valid by construction)
                  ↓  flows through the application
          downstream functions receive valid values, no re-validation
```

### `@projectable` — generating views

```lyric
pub opaque type User @projectable {
  id: UserId
  email: Email
  createdAt: Instant
  passwordHash: PasswordHash @hidden    // excluded from projection
  invariant: email.isVerified or createdAt > now() - days(7)
}
```

The compiler generates:
- `exposed record UserView @generate(Json) { id: Guid; email: String; createdAt: String }` — non-hidden fields, opaque field types projected to their view counterparts
- `func User.toView(self: in User): UserView` — always safe, excludes `@hidden` fields
- `func UserView.tryInto(self: in UserView): Result[User, ContractViolation]` — runs invariant on reconstruction, returns `Result`

```lyric
val view: UserView = user.toView()   // safe
val roundTripped = view.tryInto()?   // validated reconstruction
```

Adding a field to the opaque type automatically updates `UserView`, `toView()`, and `tryInto()` — no drift possible.

### `@projectionBoundary(asId)` — breaking cycles

When `@projectable` types reference each other, the compiler requires an explicit cycle break:

```lyric
pub opaque type Team @projectable {
  id: TeamId
  name: String
  members: slice[User] @projectionBoundary(asId)  // emits memberIds: slice[Guid] in TeamView
}

pub opaque type User @projectable {
  id: UserId
  email: String
  team: Team? @projectionBoundary(asId)            // emits teamId: Guid? in UserView
}
```

Without `@projectionBoundary`, the compiler reports the full cycle path and refuses to guess a default (E0501).

---

## Visibility

```lyric
pub func f(): Unit { ... }     // visible outside package
func g(): Unit { ... }         // package-private (default)

pub record Foo {
  pub x: Int    // field accessible outside
  y: Int        // field package-private
}

pub use Other.SomeName   // re-export
```

- No `internal`, no `protected`, no reflection escape hatch
- Package = visibility unit

---

## Async

```lyric
async func fetchUser(id: in UserId): User? {
  val response = await http.get("/users/${toString(id)}")
  return User.parseJson(response.body)
}
```

- `async func` / `await` — `await` is an expression, not a statement
- Calling async does not auto-await. Returns a task. Await explicitly or pass to `scope`.
- Async functions cannot have `out`/`inout` parameters crossing `await` points — use tuple/record return

### Sequential vs parallel

```lyric
// Sequential — each awaited before next starts
val a = await fetchA()
val b = await fetchB()

// Parallel — both tasks in flight
scope {
  val taskA = spawn fetchA()
  val taskB = spawn fetchB()
  val a = await taskA
  val b = await taskB
}
```

### `scope` and `spawn` (structured concurrency)

- Tasks spawned inside a `scope` cannot outlive it
- Scope does not exit until all spawned tasks complete or are cancelled
- If any spawned task fails: siblings are cancelled, first failure propagates, subsequent failures collected
- No fire-and-forget

### Cancellation

Every async function has an **implicit** cancellation token — not declared, not passed, cannot be forgotten.

```lyric
async func processItems(items: in slice[Item]): Unit {
  for item in items {
    cancellation.checkOrThrow()   // cooperative cancellation point
    await processOne(item)
  }
}
```

- `cancellation.checkOrThrow()` — raises `OperationCancelled` bug if cancelled
- Token propagates automatically to all async callees — entire async call tree shares one signal
- `await` expressions are also implicit cancellation points

### `protected type` (shared mutable state)

```lyric
protected type BoundedQueue[T] {
  var items: array[100, T]
  var count: Nat range 0 ..= 100

  invariant: count <= 100

  entry put(item: in T)
    when: count < 100
  {
    items[count] = item
    count += 1
  }

  entry take(): T
    when: count > 0
  {
    count -= 1
    return items[count]
  }
}
```

- `entry` operations are mutually exclusive — only one runs at a time
- `when:` — barrier condition. Caller blocks until condition is true (no spinning, no error)
- `invariant:` checked after every `entry` returns — violation terminates
- State is inaccessible from outside — no field access, no reflection
- No raw locks anywhere else in normal Lyric code

### Async generators

A function with `yield` is an async generator returning `IAsyncEnumerable[T]`:

```lyric
async func pagedItems(url: in String): Item {
  var page = 0
  loop {
    val result = await fetchPage(url, page)
    for item in result.items { yield item }
    if not result.hasMore { return }
    page = page + 1
  }
}

async func main(): Unit {
  for item in pagedItems("https://api.example.com/items") {
    println(item.name)
  }
}
```

### `defer`

```lyric
async func fetchOne(url: in String, sem: in Semaphore): PageResult {
  await sem.acquire()
  defer { sem.release() }   // runs on scope exit regardless of how (return, error, bug)
  // ...
}
```

- Multiple `defer` blocks execute in reverse declaration order (last declared, first executed)

---

## Interfaces and implementations

```lyric
pub interface AccountRepository {
  async func findById(id: in AccountId): Account?
  async func saveAll(accounts: in slice[Account]): Unit
}

impl AccountRepository for PostgresAccountRepository {
  async func findById(id: in AccountId): Account? { ... }
  async func saveAll(accounts: in slice[Account]): Unit { ... }
}
```

- `impl Interface for Type` — provides all methods declared in interface
- Synchronous function satisfying an `async`-declared method is **lifted automatically** (no `Task.fromValue` boilerplate)

---

## Dependency injection (wire blocks)

```lyric
wire ProductionApp {
  @provided config: AppConfig               // parameter to bootstrap function
  @provided cancellationToken: CancellationToken

  singleton clock: Clock = SystemClock.make()
  singleton db: DatabasePool = DatabasePool.make(config.dbUrl, config.dbPoolSize)

  scoped[Request] dbConnection: DatabaseConnection = db.acquire()

  bind AccountRepository -> PostgresAccountRepository.make(dbConnection)
  bind Clock -> clock

  singleton transferService: TransferService =
      TransferService.make(AccountRepository, Clock)

  expose transferService
}

func main(): Unit {
  val config = unwrapResult(AppConfig.load(RawConfig.readFromEnvironment()))
  val app = ProductionApp.bootstrap(config, CancellationToken.none())
  HttpServer.run(app.transferService, config.port)
}
```

### Wire declaration kinds

| Declaration | Meaning |
|-------------|---------|
| `@provided name: T` | External value — becomes a parameter to `bootstrap()` |
| `singleton name: T = expr` | Constructed once per wire instance, cached |
| `scoped[X] name: T = expr` | Constructed once per scope of type X |
| `bind I -> impl` | Registers `impl` as the resolution for interface `I` |
| `expose name` | Makes a value accessible from outside the wire instance |

### Built-in scope kinds: `[Request]`, `[Transaction]`, `[Session]`

Custom scopes: `scope_kind Tenant` — then use `scoped[Tenant]`.

### Compile-time checks

The compiler verifies:
1. **All dependencies satisfied** — missing `bind` is a compile error naming the unsatisfied dependency
2. **No cycles** — reports full cycle path
3. **No lifetime violations** — `singleton` cannot depend on `scoped[X]` (captive dependency = compile error)
4. **All `bind` targets implement the interface** — checked structurally

### Test wires

```lyric
@test_module
package TransferService

wire TestWire {
  @provided alice: Account
  @provided bob: Account
  @provided fixedNow: Instant

  singleton accounts: AccountRepository =
      AccountRepositoryStub.recording()
          .returning {
            it.findById(alice.id) -> Some(alice)
            it.findById(bob.id)   -> Some(bob)
          }

  singleton clock: Clock = ClockStub.returning { it.now() -> fixedNow }
  singleton svc: TransferService = TransferService.make(accounts, clock)

  expose svc
  expose accounts    // tests inspect the recording
}
```

Test wires are just `wire` blocks in `@test_module` packages. Stubs are generated by `@stubbable` on interfaces. Stub signatures are statically typed — changing an interface signature breaks the stub at compile time.


---

## Runtime configuration

```lyric
config Server {
  host: String                = "0.0.0.0"
  port: Int range 1 ..= 65535 = 8080
}

config Connection {
  url:      String             // required — no default; process panics at startup if env var absent
  poolSize: Int range 1 ..= 100 = 10
  @sensitive
  password: String = ""        // value suppressed in logs/diagnostics
}
```

- `config` declares a typed, env-var-backed config block
- Fields without `= default` are **required** — process panics at startup if the env var is absent
- Range constraints enforced at startup (out-of-range = treated as missing required field)
- `@sensitive` suppresses display in logs and config dumps; value still read normally
- Fields are read-only at runtime

### Env var naming

`LYRIC_CONFIG_<PACKAGE>_<BLOCK>_<FIELD>` — all uppercase, package separators become `_`

| Package | Block | Field | Env var |
|---------|-------|-------|---------|
| `Web` | `Server` | `port` | `LYRIC_CONFIG_WEB_SERVER_PORT` |
| `Db` | `Connection` | `poolSize` | `LYRIC_CONFIG_DB_CONNECTION_POOLSIZE` |

### Reading config

```lyric
// Inside the same package — access as BlockName.fieldName
func connectDb(): Result[DbConnection, DbError] {
  DbKernel.connect(Connection.url, Connection.poolSize)
}
```

**Config vs wire:** `config` is for scalar primitives from env vars. `wire` is for constructed objects and DI. The two are complementary.

---

## FFI and interop

Lyric runs on .NET. All BCL interop is explicit — no implicit calls to platform types.

### `extern package` + `@axiom`

```lyric
@axiom("System.IO.File operations conform to the .NET BCL contract")
extern package System.IO {
  pub func readAllText(path: in String): String
    requires: path.length > 0

  pub func writeAllBytes(path: in String, bytes: in slice[Byte]): Unit
    requires: path.length > 0

  pub func exists(path: in String): Bool
}
```

- `@axiom` string is recorded in `.lyric-contract` metadata — it is a human-readable trust commitment, not a comment
- `requires:`/`ensures:` inside extern are **axioms** — the prover treats them as facts, does not check them
- Wrong axioms produce wrong proofs — be conservative on `ensures:`, precise on `requires:`

### Static vs instance extern calls

```lyric
@externTarget("System.Math.Abs")
@externStatic
pub func mathAbs(n: in Int): Int
  ensures: result >= 0

@externTarget("System.String.Trim")
@externInstance
pub func strTrim(s: in String): String
```

- `@externStatic` → `call` / `invokestatic`
- `@externInstance` → `callvirt` / `invokevirtual`, arg 0 is the receiver
- Default (neither) = static on .NET target

### `extern type` (lighter form)

```lyric
extern type Math = "System.Math"
extern type Ts   = "System.TimeSpan"

Math.Max(2, 5)                                  // resolves against real BCL metadata
Ts.Compare(Ts.FromMinutes(5.0), Ts.FromMinutes(3.0))
Typ.GetType("System.Int32").ToString()          // instance call on class-typed result
```

- Resolves against real .NET reference assemblies at compile time — no hand-written signature drift
- No `@axiom` block needed — trusting the named method's documented BCL behaviour
- Fully AOT-compatible (statically-emitted `MemberRef`)
- Unresolvable target = compile-time error on .NET target

### Wrapping the boundary

```lyric
@runtime_checked
package Fs

import System.IO as Sys

pub union FsError {
  case NotFound(path: String)
  case IoError(path: String, message: String)
}

pub func readBytes(path: in String): Result[slice[Byte], FsError]
  requires: path.length > 0
{
  if not Sys.exists(path) { return Err(NotFound(path)) }
  return try {
    Ok(Sys.readAllBytes(path))
  } catch Bug as b {
    Err(IoError(path, b.message))
  }
}
```

- `try { } catch Bug as b` converts platform exceptions into typed `Result` at the boundary
- Isolation: the `@axiom` block stays in one file; callers above it see only `Result`
- This is exactly how `Std.File`, `Std.Http`, `Std.Time` are built

### Cross-boundary marshalling

| Direction | Rule |
|-----------|------|
| Lyric → .NET | Opaque types pass as sealed handles (no public fields, no accessible constructors). Exposed records pass as `.NET record class`. Primitives map directly. Slices → arrays. |
| .NET → Lyric | Arrives as exposed record by default. To wrap into opaque type: explicit constructor returning `Result` — no implicit coercion. |

### AOT

All Lyric code is AOT-compatible. No `System.Reflection.Emit`, no `Activator.CreateInstance`, no runtime type introspection. `lyric build --aot` produces a self-contained native binary.

**No reflection** — required by opaque type guarantees and AOT. Source generators (`@generate`) are the compile-time alternative.

### Std.Bcl wrappers (use these first)

| Module | Wraps |
|--------|-------|
| `Std.File` | `System.IO.File` |
| `Std.Http` | `System.Net.Http.HttpClient` |
| `Std.Time` | `System.DateTime`, `System.DateTimeOffset` |
| `Std.Random` | `System.Random` |

---

## Aspects

Aspects apply cross-cutting behaviour to a matched set of functions — written once, no call-site boilerplate.

```lyric
aspect Logging {
  matches: name like "handle*"

  around(args) -> ret {
    Std.Log.info("→ entering handler")
    proceed(args)
    Std.Log.info("← exiting handler")
  }
}
```

- Aspects are package-private: weave over functions in the **same package only**
- `matches:` determines which functions are selected
- `around(args) -> ret` is the advice body; `ret` binds to the return value
- `proceed(args)` calls the original function with the original arguments

### `matches:` predicates

| Predicate | Selects when |
|-----------|-------------|
| `name like "<glob>"` | Short name matches glob (`*` any sequence, `?` one char) |
| `annotated: @Name` | Function carries the named annotation |
| `visibility: pub \| priv \| internal` | Function has that access level |
| `signature: returns "<glob>"` | Return type matches glob |

Predicates joined by `and`. Optional `except name in { fn1, fn2 }` to exclude specific functions.

### `proceed(args)` patterns

```lyric
// Before/after
around(args) -> ret {
  before()
  proceed(args)
  after()
}

// Early return (skip target)
around(args) -> ret {
  if cache.has(key) { return cache.get(key) }
  proceed(args)
}

// Retry
around(args) -> ret {
  var i = 0
  while i < 3 { proceed(args); i = i + 1 }
}
```

### Composition ordering

```lyric
aspect Auth {
  matches: name like "handle*"
  wraps: Logging    // Auth is outside Logging — Auth runs first

  around(args) -> ret {
    if not AuthStore.verify() { return Result.err(AuthError.unauthorized()) }
    proceed(args)
  }
}
```

- `wraps: Other` — this aspect is outside Other (runs first)
- `inside: Other` — this aspect is inside Other (runs after)
- Default: lexical declaration order, first = outermost
- Cycle in ordering constraints = compile error

### Opt-out

```lyric
@no_aspect
pub func handleHealth(): HealthStatus { ... }          // excluded from ALL aspects

@no_aspect("Logging")
pub func handleMetrics(): MetricsPayload { ... }       // excluded from Logging only
```

### Contract augmentation

Aspects can add `requires:`/`ensures:` clauses — composed additively with the function's own. Aspects cannot remove or weaken existing contracts.

### Not yet implemented

- `call` context (`call.shortName`, `call.sourceLocation`, `call.elapsed` etc.) — partly wired, `call.caller` not implemented (emits A0043)
- `config {}` injection in aspect bodies — A0044 diagnostic for fields without defaults
- `@inline_template` C-mode — A0042 for mismatched field names


---

## Testing

### `@test_module`

```lyric
@test_module
package MyServiceTests
import Std.Testing
import MyService.{MyService}

test "description" {
  val result = myService.doThing()
  assertTrue(isOk(result), "should succeed")
}
```

- `@test_module` marks a package as test-only — invisible to production builds
- `test "name" { ... }` declares a test block
- `await` works inside test blocks — no special annotations needed
- Run: `lyric test` / `lyric test --filter "substring"` / `lyric test --fail-fast`

### Assertions (`Std.Testing`)

```lyric
assertTrue(condition, "message")
assertFalse(condition, "message")
assertEqualInt(actual, expected, "message")
assertEqual(actual, expected)
expect(condition)          // fails test if false
isOk(result): Bool         // for use with assertTrue
unwrapResult(result): T    // panics on Err — use in setup, not assertions
```

### `@stubbable` interfaces

```lyric
@stubbable
pub interface AccountRepository {
  async func findById(id: in AccountId): Account?
  async func saveAll(accounts: in slice[Account]): Unit
}
```

Generates `AccountRepositoryStub` in the same package. Import alongside the interface:

```lyric
import Repositories.{AccountRepository, AccountRepositoryStub}
```

### Stub builders

```lyric
// Fixed return values — typed proxy, cases tested top-to-bottom
val repoStub = AccountRepositoryStub.returning {
  it.findById(alice.id) -> Some(alice)
  it.findById(bob.id)   -> Some(bob)
  it.findById(_)        -> None      // wildcard
}

// Recording + fixed returns
val repoStub = AccountRepositoryStub.recording()
    .returning {
      it.findById(alice.id) -> Some(alice)
      it.findById(_)        -> None
    }

// Always-failing stubs
val failingRepo = AccountRepositoryStub.failing {
  it.findById(_)  -> Err(DatabaseError("connection refused"))
}
```

- `it.method(args) -> value` — left side is a typed call (compile error if wrong types), right side is the return value
- Unmatched call (no case matches) → raises `Bug` and fails the test immediately
- `.recording()` alone with no `.returning` chain → raises `Bug` on any call (verify method is never called)

### Asserting on recorded calls

```lyric
val calls = repoStub.recorded("saveAll")   // slice of call records
assertEqualInt(calls.length, 1, "saveAll called once")

// Inspect arguments
val savedAccounts = calls[0].args[0] as slice[Account]
assertEqualInt(savedAccounts.length, 2, "two accounts saved")
```

- `.recorded("methodName")` returns `slice` of call records (empty slice if never called — does not fail)
- Each record: `.args: slice[Any]` (positional), `.callIndex: Int` (order across all methods on stub)
- `as T` cast needed — compiler cannot verify statically; raises `Bug` if cast fails

### Test wires

```lyric
@test_module
package TransferServiceTests

wire TestWire {
  @provided alice: Account
  @provided bob: Account
  @provided fixedNow: Instant

  singleton accounts: AccountRepository =
      AccountRepositoryStub.recording()
          .returning {
            it.findById(alice.id) -> Some(alice)
            it.findById(bob.id)   -> Some(bob)
          }

  singleton clock: Clock =
      ClockStub.returning { it.now() -> fixedNow }

  singleton svc: TransferService = TransferService.make(accounts, clock)

  expose svc
  expose accounts
}

test "transfer saves both accounts" {
  val w = TestWire.bootstrap(alice, bob, now)
  val result = await transfer(w.svc, alice.id, bob.id, amount, key)
  assertTrue(isOk(result), "transfer should succeed")
  assertEqualInt(w.accounts.recorded("saveAll").length, 1, "saveAll called once")
}
```

- Each `bootstrap(...)` call = fresh, independent wire instance with new stub state — no leakage between tests
- `@provided` values captured in `.returning` blocks — compiler verifies types
- Interface signature change = compile error in stub config, not a runtime surprise

---

## Modules / packages

- Package = directory
- No circular package dependencies
- Contract artifact: `<package>.lyric-contract` — downstream compiles against this, not source
- `pub use` for re-exports
- `lyric.toml` for project manifest and dependencies

---

## Annotations reference

| Annotation | Purpose |
|-----------|---------|
| `@valueType` | Emit record as .NET `readonly struct` |
| `@test_module` | Marks a test file |
| `@bench_module` | Marks a benchmark file |
| `@proof_required` | Enable SMT verification for package |
| `@runtime_checked` | Contract violations panic (default) |
| `@stubbable` | Interface can be stubbed in tests |
| `@projectable` | Opaque type fields readable outside package |
| `@projectionBoundary` | Cycle-breaking for projections |
| `@axiom` | Mark an extern function as trusted (FFI) |
| `@generate` | Source generator invocation |
| `@pure` | Function has no side effects (for use in contracts/lemmas) |

---

## String literals

```lyric
"Hello, ${name}!"          // interpolation with ${expr}
r"C:\path\no\escapes"      // raw string
r#"contains "quotes""#     // raw string with hash delimiters
"""
  multiline
  strips leading whitespace to closing indentation
"""
```

---

## lyric.toml structure

```toml
[package]
name = "MyApp"
version = "0.1.0"

[project]
# file_layout = "split"   # optional: .lspec/.lbody split mode

[dependencies]
lyric-web = "^1.0"
lyric-db  = "^1.0"
```
