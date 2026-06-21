//! SQLite driver: a thin FFI wrapper over Microsoft.Data.Sqlite (ADO.NET).
//!
//! This is the only module that touches the native database. Everything above
//! it (CloudAgents.Repository) works in terms of `execute`/`query` over plain
//! SQL strings and never sees an `extern` handle. SQL text is assembled in the
//! pure CloudAgents.Db layer using `sqlLiteral` escaping, so this layer does no
//! parameter binding — keeping the FFI surface small and reviewable.
//!
//! NOTE: the `extern` targets below resolve against the installed
//! Microsoft.Data.Sqlite assembly (enabled by the `sqlite` feature in
//! lyric.toml). They follow the documented `@externInstance`/`@externTarget`
//! mechanism (docs/lyric/reference.md §FFI) and the same pattern used for
//! System.Environment in src/sessions/session_manager.l.
@runtime_checked
package CloudAgents.Sqlite

import Std.Core

extern type SqliteConnection = "Microsoft.Data.Sqlite.SqliteConnection"
extern type SqliteCommand    = "Microsoft.Data.Sqlite.SqliteCommand"
extern type SqliteDataReader = "Microsoft.Data.Sqlite.SqliteDataReader"

// new SqliteConnection(connectionString)
@externTarget("Microsoft.Data.Sqlite.SqliteConnection..ctor")
func ctorConnection(connectionString: in String): SqliteConnection = ()

@externInstance
@externTarget("Microsoft.Data.Sqlite.SqliteConnection.Open")
func connOpen(conn: in SqliteConnection): Unit = ()

@externInstance
@externTarget("Microsoft.Data.Sqlite.SqliteConnection.Close")
func connClose(conn: in SqliteConnection): Unit = ()

@externInstance
@externTarget("Microsoft.Data.Sqlite.SqliteConnection.CreateCommand")
func connCreateCommand(conn: in SqliteConnection): SqliteCommand = ()

@externInstance
@externTarget("Microsoft.Data.Sqlite.SqliteCommand.set_CommandText")
func cmdSetText(cmd: in SqliteCommand, text: in String): Unit = ()

@externInstance
@externTarget("Microsoft.Data.Sqlite.SqliteCommand.ExecuteNonQuery")
func cmdExecuteNonQuery(cmd: in SqliteCommand): Int = ()

@externInstance
@externTarget("Microsoft.Data.Sqlite.SqliteCommand.ExecuteReader")
func cmdExecuteReader(cmd: in SqliteCommand): SqliteDataReader = ()

@externInstance
@externTarget("Microsoft.Data.Sqlite.SqliteDataReader.Read")
func readerRead(reader: in SqliteDataReader): Bool = ()

@externInstance
@externTarget("Microsoft.Data.Sqlite.SqliteDataReader.get_FieldCount")
func readerFieldCount(reader: in SqliteDataReader): Int = ()

@externInstance
@externTarget("Microsoft.Data.Sqlite.SqliteDataReader.IsDBNull")
func readerIsNull(reader: in SqliteDataReader, ordinal: in Int): Bool = ()

@externInstance
@externTarget("Microsoft.Data.Sqlite.SqliteDataReader.GetString")
func readerGetString(reader: in SqliteDataReader, ordinal: in Int): String = ()

@externInstance
@externTarget("Microsoft.Data.Sqlite.SqliteDataReader.Close")
func readerClose(reader: in SqliteDataReader): Unit = ()

@externTarget("System.Environment.GetEnvironmentVariable")
func getEnvVar(name: in String): String = ()

@externTarget("System.String.IsNullOrEmpty")
func isNullOrEmpty(s: in String): Bool = ()

/// One result row: every column is read as text (the schema stores all columns
/// with TEXT affinity, so `GetString` is always valid — see CloudAgents.Db).
pub record Row {
  pub cols: slice[String]
}

/// Failure modes at the database boundary.
pub union DbError {
  case OpenFailed(message: String)
  case ExecFailed(sql: String, message: String)
}

pub func dbErrorMessage(e: in DbError): String {
  return match e {
    case OpenFailed(m)      -> "failed to open database: " + m
    case ExecFailed(sql, m) -> "query failed (" + sql + "): " + m
  }
}

/// Path to the SQLite database file. Overridable via CLOUD_AGENTS_DB_PATH so
/// tests and deployments can point at different files; defaults to a file in
/// the working directory.
pub func dbPath(): String {
  val p = getEnvVar("CLOUD_AGENTS_DB_PATH")
  if isNullOrEmpty(p) {
    return "cloud-agents.db"
  }
  return p
}

pub func connectionString(): String {
  return "Data Source=" + dbPath()
}

func openConn(): Result[SqliteConnection, DbError] {
  return try {
    val conn = ctorConnection(connectionString())
    connOpen(conn)
    Ok(value = conn)
  } catch Bug as b {
    Err(error = OpenFailed(message = b.message))
  }
}

/// Run a statement that returns no rows (DDL, INSERT, UPDATE, DELETE).
/// Returns the number of rows affected.
pub func execute(sql: in String): Result[Int, DbError] {
  val conn = openConn()?
  defer connClose(conn)
  return try {
    val cmd = connCreateCommand(conn)
    cmdSetText(cmd, sql)
    Ok(value = cmdExecuteNonQuery(cmd))
  } catch Bug as b {
    Err(error = ExecFailed(sql = sql, message = b.message))
  }
}

/// Run a query and read every row as a list of text columns.
pub func query(sql: in String): Result[slice[Row], DbError] {
  val conn = openConn()?
  defer connClose(conn)
  return try {
    val cmd = connCreateCommand(conn)
    cmdSetText(cmd, sql)
    val reader = cmdExecuteReader(cmd)
    val fields = readerFieldCount(reader)
    var rows: slice[Row] = []
    while readerRead(reader) {
      var cols: slice[String] = []
      var i = 0
      while i < fields {
        if readerIsNull(reader, i) {
          cols = cols.append("")
        } else {
          cols = cols.append(readerGetString(reader, i))
        }
        i = i + 1
      }
      rows = rows.append(Row(cols = cols))
    }
    readerClose(reader)
    Ok(value = rows)
  } catch Bug as b {
    Err(error = ExecFailed(sql = sql, message = b.message))
  }
}
