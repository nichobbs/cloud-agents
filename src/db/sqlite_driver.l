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
import extern Microsoft.Data.Sqlite.SqliteConnection as SqliteConnection
import extern Microsoft.Data.Sqlite.SqliteCommand as SqliteCommand
import extern Microsoft.Data.Sqlite.SqliteDataReader as SqliteDataReader
import extern System.Environment as Env
import extern System.String as DotNetString
import extern System.Type as DotNetType
import extern SQLitePCL.SQLite3Provider_dynamic_cdecl as SQLiteProvider

@externTarget("SQLitePCL.raw.SetProvider")
func sqliteSetProvider(provider: in SQLiteProvider): Unit = ()

@externTarget("SQLitePCL.raw.FreezeProvider")
func sqliteFreezeProvider(): Unit = ()

extern type Type = "System.Type"

extern type StringArray = "System.String[]"

extern type RowArray = "CloudAgents.Sqlite.Row[]"

@externInstance
@externTarget("System.Object.GetType")
func getStringType(obj: in String): Type = ()

@externInstance
@externTarget("System.Object.GetType")
func getRowType(obj: in Row): Type = ()

@externTarget("System.Array.CreateInstance")
func createStringArray(elementType: in Type, length: in Int): StringArray = ()

@externTarget("System.Array.CreateInstance")
func createRowArray(elementType: in Type, length: in Int): RowArray = ()

@externTarget("System.Array.Copy")
func copyStringArray(
  sourceArray: in StringArray,
  sourceIndex: in Int,
  destinationArray: in StringArray,
  destinationIndex: in Int,
  length: in Int,
): Unit = ()

@externTarget("System.Array.Copy")
func copyRowArray(
  sourceArray: in RowArray,
  sourceIndex: in Int,
  destinationArray: in RowArray,
  destinationIndex: in Int,
  length: in Int,
): Unit = ()

@externInstance
@externTarget("System.Array.get_Length")
pub func getStringArrayLength(arr: in StringArray): Int = ()

@externInstance
@externTarget("System.Array.get_Length")
pub func getRowArrayLength(arr: in RowArray): Int = ()

@externInstance
@externTarget("System.Array.SetValue")
func setStringArrayValue(arr: in StringArray, value: in String, index: in Int): Unit = ()

@externInstance
@externTarget("System.Array.SetValue")
func setRowArrayValue(arr: in RowArray, value: in Row, index: in Int): Unit = ()

@externInstance
@externTarget("System.Array.GetValue")
pub func getStringArrayValue(arr: in StringArray, index: in Int): String = ()

@externInstance
@externTarget("System.Array.GetValue")
pub func getRowArrayValue(arr: in RowArray, index: in Int): Row = ()

pub func appendString(arr: in StringArray, item: in String): StringArray {
  val oldLen = getStringArrayLength(arr)
  val stringType = getStringType("")
  val newArr = createStringArray(stringType, oldLen + 1)
  if oldLen > 0 {
    copyStringArray(arr, 0, newArr, 0, oldLen)
  }
  setStringArrayValue(newArr, item, oldLen)
  return newArr
}

pub func createEmptyStringArray(): StringArray {
  val stringType = getStringType("")
  return createStringArray(stringType, 0)
}

pub func appendRow(arr: in RowArray, item: in Row): RowArray {
  val oldLen = getRowArrayLength(arr)
  val rowType = getRowType(item)
  val newArr = createRowArray(rowType, oldLen + 1)
  if oldLen > 0 {
    copyRowArray(arr, 0, newArr, 0, oldLen)
  }
  setRowArrayValue(newArr, item, oldLen)
  return newArr
}

pub func createEmptyRowArray(): RowArray {
  val dummy = Row(cols = createEmptyStringArray())
  val rowType = getRowType(dummy)
  return createRowArray(rowType, 0)
}

/// One result row: every column is read as text (the schema stores all columns
/// with TEXT affinity, so `GetString` is always valid — see CloudAgents.Db).
pub record Row {
  pub cols: StringArray
}

/// Failure modes at the database boundary.
pub union DbError {
  case OpenFailed(message: String)
  case ExecFailed(sql: String, message: String)
}

