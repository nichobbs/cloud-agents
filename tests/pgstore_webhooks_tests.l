//! Live-Postgres tests for CloudAgents.PgStore.Webhooks and
//! CloudAgents.PgStore.TokenCache (docs/phase11-postgres-tenancy.md §4.2, §9
//! slices B/C): per-user webhooks and their outbox behave like the SQLite
//! store within a tenant, and the global token cache answers before any
//! tenant is set. Runs iff the Postgres DSNs are set (see
//! tests/pg_live_tests.l). Per-run unique ids keep it re-runnable.
@test_module
package CloudAgents.PgStoreWebhooksTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Webhooks as Hooks
import CloudAgents.PgStore.TokenCache as Tokens
import CloudAgents.Repository
import CloudAgents.Sqlite

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
  println("SKIP: PgStore webhook tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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

func uid(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func fresh(): CloudAgents.Pg.TenantScope {
  return CloudAgents.Pg.personalScope("gh-pgw-" + uid())
}

func hook(r: in Result[Webhook, DbError]): Webhook {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func hooks(r: in Result[slice[Webhook], DbError]): slice[Webhook] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func events(r: in Result[slice[WebhookEvent], DbError]): slice[WebhookEvent] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func int(r: in Result[Int, DbError]): Int {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func unit(r: in Result[Unit, DbError]): Unit {
  match r {
    case Ok(_) -> ()
    case Err(e) -> panic("store call failed: " + dbErrorMessage(e))
  }
}

func tokenEntry(r: in Result[Option[GitHubTokenCacheEntry], DbError]): String {
  return match r {
    case Ok(Some(e)) -> e.userId + "/" + e.login
    case Ok(None) -> "<none>"
    case Err(e) -> panic("store call failed: " + dbErrorMessage(e))
  }
}

test "webhooks: no duplicates, per user, newest first, delete" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  val a = hook(Hooks.addWebhook(sc, "https://example.com/a"))
  val again = hook(Hooks.addWebhook(sc, "https://example.com/a"))
  assertEqual(again.id, a.id, "a repeated URL returns the existing webhook")
  hook(Hooks.addWebhook(sc, "https://example.com/b"))
  val other = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-pgw-other-" + uid())
  hook(Hooks.addWebhook(other, "https://other.example.com/"))
  val mine = hooks(Hooks.listWebhooks(sc))
  assertEqualInt(mine.length.toInt(), 2, "only my webhooks")
  assertEqual(mine[0].url, "https://example.com/b", "newest first")
  assertEqualInt(int(Hooks.deleteWebhook(a.id, other)), 0, "another user cannot delete it")
  assertEqualInt(int(Hooks.deleteWebhook(a.id, sc)), 1, "deleted")
  assertEqualInt(hooks(Hooks.listWebhooks(sc)).length.toInt(), 1, "one left")
}

test "events are enqueued only with a webhook, listed oldest first, delivered once" {
  if not live() {
    return
  }
  migrate()
  val sc = fresh()
  unit(Hooks.enqueueWebhookEvent(sc, "s1", "r1", "succeeded"))
  assertEqualInt(events(Hooks.listPendingWebhookEvents(sc)).length.toInt(), 0, "no webhook, no event")
  hook(Hooks.addWebhook(sc, "https://example.com/hook"))
  unit(Hooks.enqueueWebhookEvent(sc, "s1", "r1", "succeeded"))
  unit(Hooks.enqueueWebhookEvent(sc, "s2", "r2", "failed"))
  val pending = events(Hooks.listPendingWebhookEvents(sc))
  assertEqualInt(pending.length.toInt(), 2, "two pending")
  assertEqual(pending[0].runId, "r1", "oldest first")
  assertEqualInt(int(Hooks.markWebhookEventDelivered(pending[0].id, sc)), 1, "delivered")
  val left = events(Hooks.listPendingWebhookEvents(sc))
  assertEqualInt(left.length.toInt(), 1, "one left")
  assertEqual(left[0].runId, "r2", "the undelivered one")
  assertEqualInt(events(Hooks.listPendingWebhookEvents(fresh())).length.toInt(), 0, "another tenant sees none")
}

test "the token cache resolves identities and denials without a tenant" {
  if not live() {
    return
  }
  migrate()
  val valid = "tok-" + uid()
  val denied = "tok-" + uid()
  val code = "code-" + uid()
  val user = "gh-pgw-" + uid()
  unit(Tokens.cacheGitHubToken(valid, user, "octo"))
  unit(Tokens.cacheGitHubTokenDenied(denied))
  unit(Tokens.cacheOAuthCodeRejected(code))
  assertEqual(tokenEntry(Tokens.cachedGitHubToken(valid)), user + "/octo", "validated token")
  assertEqual(tokenEntry(Tokens.cachedGitHubToken(denied)), "/", "a denial is an entry with no user")
  assertEqual(tokenEntry(Tokens.lookupHistoricalGitHubToken(valid)), user + "/octo", "historical lookup")
  assertEqual(tokenEntry(Tokens.lookupHistoricalGitHubToken(denied)), "<none>", "denials are not historical identities")
  match Tokens.lookupGitHubLoginForUser(user) {
    case Ok(l) -> assertEqual(l, "octo", "login by user")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Tokens.activeNegativeGitHubTokens() {
    case Ok(n) -> assertTrue(n >= 1, "at least this denial is active")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  match Tokens.activeRejectedOAuthCodes() {
    case Ok(n) -> assertTrue(n >= 1, "at least this rejected code is active")
    case Err(e) -> panic(dbErrorMessage(e))
  }
  unit(Tokens.cacheGitHubToken(valid, user, "octo-renamed"))
  assertEqual(tokenEntry(Tokens.cachedGitHubToken(valid)), user + "/octo-renamed", "a re-cache replaces the entry")
  unit(Tokens.invalidateGitHubToken(valid))
  assertEqual(tokenEntry(Tokens.cachedGitHubToken(valid)), "<none>", "invalidated")
}
