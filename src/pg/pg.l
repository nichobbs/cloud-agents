//! CloudAgents.Pg — Postgres connection and unit-of-work primitives for the
//! phase 11 store (docs/phase11-postgres-tenancy.md §5.2, §4.3a).
//!
//! Isolation is enforced by Postgres row-level security keyed on two
//! transaction-local settings, `app.current_tenant` and `app.current_user`.
//! Every unit of work that touches tenant-owned data runs inside a
//! transaction that first sets them from an explicit `TenantScope`; a unit
//! that touches only user-owned data (sign-in, membership sync) sets
//! `app.current_user` alone from a `UserScope`.
//!
//! Scopes are explicit values, never ambient state: the thread-local slot
//! `CloudAgents.Auth.currentUserId` uses is lost once an `await` resumes on
//! another thread, and it falls back to the operator identity when unset,
//! either of which would silently widen a query's scope. A scope with an empty
//! id is rejected here, before any SQL runs.
//!
//! Settings are always set with `is_local = true`, so they end with the
//! transaction and cannot leak to the next borrower of a pooled connection.
//! (A pooled connection that has used a setting reads it back as `''`, not
//! NULL; the schema's policies use `NULLIF(..., '')` for exactly that reason,
//! see `CloudAgents.Pg.Schema`.)
@runtime_checked
package CloudAgents.Pg

import Std.Core
import Std.Environment
import Db

/// The tenant and user a unit of work acts for. Constructed only by the auth
/// middleware (from a validated membership), the callback-token resolver, a
/// maintenance claim, or the SQLite export (spec §5.2).
pub record TenantScope {
  pub tenantId: String
  pub userId: String
}

/// The user a unit of work acts for when it touches only user-owned data
/// (spec §4.3a): no tenant is set, so tenant-owned tables stay invisible.
pub record UserScope {
  pub userId: String
}

pub union PgError {
  // A scope with an empty tenant or user id: rejected before any SQL runs.
  case InvalidScope(message: String)
  case Connect(message: String)
  case Query(message: String)
}

pub func pgErrorMessage(e: in PgError): String {
  return match e {
    case InvalidScope(m) -> "invalid scope: " + m
    case Connect(m) -> "database connection failed: " + m
    case Query(m) -> "database query failed: " + m
  }
}

/// The implicit personal tenant of a user (spec §6.1, §9 slice B): every user
/// has exactly one, and its id is derived from the user id so the SQLite-era
/// code, the export and the organisation code all agree on it.
pub func personalTenantId(userId: in String): String {
  return "personal:" + userId
}

/// The DSN the service connects with (`cloudagents_app`).
pub func serviceDsnVar(): String {
  return "LYRIC_CONFIG_DB_CONNECTION_URL"
}

/// The DSN `--migrate` connects with (`cloudagents_owner`).
pub func migrateDsnVar(): String {
  return "CLOUD_AGENTS_MIGRATE_DATABASE_URL"
}

/// True when the service is configured to use Postgres.
pub func serviceConfigured(): Bool {
  return Std.Environment.getVarOrDefault(serviceDsnVar(), "").length.toInt() > 0
}

/// Open a pooled service connection from `LYRIC_CONFIG_DB_CONNECTION_URL`.
pub func connectService(): Result[DbConnection, PgError] {
  return match Db.connectFromEnv() {
    case Ok(c) -> Ok(value = c)
    case Err(e) -> Err(error = Connect(message = e.message))
  }
}

/// Open a connection from an explicit DSN (the migration and export roles).
pub func connectDsn(dsn: in String): Result[DbConnection, PgError] {
  if dsn.length.toInt() == 0 {
    return Err(error = Connect(message = "no DSN configured"))
  }
  return match Db.connectPostgres(dsn, 2, 5000, "") {
    case Ok(c) -> Ok(value = c)
    case Err(e) -> Err(error = Connect(message = e.message))
  }
}

func setTenantSql(): String {
  return "SELECT set_config('app.current_tenant', @p0, true), set_config('app.current_user', @p1, true)"
}

func setUserSql(): String {
  return "SELECT set_config('app.current_user', @p0, true)"
}

/// Validate a tenant scope; the error names which id is missing.
pub func checkTenantScope(sc: in TenantScope): Result[Unit, PgError] {
  if sc.tenantId.length.toInt() == 0 {
    return Err(error = InvalidScope(message = "empty tenant id"))
  }
  if sc.userId.length.toInt() == 0 {
    return Err(error = InvalidScope(message = "empty user id"))
  }
  return Ok(value = ())
}

/// Validate a user scope.
pub func checkUserScope(sc: in UserScope): Result[Unit, PgError] {
  if sc.userId.length.toInt() == 0 {
    return Err(error = InvalidScope(message = "empty user id"))
  }
  return Ok(value = ())
}

func beginRaw(conn: in DbConnection): Result[DbTransaction, PgError] {
  return match conn.transaction() {
    case Ok(tx) -> Ok(value = tx)
    case Err(e) -> Err(error = Query(message = e.message))
  }
}

/// Start a tenant-scoped unit of work on `conn`. The scope is validated
/// before anything is sent to the server. The caller must `commitUnit` or
/// `rollbackUnit` the returned transaction.
pub func beginTenantUnit(conn: in DbConnection, sc: in TenantScope): Result[DbTransaction, PgError] {
  checkTenantScope(sc)?
  val tx = beginRaw(conn)?
  match tx.query(setTenantSql(), [sc.tenantId, sc.userId]) {
    case Ok(_) -> ()
    case Err(e) -> {
      rollbackUnit(tx)
      return Err(error = Query(message = e.message))
    }
  }
  return Ok(value = tx)
}

/// Start a user-scoped unit of work on `conn` (user-owned tables only).
pub func beginUserUnit(conn: in DbConnection, sc: in UserScope): Result[DbTransaction, PgError] {
  checkUserScope(sc)?
  val tx = beginRaw(conn)?
  match tx.query(setUserSql(), [sc.userId]) {
    case Ok(_) -> ()
    case Err(e) -> {
      rollbackUnit(tx)
      return Err(error = Query(message = e.message))
    }
  }
  return Ok(value = tx)
}

/// Start an unscoped transaction. Only for statements that need no tenant or
/// user (maintenance claim functions, global identity lookups); tenant- and
/// user-owned tables return no rows and reject writes inside it.
pub func beginUnscopedUnit(conn: in DbConnection): Result[DbTransaction, PgError] {
  return beginRaw(conn)
}

pub func commitUnit(tx: in DbTransaction): Result[Unit, PgError] {
  return match tx.commit() { case Ok(_) -> Ok(value = ()); case Err(e) -> Err(error = Query(message = e.message)) }
}

/// Roll back, ignoring errors: used on paths that are already failing.
pub func rollbackUnit(tx: in DbTransaction): Unit {
  match tx.rollback() {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

/// Run a statement inside a unit, mapping the error.
pub func execIn(tx: in DbTransaction, sql: in String, params: in slice[String]): Result[Int, PgError] {
  return match tx.execute(sql, params) {
    case Ok(n) -> Ok(value = n)
    case Err(e) -> Err(error = Query(message = e.message))
  }
}

/// Run a query inside a unit, mapping the error.
pub func queryIn(tx: in DbTransaction, sql: in String, params: in slice[String]): Result[slice[DbRow], PgError] {
  return match tx.query(sql, params) {
    case Ok(rows) -> Ok(value = rows)
    case Err(e) -> Err(error = Query(message = e.message))
  }
}
