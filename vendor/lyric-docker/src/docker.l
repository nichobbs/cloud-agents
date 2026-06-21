//! Docker client — High-level API for Docker daemon operations.
//!
//! Provides convenience functions and types for interacting with the Docker
//! daemon. Abstracts away HTTP details and provides typed results via
//! Result[T, DockerError].
//!
//! The connection is exposed as the opaque `DockerClient` handle so the
//! underlying transport never crosses the package boundary.
//!
//! ```lyric
//! val client = Docker.makeDockerClient()
//! match await Docker.ping(client) {
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

/// Opaque handle to a Docker daemon connection. Wraps the underlying HTTP
/// client so callers never touch the extern transport type.
pub opaque type DockerClient {
  handle: Std.Http.HttpClient
}

/// Docker error type — encapsulates HTTP errors with Docker-specific context.
pub record DockerError {
  /// HTTP status code (if available).
  pub statusCode: Option[Int]
  /// Error message.
  pub message: String
  /// Docker error details from response body (if available).
  pub details: String
}

/// Create a new Docker error from an HTTP error.
func fromHttpError(httpError: in HttpError, details: in String): DockerError {
  match httpError {
    case ConnectionFailed(_, message) ->
      DockerError(statusCode = None, message = message, details = details)
    case BadStatus(_, statusCode) ->
      DockerError(statusCode = Some(value = statusCode), message = "HTTP " + toString(statusCode), details = details)
    case InvalidUrl(url) ->
      DockerError(statusCode = None, message = "Invalid Docker URL: " + url, details = details)
    case _ ->
      DockerError(statusCode = None, message = "Unknown Docker error", details = details)
  }
}

/// Connect to the Docker daemon, honouring DOCKER_HOST then the default
/// Unix socket.
pub func makeDockerClient(): DockerClient {
  val socketPath = match Lyric.Docker.Sockets.parseDockerHost() {
    case Some(p) -> p
    case None -> Lyric.Docker.Sockets.unixSocketPath()
  }
  DockerClient(handle = Std.Http.clientWithUnixSocket(socketPath))
}

/// Connect to the Docker daemon in rootless mode ($XDG_RUNTIME_DIR/docker.sock).
pub func makeRootlessDockerClient(): Result[DockerClient, DockerError] {
  match Lyric.Docker.Sockets.resolveRootlessSocket() {
    case Ok(socketPath) -> Ok(value = DockerClient(handle = Std.Http.clientWithUnixSocket(socketPath)))
    case Err(message) -> Err(error = DockerError(statusCode = None, message = message, details = ""))
  }
}

/// Connect to the Docker daemon at a custom socket path.
pub func makeDockerClientAt(socketPath: in String): DockerClient
  requires: socketPath.length > 0
{
  DockerClient(handle = Std.Http.clientWithUnixSocket(socketPath))
}

/// Ping the Docker daemon to verify connectivity.
pub async func ping(client: in DockerClient): Result[String, DockerError] {
  val url = unwrapResult(Std.Http.Url.tryFrom("http://docker/v1.40/ping"))
  val sent = await client.handle.send(Std.Http.request(Std.Http.GET, url))
  val response = match sent {
    case Err(e) -> return Err(error = fromHttpError(e, ""))
    case Ok(r) -> r
  }

  if response.isSuccess() {
    Ok(value = "connected")
  } else {
    val statusCode = response.statusCode()
    val bodyResult = await response.bodyText()
    match bodyResult {
      case Ok(body) ->
        Err(error = DockerError(
          statusCode = Some(value = statusCode),
          message = "Ping failed",
          details = body
        ))
      case Err(ioErr) ->
        Err(error = fromHttpError(
          ConnectionFailed(url = "http://docker/v1.40/ping", message = IOError.message(ioErr)), ""
        ))
    }
  }
}

