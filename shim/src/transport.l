//! src/transport.l — CloudAgents.Shim.Transport: the shim's HTTP boundary
//! against the cloud-agents host API (docs/phase6-mcp-callbacks.md §5),
//! plus the wire records mirroring CloudAgents.Callbacks (cloud-agents'
//! src/handlers/callbacks.l) field-for-field.
//!
//! Uses direct System.Net.HttpWebRequest bindings rather than Std.Http —
//! same reasoning as cloud-agents' own src/github_api.l: every call here
//! needs an Authorization header, and Std.Http's documented surface has no
//! way to set one. Fully synchronous (no `async func`): keeps this package
//! importable directly from a `@test_module` (docs/lyric/gotchas.md — a
//! test module cannot invoke anything reached by importing a package that
//! contains `async func`s, even a pure non-async one) and matches
//! Mcp.Server's own tool-handler contract (`McpToolHandler.call` is
//! synchronous).
//!
//! Response bodies here can carry arbitrary human-authored text (a
//! reviewer's note, a question, an answer) so — unlike github_api.l's
//! ASCII-only `readAll` used for its OAuth fields — this module always
//! decodes as real UTF-8 (`readAllUtf8`, the same byte-buffer approach
//! github_api.l uses for proxy passthrough) to avoid mangling non-ASCII
//! text.
package CloudAgents.Shim.Transport

import Std.Core

extern type HttpWebRequest = "System.Net.HttpWebRequest"

extern type WebResponse = "System.Net.WebResponse"

extern type NetStream = "System.IO.Stream"

extern type WebHeaderCollection = "System.Net.WebHeaderCollection"

extern type Encoding = "System.Text.Encoding"

extern type TextWriter = "System.IO.TextWriter"

