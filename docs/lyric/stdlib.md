# Lyric Standard Library Reference

Full API: run `lyric doc` in the project to generate rendered docs from stdlib source.

---

## Import map

| Module | Import |
|--------|--------|
| Core (always available) | `import Std.Core` |
| Strings | `import Std.String` |
| Collections | `import Std.Collections` |
| Time | `import Std.Time` |
| File I/O | `import Std.File` |
| HTTP client | `import Std.Http` |
| REST client | `import Std.Rest` |

Builtins always available without import: `println`, `panic`, `assert`, `toString`.

---

## Std.Core

### Result[T, E]

```lyric
union Result[T, E] {
  case Ok(value: T)
  case Err(error: E)
}
```

Common operations:
```lyric
r.isOk(): Bool
r.isErr(): Bool
r.unwrap(): T                    // panics on Err
r.unwrapOr(default: T): T
r.map { v -> transform(v) }: Result[U, E]
r.mapErr { e -> transform(e) }: Result[T, F]
r.andThen { v -> other(v) }: Result[U, E]  // flatMap
```

### Option[T]

```lyric
union Option[T] {
  case Some(value: T)
  case None
}
```

Common operations:
```lyric
o.isSome(): Bool
o.isNone(): Bool
o.unwrap(): T                    // panics on None
o.unwrapOr(default: T): T
o.map { v -> transform(v) }: Option[U]
o.filter { v -> predicate(v) }: Option[T]
o.orElse { -> other() }: Option[T]
o.toResult(err: E): Result[T, E]
```

### Builtins

```lyric
println(msg: String): Unit
panic(msg: String): Never
assert(condition: Bool): Unit     // panics with assertion failure if false
assert(condition: Bool, msg: String): Unit
toString(x: T): String            // works on all primitives
```

---

## Std.String

```lyric
s.length: Nat
s.isEmpty(): Bool
s.contains(sub: String): Bool
s.startsWith(prefix: String): Bool
s.endsWith(suffix: String): Bool
s.toUpperCase(): String
s.toLowerCase(): String
s.trim(): String
s.trimStart(): String
s.trimEnd(): String
s.split(sep: String): slice[String]
s.replace(from: String, to: String): String
s.indexOf(sub: String): Option[Nat]
s.substring(start: Nat, end: Nat): String
s.chars(): slice[Char]
String.join(sep: String, parts: slice[String]): String

// Parsing
tryParseInt(s: String): Result[Int, ParseError]
tryParseLong(s: String): Result[Long, ParseError]
tryParseDouble(s: String): Result[Double, ParseError]
```

---

## Std.Collections

### Map[K, V]

```lyric
Map.empty[K, V](): Map[K, V]
Map.of(entries: slice[(K, V)]): Map[K, V]

m.get(key: K): Option[V]
m.put(key: K, value: V): Map[K, V]    // returns new map
m.remove(key: K): Map[K, V]
m.containsKey(key: K): Bool
m.keys(): slice[K]
m.values(): slice[V]
m.entries(): slice[(K, V)]
m.size: Nat
m.isEmpty(): Bool
```

### Set[T]

```lyric
Set.empty[T](): Set[T]
Set.of(items: slice[T]): Set[T]

s.contains(item: T): Bool
s.add(item: T): Set[T]
s.remove(item: T): Set[T]
s.union(other: Set[T]): Set[T]
s.intersect(other: Set[T]): Set[T]
s.difference(other: Set[T]): Set[T]
s.size: Nat
s.toSlice(): slice[T]
```

### slice[T] operations (from Std.Core)

```lyric
xs.map { x -> f(x) }: slice[U]
xs.filter { x -> pred(x) }: slice[T]
xs.reduce(init: U) { acc, x -> f(acc, x) }: U
xs.find { x -> pred(x) }: Option[T]
xs.any { x -> pred(x) }: Bool
xs.all { x -> pred(x) }: Bool
xs.count { x -> pred(x) }: Nat
xs.sortBy { x -> key(x) }: slice[T]
xs.sortedWith { a, b -> compare(a, b) }: slice[T]
xs.first(): Option[T]
xs.last(): Option[T]
xs.take(n: Nat): slice[T]
xs.drop(n: Nat): slice[T]
xs.zip(ys: slice[U]): slice[(T, U)]
xs.flatten(): slice[U]          // when T = slice[U]
xs.distinct(): slice[T]         // requires Equals derive
xs.groupBy { x -> key(x) }: Map[K, slice[T]]
xs.isEmpty(): Bool
xs.length: Nat
```

---

## Std.Time

```lyric
import Std.Time.{Instant, Duration, Clock}

// Instant
Instant.now(): Instant              // wall clock
i.plusSeconds(n: Long): Instant
i.plusMillis(n: Long): Instant
i.minusSeconds(n: Long): Instant
i.isBefore(other: Instant): Bool
i.isAfter(other: Instant): Bool
i.toEpochMillis(): Long
i.toEpochSeconds(): Long
Instant.fromEpochMillis(ms: Long): Instant

// Duration
Duration.ofSeconds(n: Long): Duration
Duration.ofMillis(n: Long): Duration
Duration.ofMinutes(n: Long): Duration
Duration.ofHours(n: Long): Duration
d.toSeconds(): Long
d.toMillis(): Long
i1 - i2: Duration                   // instant subtraction
i + d: Instant                      // instant + duration
```