/// Get Docker system information (JSON-formatted).
pub async func systemInfo(client: in DockerClient): Result[String, DockerError] {
  val url = unwrapResult(Std.Http.Url.tryFrom("http://docker/v1.40/info"))
  val sent = await client.handle.send(Std.Http.request(Std.Http.GET, url))
  val response = match sent {
    case Err(e) -> return Err(error = fromHttpError(e, ""))
    case Ok(r) -> r
  }

  if response.isSuccess() {
    val bodyResult = await response.bodyText()
    match bodyResult {
      case Ok(body) -> Ok(value = body)
      case Err(ioErr) ->
        Err(error = fromHttpError(
          ConnectionFailed(url = "http://docker/v1.40/info", message = IOError.message(ioErr)), ""
        ))
    }
  } else {
    val statusCode = response.statusCode()
    val bodyResult = await response.bodyText()
    match bodyResult {
      case Ok(body) ->
        Err(error = DockerError(
          statusCode = Some(value = statusCode),
          message = "System info failed",
          details = body
        ))
      case Err(ioErr) ->
        Err(error = fromHttpError(
          ConnectionFailed(url = "http://docker/v1.40/info", message = IOError.message(ioErr)), ""
        ))
    }
  }
}

/// List all containers (Phase 1 placeholder: returns the JSON array).
pub async func listContainers(client: in DockerClient): Result[String, DockerError] {
  val url = unwrapResult(Std.Http.Url.tryFrom("http://docker/v1.40/containers/json"))
  val sent = await client.handle.send(Std.Http.request(Std.Http.GET, url))
  val response = match sent {
    case Err(e) -> return Err(error = fromHttpError(e, ""))
    case Ok(r) -> r
  }

  if response.isSuccess() {
    val bodyResult = await response.bodyText()
    match bodyResult {
      case Ok(body) -> Ok(value = body)
      case Err(ioErr) ->
        Err(error = fromHttpError(
          ConnectionFailed(url = "http://docker/v1.40/containers/json", message = IOError.message(ioErr)), ""
        ))
    }
  } else {
    val statusCode = response.statusCode()
    val bodyResult = await response.bodyText()
    match bodyResult {
      case Ok(body) ->
        Err(error = DockerError(
          statusCode = Some(value = statusCode),
          message = "List containers failed",
          details = body
        ))
      case Err(ioErr) ->
        Err(error = fromHttpError(
          ConnectionFailed(url = "http://docker/v1.40/containers/json", message = IOError.message(ioErr)), ""
        ))
    }
  }
}

/// List all images (Phase 1 placeholder: returns the JSON array).
pub async func listImages(client: in DockerClient): Result[String, DockerError] {
  val url = unwrapResult(Std.Http.Url.tryFrom("http://docker/v1.40/images/json"))
  val sent = await client.handle.send(Std.Http.request(Std.Http.GET, url))
  val response = match sent {
    case Err(e) -> return Err(error = fromHttpError(e, ""))
    case Ok(r) -> r
  }

  if response.isSuccess() {
    val bodyResult = await response.bodyText()
    match bodyResult {
      case Ok(body) -> Ok(value = body)
      case Err(ioErr) ->
        Err(error = fromHttpError(
          ConnectionFailed(url = "http://docker/v1.40/images/json", message = IOError.message(ioErr)), ""
        ))
    }
  } else {
    val statusCode = response.statusCode()
    val bodyResult = await response.bodyText()
    match bodyResult {
      case Ok(body) ->
        Err(error = DockerError(
          statusCode = Some(value = statusCode),
          message = "List images failed",
          details = body
        ))
      case Err(ioErr) ->
        Err(error = fromHttpError(
          ConnectionFailed(url = "http://docker/v1.40/images/json", message = IOError.message(ioErr)), ""
        ))
    }
  }
}

// ─── Container lifecycle ──────────────────────────────────────────────────────
//
// Operations the cloud-agents runner needs: create a container from an image
// with env + volume binds, start/stop/remove it, and fetch its logs. Bodies are
// built as JSON by hand (no reflection); responses are parsed with a small
// field scanner.

/// Default Docker connection (honours DOCKER_HOST, else the standard socket).
pub func defaultClient(): DockerClient {
  makeDockerClient()
}

/// Escape a string for embedding in a JSON string literal.
func jsonEscapeValue(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    if c == "\"" {
      acc = acc + "\\\""
    } else if c == "\\" {
      acc = acc + "\\\\"
    } else {
      acc = acc + c
    }
    i = i + 1
  }
  return acc
}

/// Render a slice of strings as a JSON array: ["a","b"].
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

/// Build the JSON body for POST /containers/create.
func createContainerBody(image: in String, env: in slice[String], binds: in slice[String]): String {
  return "{\"Image\":\"" + jsonEscapeValue(image) + "\"," +
    "\"Env\":" + jsonStringArray(env) + "," +
    "\"HostConfig\":{\"Binds\":" + jsonStringArray(binds) + "}}"
}

