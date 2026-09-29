//! CloudAgents.Pg.SelfCheck — the startup check that the service's Postgres
//! role cannot defeat row-level security (docs/phase11-postgres-tenancy.md
//! §5.1, §8).
//!
//! `FORCE ROW LEVEL SECURITY` binds a table's owner but not a superuser or a
//! `BYPASSRLS` role, so a service connected as any of those would pass every
//! isolation test vacuously. The service therefore refuses to start unless:
//! - its role is not a superuser, has no `BYPASSRLS`, and owns no table in
//!   `public` (and not the schema itself);
//! - the provisioned roles exist (`deploy/postgres/provision.sql`);
//! - it is not a member (directly or indirectly) of `cloudagents_owner`,
//!   `cloudagents_claimer`, `cloudagents_migrator`, or any superuser or
//!   `BYPASSRLS` role, which would let it switch to that role;
//! - the claim-function owner `cloudagents_claimer` cannot log in, and the
//!   export role `cloudagents_migrator` cannot either (it may only log in
//!   during the one-off cut-over export);
//! - the schema is at the version this build expects (`--migrate` has run).
//! Each failure names what is wrong and where to fix it.
@runtime_checked
package CloudAgents.Pg.SelfCheck

import Std.Core
import Db
import CloudAgents.Pg
import CloudAgents.Pg.Schema

func one(conn: in DbConnection, sql: in String): Result[Option[DbRow], String] {
  return match conn.query(sql, []) {
    case Ok(rows) -> if rows.length > 0 then Ok(value = Some(value = rows[0])) else Ok(value = None)
    case Err(e) -> Err(error = "self-check query failed: " + e.message)
  }
}

func flag(row: in DbRow, name: in String): Bool {
  return Db.dbGetString(row, name) == "t" or Db.dbGetString(row, name) == "true" or Db.dbGetString(row, name) == "True"
}

func provisionHint(): String {
  return " (see deploy/postgres/provision.sql and docs/phase11-postgres-tenancy.md §8)"
}

/// Check the connected role and database. `Ok(())` means safe to serve.
pub func check(conn: in DbConnection): Result[Unit, String] {
  val me = match one(conn, "SELECT current_user::text AS name, rolsuper::text AS su, rolbypassrls::text AS bypass " + "FROM pg_roles WHERE rolname = current_user")? {
    case Some(r) -> r
    case None -> return Err(error = "cannot read the service role from pg_roles")
  }
  val name = Db.dbGetString(me, "name")
  if flag(me, "su") {
    return Err(error = "service role '" + name + "' is a superuser, which bypasses row-level security" + provisionHint())
  }
  if flag(me, "bypass") {
    return Err(error = "service role '" + name + "' has BYPASSRLS" + provisionHint())
  }
  val owned = match one(conn, "SELECT count(*)::text AS n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " + "WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND c.relowner = " + "(SELECT oid FROM pg_roles WHERE rolname = current_user)")? {
    case Some(r) -> Db.dbGetString(r, "n")
    case None -> "0"
  }
  if owned != "0" {
    return Err(
      error = "service role '" + name + "' owns " + owned +
        " table(s); tables must be owned by cloudagents_owner (run --migrate as that role)" +
        provisionHint()
    )
  }
  val schemaOwner = match one(conn, "SELECT pg_get_userbyid(nspowner)::text AS o FROM pg_namespace WHERE nspname = 'public'")? {
    case Some(r) -> Db.dbGetString(r, "o")
    case None -> ""
  }
  if schemaOwner == name {
    return Err(error = "service role '" + name + "' owns schema public" + provisionHint())
  }
  for role in ["cloudagents_owner", "cloudagents_claimer", "cloudagents_migrator"] {
    val found = match conn.query("SELECT rolcanlogin::text AS login FROM pg_roles WHERE rolname = @p0", [role]) {
      case Ok(rows) -> rows
      case Err(e) -> return Err(error = "self-check query failed: " + e.message)
    }
    if found.length == 0 {
      return Err(error = "required role '" + role + "' does not exist" + provisionHint())
    }
    if role == "cloudagents_migrator" and flag(found[0], "login") {
      return Err(
        error = "cloudagents_migrator can log in; it may only do so during the cut-over export " +
          "(ALTER ROLE cloudagents_migrator NOLOGIN)" +
          provisionHint()
      )
    }
    if role == "cloudagents_claimer" and flag(found[0], "login") {
      return Err(
        error = "cloudagents_claimer can log in; it must only be reachable through the claim functions " +
          "(ALTER ROLE cloudagents_claimer NOLOGIN)" +
          provisionHint()
      )
    }
  }
  // Membership, direct or indirect, in a privileged role would let the
  // service SET ROLE to it (or inherit it), bypassing the checks above.
  val privileged = match one(conn, "SELECT coalesce(string_agg(r.rolname, ', ' ORDER BY r.rolname), '') AS v FROM pg_roles r " + "WHERE r.rolname <> current_user AND pg_has_role(current_user, r.oid, 'MEMBER') " + "AND (r.rolsuper OR r.rolbypassrls OR r.rolname IN " + "('cloudagents_owner', 'cloudagents_claimer', 'cloudagents_migrator'))")? {
    case Some(r) -> Db.dbGetString(r, "v")
    case None -> ""
  }
  if privileged != "" {
    return Err(
      error = "service role '" + name + "' is a member of privileged role(s): " + privileged +
        "; revoke that membership" +
        provisionHint()
    )
  }
  val want = CloudAgents.Pg.Schema.latestVersion()
  val have = match one(conn, "SELECT coalesce(max(version), '') AS v FROM public.schema_migrations") {
    case Ok(Some(r)) -> Db.dbGetString(r, "v")
    case Ok(None) -> ""
    case Err(e) -> return Err(
      error = "cannot read public.schema_migrations (" + e + "); run CloudAgents.dll --migrate with " +
        CloudAgents.Pg.migrateDsnVar() +
        " set, and check the service role's grants" +
        provisionHint()
    )
  }
  if have != want {
    return Err(
      error = "database schema is at '" + have + "' but this build expects '" + want +
        "'; run CloudAgents.dll --migrate with " +
        CloudAgents.Pg.migrateDsnVar() +
        " set"
    )
  }
  return Ok(value = ())
}
