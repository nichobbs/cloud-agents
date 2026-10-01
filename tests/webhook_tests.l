//! Webhook tests: URL validation, and the webhook registry and event outbox
//! on the Postgres store (phase 11 cut-over).
@test_module
package CloudAgents.WebhookTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.Db
import CloudAgents.Webhooks

// ── URL validation (pure) ─────────────────────────────────────────────────────

test "webhook URL validation requires a clean https URL" {
  assertTrue(isValidWebhookUrl("https://example.com/hook"), "plain https URL ok")
  assertTrue(not isValidWebhookUrl("http://example.com/hook"), "http rejected")
  assertTrue(not isValidWebhookUrl("https://"), "scheme with no host rejected")
  assertTrue(not isValidWebhookUrl(""), "empty rejected")
  assertTrue(not isValidWebhookUrl("https://ex ample.com"), "whitespace rejected")
  assertTrue(not isValidWebhookUrl("ftp://example.com"), "non-https scheme rejected")
  // SSRF defense-in-depth (#253): internal/loopback hosts rejected.
  assertTrue(not isValidWebhookUrl("https://localhost/hook"), "localhost rejected")
  assertTrue(not isValidWebhookUrl("https://127.0.0.1/hook"), "loopback ip rejected")
  assertTrue(not isValidWebhookUrl("https://10.0.0.5/hook"), "private 10/8 rejected")
  assertTrue(not isValidWebhookUrl("https://192.168.1.1/hook"), "private 192.168 rejected")
  assertTrue(not isValidWebhookUrl("https://169.254.169.254/latest"), "link-local metadata rejected")
  assertTrue(isValidWebhookUrl("https://example.com:8443/hook"), "https with a port is fine")
  assertEqual(webhookHost("https://example.com:8443/hook"), "example.com", "host extracted before port")
  // #257: case and embedded userinfo must not bypass the blocklist.
  assertTrue(not isValidWebhookUrl("https://LOCALHOST/hook"), "uppercase localhost rejected")
  assertTrue(not isValidWebhookUrl("https://evil@127.0.0.1/hook"), "userinfo can't hide the real host")
  assertEqual(webhookHost("https://evil@127.0.0.1/hook"), "127.0.0.1", "userinfo stripped from host")
  assertEqual(webhookHost("https://user:pw@example.com:443/x"), "example.com", "userinfo+port stripped")
  // #260: 172.16/12 (Docker's bridge range) rejected; a public 172.x is fine.
  assertTrue(not isValidWebhookUrl("https://172.17.0.1/hook"), "docker bridge subnet rejected")
  assertTrue(not isValidWebhookUrl("https://172.31.255.255/hook"), "end of 172.16/12 rejected")
  assertTrue(isValidWebhookUrl("https://172.32.0.1/hook"), "public 172.32 allowed")
  assertTrue(isValidWebhookUrl("https://172.15.0.1/hook"), "public 172.15 allowed")
  // #264: a long-digit 172. host must not overflow/panic. It isn't in the
  // 16-31 range so it's simply allowed — the point is the call COMPLETES
  // (a panic would crash this test) rather than what it returns.
  val _ = isValidWebhookUrl("https://172.99999999999999999999999/hook")
  assertTrue(true, "long-digit 172 host handled without overflow/panic")
  // #266: non-dotted IP-literal forms rejected.
  assertTrue(not isValidWebhookUrl("https://2130706433/hook"), "decimal ip literal rejected")
  assertTrue(not isValidWebhookUrl("https://0x7f000001/hook"), "hex ip literal rejected")
}

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
  println("SKIP: webhook tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Db.dbErrorMessage(e))
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

func mustWebhook(r: in Result[Webhook, CloudAgents.Db.DbError]): Webhook {
  return match r {
    case Ok(w) -> w
    case Err(e) -> panic("webhook op failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func mustWebhooks(r: in Result[slice[Webhook], CloudAgents.Db.DbError]): slice[Webhook] {
  return match r {
    case Ok(ws) -> ws
    case Err(e) -> panic("webhook list failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func mustEvents(r: in Result[slice[WebhookEvent], CloudAgents.Db.DbError]): slice[WebhookEvent] {
  return match r {
    case Ok(es) -> es
    case Err(e) -> panic("event list failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func mustRows(r: in Result[Int, CloudAgents.Db.DbError]): Int {
  return match r {
    case Ok(n) -> n
    case Err(e) -> panic("webhook write failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

test "Webhook registration is idempotent and per-user" {
  if not live() {
    return
  }
  val me = freshUser("wh-webhook-crud")
  val mine = mustWebhook(addWebhook(CloudAgents.Pg.personalScope(me), "https://example.com/hook"))
  assertTrue(mine.id.length > 0, "registered webhook has an id")
  // Re-registering the same URL is a no-op (UNIQUE) and must return the SAME
  // persisted row, not a freshly-minted id/timestamp (#255).
  val again = mustWebhook(addWebhook(CloudAgents.Pg.personalScope(me), "https://example.com/hook"))
  assertEqual(again.id, mine.id, "re-register returns the existing row's id")
  assertEqualInt(mustWebhooks(listWebhooks(CloudAgents.Pg.personalScope(me))).length.toInt(), 1, "same url not duplicated")

  // Another user's webhook is invisible.
  val other = newUser("wh-other")
  val _ = mustWebhook(addWebhook(CloudAgents.Pg.personalScope(other), "https://other.com/hook"))
  assertEqualInt(mustWebhooks(listWebhooks(CloudAgents.Pg.personalScope(me))).length.toInt(), 1, "only my webhook listed")

  assertEqualInt(mustRows(deleteWebhook(mine.id, CloudAgents.Pg.personalScope(me))), 1, "delete my webhook")
  assertEqualInt(mustWebhooks(listWebhooks(CloudAgents.Pg.personalScope(me))).length.toInt(), 0, "empty after delete")
}

test "Run-completion events flow through the outbox" {
  if not live() {
    return
  }
  val me = freshUser("wh-webhook-outbox")
  val userId = me
  // Events are only enqueued when the user has a registered webhook (#251).
  val _ = mustWebhook(addWebhook(CloudAgents.Pg.personalScope(userId), "https://example.com/hook"))
  match enqueueWebhookEvent(CloudAgents.Pg.personalScope(userId), "s1", "r1", "succeeded") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "enqueue failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  match enqueueWebhookEvent(CloudAgents.Pg.personalScope(userId), "s2", "r2", "failed") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "enqueue failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  val pending = mustEvents(listPendingWebhookEvents(CloudAgents.Pg.personalScope(userId)))
  assertEqualInt(pending.length.toInt(), 2, "two events pending")
  // FIFO: the first enqueued is delivered first.
  assertEqual(pending[0].sessionId, "s1", "oldest event first")

  // Marking one delivered removes it from pending.
  assertEqualInt(mustRows(markWebhookEventDelivered(pending[0].id, CloudAgents.Pg.personalScope(userId))), 1, "mark delivered")
  val after = mustEvents(listPendingWebhookEvents(CloudAgents.Pg.personalScope(userId)))
  assertEqualInt(after.length.toInt(), 1, "one event still pending")
  assertEqual(after[0].sessionId, "s2", "remaining event is the undelivered one")
}

test "Events are not enqueued without a registered webhook (#251)" {
  if not live() {
    return
  }
  val me = freshUser("wh-webhook-gate")
  match enqueueWebhookEvent(CloudAgents.Pg.personalScope(me), "s1", "r1", "succeeded") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "enqueue failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  assertEqualInt(mustEvents(listPendingWebhookEvents(CloudAgents.Pg.personalScope(me))).length.toInt(), 0, "no event enqueued when no webhook is registered")
}

test "Webhook handlers validate and 404 correctly" {
  if not live() {
    return
  }
  val me = freshUser("wh-webhook-handlers")
  // Invalid URL -> 400.
  match registerWebhookHandler(RegisterWebhookRequest(url = "http://insecure")) {
    case Ok(_) -> assertTrue(false, "http url should be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "http url -> 400")
  }
  // Valid URL -> created and listed.
  match registerWebhookHandler(RegisterWebhookRequest(url = "https://example.com/hook")) {
    case Ok(w) -> assertEqual(w.url, "https://example.com/hook", "handler stores the url")
    case Err(_) -> assertTrue(false, "valid url should register")
  }
  match listWebhooksHandler() {
    case Ok(wl) -> assertEqualInt(wl.webhooks.length.toInt(), 1, "list handler returns the webhook")
    case Err(_) -> assertTrue(false, "list handler should succeed")
  }
  // Unknown ids are 404s.
  match deleteWebhookHandler("nope") {
    case Ok(_) -> assertTrue(false, "unknown delete should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "delete unknown -> 404")
  }
  match markWebhookDeliveredHandler("nope") {
    case Ok(_) -> assertTrue(false, "unknown event should 404")
    case Err(err) -> assertEqualInt(err.status, 404, "mark unknown -> 404")
  }
}