---

## Std.File

```lyric
import Std.File.{File, Path}

File.read(path: String): Result[String, IoError]
File.readBytes(path: String): Result[slice[Byte], IoError]
File.write(path: String, content: String): Result[Unit, IoError]
File.writeBytes(path: String, bytes: slice[Byte]): Result[Unit, IoError]
File.exists(path: String): Bool
File.delete(path: String): Result[Unit, IoError]
File.listDir(path: String): Result[slice[String], IoError]
```

---

## Std.Http (client primitives)

```lyric
import Std.Http.{HttpClient, HttpRequest, HttpResponse, HttpError}

// Low-level client
val client = HttpClient.default()
val resp = await client.get("https://api.example.com/users")?
resp.status: Int
resp.body: String
resp.headers: Map[String, String]

await client.post(url, body: String)?
await client.put(url, body: String)?
await client.delete(url)?
```

---

## Std.Rest (typed REST client)

```lyric
import Std.Rest.{RestClient, RestError}

val client = RestClient.of("https://api.example.com")

// GET with typed response
val users = await client.get[slice[User]]("/users")?

// POST with typed body and response
val created = await client.post[CreateRequest, User]("/users", req)?
```

---

## JSON (via @generate)

```lyric
import Std.Core

@generate(Json)
pub record UserDto {
  id: Long
  name: String
  email: String
}

// Generated:
// UserDto.fromJson(s: String): Result[UserDto, JsonError]
// UserDto.toJson(self: UserDto): String
```

---

## Application libraries (add to lyric.toml)

### lyric-logging

```toml
[dependencies]
lyric-logging = "^1.0"
```

```lyric
import Std.Logging.{Logger, LogLevel}

val log = Logger.named("MyService")
log.info("user created", fields = [("userId", userId.toString())])
log.warn("slow query", fields = [("ms", ms.toString())])
log.error("request failed", fields = [("error", e.message())])
log.debug("processing item", fields = [("id", id.toString())])
```

### lyric-web (HTTP server)

```toml
[dependencies]
lyric-web = "^1.0"
```

```lyric
import Web.{Handler, Router, Request, Response, HttpError}

pub async func getUser(req: in Request): Result[Response, HttpError] {
  val id = req.pathParam("id").andThen { s -> UserId.tryFrom(tryParseLong(s)?) }?
  val user = await userService.findById(id)?
  return match user {
    case Some(u) -> Ok(Response.json(u.toJson()))
    case None    -> Err(HttpError.notFound("user not found"))
  }
}

val router = Router.new()
  .get("/users/:id", getUser)
  .post("/users", createUser)

val server = WebServer.bind(router, config.port)
await server.run()
```

### lyric-db (SQL)

```toml
[dependencies]
lyric-db = "^1.0"
```

```lyric
import Db.{DbConnection, DbError, Row}

val db: DbConnection = ...  // injected via wire

// Query
val rows = await db.query(
  "SELECT id, name, email FROM users WHERE active = $1",
  [DbValue.Bool(true)]
)?

for row in rows {
  val id    = row.getLong("id")?
  val name  = row.getString("name")?
  val email = row.getString("email")?
}

// DML
val affected = await db.execute(
  "UPDATE users SET active = $1 WHERE id = $2",
  [DbValue.Bool(false), DbValue.Long(userId.toLong())]
)?

// Transaction
await db.transaction { tx ->
  await tx.execute("INSERT INTO ...", [...])?
  await tx.execute("UPDATE ...", [...])?
  Ok(())
}?
```

### lyric-cache

```toml
[dependencies]
lyric-cache = "^1.0"
```

```lyric
import Cache.{Cache, CacheStore}

val cache: Cache = ...  // injected

await cache.get("key")?                   // Option[String]
await cache.set("key", value, ttl)?       // Unit
await cache.delete("key")?
await cache.getOrSet("key", ttl) { -> computeExpensive() }?
```

### lyric-otel (OpenTelemetry)

```toml
[dependencies]
lyric-otel = "^1.0"
```

```lyric
import OTel.{Tracer, Span}

val tracer: Tracer = ...  // injected

await tracer.span("operationName") { span ->
  span.setAttribute("userId", userId.toString())
  await doWork()
}
```

### lyric-health

```toml
[dependencies]
lyric-health = "^1.0"
```

```lyric
import Health.{HealthCheck, HealthStatus}

pub async func dbHealthCheck(): HealthStatus {
  val result = await db.query("SELECT 1", [])
  return match result {
    case Ok(_)  -> HealthStatus.healthy()
    case Err(e) -> HealthStatus.unhealthy("db: ${e.message()}")
  }
}
```
