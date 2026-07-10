//! Docker client — High-level API for Docker daemon operations.
//!
//! Provides convenience functions for interacting with the Docker daemon.
//! Each public function connects to the daemon via the default socket
//! (honouring DOCKER_HOST) and returns a typed Result.
//!
//! ```lyric
//! match await Docker.ping() {
//!   case Ok(version) -> println("Docker API version: " + version)
//!   case Err(e) -> println("Error: " + e.message)
//! }
//! ```
@runtime_checked
package Lyric.Docker

import Lyric.Docker.Sockets
import Std.Core
import Std.Errors
import Std.Http

/// Docker error type — encapsulates HTTP errors with Docker-specific context.
pub record DockerError {
  /// HTTP status code (if available).
  pub statusCode: Option[Int]
  /// Error message.
  pub message: String
  /// Docker error details from response body (if available).
  pub details: String
}

func fromHttpError(httpError: in HttpError, details: in String): DockerError {
  match httpError {
    case ConnectionFailed(_, message) -> DockerError(statusCode = None, message = message, details = details)
    case BadStatus(_, statusCode) -> DockerError(statusCode = Some(value = statusCode), message = "HTTP " + toString(statusCode), details = details)
    case InvalidUrl(url) -> DockerError(statusCode = None, message = "Invalid Docker URL: " + url, details = details)
    case _ -> DockerError(statusCode = None, message = "Unknown Docker error", details = details)
  }
}

/// Resolve the Docker daemon socket and return a configured HTTP client.
/// Not exposed publicly — HttpClient is an extern type and must not appear
/// in public signatures (contract synthesis limitation).
func defaultClient(): HttpClient {
  val socketPath = match Lyric.Docker.Sockets.parseDockerHost() {
    case Some(p) -> p
    case None -> Lyric.Docker.Sockets.unixSocketPath()
  }
  Std.Http.clientWithUnixSocket(socketPath)
}

/// Ping the Docker daemon to verify connectivity.
pub async func ping(): Result[String, DockerError] {
  val client = defaultClient()
  val url = Std.Http.Url.tryFrom("http://docker/v1.40/ping").unwrap()
  val sent = await client.send(Std.Http.request(Std.Http.GET, url))
  val response = match sent { case Err(e) -> return Err(error = fromHttpError(e, "")); case Ok(r) -> r }
  if response.isSuccess() {
    Ok(value = "connected")
  } else {
    val statusCode = response.statusCode()
    val bodyResult = await response.bodyText()
    match bodyResult {
      case Ok(body) -> Err(error = DockerError(statusCode = Some(value = statusCode), message = "Ping failed", details = body))
      case Err(ioErr) -> Err(error = fromHttpError(ConnectionFailed(url = "http://docker/v1.40/ping", message = IOError.message(ioErr)), ""))
    }
  }
}

// ─── Container lifecycle ──────────────────────────────────────────────────────
//
// The daemon's JSON decoder rejects raw control characters (U+0000–U+001F) in
// string literals, and env values routinely contain them: multi-line PROMPT
// (newlines) or pasted terminal output (ESC and friends). Without full
// escaping any such prompt made the whole create-container body unparseable.
// Lyric string literals cannot express these bytes, so the helpers below go
// through the BCL — same approach as CloudAgents.Streaming.
@externTarget("System.String.CompareOrdinal")
func strCompareOrdinal(a: in String, b: in String): Int = ()

/// The single-character string for a Unicode code point. Exposed so tests can
/// construct control characters that Lyric literals cannot express.
@externTarget("System.Char.ConvertFromUtf32")
pub func charFromCode(code: in Int): String = ()

/// True for a single UTF-16 unit below U+0020. Ordinal comparison against " "
/// is exact here: any unit >= 0x20 (including lone surrogates) compares >= 0.
func isControlChar(c: in String): Bool {
  return strCompareOrdinal(c, " ") < 0
}

func hexDigit(n: in Int): String {
  if n == 10 {
    return "a"
  }
  if n == 11 {
    return "b"
  }
  if n == 12 {
    return "c"
  }
  if n == 13 {
    return "d"
  }
  if n == 14 {
    return "e"
  }
  if n == 15 {
    return "f"
  }
  return toString(n)
}

