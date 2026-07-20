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

// Static Type.GetType(string), not an @externInstance-bound Object.GetType()
// on a boxed argument (#513) — the same instance-bound GetType() shape that
// crashed the process with an uncatchable AccessViolationException for a
// boxed Byte (docs/lyric/gotchas.md), migrated here as defense-in-depth even
// though String is a reference type and the specific boxing-mismatch
// mechanism described there is scoped to value-type arguments. Same pattern
// as src/github_api.l's typeFromName. getRowType below is left on the
// instance-bound form: Row is a reference type too (same lower-risk category
// as String), but migrating it needs the exact runtime-emitted type name for
// a Lyric record, which isn't safely guessable without the compiler to
// verify against — a wrong string here breaks Array.CreateInstance outright,
// trading a currently-working (if same-shaped) call for a worse failure.
@externTarget("System.Type.GetType")
func stringType(name: in String): Type = ()

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
  val strType = stringType("System.String")
  val newArr = createStringArray(strType, oldLen + 1)
  if oldLen > 0 {
    copyStringArray(arr, 0, newArr, 0, oldLen)
  }
  setStringArrayValue(newArr, item, oldLen)
  return newArr
}

pub func createEmptyStringArray(): StringArray {
  val strType = stringType("System.String")
  return createStringArray(strType, 0)
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

/// Apply connection tuning pragmas (best-effort). WAL lets readers and a
/// writer proceed concurrently instead of blocking each other, and
/// busy_timeout makes a connection wait for a held write lock rather than
/// failing immediately with SQLITE_BUSY — both matter here because every
/// execute/query opens its own connection (docs: the SQLite recommendation to
/// stay single-node but take the cheap WAL win). journal_mode is persistent on
/// the database file; busy_timeout is per-connection, so it is re-applied on
/// each open. A failure (e.g. a filesystem that can't do WAL) must not stop the
/// connection from being used, so it is swallowed.
func applyPragmas(conn: in SqliteConnection): Unit {
  try {
    val c1 = conn.CreateCommand()
    c1.set_CommandText("PRAGMA busy_timeout=5000")
    val _ = c1.ExecuteNonQuery()
    val c2 = conn.CreateCommand()
    c2.set_CommandText("PRAGMA journal_mode=WAL")
    val _ = c2.ExecuteNonQuery()
  } catch Bug as b {
    // Pragmas are tuning, not correctness — proceed without them.
  }
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
    applyPragmas(conn)
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
///
/// Returns the rows affected by the LAST statement in `sqls` (mirroring
/// `execute()`'s single-statement return), so a caller whose transaction ends
/// with the mutation it actually cares about (e.g. a profile UPDATE/DELETE run
/// alongside its credential-grant replacement) can derive its 0-vs-success
/// signal from the mutation itself instead of from a pre-check performed
/// before the transaction ran, which can go stale under concurrent access
/// (#238). Order statements accordingly when a caller needs this signal;
/// callers that don't care about the count (migrations, inserts) just discard
/// it.
pub func executeTransaction(sqls: in slice[String]): Result[Int, DbError] {
  val conn = openConn()?
  defer {
    conn.Close()
  }
  // Track the statement in flight so a failure names the offending SQL (#234)
  // rather than an opaque "transaction". Starts on BEGIN.
  var currentSql = "BEGIN"
  return try {
    val begin = conn.CreateCommand()
    begin.set_CommandText(currentSql)
    val _ = begin.ExecuteNonQuery()
    var i = 0
    var lastAffected = 0
    while i < sqls.length {
      currentSql = sqls[i]
      val cmd = conn.CreateCommand()
      cmd.set_CommandText(currentSql)
      lastAffected = cmd.ExecuteNonQuery()
      i = i + 1
    }
    currentSql = "COMMIT"
    val commit = conn.CreateCommand()
    commit.set_CommandText(currentSql)
    val _ = commit.ExecuteNonQuery()
    Ok(value = lastAffected)
  } catch Bug as b {
    // Roll back so nothing from this batch persists, then surface the error
    // with the statement that failed. The rollback is itself best-effort (the
    // connection may already be broken).
    try {
      val rb = conn.CreateCommand()
      rb.set_CommandText("ROLLBACK")
      val _ = rb.ExecuteNonQuery()
    } catch Bug as b2 {
      // connection unusable; Close() in the defer still runs
    }
    Err(error = ExecFailed(sql = currentSql, message = b.message))
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
