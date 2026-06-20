# Lyric Idioms

Canonical patterns. Follow these unless you have a specific reason not to.

---

## Domain types first

Before writing any logic, declare your domain types:

```lyric
type UserId   = Long derives Compare, Hash
type OrderId  = Long derives Compare, Hash
type Cents    = Long range 0 ..= 100_000_000_000 derives Add, Sub, Compare
type Email    = String derives Equals, Hash  // or opaque type for validation

// Not:
func processOrder(userId: Long, orderId: Long, amount: Long) // untyped, dangerous
// Yes:
func processOrder(userId: in UserId, orderId: in OrderId, amount: in Cents) // typed
```

---

## Validate at boundaries, trust inside

Validate at the entry point (API boundary, CLI args, config), propagate the validated type:

```lyric
// At the boundary:
val age = Age.tryFrom(rawAge)?   // Result propagates up; ? unwraps or returns Err

// Inside the domain — no re-validation needed:
func canVote(age: in Age): Bool = age.toInt() >= 18
```

---

## Result propagation with `?`

Chain `?` for clean error propagation:

```lyric
func createUser(req: in CreateRequest): Result[User, AppError] {
  val email = Email.tryFrom(req.email)?
  val age   = Age.tryFrom(req.age)?
  val id    = repo.nextId()?
  return Ok(User(id = id, email = email, age = age))
}
```

---

## Prefer `val`

Use `var` only when the algorithm genuinely requires mutation:

```lyric
// preferred
val result = computeThing(input)

// only when needed
var acc = 0
for x in xs { acc = acc + x }
```

---

## Named records over tuples for public APIs

```lyric
// ok internally
func minMax(xs: slice[Int]): (Int, Int) { ... }

// prefer for pub functions
pub record Bounds { min: Int; max: Int }
pub func bounds(xs: in slice[Int]): Bounds { ... }
```

---

## Opaque types for domain invariants

When a value has a non-trivial invariant, use `opaque type`:

```lyric
pub opaque type NonEmptyString {
  val raw: String
  invariant: raw.length > 0

  pub func from(s: in String): Result[NonEmptyString, String] {
    if s.length == 0 { return Err("must not be empty") }
    return Ok(NonEmptyString(raw = s))
  }

  pub func value(self: in NonEmptyString): String = self.raw
}
```

---

## Contracts on public functions

Add `requires:` and `ensures:` to `pub` functions where the constraints are non-obvious:

```lyric
pub func divide(a: in Int, b: in Int): Int
  requires: b != 0
{
  return a / b
}

pub func withdraw(amount: in Cents, balance: inout Cents)
  requires: amount <= balance
  ensures: balance == old(balance) - amount
{
  balance = balance - amount
}
```

---

## Pattern match exhaustively — don't reach for `case _`

```lyric
// Bad: silently ignores future cases
func describeStatus(s: in Status): String {
  return match s {
    case Active  -> "active"
    case _       -> "other"   // bad
  }
}

// Good: compiler catches new cases
func describeStatus(s: in Status): String {
  return match s {
    case Active   -> "active"
    case Inactive -> "inactive"
    case Pending  -> "pending"
  }
}
```

Use `case _ ->` only when you genuinely want to ignore future variants (rare).

---

## Interfaces for DI seams

```lyric
pub interface EmailSender {
  async func send(to: in Email, subject: in String, body: in String): Result[Unit, SendError]
}

@stubbable
pub interface UserRepo {
  async func findById(id: in UserId): Option[User]
  async func save(user: in User): Result[Unit, DbError]
}
```

Mark interfaces `@stubbable` when they need to be mocked in tests.

---

## Wire blocks at the app root

```lyric
wire AppWire {
  val db: DbConnection = PostgresConnection(config.dbUrl)
  val userRepo: UserRepo = PostgresUserRepo(db)
  val emailSender: EmailSender = SmtpSender(config.smtpHost)
  val userService: UserService = UserService(userRepo, emailSender)
}
```

---

## Test structure

```lyric
@test_module
package UserServiceTests
import Std.Core
import Testing.{assert, assertEqual}
import UserService.{UserService}

test "createUser returns Ok for valid input" {
  val stub = UserRepoStub.builder()
    .findById { _ -> None }
    .save { _ -> Ok(()) }
    .build()
  val svc = UserService(repo = stub)
  val result = svc.createUser(validRequest)
  assert(result is Ok)
}
```

---

## Use `Nat` for non-negative quantities

```lyric
record Pageable {
  page: Nat    // not Int
  pageSize: Nat range 1 ..= 100
}
```

---

## `match` shape for error unions

```lyric
func handleResult(r: Result[User, AppError]): String {
  return match r {
    case Ok(user)               -> "found: ${user.name}"
    case Err(NotFound(id))      -> "user ${toString(id)} not found"
    case Err(Unauthorised)      -> "access denied"
    case Err(DbError(msg))      -> "database error: ${msg}"
  }
}
```

---

## Config blocks for runtime config

```lyric
config AppConfig {
  dbUrl:    String
  port:     Int range 1 ..= 65535 = 8080
  apiKey:   String @sensitive
}
```

Environment variable naming: `APP_CONFIG_DB_URL`, `APP_CONFIG_PORT`, etc.
