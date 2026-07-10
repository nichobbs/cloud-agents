//! HTTP handlers for run-completion webhooks. Registered target URLs and an
//! outbox of completion events (CloudAgents.Repository); actual HTTP delivery is
//! performed by an external worker that polls the pending endpoint and marks
//! events delivered (Lyric.Web has no in-process timer and reliable outbound
//! HTTPS from Lyric isn't available yet — same external-scheduler approach as
//! container reaping). Ownership-scoped by CloudAgents.Auth.currentUserId().
package CloudAgents.Webhooks

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Sqlite

val maxWebhookUrlLen = 2048

@generate(Json)
pub record RegisterWebhookRequest {
  pub url: String
}

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

@externTarget("System.String.CompareOrdinal")
func strCompareOrdinal(a: in String, b: in String): Int = ()

func containsControlChar(s: in String): Bool {
  var i = 0
  while i < s.length {
    if strCompareOrdinal(s.substring(i, 1), " ") < 0 {
      return true
    }
    i = i + 1
  }
  return false
}

/// The host component of an https URL (between "https://" and the next
/// '/', ':', '?' or '#'). Assumes the "https://" prefix is already verified.
pub func webhookHost(url: in String): String {
  val rest = url.substring(8, url.length - 8)
  var host = ""
  var i = 0
  while i < rest.length {
    val c = rest.substring(i, 1)
    if c == "/" or c == ":" or c == "?" or c == "#" {
      return host
    }
    host = host + c
    i = i + 1
  }
  return host
}

/// Whether a host is an obvious internal/loopback target that a webhook must
/// not point at. Defense-in-depth at registration (#253) — the external
/// deliverer is still responsible for full egress/SSRF policy (172.16/12, DNS
/// rebinding, redirects), which this can't cover.
pub func isBlockedWebhookHost(host: in String): Bool {
  if host.length == 0 {
    return true
  }
  if host.startsWith("[") {
    return true // IPv6 literal (e.g. [::1]) — conservatively rejected
  }
  if host == "localhost" or host == "0.0.0.0" {
    return true
  }
  return host.startsWith("127.") or host.startsWith("10.") or host.startsWith("192.168.") or host.startsWith("169.254.")
}

/// A webhook URL must be https, well-formed enough to store, free of
/// whitespace/control characters, and not point at an obvious internal host.
pub func isValidWebhookUrl(url: in String): Bool {
  if url.length == 0 or url.length > maxWebhookUrlLen {
    return false
  }
  if not url.startsWith("https://") {
    return false
  }
  // Must have a non-empty host after the scheme.
  if url.length <= 8 {
    return false
  }
  if url.contains(" ") or url.contains("\"") or url.contains("\\") {
    return false
  }
  if containsControlChar(url) {
    return false
  }
  return not isBlockedWebhookHost(webhookHost(url))
}

/// Register a webhook target URL for run-completion notifications.
@post("/api/webhooks")
pub func registerWebhookHandler(@body req: in RegisterWebhookRequest): Result[Webhook, Web.ApiError] {
  if not isValidWebhookUrl(req.url) {
    return Err(Web.badRequest("url must be a valid https:// URL"))
  }
  match addWebhook(CloudAgents.Auth.currentUserId(), req.url) {
    case Ok(w) -> return Ok(w)
    case Err(e) -> return Err(dbError(e))
  }
}

/// List the caller's registered webhooks.
@get("/api/webhooks")
pub func listWebhooksHandler(): Result[WebhookList, Web.ApiError] {
  match listWebhooks(CloudAgents.Auth.currentUserId()) {
    case Ok(ws) -> return Ok(WebhookList(webhooks = ws))
    case Err(e) -> return Err(dbError(e))
  }
}

/// Delete a registered webhook.
@delete("/api/webhooks/{id}")
pub func deleteWebhookHandler(id: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("webhook id is required"))
  }
  val affected = match deleteWebhook(id, CloudAgents.Auth.currentUserId()) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("webhook not found"))
  }
  return Ok(())
}

/// Undelivered run-completion events, oldest first — the queue an external
/// delivery worker polls. It POSTs each event to the caller's registered
/// webhook URLs, then calls the mark-delivered endpoint.
@get("/api/webhooks/pending")
pub func pendingWebhookEventsHandler(): Result[WebhookEventList, Web.ApiError] {
  match listPendingWebhookEvents(CloudAgents.Auth.currentUserId()) {
    case Ok(es) -> return Ok(WebhookEventList(events = es))
    case Err(e) -> return Err(dbError(e))
  }
}

/// Mark an outbox event delivered (called by the external deliverer).
@post("/api/webhooks/events/{id}/delivered")
pub func markWebhookDeliveredHandler(id: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("event id is required"))
  }
  val affected = match markWebhookEventDelivered(id, CloudAgents.Auth.currentUserId()) {
    case Ok(n) -> n
    case Err(e) -> return Err(dbError(e))
  }
  if affected == 0 {
    return Err(Web.notFound("event not found"))
  }
  return Ok(())
}