pub func dbErrorMessage(e: in DbError): String {
  return match e {
    case OpenFailed(m) -> "failed to open database: " + m
    case ExecFailed(sql, m) -> "query failed (" + sql + "): " + m
  }
}

/// Path to the SQLite database file. Overridable via CLOUD_AGENTS_DB_PATH so
/// tests and deployments can point at different files; defaults to a file in
/// the working directory.
pub func dbPath(): String {
  val p = Env.GetEnvironmentVariable("CLOUD_AGENTS_DB_PATH")
  if DotNetString.IsNullOrEmpty(p) {
    return "cloud-agents.db"
  }
  return p
}

pub func connectionString(): String {
  return "Data Source=" + dbPath()
}

func openConn(): Result[SqliteConnection, DbError] {
  try {
    sqliteSetProvider(SQLiteProvider.new())
    sqliteFreezeProvider()
  } catch Bug as b {
    // Already set or failed, ignore
  }
  return try {
    val conn = SqliteConnection.new(connectionString())
    conn.Open()
    Ok(value = conn)
  } catch Bug as b {
    Err(error = OpenFailed(message = b.message))
  }
}

/// Run a statement that returns no rows (DDL, INSERT, UPDATE, DELETE).
/// Returns the number of rows affected.
pub func execute(sql: in String): Result[Int, DbError] {
  val conn = openConn()?
  defer {
    conn.Close()
  }
  return try {
    val cmd = conn.CreateCommand()
    cmd.set_CommandText(sql)
    Ok(value = cmd.ExecuteNonQuery())
  } catch Bug as b {
    Err(error = ExecFailed(sql = sql, message = b.message))
  }
}

/// Run several statements on a single connection inside one transaction —
/// all-or-nothing. On any failure the whole batch is rolled back, so a partial
/// migration (or any multi-step change) never persists. This is the ONLY way to
/// get atomicity across statements here: `execute` opens a fresh connection per
/// call, so a BEGIN in one `execute` and the DDL in the next would not share a
/// transaction. Used by the migration runner so a migration and its ledger row
/// commit together, making every retry of a failed migration safe (review #229).
pub func executeTransaction(sqls: in slice[String]): Result[Unit, DbError] {
  val conn = openConn()?
  defer {
    conn.Close()
  }
  return try {
    val begin = conn.CreateCommand()
    begin.set_CommandText("BEGIN")
    val _ = begin.ExecuteNonQuery()
    var i = 0
    while i < sqls.length {
      val cmd = conn.CreateCommand()
      cmd.set_CommandText(sqls[i])
      val _ = cmd.ExecuteNonQuery()
      i = i + 1
    }
    val commit = conn.CreateCommand()
    commit.set_CommandText("COMMIT")
    val _ = commit.ExecuteNonQuery()
    Ok(value = ())
  } catch Bug as b {
    // Roll back so nothing from this batch persists, then surface the error.
    // The rollback is itself best-effort (the connection may already be broken).
    try {
      val rb = conn.CreateCommand()
      rb.set_CommandText("ROLLBACK")
      val _ = rb.ExecuteNonQuery()
    } catch Bug as b2 {
      // connection unusable; Close() in the defer still runs
    }
    Err(error = ExecFailed(sql = "transaction", message = b.message))
  }
}

/// Run a query and read every row as a list of text columns.
pub func query(sql: in String): Result[RowArray, DbError] {
  val conn = openConn()?
  defer {
    conn.Close()
  }
  return try {
    val cmd = conn.CreateCommand()
    cmd.set_CommandText(sql)
    val reader = cmd.ExecuteReader()
    val fields = reader.get_FieldCount()
    var rows = createEmptyRowArray()
    while reader.Read() {
      var cols = createEmptyStringArray()
      var i = 0
      while i < fields {
        if reader.IsDBNull(i) {
          cols = appendString(cols, "")
        } else {
          cols = appendString(cols, reader.GetString(i))
        }
        i = i + 1
      }
      rows = appendRow(rows, Row(cols = cols))
    }
    reader.Close()
    Ok(value = rows)
  } catch Bug as b {
    Err(error = ExecFailed(sql = sql, message = b.message))
  }
}
