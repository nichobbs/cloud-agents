@test_module
package CloudAgents.DbTests

import Std.Core
import Std.Testing
import CloudAgents.Db

func transitionLabel(t: in Transition): String {
  return match t {
    case To(s) -> statusToString(s)
    case Invalid -> "INVALID"
  }
}

func recycleLabel(r: in RecycleAction): String {
  return match r {
    case StopAndIdle -> "STOP"
    case EvictCold -> "EVICT"
    case NoAction -> "NONE"
  }
}

test "Status string round-trips" {
  assertEqual(statusToString(Running), "RUNNING", "Running -> RUNNING")
  match statusFromString("WARM") {
    case Some(s) -> assertEqual(statusToString(s), "WARM", "WARM parses back to Warm")
    case None -> assertTrue(false, "WARM should parse")
  }
  match statusFromString("bogus") {
    case Some(_) -> assertTrue(false, "bogus must not parse")
    case None -> assertTrue(true, "unknown status -> None")
  }
}

test "State machine follows the Phase 2 diagram" {
  assertEqual(transitionLabel(nextStatus(Created, CloneStarted)), "CLONING", "Created+CloneStarted")
  assertEqual(transitionLabel(nextStatus(Cloning, CloneFinished)), "IDLE", "Cloning+CloneFinished")
  assertEqual(transitionLabel(nextStatus(Idle, MessageReceived)), "RUNNING", "Idle+MessageReceived")
  assertEqual(transitionLabel(nextStatus(Running, ProcessExited)), "WARM", "Running+ProcessExited")
  assertEqual(transitionLabel(nextStatus(Warm, MessageReceived)), "RUNNING", "Warm+MessageReceived")
  assertEqual(transitionLabel(nextStatus(Warm, IdleTimeout)), "IDLE", "Warm+IdleTimeout")
  assertEqual(transitionLabel(nextStatus(Warm, Deleted)), "DESTROYED", "Warm+Deleted")
}

test "Illegal transitions return Invalid" {
  assertEqual(transitionLabel(nextStatus(Running, MessageReceived)), "INVALID", "no message while running")
  assertEqual(transitionLabel(nextStatus(Idle, IdleTimeout)), "INVALID", "no idle-timeout from idle")
  assertEqual(transitionLabel(nextStatus(Destroyed, MessageReceived)), "INVALID", "destroyed is terminal")
}

test "Idle recycling honours the warm and cold windows" {
  assertEqual(recycleLabel(recycleDecision(Warm, 299999.toLong())), "NONE", "warm under 5min")
  assertEqual(recycleLabel(recycleDecision(Warm, 300000.toLong())), "STOP", "warm at 5min")
  assertEqual(recycleLabel(recycleDecision(Idle, 3599999.toLong())), "NONE", "idle under 1h")
  assertEqual(recycleLabel(recycleDecision(Idle, 3600000.toLong())), "EVICT", "idle at 1h")
  assertEqual(recycleLabel(recycleDecision(Running, 9999999.toLong())), "NONE", "running not swept")
}

test "SQL statements are scoped by owner" {
  assertTrue(selectSessionByIdSql("s1", "u1").endsWith("AND user_id = 'u1'"), "select scoped by owner")
  assertTrue(listSessionsByUserSql("u1").contains("WHERE user_id = 'u1'"), "list scoped by owner")
  assertTrue(deleteSessionSql("s1", "u1").endsWith("AND user_id = 'u1'"), "delete scoped by owner")
  assertTrue(updateSessionContainerSql("s1", "u1", "c1").contains("AND user_id = 'u1'"), "container update scoped by owner")
  assertTrue(updateSessionModelSql("s1", "u1", "m1").contains("AND user_id = 'u1'"), "model update scoped by owner")
  assertTrue(insertSessionSql("s1", "u1", "r", "b", "", "claude", "m", "n", "1000").contains("'IDLE'"), "insert starts IDLE")
}

