//! Phase 7 §5 (docs/phase7-autonomy.md): the notify MCP tool's host handlers,
//! against the Postgres store.
//! Small live-DB prelude copied from tests/callbacks_v2_tests.l's own header
//! (`@test_module` cannot invoke anything reached through a package that
//! declares `async func`s, and sharing helpers across `@test_module` files
//! means duplicating them, not importing them).
@test_module
package CloudAgents.NotifyTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Callbacks
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── Live Postgres ─────────────────────────────────────────────────────────────
//
// The store is Postgres (docs/phase11-postgres-tenancy.md). These tests run iff
// LYRIC_CONFIG_DB_CONNECTION_URL (cloudagents_app) and
// CLOUD_AGENTS_MIGRATE_DATABASE_URL (cloudagents_owner) are set, and fail rather
// than skip when CLOUD_AGENTS_REQUIRE_LIVE_PG=1 (CI). Each test acts as a fresh
// user with its own personal tenant, so tests, suites and repeated runs against
// the same database never see each other's rows.
func live(): Bool {
  val ok = CloudAgents.Pg.serviceConfigured() and
    Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "").length.toInt() > 0
  if ok {
    return true
  }
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: notify tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
  return false
}

func migrate(): Unit {
  val conn = match CloudAgents.Pg.connectDsn(Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "")) {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(_) -> ()
    case Err(e) -> panic("migrate failed: " + CloudAgents.Pg.pgErrorMessage(e))
  }
}

/// A new user with a provisioned personal tenant. Does not change the request
/// identity.
func newUser(tag: in String): String {
  val uid = "t-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(uid) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return uid
}

/// Migrate, then make a new user the request identity (what handlers read via
/// CloudAgents.Auth.requestScope()).
func freshUser(tag: in String): String {
  migrate()
  val uid = newUser(tag)
  CloudAgents.Auth.setCurrentUserId(uid)
  return uid
}

/// Session ids are global primary keys that persist across runs.
func uniq(prefix: in String): String {
  return prefix + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

/// freshUser plus the encryption key the credential-backed handlers need.
func fresh(tag: in String): String {
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
  return freshUser(tag)
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
  match addSession(s, CloudAgents.Auth.requestScope()) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mintToken(id: in String, ownerUserId: in String): String {
  return match CloudAgents.SessionStore.mintCallbackToken(id, CloudAgents.Pg.personalScope(ownerUserId)) {
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
  if not live() {
    return
  }
  val me = fresh("notify-create")
  val sid = uniq("sess-notify-1")
  mkSession(sid)
  val token = mintToken(sid, me)

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
  if not live() {
    return
  }
  val me = fresh("notify-level")
  val sid = uniq("sess-notify-2")
  mkSession(sid)
  val token = mintToken(sid, me)

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
  if not live() {
    return
  }
  val me = fresh("notify-validation")
  val sid = uniq("sess-notify-3")
  mkSession(sid)
  val token = mintToken(sid, me)

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
  if not live() {
    return
  }
  val me = fresh("notify-validation-utf8")
  val sid = uniq("sess-notify-3b")
  mkSession(sid)
  val token = mintToken(sid, me)

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
  if not live() {
    return
  }
  val me = fresh("notify-auth")
  val sid = uniq("sess-notify-4")
  mkSession(sid)
  val token = mintToken(sid, me)

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
  if not live() {
    return
  }
  val me = fresh("notify-empty-id")
  match createNotificationHandler("", "", NotifyRequest(summary = "x", level = "")) {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id returns 400")
  }
  match listNotificationsHandler("") {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id returns 400")
  }
}
