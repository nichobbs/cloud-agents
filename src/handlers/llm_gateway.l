//! LLM Gateway: Standard Anthropic (/v1/messages) and OpenAI (/v1/chat/completions)
//! endpoints routed to Cloud Agents profiles with explicit credential mapping.
package CloudAgents.LlmGateway

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.ClaudeLogin
import CloudAgents.GitHubApi
import CloudAgents.Repository
import CloudAgents.Scope
import CloudAgents.Streaming
import CloudAgents.Text
import CloudAgents.PgStore.Credentials
import CloudAgents.PgStore.Library

extern type HttpWebRequest = "System.Net.HttpWebRequest"
extern type HttpWebResponse = "System.Net.HttpWebResponse"
extern type NetStream = "System.IO.Stream"
extern type StreamReader = "System.IO.StreamReader"
extern type WebHeaderCollection = "System.Net.WebHeaderCollection"
extern type Encoding = "System.Text.Encoding"

@externTarget("System.Net.WebRequest.Create")
func createRequest(url: in String): HttpWebRequest = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_Method")
func setMethod(req: in HttpWebRequest, method: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_UserAgent")
func setUserAgent(req: in HttpWebRequest, ua: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_Accept")
func setAccept(req: in HttpWebRequest, accept: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_ContentType")
func setContentType(req: in HttpWebRequest, contentType: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_Timeout")
func setTimeout(req: in HttpWebRequest, millis: in Int): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_ReadWriteTimeout")
func setReadWriteTimeout(req: in HttpWebRequest, millis: in Int): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_AllowAutoRedirect")
func setAllowAutoRedirect(req: in HttpWebRequest, allow: in Bool): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.get_Headers")
func getHeaders(req: in HttpWebRequest): WebHeaderCollection = ()

@externInstance
@externTarget("System.Net.WebHeaderCollection.Set")
func headerSet(headers: in WebHeaderCollection, name: in String, value: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.GetRequestStream")
func getRequestStream(req: in HttpWebRequest): NetStream = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.GetResponse")
func getHttpResponse(req: in HttpWebRequest): HttpWebResponse = ()

@externInstance
@externTarget("System.Net.HttpWebResponse.get_StatusCode")
func getStatusCode(resp: in HttpWebResponse): Int = 0

@externInstance
@externTarget("System.Net.HttpWebResponse.GetResponseStream")
func getHttpResponseStream(resp: in HttpWebResponse): NetStream = ()

@externInstance
@externTarget("System.IDisposable.Dispose")
func httpResponseDispose(resp: in HttpWebResponse): Unit = ()

@externInstance
@externTarget("System.IO.Stream.Write")
func streamWrite(s: in NetStream, bytes: in slice[Byte], offset: in Int, count: in Int): Unit = ()

@externInstance
@externTarget("System.IDisposable.Dispose")
func streamDispose(s: in NetStream): Unit = ()

@externInstance
@externTarget("System.IO.StreamReader.ReadLine")
func readerReadLine(reader: in StreamReader): String = ""

@externInstance
@externTarget("System.IO.StreamReader.get_EndOfStream")
func readerEndOfStream(reader: in StreamReader): Bool = false

@externTarget("System.String.IsNullOrEmpty")
func isNullOrEmpty(s: in String): Bool = false

@externTarget("System.Text.Encoding.get_UTF8")
func utf8(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetBytes")
func encGetBytes(enc: in Encoding, s: in String): slice[Byte] = []

val defaultGatewayTimeoutMillis = 180000

// ── Pure Helpers ─────────────────────────────────────────────────────────────

pub func anthropicErrorJson(errorType: in String, message: in String): String {
  return "{\"type\":\"error\",\"error\":{\"type\":\"" + CloudAgents.Streaming.jsonEscape(errorType) + "\",\"message\":\"" + CloudAgents.Streaming.jsonEscape(message) + "\"}}"
}

pub func openAiErrorJson(message: in String, errorType: in String, code: in String): String {
  return "{\"error\":{\"message\":\"" + CloudAgents.Streaming.jsonEscape(message) + "\",\"type\":\"" + CloudAgents.Streaming.jsonEscape(errorType) + "\",\"code\":\"" + CloudAgents.Streaming.jsonEscape(code) + "\"}}"
}

func containsStr(haystack: in String, needle: in String): Bool {
  return CloudAgents.Text.indexOfFrom(haystack, needle, 0) >= 0
}

pub func isStreamingRequested(body: in String): Bool {
  return containsStr(body, "\"stream\": true") or
    containsStr(body, "\"stream\":true") or
    containsStr(body, "\"stream\": 1") or
    containsStr(body, "\"stream\":1")
}

pub record AnthropicAuth {
  pub isBearer: Bool,
  pub token: String
}

/// Resolve profile from URL path segment (urlPid) or explicit header value (headerPid) for a given userId
pub func resolveProfileRef(urlPid: in String, headerPid: in String, userId: in String): Result[CloudAgents.Repository.Profile, String] {
  val sc = CloudAgents.Pg.personalScope(userId)
  var targetPid = urlPid.trim()
  if targetPid.length == 0 {
    targetPid = headerPid.trim()
  }

  if targetPid.length == 0 {
    return Err(error = "Profile must be specified either via URL path segment (/api/v1/profiles/{id}/...) or X-CloudAgents-Profile header")
  }

  // 1. Try lookup by profile ID
  match CloudAgents.Repository.getProfile(targetPid, sc) {
    case Ok(Some(p)) -> return Ok(value = p)
    case Ok(None) -> ()
    case Err(e) -> return Err(error = "Database error looking up profile: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // 2. Try lookup by profile Name
  match CloudAgents.Repository.listProfiles(sc) {
    case Ok(profiles) -> {
      var i = 0
      while i < profiles.length {
        if profiles[i].name == targetPid {
          return Ok(value = profiles[i])
        }
        i = i + 1
      }
      return Err(error = "Profile '" + targetPid + "' not found")
    }
    case Err(e) -> return Err(error = "Database error listing profiles: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

/// Resolve profile from URL path segment (urlPid) or request headers (X-CloudAgents-Profile, etc.)
pub func resolveProfile(req: in Web.Request, urlPid: in String): Result[CloudAgents.Repository.Profile, String] {
  val userId = CloudAgents.Auth.currentUserId()

  var targetPid = match Web.header(req, "X-CloudAgents-Profile") {
    case Some(v) -> v.trim()
    case None -> ""
  }
  if targetPid.length == 0 {
    targetPid = match Web.header(req, "x-cloudagents-profile") {
      case Some(v) -> v.trim()
      case None -> ""
    }
  }
  if targetPid.length == 0 {
    targetPid = match Web.header(req, "X-Profile") {
      case Some(v) -> v.trim()
      case None -> ""
    }
  }
  if targetPid.length == 0 {
    targetPid = match Web.header(req, "x-profile") {
      case Some(v) -> v.trim()
      case None -> ""
    }
  }

  return resolveProfileRef(urlPid, targetPid, userId)
}

/// Resolves Anthropic credentials from decrypted profile credentials
pub func resolveAnthropicAuth(profile: in CloudAgents.Repository.Profile, userId: in String): Result[AnthropicAuth, String] {
  val creds = match CloudAgents.PgStore.Credentials.decryptedCredentialsForProfile(CloudAgents.Pg.personalScope(userId), profile.id) {
    case Ok(cs) -> cs
    case Err(e) -> return Err(error = "Failed to decrypt credentials for profile: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // 1. Check for CLAUDE_CREDENTIALS_JSON (OAuth subscription)
  var i = 0
  while i < creds.length {
    if creds[i].name == "CLAUDE_CREDENTIALS_JSON" {
      val parsed = CloudAgents.ClaudeLogin.parseLogin(creds[i].value)
      match parsed {
        case Some(login) -> {
          if login.claudeAiOauth.accessToken.length > 0 {
            return Ok(value = AnthropicAuth(isBearer = true, token = login.claudeAiOauth.accessToken))
          }
        }
        case None -> ()
      }
    }
    i = i + 1
  }

  // 2. Check for ANTHROPIC_API_KEY
  i = 0
  while i < creds.length {
    if creds[i].name == "ANTHROPIC_API_KEY" and creds[i].value.length > 0 {
      return Ok(value = AnthropicAuth(isBearer = false, token = creds[i].value))
    }
    i = i + 1
  }

  return Err(error = "Profile '" + profile.name + "' has no valid credential mapping or grant for 'CLAUDE_CREDENTIALS_JSON' or 'ANTHROPIC_API_KEY'")
}

/// Resolves OpenAI credentials from decrypted profile credentials
pub func resolveOpenAiAuth(profile: in CloudAgents.Repository.Profile, userId: in String): Result[String, String] {
  val creds = match CloudAgents.PgStore.Credentials.decryptedCredentialsForProfile(CloudAgents.Pg.personalScope(userId), profile.id) {
    case Ok(cs) -> cs
    case Err(e) -> return Err(error = "Failed to decrypt credentials for profile: " + CloudAgents.Db.dbErrorMessage(e))
  }

  var i = 0
  while i < creds.length {
    if creds[i].name == "OPENAI_API_KEY" and creds[i].value.length > 0 {
      return Ok(value = creds[i].value)
    }
    i = i + 1
  }

  return Err(error = "Profile '" + profile.name + "' has no valid credential mapping or grant for 'OPENAI_API_KEY'")
}

// ── Outbound Forwarding ──────────────────────────────────────────────────────

func writeGatewayError(w: in Web.ResponseWriter, code: in Int, isAnthropic: in Bool, errorType: in String, message: in String): Unit {
  Web.writeStatus(w, code)
  Web.writeHeader(w, "Content-Type", "application/json")
  if isAnthropic {
    val _ = Web.writeChunk(w, anthropicErrorJson(errorType, message))
  } else {
    val _ = Web.writeChunk(w, openAiErrorJson(message, errorType, "gateway_error"))
  }
}

func forwardHttpRequest(
  url: in String,
  headerNames: in slice[String],
  headerValues: in slice[String],
  jsonBody: in String,
  isStream: in Bool,
  w: in Web.ResponseWriter,
  isAnthropic: in Bool,
): Unit {
  try {
    val req = createRequest(url)
    setMethod(req, "POST")
    setTimeout(req, defaultGatewayTimeoutMillis)
    setReadWriteTimeout(req, defaultGatewayTimeoutMillis)
    setUserAgent(req, "cloud-agents-gateway")
    setContentType(req, "application/json")
    setAllowAutoRedirect(req, false)

    val hdrs = getHeaders(req)
    var i = 0
    while i < headerNames.length and i < headerValues.length {
      headerSet(hdrs, headerNames[i], headerValues[i])
      i = i + 1
    }

    val bytes = encGetBytes(utf8(), jsonBody)
    val reqStream = getRequestStream(req)
    defer {
      streamDispose(reqStream)
    }
    streamWrite(reqStream, bytes, 0, bytes.length.toInt())
    streamDispose(reqStream)

    val resp = getHttpResponse(req)
    defer {
      httpResponseDispose(resp)
    }
    val code = getStatusCode(resp)
    val respStream = getHttpResponseStream(resp)
    defer {
      streamDispose(respStream)
    }

    if isStream and code == 200 {
      Web.writeStatus(w, 200)
      Web.writeHeader(w, "Content-Type", "text/event-stream")
      Web.writeHeader(w, "Cache-Control", "no-cache")
      Web.writeHeader(w, "Connection", "keep-alive")
      Web.writeHeader(w, "X-Accel-Buffering", "no")

      val reader = StreamReader.new(respStream)
      while not readerEndOfStream(reader) {
        val line = readerReadLine(reader)
        if not isNullOrEmpty(line) {
          val _ = Web.writeChunk(w, line + "\n")
        } else {
          val _ = Web.writeChunk(w, "\n")
        }
      }
    } else {
      val respBody = CloudAgents.GitHubApi.readAllUtf8(respStream)
      Web.writeStatus(w, code)
      Web.writeHeader(w, "Content-Type", "application/json")
      val _ = Web.writeChunk(w, respBody)
    }
  } catch Bug as b {
    var status = CloudAgents.GitHubApi.httpStatusOf(b.message)
    if status == 0 {
      status = 502
    }
    writeGatewayError(w, status, isAnthropic, "api_error", b.message)
  }
}

// ── Streaming Handlers ───────────────────────────────────────────────────────

pub func messagesHandler(urlPid: in String, req: in Web.Request, w: in Web.ResponseWriter): Unit {
  val userId = CloudAgents.Auth.currentUserId()
  val profile = match resolveProfile(req, urlPid) {
    case Ok(p) -> p
    case Err(e) -> {
      writeGatewayError(w, 400, true, "invalid_request_error", e)
      return ()
    }
  }

  val auth = match resolveAnthropicAuth(profile, userId) {
    case Ok(a) -> a
    case Err(e) -> {
      writeGatewayError(w, 400, true, "invalid_request_error", e)
      return ()
    }
  }

  var headerNames: slice[String] = []
  var headerValues: slice[String] = []

  if auth.isBearer {
    headerNames = headerNames.append("Authorization")
    headerValues = headerValues.append("Bearer " + auth.token)
  } else {
    headerNames = headerNames.append("x-api-key")
    headerValues = headerValues.append(auth.token)
  }

  val antVer = match Web.header(req, "anthropic-version") {
    case Some(v) -> v
    case None -> "2023-06-01"
  }
  headerNames = headerNames.append("anthropic-version")
  headerValues = headerValues.append(antVer)

  match Web.header(req, "anthropic-beta") {
    case Some(b) -> {
      headerNames = headerNames.append("anthropic-beta")
      headerValues = headerValues.append(b)
    }
    case None -> ()
  }

  val isStream = isStreamingRequested(req.body)
  forwardHttpRequest(
    "https://api.anthropic.com/v1/messages",
    headerNames,
    headerValues,
    req.body,
    isStream,
    w,
    true
  )
}

pub func chatCompletionsHandler(urlPid: in String, req: in Web.Request, w: in Web.ResponseWriter): Unit {
  val userId = CloudAgents.Auth.currentUserId()
  val profile = match resolveProfile(req, urlPid) {
    case Ok(p) -> p
    case Err(e) -> {
      writeGatewayError(w, 400, false, "invalid_request_error", e)
      return ()
    }
  }

  val apiKey = match resolveOpenAiAuth(profile, userId) {
    case Ok(k) -> k
    case Err(e) -> {
      writeGatewayError(w, 400, false, "invalid_request_error", e)
      return ()
    }
  }

  var headerNames: slice[String] = ["Authorization"]
  var headerValues: slice[String] = ["Bearer " + apiKey]

  match Web.header(req, "OpenAI-Organization") {
    case Some(o) -> {
      headerNames = headerNames.append("OpenAI-Organization")
      headerValues = headerValues.append(o)
    }
    case None -> ()
  }
  match Web.header(req, "OpenAI-Project") {
    case Some(p) -> {
      headerNames = headerNames.append("OpenAI-Project")
      headerValues = headerValues.append(p)
    }
    case None -> ()
  }

  val isStream = isStreamingRequested(req.body)
  forwardHttpRequest(
    "https://api.openai.com/v1/chat/completions",
    headerNames,
    headerValues,
    req.body,
    isStream,
    w,
    false
  )
}

pub func listModelsJson(): String {
  val userId = CloudAgents.Auth.currentUserId()
  val sc = CloudAgents.Pg.personalScope(userId)
  var agentModelsJson = ""
  match CloudAgents.Repository.listProfiles(sc) {
    case Ok(profiles) -> {
      var i = 0
      while i < profiles.length {
        agentModelsJson = agentModelsJson + ",{\"id\":\"agent:" + CloudAgents.Streaming.jsonEscape(profiles[i].name) + "\",\"object\":\"model\",\"created\":1740000000,\"owned_by\":\"cloud-agents\"}"
        i = i + 1
      }
    }
    case Err(_) -> ()
  }

  return "{\"object\":\"list\",\"data\":[" +
    "{\"id\":\"claude-3-7-sonnet-20250219\",\"object\":\"model\",\"created\":1740000000,\"owned_by\":\"anthropic\"}," +
    "{\"id\":\"claude-3-5-sonnet-20241022\",\"object\":\"model\",\"created\":1729555200,\"owned_by\":\"anthropic\"}," +
    "{\"id\":\"claude-3-5-haiku-20241022\",\"object\":\"model\",\"created\":1729555200,\"owned_by\":\"anthropic\"}," +
    "{\"id\":\"gpt-4o\",\"object\":\"model\",\"created\":1715558400,\"owned_by\":\"openai\"}," +
    "{\"id\":\"gpt-4o-mini\",\"object\":\"model\",\"created\":1721260800,\"owned_by\":\"openai\"}," +
    "{\"id\":\"o1\",\"object\":\"model\",\"created\":1726099200,\"owned_by\":\"openai\"}," +
    "{\"id\":\"o3-mini\",\"object\":\"model\",\"created\":1738281600,\"owned_by\":\"openai\"}" +
    agentModelsJson +
    "]}"
}

pub func listModelsHandler(): Web.Response {
  val resp = Web.text(200, listModelsJson())
  return Web.withResponseHeader(resp, "Content-Type", "application/json")
}
