//! CloudAgents.PgStore — shared plumbing for the Postgres implementations of
//! the store (docs/phase11-postgres-tenancy.md §9 slices B/C).
//!
//! Each `CloudAgents.PgStore.<Domain>` package mirrors the SQLite-backed
//! functions of `CloudAgents.Repository` for one domain, with the same
//! signatures (including the `CloudAgents.Sqlite.DbError` error type), so the
//! cut-over (slice E) is an import switch rather than a rewrite. Every call
//! is one unit of work on one pooled connection, scoped by the caller's
//! explicit `TenantScope` (spec §5.2).
//!
//! Lyric has no closures here, so each store function follows the same
//! shape: `open` a unit, `defer` its `release`, run statements with `q`/`ex`,
//! and `commit` before returning success. `release` after a commit is a
//! harmless no-op rollback.
@runtime_checked
package CloudAgents.PgStore

import Std.Core
import Db
import CloudAgents.Pg
import CloudAgents.Sqlite

pub record PgUnit {
  pub conn: DbConnection
  pub tx: DbTransaction
}

func toDbError(context: in String, e: in CloudAgents.Pg.PgError): CloudAgents.Sqlite.DbError {
  return match e {
    case InvalidScope(m) -> CloudAgents.Sqlite.ValidationFailed(message = "invalid scope: " + m)
    case Connect(m) -> CloudAgents.Sqlite.OpenFailed(message = m)
    case Query(m) -> CloudAgents.Sqlite.ExecFailed(sql = context, message = m)
  }
}

/// Open a tenant-scoped unit of work. The scope is validated before any SQL.
pub func open(sc: in CloudAgents.Pg.TenantScope): Result[PgUnit, CloudAgents.Sqlite.DbError] {
  match CloudAgents.Pg.checkTenantScope(sc) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = toDbError("scope", e))
  }
  val conn = match CloudAgents.Pg.connectService() {
    case Ok(c) -> c
    case Err(e) -> return Err(error = toDbError("connect", e))
  }
  match CloudAgents.Pg.beginTenantUnit(conn, sc) {
    case Ok(tx) -> return Ok(value = PgUnit(conn = conn, tx = tx))
    case Err(e) -> {
      conn.close()
      return Err(error = toDbError("begin", e))
    }
  }
}

/// Roll back (a no-op after commit) and return the connection to the pool.
pub func release(u: in PgUnit): Unit {
  CloudAgents.Pg.rollbackUnit(u.tx)
  u.conn.close()
}

pub func commit(u: in PgUnit): Result[Unit, CloudAgents.Sqlite.DbError] {
  return match CloudAgents.Pg.commitUnit(u.tx) {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = toDbError("commit", e))
  }
}

pub func q(u: in PgUnit, sql: in String, params: in slice[String]): Result[slice[DbRow], CloudAgents.Sqlite.DbError] {
  return match u.tx.query(sql, params) {
    case Ok(rows) -> Ok(value = rows)
    case Err(e) -> Err(error = CloudAgents.Sqlite.ExecFailed(sql = sql, message = e.message))
  }
}

pub func ex(u: in PgUnit, sql: in String, params: in slice[String]): Result[Int, CloudAgents.Sqlite.DbError] {
  return match u.tx.execute(sql, params) {
    case Ok(n) -> Ok(value = n)
    case Err(e) -> Err(error = CloudAgents.Sqlite.ExecFailed(sql = sql, message = e.message))
  }
}

/// A column as text; SQL NULL reads as "" (the store's "unset").
pub func col(row: in DbRow, name: in String): String {
  return match Db.dbGetStringOpt(row, name) { case Some(v) -> v; case None -> "" }
}
