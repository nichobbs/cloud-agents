//! CloudAgents.Pg.Migrate — the Postgres migration runner behind
//! `CloudAgents.dll --migrate` (docs/phase11-postgres-tenancy.md §4.1, §5.1).
//!
//! Runs as `cloudagents_owner` (DSN `CLOUD_AGENTS_MIGRATE_DATABASE_URL`) so
//! every object it creates is owned by that role, never by the service role:
//! a service that owned its tables could not be held to row-level security
//! reliably. It refuses to run as any other role for the same reason.
//!
//! Each migration's statements and its `schema_migrations` row are applied in
//! one transaction (Postgres DDL is transactional), under a transaction-scoped
//! advisory lock, so a failure leaves the database at the previous version and
//! two concurrent runs cannot interleave. Re-running is a no-op.
@runtime_checked
package CloudAgents.Pg.Migrate

import Std.Core
import Db
import CloudAgents.Pg
import CloudAgents.Pg.Schema

/// Arbitrary constant for pg_advisory_xact_lock, unique to this runner.
func lockSql(): String {
  return "SELECT pg_advisory_xact_lock(7314250981)"
}

func ledgerSql(): String {
  return "CREATE TABLE IF NOT EXISTS public.schema_migrations (" + "version text PRIMARY KEY, " +
    "applied_at timestamptz NOT NULL DEFAULT now())"
}

pub func requiredRole(): String {
  return "cloudagents_owner"
}

func currentRole(conn: in DbConnection): Result[String, CloudAgents.Pg.PgError] {
  return match conn.query("SELECT current_user::text AS r", []) {
    case Ok(rows) -> if rows.length > 0 then Ok(value = Db.dbGetString(rows[0], "r")) else Ok(value = "")
    case Err(e) -> Err(error = CloudAgents.Pg.Query(message = e.message))
  }
}

func applied(tx: in DbTransaction, version: in String): Result[Bool, CloudAgents.Pg.PgError] {
  val rows = CloudAgents.Pg.queryIn(tx, "SELECT 1 AS x FROM public.schema_migrations WHERE version = @p0", [version])?
  return Ok(value = rows.length > 0)
}

/// Apply one migration if it is not already recorded. Returns whether it ran.
func applyOne(conn: in DbConnection, m: in CloudAgents.Pg.Schema.PgMigration): Result[Bool, CloudAgents.Pg.PgError] {
  val tx = CloudAgents.Pg.beginUnscopedUnit(conn)?
  match applyInTx(tx, m) {
    case Ok(ran) -> {
      CloudAgents.Pg.commitUnit(tx)?
      return Ok(value = ran)
    }
    case Err(e) -> {
      CloudAgents.Pg.rollbackUnit(tx)
      return Err(error = e)
    }
  }
}

func applyInTx(tx: in DbTransaction, m: in CloudAgents.Pg.Schema.PgMigration): Result[Bool, CloudAgents.Pg.PgError] {
  CloudAgents.Pg.queryIn(tx, lockSql(), [])?
  CloudAgents.Pg.execIn(tx, ledgerSql(), [])?
  if applied(tx, m.version)? {
    return Ok(value = false)
  }
  for stmt in m.statements {
    match tx.execute(stmt, []) {
      case Ok(_) -> ()
      case Err(e) -> return Err(error = CloudAgents.Pg.Query(message = m.version + ": " + e.message))
    }
  }
  CloudAgents.Pg.execIn(tx, "INSERT INTO public.schema_migrations (version) VALUES (@p0)", [m.version])?
  return Ok(value = true)
}

/// Bring the database to the latest schema version. Returns the versions
/// applied by this call (empty when already current).
pub func migrate(conn: in DbConnection): Result[slice[String], CloudAgents.Pg.PgError] {
  val role = currentRole(conn)?
  if role != requiredRole() {
    return Err(
      error = CloudAgents.Pg.Query(
        message = "migrations must run as " + requiredRole() + " (connected as '" + role + "'); set " +
          CloudAgents.Pg.migrateDsnVar() +
          " to that role's DSN"
      )
    )
  }
  var ran: slice[String] = []
  for m in CloudAgents.Pg.Schema.migrations() {
    if applyOne(conn, m)? {
      ran = ran.append(m.version)
    }
  }
  return Ok(value = ran)
}
