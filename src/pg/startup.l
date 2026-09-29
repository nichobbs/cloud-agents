//! CloudAgents.Pg.Startup — process-level entry points for the Postgres store
//! (docs/phase11-postgres-tenancy.md §5.1, §8): the `--migrate` command and
//! the startup role self-check. Kept out of `main.l` so the CLI wiring there
//! stays a few lines.
@runtime_checked
package CloudAgents.Pg.Startup

import Std.Core
import Std.Environment
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.Pg.SelfCheck

/// `CloudAgents.dll --migrate`: apply pending migrations as
/// `cloudagents_owner`, print what ran, and return the process exit code.
pub func runMigrateCommand(): Int {
  val dsn = Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "")
  if dsn.length.toInt() == 0 {
    println("ERROR: --migrate needs " + CloudAgents.Pg.migrateDsnVar() + " (the cloudagents_owner DSN)")
    return 2
  }
  val conn = match CloudAgents.Pg.connectDsn(dsn) {
    case Ok(c) -> c
    case Err(e) -> {
      println("ERROR: " + CloudAgents.Pg.pgErrorMessage(e))
      return 1
    }
  }
  defer {
    conn.close()
  }
  return match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(ran) -> {
      if ran.length == 0 {
        println("Postgres schema already current")
      } else {
        for v in ran {
          println("applied migration " + v)
        }
      }
      0
    }
    case Err(e) -> {
      println("ERROR: migration failed: " + CloudAgents.Pg.pgErrorMessage(e))
      1
    }
  }
}

/// Run the service-role self-check when Postgres is configured. `Ok(())` when
/// Postgres is not configured (the service is still on SQLite) or the check
/// passes; `Err(message)` means the process must not serve.
pub func checkServiceRole(): Result[Unit, String] {
  if not CloudAgents.Pg.serviceConfigured() {
    return Ok(value = ())
  }
  val conn = match CloudAgents.Pg.connectService() {
    case Ok(c) -> c
    case Err(e) -> return Err(error = CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  return CloudAgents.Pg.SelfCheck.check(conn)
}
