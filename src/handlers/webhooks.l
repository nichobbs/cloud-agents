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

@externInstance
@externTarget("System.String.ToLowerInvariant")
func strToLower(s: in String): String = ()

/// The host component of an https URL. Parses the authority properly so it
/// can't be fooled by embedded userinfo or a port (#257): takes the substring
/// after "https://" up to the first '/', '?' or '#', drops any `userinfo@`
/// prefix, and strips a `:port` suffix (keeping a bracketed IPv6 literal whole).
/// Assumes the "https://" prefix is already verified.
pub func webhookHost(url: in String): String {
  val rest = url.substring(8, url.length - 8)
  // Authority = up to the first '/', '?' or '#'.
  var authority = ""
  var i = 0
  var done = false
  while i < rest.length and not done {
    val c = rest.substring(i, 1)
    if c == "/" or c == "?" or c == "#" {
      done = true
    } else {
      authority = authority + c
      i = i + 1
    }
  }
  // Drop userinfo: everything up to and including the LAST '@'.
  var atIdx = -1
  var j = 0
  while j < authority.length {
    if authority.substring(j, 1) == "@" {
      atIdx = j
    }
    j = j + 1
  }
  var hostport = authority
  if atIdx >= 0 {
    hostport = authority.substring(atIdx + 1, authority.length - atIdx - 1)
  }
  // IPv6 literal [....](:port) — keep the bracketed part.
  if hostport.startsWith("[") {
    var host6 = ""
    var k = 0
    var closed = false
    while k < hostport.length and not closed {
      val c = hostport.substring(k, 1)
      host6 = host6 + c
      if c == "]" {
        closed = true
      } else {
        k = k + 1
      }
    }
    return host6
  }
  // Strip ':port'.
  var host = ""
  var m = 0
  var stop = false
  while m < hostport.length and not stop {
    val c = hostport.substring(m, 1)
    if c == ":" {
      stop = true
    } else {
      host = host + c
      m = m + 1
    }
  }
  return host
}

func digitVal(c: in String): Int {
  if c == "0" { return 0 }
  if c == "1" { return 1 }
  if c == "2" { return 2 }
  if c == "3" { return 3 }
  if c == "4" { return 4 }
  if c == "5" { return 5 }
  if c == "6" { return 6 }
  if c == "7" { return 7 }
  if c == "8" { return 8 }
  if c == "9" { return 9 }
  return -1
}

/// Whether `host` is in the 172.16.0.0/12 private range (172.16.x – 172.31.x) —
/// which includes Docker's default bridge subnet (#260).
func isPrivate172(host: in String): Bool {
  if not host.startsWith("172.") {
    return false
  }
  var oct = 0
  var seen = false
  var i = 4
  var stop = false
  while i < host.length and not stop {
    val d = digitVal(host.substring(i, 1))
    if d < 0 {
      stop = true
    } else {
      oct = oct * 10 + d
      seen = true
      i = i + 1
    }
  }
  return seen and oct >= 16 and oct <= 31
}

/// Whether a host is an obvious internal/loopback/private target a webhook must
/// not point at. Defense-in-depth at registration (#253/#257/#260) — the
/// external deliverer still owns full egress/SSRF policy (DNS rebinding,
/// redirects), which this can't cover. Case-insensitive.
pub func isBlockedWebhookHost(host: in String): Bool {
  if host.length == 0 {
    return true
  }
  val h = strToLower(host)
  if h.startsWith("[") {
    return true // IPv6 literal (e.g. [::1]) — conservatively rejected
  }
  if h == "localhost" or h == "0.0.0.0" {
    return true
  }
  if h.startsWith("127.") or h.startsWith("10.") or h.startsWith("192.168.") or h.startsWith("169.254.") {
    return true
  }
  return isPrivate172(h)
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