/// The `\u00XX` escape for a control character (code point below 0x20).
func controlEscape(c: in String): String {
  var code = 0
  while code < 32 {
    if charFromCode(code) == c {
      if code < 16 {
        return "\\u000" + hexDigit(code)
      }
      return "\\u001" + hexDigit(code - 16)
    }
    code = code + 1
  }
  return c // unreachable: isControlChar guarantees code < 32
}

/// Escape a string for embedding in a JSON string literal. Pub for test
/// coverage — createContainerBody feeds every env value through this.
pub func jsonEscapeValue(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    if c == "\"" {
      acc = acc + "\\\""
    } else if c == "\\" {
      acc = acc + "\\\\"
    } else if c == "\n" {
      acc = acc + "\\n"
    } else if c == "\r" {
      acc = acc + "\\r"
    } else if c == "\t" {
      acc = acc + "\\t"
    } else if isControlChar(c) {
      acc = acc + controlEscape(c)
    } else {
      acc = acc + c
    }
    i = i + 1
  }
  return acc
}

func jsonStringArray(items: in slice[String]): String {
  var acc = "["
  var i = 0
  while i < items.length {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + "\"" + jsonEscapeValue(items[i]) + "\""
    i = i + 1
  }
  return acc + "]"
}

func createContainerBody(
  image: in String, env: in slice[String], binds: in slice[String], networkMode: in String
): String {
  // NetworkMode is only emitted when set, so callers that don't care keep the
  // Docker default (bridge). An empty networkMode -> field omitted.
  var hostConfig = "\"Binds\":" + jsonStringArray(binds)
  if networkMode.length > 0 {
    hostConfig = hostConfig + ",\"NetworkMode\":\"" + jsonEscapeValue(networkMode) + "\""
  }
  return "{\"Image\":\"" + jsonEscapeValue(image) + "\"," + "\"Env\":" + jsonStringArray(env) + "," +
    "\"HostConfig\":{" +
    hostConfig +
    "}}"
}

/// Pure builder exposed for tests: the create-container request body with an
/// explicit NetworkMode (empty = Docker default).
pub func containerBodyWithNetwork(
  image: in String, env: in slice[String], binds: in slice[String], networkMode: in String
): String {
  return createContainerBody(image, env, binds, networkMode)
}

func indexOfSub(hay: in String, needle: in String): Int {
  val hayLen = hay.length.toInt()
  val needleLen = needle.length.toInt()
  if needleLen == 0 {
    return 0
  }
  var i = 0
  val last = hayLen - needleLen
  while i <= last {
    var j = 0
    var matched = true
    while j < needleLen {
      if hay.substring(i + j, 1) != needle.substring(j, 1) {
        matched = false
        j = needleLen
      } else {
        j = j + 1
      }
    }
    if matched {
      return i
    }
    i = i + 1
  }
  return -1
}

func extractJsonField(json: in String, field: in String): String {
  val target = "\"" + field + "\""
  val pos = indexOfSub(json, target)
  if pos < 0 {
    return ""
  }
  val jsonLen = json.length.toInt()
  var i = pos + target.length.toInt()
  var inValue = false
  var start = 0
  while i < jsonLen {
    val c = json.substring(i, 1)
    if not inValue {
      if c == "\"" {
        inValue = true
        start = i + 1
      }
      i = i + 1
    } else {
      if c == "\"" {
        return json.substring(start, i - start)
      }
      i = i + 1
    }
  }
  return ""
}

async func sendExpectSuccess(
  client: in HttpClient,
  urlStr: in String,
  method: in Std.Http.HttpMethod,
  failMsg: in String,
): Result[Unit, DockerError] {
  val url = Std.Http.Url.tryFrom(urlStr).unwrap()
  val sent = await client.send(Std.Http.request(method, url))
  val response = match sent { case Err(e) -> return Err(error = fromHttpError(e, "")); case Ok(r) -> r }
  if response.isSuccess() {
    Ok(value = ())
  } else {
    val statusCode = response.statusCode()
    val bodyResult = await response.bodyText()
    val details = match bodyResult { case Ok(b) -> b; case Err(_) -> "" }
    Err(error = DockerError(statusCode = Some(value = statusCode), message = failMsg, details = details))
  }
}

