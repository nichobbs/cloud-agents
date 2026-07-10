@test_module
package CloudAgents.WebhookTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Db
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.Webhooks
import extern System.Environment as Env

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
}

// ── SQL builder shape ─────────────────────────────────────────────────────────

test "webhook SQL builders are scoped and outbox-shaped" {
  assertTrue(webhooksSchemaSql().contains("UNIQUE(user_id, url)"), "one url per user")
  assertTrue(insertWebhookSql("w1", "u1", "https://x", "1000").contains("ON CONFLICT(user_id, url) DO NOTHING"), "register idempotent")
  assertTrue(selectWebhooksSql("u1").contains("WHERE user_id = 'u1'"), "list scoped by owner")
  assertTrue(deleteWebhookSql("w1", "u1").endsWith("AND user_id = 'u1'"), "delete scoped by owner")
  assertTrue(insertWebhookEventSql("e1", "u1", "s1", "r1", "succeeded", "1000").contains("'0'"), "event starts undelivered")
  assertTrue(selectPendingWebhookEventsSql("u1").contains("delivered = '0'"), "pending = undelivered")
  assertTrue(selectPendingWebhookEventsSql("u1").contains("ORDER BY created_at ASC"), "FIFO delivery")
  assertTrue(markWebhookEventDeliveredSql("e1", "u1").contains("SET delivered = '1'"), "mark delivered")
}

// ── Live-database ─────────────────────────────────────────────────────────────

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
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
    // fine
  }
}

func mustWebhook(r: in Result[Webhook, CloudAgents.Sqlite.DbError]): Webhook {
  return match r {
    case Ok(w) -> w
    case Err(e) -> panic("webhook op failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustWebhooks(r: in Result[slice[Webhook], CloudAgents.Sqlite.DbError]): slice[Webhook] {
  return match r {
    case Ok(ws) -> ws
    case Err(e) -> panic("webhook list failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustEvents(r: in Result[slice[WebhookEvent], CloudAgents.Sqlite.DbError]): slice[WebhookEvent] {
  return match r {
    case Ok(es) -> es
    case Err(e) -> panic("event list failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustRows(r: in Result[Int, CloudAgents.Sqlite.DbError]): Int {
  return match r {
    case Ok(n) -> n
    case Err(e) -> panic("webhook write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "Webhook registration is idempotent and per-user" {
  val dbPath = useFreshTestDb("webhook-crud")
  defer {
    cleanupTestDb(dbPath)
  }
  val mine = mustWebhook(addWebhook("default", "https://example.com/hook"))
  assertTrue(mine.id.length > 0, "registered webhook has an id")
  // Re-registering the same URL is a no-op (UNIQUE), not a duplicate.
  val _ = mustWebhook(addWebhook("default", "https://example.com/hook"))
  assertEqualInt(mustWebhooks(listWebhooks("default")).length.toInt(), 1, "same url not duplicated")

  // Another user's webhook is invisible.
  val _ = mustWebhook(addWebhook("someone-else", "https://other.com/hook"))
  assertEqualInt(mustWebhooks(listWebhooks("default")).length.toInt(), 1, "only my webhook listed")

  assertEqualInt(mustRows(deleteWebhook(mine.id, "default")), 1, "delete my webhook")
  assertEqualInt(mustWebhooks(listWebhooks("default")).length.toInt(), 0, "empty after delete")
}

test "Run-completion events flow through the outbox" {
  val dbPath = useFreshTestDb("webhook-outbox")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"
  // Events are only enqueued when the user has a registered webhook (#251).
  val _ = mustWebhook(addWebhook(userId, "https://example.com/hook"))
  match enqueueWebhookEvent(userId, "s1", "r1", "succeeded") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "enqueue failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match enqueueWebhookEvent(userId, "s2", "r2", "failed") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "enqueue failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val pending = mustEvents(listPendingWebhookEvents(userId))
  assertEqualInt(pending.length.toInt(), 2, "two events pending")
  // FIFO: the first enqueued is delivered first.
  assertEqual(pending[0].sessionId, "s1", "oldest event first")

  // Marking one delivered removes it from pending.
  assertEqualInt(mustRows(markWebhookEventDelivered(pending[0].id, userId)), 1, "mark delivered")
  val after = mustEvents(listPendingWebhookEvents(userId))
  assertEqualInt(after.length.toInt(), 1, "one event still pending")
  assertEqual(after[0].sessionId, "s2", "remaining event is the undelivered one")
}

test "Events are not enqueued without a registered webhook (#251)" {
  val dbPath = useFreshTestDb("webhook-gate")
  defer {
    cleanupTestDb(dbPath)
  }
  match enqueueWebhookEvent("default", "s1", "r1", "succeeded") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "enqueue failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertEqualInt(mustEvents(listPendingWebhookEvents("default")).length.toInt(), 0, "no event enqueued when no webhook is registered")
}

test "Webhook handlers validate and 404 correctly" {
  val dbPath = useFreshTestDb("webhook-handlers")
  defer {
    cleanupTestDb(dbPath)
  }
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