test "run-claim SQL is atomic and status-guarded" {
  // 'end' (and defensively 'begin') are reserved keywords in Lyric (P0051),
  // hence the Sql-suffixed binding names.
  val claimSql = tryBeginRunSql("s1", "u1", "1000")
  assertTrue(claimSql.contains("SET status = 'RUNNING'"), "claim sets RUNNING")
  assertTrue(claimSql.contains("AND status <> 'RUNNING'"), "claim refuses an already-running session")
  assertTrue(claimSql.contains("AND user_id = 'u1'"), "claim scoped by owner")
  val releaseSql = endRunSql("s1", "u1", "2000")
  assertTrue(releaseSql.contains("SET status = 'IDLE'"), "end returns to IDLE")
  assertTrue(recoverDanglingSessionsSql().contains("WHERE status = 'RUNNING' OR status = 'WARM'"), "recovery targets stranded sessions")
}

test "Volume names key by user and session" {
  assertEqual(workspaceVolumeName("42", "abc"), "session-42-abc", "workspace volume")
  assertEqual(homeVolumeName("42"), "user-42-home", "home volume")
}

test "sqlLiteral wraps and escapes single quotes" {
  assertEqual(sqlLiteral("hi"), "'hi'", "plain value wrapped")
  assertEqual(sqlLiteral("it's"), "'it''s'", "single quote doubled")
  assertEqual(sqlLiteral(""), "''", "empty value")
}

test "padSeq zero-pads to a fixed width" {
  assertEqual(padSeq(0), "000000000000", "zero")
  assertEqual(padSeq(42), "000000000042", "small number")
  assertEqual(padSeq(7), "000000000007", "single digit")
}

test "message SQL builders inline escaped values" {
  val sql = insertMessageSql("id1", "s1", "user", "he said 'hi'", "000000000000", "1000")
  assertTrue(sql.startsWith("INSERT INTO messages"), "insert target")
  assertTrue(sql.contains("'he said ''hi'''"), "content is escaped")
  assertTrue(selectMessagesSql("s1").contains("ORDER BY seq ASC"), "transcript ordered by seq")
  assertTrue(countMessagesSql("s1").contains("CAST(COUNT(*) AS TEXT)"), "count cast to text for GetString")
  assertTrue(selectMessageSessionIdSql("m1").contains("WHERE id = 'm1'"), "message session lookup scoped by id")
}

test "comment and todo SQL builders are scoped and escaped" {
  assertTrue(insertCommentSql("c1", "m1", "s1", "body", "1").startsWith("INSERT INTO comments"), "comment insert")
  assertTrue(selectCommentsSql("m1").contains("WHERE message_id = 'm1'"), "comments scoped to message")
  assertTrue(insertTodoSql("t1", "s1", "m1", "note", "1").contains("'0'"), "new todo defaults to not done")
  assertTrue(selectTodosSql("s1").contains("ORDER BY created_at DESC"), "todos newest first")
  assertTrue(toggleTodoSql("t1").contains("CASE done"), "toggle flips done flag")
  assertTrue(deleteTodoSql("t1").endsWith("'t1'"), "delete by id")
}

test "schema DDL is idempotent" {
  assertTrue(messagesSchemaSql().contains("CREATE TABLE IF NOT EXISTS messages"), "messages ddl")
  assertTrue(commentsSchemaSql().contains("CREATE TABLE IF NOT EXISTS comments"), "comments ddl")
  assertTrue(todosSchemaSql().contains("CREATE TABLE IF NOT EXISTS todos"), "todos ddl")
}

test "migration ledger SQL is well-formed" {
  assertTrue(migrationsSchemaSql().contains("CREATE TABLE IF NOT EXISTS schema_migrations"), "ledger ddl")
  assertTrue(migrationsSchemaSql().contains("version TEXT PRIMARY KEY"), "version is the key")
  assertTrue(countMigrationSql("0001_init").contains("CAST(COUNT(*) AS TEXT)"), "count cast to text for GetString")
  assertTrue(countMigrationSql("0001_init").contains("WHERE version = '0001_init'"), "count scoped by version")
  assertTrue(recordMigrationSql("0001_init", "1000").startsWith("INSERT INTO schema_migrations"), "record inserts")
  assertTrue(recordMigrationSql("0001_init", "1000").contains("'0001_init'"), "record carries the version")
}