/// Create a container from an image with environment variables and volume binds.
/// Returns the new container id. Uses the Docker default network.
pub async func createContainer(
  image: in String, env: in slice[String], binds: in slice[String]
): Result[String, DockerError] {
  return await createContainerWithNetwork(image, env, binds, "")
}

/// Create a container, additionally pinning the container's NetworkMode (e.g.
/// "none" for full isolation). An empty networkMode keeps the Docker default.
pub async func createContainerWithNetwork(
  image: in String, env: in slice[String], binds: in slice[String], networkMode: in String
): Result[String, DockerError] {
  val client = defaultClient()
  val url = Std.Http.Url.tryFrom("http://docker/v1.40/containers/create").unwrap()
  val request = Std.Http.withJsonBody(Std.Http.request(Std.Http.POST, url), createContainerBody(image, env, binds, networkMode))
  val sent = await client.send(request)
  val response = match sent { case Err(e) -> return Err(error = fromHttpError(e, "")); case Ok(r) -> r }
  if response.isSuccess() {
    val bodyResult = await response.bodyText()
    match bodyResult {
      case Ok(body) -> {
        val id = extractJsonField(body, "Id")
        if id.length > 0 {
          Ok(value = id)
        } else {
          Err(error = DockerError(statusCode = None, message = "Create container returned no Id", details = body))
        }
      }
      case Err(ioErr) -> Err(error = fromHttpError(ConnectionFailed(url = "http://docker/v1.40/containers/create", message = IOError.message(ioErr)), ""))
    }
  } else {
    val statusCode = response.statusCode()
    val bodyResult = await response.bodyText()
    val details = match bodyResult { case Ok(b) -> b; case Err(_) -> "" }
    Err(
      error = DockerError(statusCode = Some(value = statusCode), message = "Create container failed", details = details)
    )
  }
}

/// Start a created container.
pub async func startContainer(containerId: in String): Result[Unit, DockerError]
  requires: containerId.length > 0
{
  await sendExpectSuccess(defaultClient(), "http://docker/v1.40/containers/" + containerId + "/start", Std.Http.POST, "Start container failed")
}

/// Stop a running container.
pub async func stopContainer(containerId: in String): Result[Unit, DockerError]
  requires: containerId.length > 0
{
  await sendExpectSuccess(defaultClient(), "http://docker/v1.40/containers/" + containerId + "/stop", Std.Http.POST, "Stop container failed")
}

/// Remove a container.
pub async func removeContainer(containerId: in String): Result[Unit, DockerError]
  requires: containerId.length > 0
{
  await sendExpectSuccess(defaultClient(), "http://docker/v1.40/containers/" + containerId + "?force=true", Std.Http.DELETE, "Remove container failed")
}

/// Block until a container exits.
pub async func waitContainer(containerId: in String): Result[Unit, DockerError]
  requires: containerId.length > 0
{
  await sendExpectSuccess(defaultClient(), "http://docker/v1.40/containers/" + containerId + "/wait", Std.Http.POST, "Wait for container failed")
}

/// Fetch a container's combined stdout/stderr logs.
pub async func getContainerLogs(containerId: in String): Result[String, DockerError]
  requires: containerId.length > 0
{
  val client = defaultClient()
  val urlStr = "http://docker/v1.40/containers/" + containerId + "/logs?stdout=true&stderr=true"
  val url = Std.Http.Url.tryFrom(urlStr).unwrap()
  val sent = await client.send(Std.Http.request(Std.Http.GET, url))
  val response = match sent { case Err(e) -> return Err(error = fromHttpError(e, "")); case Ok(r) -> r }
  if response.isSuccess() {
    val bodyResult = await response.bodyText()
    match bodyResult {
      case Ok(body) -> Ok(value = body)
      case Err(ioErr) -> Err(error = fromHttpError(ConnectionFailed(url = urlStr, message = IOError.message(ioErr)), ""))
    }
  } else {
    val statusCode = response.statusCode()
    Err(error = DockerError(statusCode = Some(value = statusCode), message = "Get container logs failed", details = ""))
  }
}
