//! Phase 7 §5 (docs/phase7-autonomy.md): the notify MCP tool's host handlers.
//! Small live-DB prelude copied from tests/callbacks_v2_tests.l's own header
//! (that file documents why: `@test_module` cannot invoke anything reached
//! through a package that declares `async func`s, and CloudAgents.Callbacks
//! itself is fine to import directly, but sharing helpers across
//! `@test_module` files means duplicating them, not importing them).
@test_module
package CloudAgents.NotifyTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Callbacks
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return path
}

func cleanupTestDb(path: in String): Unit {
  try {
    fileDelete(path)
  } catch Bug as b {
    // locked or already gone — fine for a temp file
  }
  CloudAgents.Auth.setCurrentUserId("default")
}

func mkSession(id: in String): Unit {
  val s = makeAgentSession(
    sessionId = id,
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = id
  )
  match addSession(s) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mintToken(id: in String, ownerUserId: in String): String {
  return match CloudAgents.SessionStore.mintCallbackToken(id, ownerUserId) {
    case Ok(t) -> t
    case Err(e) -> panic("mintCallbackToken failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func bearer(token: in String): String {
  return "Bearer " + token
}

/// A string at least `minLen` characters long, built by doubling
/// (`s = s + s`, O(n)) rather than single-character concatenation (O(n^2),
/// unworkably slow at this size — mirrors tests/callbacks_v2_tests.l's
/// atLeast helper).
func atLeast(minLen: in Int): String {
  var s = "A"
  while s.length < minLen {
    s = s + s
  }
  return s
}

test "notify creates a notification and defaults an empty level to info" {
  val dbPath = useFreshTestDb("notify-create")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-notify-1"
  mkSession(sid)
  val token = mintToken(sid, "default")

  val created = match createNotificationHandler(sid, bearer(token), NotifyRequest(summary = "build finished", level = "")) {
    case Ok(r) -> r
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  assertTrue(created.id.length > 0, "a notification id is returned")

  match listNotificationsHandler(sid) {
    case Ok(l) -> {
      assertEqualInt(l.notifications.length.toInt(), 1, "one notification stored")
      assertEqual(l.notifications[0].level, "info", "an empty level defaults to info")
      assertEqual(l.notifications[0].summary, "build finished", "summary round-trips")
      assertEqual(l.notifications[0].id, created.id, "the listed id matches the created id")
    }
    case Err(e) -> assertTrue(false, "list failed: " + toString(e.status))
  }
}

test "notify accepts info/done/blocked and rejects any other level" {
  val dbPath = useFreshTestDb("notify-level")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-notify-2"
  mkSession(sid)
  val token = mintToken(sid, "default")

  match createNotificationHandler(sid, bearer(token), NotifyRequest(summary = "still working", level = "info")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "info should be accepted: " + toString(e.status))
  }
  match createNotificationHandler(sid, bearer(token), NotifyRequest(summary = "all done", level = "done")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "done should be accepted: " + toString(e.status))
  }
  match createNotificationHandler(sid, bearer(token), NotifyRequest(summary = "need input", level = "blocked")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "blocked should be accepted: " + toString(e.status))
  }
  match createNotificationHandler(sid, bearer(token), NotifyRequest(summary = "x", level = "urgent")) {
    case Ok(_) -> assertTrue(false, "an unrecognized level must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "unrecognized level -> 400")
  }
}

test "notify validates summary presence and length" {
  val dbPath = useFreshTestDb("notify-validation")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-notify-3"
  mkSession(sid)
  val token = mintToken(sid, "default")

  match createNotificationHandler(sid, bearer(token), NotifyRequest(summary = "", level = "")) {
    case Ok(_) -> assertTrue(false, "an empty summary must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty summary -> 400")
  }
  // maxProgressSummaryLen is 4096 bytes.
  match createNotificationHandler(sid, bearer(token), NotifyRequest(summary = atLeast(4097), level = "")) {
    case Ok(_) -> assertTrue(false, "an over-length summary must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "over-length summary -> 400")
  }
}

test "notify rejects a summary whose UTF-8 byte size is over the cap even when its char count is not (#617)" {
  val dbPath = useFreshTestDb("notify-validation-utf8")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-notify-3b"
  mkSession(sid)
  val token = mintToken(sid, "default")

  // U+3042 (HIRAGANA A) is one Lyric character but three UTF-8 bytes
  // (docs/lyric/gotchas.md #64). 1400 copies is 1400 characters (well under
  // the 4096-character mark) but 4200 bytes (over the 4096-byte cap) — a
  // char-length check alone would wrongly accept this.
  var wide = ""
  var i = 0
  while i < 1400 {
    wide = wide + "あ"
    i = i + 1
  }
  match createNotificationHandler(sid, bearer(token), NotifyRequest(summary = wide, level = "")) {
    case Ok(_) -> assertTrue(false, "a summary over the byte cap must be rejected even though it's under the char cap")
    case Err(e) -> assertEqualInt(e.status, 400, "over-byte-length summary -> 400")
  }
}

test "notify requires a valid callback token; the owner can list via the user route" {
  val dbPath = useFreshTestDb("notify-auth")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-notify-4"
  mkSession(sid)
  val token = mintToken(sid, "default")

  match createNotificationHandler(sid, bearer("wrong-token"), NotifyRequest(summary = "x", level = "")) {
    case Ok(_) -> assertTrue(false, "a wrong callback token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 401, "bad token -> 401")
  }
  match createNotificationHandler(sid, bearer(token), NotifyRequest(summary = "done with the migration", level = "done")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "notify failed: " + toString(e.status))
  }
  match listNotificationsHandler(sid) {
    case Ok(l) -> assertEqualInt(l.notifications.length.toInt(), 1, "the owner can list session notifications")
    case Err(e) -> assertTrue(false, "listNotifications failed: " + toString(e.status))
  }
}

test "notify rejects an empty session id before touching the database" {
  val dbPath = useFreshTestDb("notify-empty-id")
  defer {
    cleanupTestDb(dbPath)
  }
  match createNotificationHandler("", "", NotifyRequest(summary = "x", level = "")) {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id returns 400")
  }
  match listNotificationsHandler("") {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id returns 400")
  }
}