@externTarget("System.Net.WebRequest.Create")
func createRequest(url: in String): HttpWebRequest = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_Method")
func setMethod(req: in HttpWebRequest, method: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_Accept")
func setAccept(req: in HttpWebRequest, accept: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_ContentType")
func setContentType(req: in HttpWebRequest, contentType: in String): Unit = ()

/// Milliseconds before GetResponse gives up connecting/reading headers.
@externInstance
@externTarget("System.Net.HttpWebRequest.set_Timeout")
func setTimeout(req: in HttpWebRequest, millis: in Int): Unit = ()

/// Milliseconds a body read/write may stall (see github_api.l's identical
/// binding for why this is set separately from Timeout above — #427 there).
@externInstance
@externTarget("System.Net.HttpWebRequest.set_ReadWriteTimeout")
func setReadWriteTimeout(req: in HttpWebRequest, millis: in Int): Unit = ()

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
func getResponse(req: in HttpWebRequest): WebResponse = ()

@externInstance
@externTarget("System.Net.WebResponse.GetResponseStream")
func getResponseStream(resp: in WebResponse): NetStream = ()

@externInstance
@externTarget("System.IO.Stream.Write")
func streamWrite(s: in NetStream, bytes: in slice[Byte], offset: in Int, count: in Int): Unit = ()

// `buf` is `slice[Byte]` — deliberately NOT an `extern type = "System.Byte[]"`
// alias (the `ByteArray`/`Array.CreateInstance` shape this file used before):
// an extern-type-alias value marshals as `System.Object` across the FFI
// boundary and only matches `System.Array`-typed overloads, so a
// `ByteArray`-typed parameter here resolves to a nonexistent
// `Stream.Read(System.Object, Int32, Int32)` overload — confirmed at runtime
// (`Method not found`) by the #541 e2e seeded-session leg, the first thing
// in this codebase to actually read a real, successful HTTP response body
// over this transport (every other caller only ever hit an error status,
// which throws before any read happens). `slice[Byte]` marshals directly to
// `byte[]` (docs/lyric/reference.md "Cross-boundary marshalling": "Slices →
// arrays") and is the pattern `src/crypto/crypto.l` documents as the fix for
// this exact class of bug.
@externInstance
@externTarget("System.IO.Stream.Read")
func streamRead(s: in NetStream, buf: in slice[Byte], offset: in Int, count: in Int): Int = 0

@externInstance
@externTarget("System.IDisposable.Dispose")
func streamDispose(s: in NetStream): Unit = ()

@externInstance
@externTarget("System.IDisposable.Dispose")
func responseDispose(r: in WebResponse): Unit = ()

@externTarget("System.Text.Encoding.get_UTF8")
func utf8(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetBytes")
func encGetBytes(enc: in Encoding, s: in String): slice[Byte] = []

@externInstance
@externTarget("System.Text.Encoding.GetString")
func encGetStringRange(enc: in Encoding, bytes: in slice[Byte], index: in Int, count: in Int): String = ()

// ── stderr — never write to stdout ──────────────────────────────────────────
// serveStdio (Mcp.Server, via JsonRpc.Stdio's NdjsonTransport) frames every
// protocol message as one NDJSON line on stdout. Any other stdout write
// (println, an uncaught printed exception, ...) corrupts that framing for
// the whole session. Diagnostics from this shim MUST go to stderr instead.
@externTarget("System.Console.get_Error")
func consoleError(): TextWriter = ()

@externInstance
@externTarget("System.IO.TextWriter.WriteLine")
func writerWriteLine(w: in TextWriter, s: in String): Unit = ()

/// Write a diagnostic line to stderr. Never call `println` (stdout) from
/// this project while the MCP server is serving stdio.
pub func eprintln(s: in String): Unit {
  writerWriteLine(consoleError(), s)
}

// ── Sleep (long-poll pacing) ────────────────────────────────────────────────
@externTarget("System.Threading.Thread.Sleep")
func threadSleep(millis: in Int): Unit = ()

/// Sleep for `millis` milliseconds. Used between long-poll attempts
/// (CloudAgents.Shim.Callbacks); tests pass small interval/timeout values
/// rather than faking the clock, so real (sub-millisecond-cost) sleeps here
/// are fine.
pub func sleepMillis(millis: in Int): Unit {
  if millis > 0 {
    threadSleep(millis)
  }
}

val requestTimeoutMillis = 15000

// A note/question/answer/summary body is bounded by CloudAgents.Callbacks'
// own server-side max-length constants (a few KB); this cap only guards
// against a misbehaving peer, mirroring github_api.l's maxProxyResponseBytes.
val maxResponseBytes = 1048576

// Fixed-size read buffer, built once per call by appending Byte zeros —
// `slice[Byte]` has no direct "allocate N zeroed elements" constructor, and
// `Stream.Read(byte[], offset, count)` needs a real, already-sized
// destination array to write into (unlike `Stream.Write`, which just
// consumes an existing `slice[Byte]` — see `streamWrite` above, which never
// needed this). 8 KiB keeps the append loop trivially fast while still
// reading a typical callback body in one or two calls.
val chunkSize = 8192

func zeroedChunk(): slice[Byte] {
  var buf: slice[Byte] = []
  var i = 0
  while i < chunkSize {
    buf = buf.append(0.toByte())
    i = i + 1
  }
  return buf
}

/// Read a response stream to a String, decoded as real UTF-8 (see module
/// doc — callback bodies carry human-authored text), chunk by chunk so no
/// single oversized buffer allocation is needed. Mirrors github_api.l's
/// `readAllUtf8` in spirit (same UTF-8-safe block-read idea), but reads into
/// a reused fixed-size `slice[Byte]` chunk and decodes+concatenates each
/// chunk's valid prefix, rather than one `maxResponseBytes`-sized buffer.
func readAllUtf8(s: in NetStream): String {
  val buf = zeroedChunk()
  var result = ""
  var total = 0
  var n = 1
  while n > 0 and total < maxResponseBytes {
    n = streamRead(s, buf, 0, chunkSize)
    if n > 0 {
      result = result + encGetStringRange(utf8(), buf, 0, n)
      total = total + n
    }
  }
  return result
}

/// GET `url` with an Authorization bearer header, returning the raw
/// response body (or a transport-level error message). Any non-2xx status
/// or transport failure surfaces as `Err` — GetResponse throws on both.
pub func getWithBearer(url: in String, bearerToken: in String): Result[String, String] {
  return try {
    val req = createRequest(url)
    setMethod(req, "GET")
    setTimeout(req, requestTimeoutMillis)
    setReadWriteTimeout(req, requestTimeoutMillis)
    setAccept(req, "application/json")
    headerSet(getHeaders(req), "Authorization", "Bearer " + bearerToken)
    val resp = getResponse(req)
    defer {
      responseDispose(resp)
    }
    val stream = getResponseStream(resp)
    defer {
      streamDispose(stream)
    }
    val body = readAllUtf8(stream)
    Ok(value = body)
  } catch Bug as b {
    Err(error = "GET " + url + " failed: " + b.message)
  }
}

/// POST a JSON body to `url` with an Authorization bearer header, returning
/// the raw response body (or a transport-level error message).
pub func postJsonWithBearer(url: in String, bearerToken: in String, jsonBody: in String): Result[String, String] {
  return try {
    val req = createRequest(url)
    setMethod(req, "POST")
    setTimeout(req, requestTimeoutMillis)
    setReadWriteTimeout(req, requestTimeoutMillis)
    setAccept(req, "application/json")
    setContentType(req, "application/json")
    headerSet(getHeaders(req), "Authorization", "Bearer " + bearerToken)
    val bytes = encGetBytes(utf8(), jsonBody)
    val reqStream = getRequestStream(req)
    // The request stream must be closed BEFORE getResponse (it finalises
    // the request body), hence the explicit dispose after the write. The
    // defer is the exception-path guard: if streamWrite throws mid-body,
    // the stream still gets released (Stream.Dispose is idempotent, so the
    // double dispose on the success path is harmless) — the same pattern
    // as src/github_api.l (#421, #539).
    defer {
      streamDispose(reqStream)
    }
    streamWrite(reqStream, bytes, 0, bytes.length.toInt())
    streamDispose(reqStream)
    val resp = getResponse(req)
    defer {
      responseDispose(resp)
    }
    val respStream = getResponseStream(resp)
    defer {
      streamDispose(respStream)
    }
    val body = readAllUtf8(respStream)
    Ok(value = body)
  } catch Bug as b {
    Err(error = "POST " + url + " failed: " + b.message)
  }
}

// ── Wire records — mirror CloudAgents.Callbacks (cloud-agents'
// src/handlers/callbacks.l) field-for-field. Keep these two in sync by hand;
// a mismatch here is a shim/host protocol break. ────────────────────────────
@generate(Json)
pub record CreatePermissionRequestRequest {
  pub toolName: String
  pub inputJson: String
}

@generate(Json)
pub record CreatePermissionRequestResponse {
  pub id: String
  pub status: String
}

@generate(Json)
pub record PermissionDecision {
  pub status: String
  pub updatedInputJson: String
  pub note: String
}

@generate(Json)
pub record CreateUserQuestionRequest {
  pub question: String
  pub optionsJson: String
}

@generate(Json)
pub record CreateUserQuestionResponse {
  pub id: String
}

@generate(Json)
pub record UserQuestionAnswer {
  pub status: String
  pub answer: String
}

@generate(Json)
pub record ReportProgressRequest {
  pub summary: String
  pub percentComplete: String
}

// ── Decoding helpers ─────────────────────────────────────────────────────────
// `@generate(Json)`'s `.fromJson` returns `Result[T, JsonError]` for a
// schema mismatch, but a syntactically invalid JSON body (exactly what "the
// host returned garbage" looks like) throws a raw
// `System.Text.Json.JsonException` instead of returning `Err` — confirmed
// by direct testing, not documented upstream. These wrappers catch that and
// fold both failure modes into a plain `Option`, so
// CloudAgents.Shim.Callbacks can treat "malformed response" uniformly
// regardless of which failure mode fired.
pub func tryDecodeCreatePermissionRequestResponse(body: in String): Option[CreatePermissionRequestResponse] {
  try {
    match CreatePermissionRequestResponse.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

pub func tryDecodePermissionDecision(body: in String): Option[PermissionDecision] {
  try {
    match PermissionDecision.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

pub func tryDecodeCreateUserQuestionResponse(body: in String): Option[CreateUserQuestionResponse] {
  try {
    match CreateUserQuestionResponse.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

pub func tryDecodeUserQuestionAnswer(body: in String): Option[UserQuestionAnswer] {
  try {
    match UserQuestionAnswer.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

// ── Transport seam ───────────────────────────────────────────────────────────
/// The shim's outbound calls to the host, as an interface so
/// CloudAgents.Shim.Callbacks' state machine can be tested against an
/// in-memory fake (tests/fakes.l) with no real socket. Each method returns
/// the raw response body string (or an `Err` transport-level message);
/// decoding/interpreting the body is CloudAgents.Shim.Callbacks' job.
pub interface CallbackTransport {
  func createPermission(toolName: in String, inputJson: in String): Result[String, String]
  func pollPermission(requestId: in String): Result[String, String]
  func createQuestion(question: in String, optionsJson: in String): Result[String, String]
  func pollQuestion(requestId: in String): Result[String, String]
  func reportProgress(summary: in String, percentComplete: in String): Result[Unit, String]
}

/// Real `CallbackTransport` against the cloud-agents host API. Route shapes
/// match CloudAgents.Callbacks / src/main.l's route table exactly
/// (docs/phase6-mcp-callbacks.md §5): POST .../callbacks/permission, GET
/// .../callbacks/permission/{rid}, POST .../callbacks/question, GET
/// .../callbacks/question/{rid}, POST .../callbacks/progress.
pub record HttpCallbackTransport {
  pub baseUrl: String
  pub sessionId: String
  pub token: String
}

impl CallbackTransport for HttpCallbackTransport {
  func createPermission(toolName: in String, inputJson: in String): Result[String, String] {
    val body = CreatePermissionRequestRequest(toolName = toolName, inputJson = inputJson).toJson()
    postJsonWithBearer(self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/permission", self.token, body)
  }

  func pollPermission(requestId: in String): Result[String, String] {
    getWithBearer(self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/permission/" + requestId, self.token)
  }

  func createQuestion(question: in String, optionsJson: in String): Result[String, String] {
    val body = CreateUserQuestionRequest(question = question, optionsJson = optionsJson).toJson()
    postJsonWithBearer(self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/question", self.token, body)
  }

  func pollQuestion(requestId: in String): Result[String, String] {
    getWithBearer(self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/question/" + requestId, self.token)
  }

  func reportProgress(summary: in String, percentComplete: in String): Result[Unit, String] {
    val body = ReportProgressRequest(summary = summary, percentComplete = percentComplete).toJson()
    match postJsonWithBearer(self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/progress", self.token, body) {
      case Ok(_) -> Ok(value = ())
      case Err(e) -> Err(error = e)
    }
  }
}