/// First index of `needle` in `hay`, or -1. Manual scan (the compiler's
/// indexOf/Option path is unreliable at runtime).
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

/// Extract a quoted string field's value from a JSON object, or "" if absent.
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

/// Send a request expecting only success/failure (no useful body on success).
async func sendExpectSuccess(
  client: in DockerClient,
  urlStr: in String,
  method: in Std.Http.HttpMethod,
  failMsg: in String,
): Result[Unit, DockerError] {
  val url = unwrapResult(Std.Http.Url.tryFrom(urlStr))
  val sent = await client.handle.send(Std.Http.request(method, url))
  val response = match sent {
    case Err(e) -> return Err(error = fromHttpError(e, ""))
    case Ok(r) -> r
  }

  if response.isSuccess() {
    Ok(value = ())
  } else {
    val statusCode = response.statusCode()
    val bodyResult = await response.bodyText()
    val details = match bodyResult {
      case Ok(b) -> b
      case Err(_) -> ""
    }
    Err(error = DockerError(statusCode = Some(value = statusCode), message = failMsg, details = details))
  }
}

/// Create a container from an image with environment variables and volume binds.
/// Returns the new container id.
pub async func createContainer(
  client: in DockerClient,
  image: in String,
  env: in slice[String],
  binds: in slice[String]
): Result[String, DockerError] {
  val url = unwrapResult(Std.Http.Url.tryFrom("http://docker/v1.40/containers/create"))
  val request = Std.Http.withJsonBody(Std.Http.request(Std.Http.POST, url), createContainerBody(image, env, binds))
  val sent = await client.handle.send(request)
  val response = match sent {
    case Err(e) -> return Err(error = fromHttpError(e, ""))
    case Ok(r) -> r
  }

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
      case Err(ioErr) ->
        Err(error = fromHttpError(
          ConnectionFailed(url = "http://docker/v1.40/containers/create", message = IOError.message(ioErr)), ""
        ))
    }
  } else {
    val statusCode = response.statusCode()
    val bodyResult = await response.bodyText()
    val details = match bodyResult {
      case Ok(b) -> b
      case Err(_) -> ""
    }
    Err(error = DockerError(statusCode = Some(value = statusCode), message = "Create container failed", details = details))
  }
}

/// Start a created container.
pub async func startContainer(client: in DockerClient, containerId: in String): Result[Unit, DockerError]
  requires: containerId.length > 0
{
  await sendExpectSuccess(
    client,
    "http://docker/v1.40/containers/" + containerId + "/start",
    Std.Http.POST,
    "Start container failed"
  )
}

/// Stop a running container.
pub async func stopContainer(client: in DockerClient, containerId: in String): Result[Unit, DockerError]
  requires: containerId.length > 0
{
  await sendExpectSuccess(
    client,
    "http://docker/v1.40/containers/" + containerId + "/stop",
    Std.Http.POST,
    "Stop container failed"
  )
}

/// Remove a container.
pub async func removeContainer(client: in DockerClient, containerId: in String): Result[Unit, DockerError]
  requires: containerId.length > 0
{
  await sendExpectSuccess(
    client,
    "http://docker/v1.40/containers/" + containerId + "?force=true",
    Std.Http.DELETE,
    "Remove container failed"
  )
}

/// Fetch a container's combined stdout/stderr logs.
pub async func getContainerLogs(client: in DockerClient, containerId: in String): Result[String, DockerError]
  requires: containerId.length > 0
{
  val urlStr = "http://docker/v1.40/containers/" + containerId + "/logs?stdout=true&stderr=true"
  val url = unwrapResult(Std.Http.Url.tryFrom(urlStr))
  val sent = await client.handle.send(Std.Http.request(Std.Http.GET, url))
  val response = match sent {
    case Err(e) -> return Err(error = fromHttpError(e, ""))
    case Ok(r) -> r
  }

  if response.isSuccess() {
    val bodyResult = await response.bodyText()
    match bodyResult {
      case Ok(body) -> Ok(value = body)
      case Err(ioErr) ->
        Err(error = fromHttpError(
          ConnectionFailed(url = urlStr, message = IOError.message(ioErr)), ""
        ))
    }
  } else {
    val statusCode = response.statusCode()
    Err(error = DockerError(statusCode = Some(value = statusCode), message = "Get container logs failed", details = ""))
  }
}
