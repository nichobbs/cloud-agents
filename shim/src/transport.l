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

// pub (#545) so tests/transport_tests.l can decode/encode via the exact
// same Encoding chain readAllUtf8/decodeUtf8Chunks use — same rationale as
// github_api.l's identical `pub` on this binding for its own #514
// regression test.
@externTarget("System.Text.Encoding.get_UTF8")
pub func utf8(): Encoding = ()

// pub (#545) — see utf8() above.
@externInstance
@externTarget("System.Text.Encoding.GetBytes")
pub func encGetBytes(enc: in Encoding, s: in String): slice[Byte] = []

// pub (#545) — see utf8() above.
@externInstance
@externTarget("System.Text.Encoding.GetString")
pub func encGetStringRange(enc: in Encoding, bytes: in slice[Byte], index: in Int, count: in Int): String = ()

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

// Fixed-size read buffer, built once by appending Byte zeros — `slice[Byte]`
// has no direct "allocate N zeroed elements" constructor, and
// `Stream.Read(byte[], offset, count)` needs a real, already-sized
// destination array to write into (unlike `Stream.Write`, which just
// consumes an existing `slice[Byte]` — see `streamWrite` above, which never
// needed this). 8 KiB keeps the append loop trivially fast (a one-time cost,
// see `sharedChunkBuf` below) while still reading a typical callback body in
// one or two calls.
val chunkSize = 8192

// pub (#545/#546) so tests/transport_tests.l can confirm this still
// produces a valid, exactly-chunkSize all-zero buffer now that it's only
// ever called once (as sharedChunkBuf's initializer) instead of per call.
pub func zeroedChunk(): slice[Byte] {
  var buf: slice[Byte] = []
  var i = 0
  while i < chunkSize {
    buf = buf.append(0.toByte())
    i = i + 1
  }
  return buf
}

// Built ONCE at module load and reused as the read destination for every
// `readAllUtf8` call (#546) — the previous design called `zeroedChunk()`
// fresh inside `readAllUtf8` itself, so every single shim<->host HTTP round
// trip (every createPermission/pollPermission/createSecret/pollSecret/
// uploadArtifact/... call, including every ~25s long-poll iteration in
// production) repaid the full O(chunkSize^2) `.append()`-loop cost above,
// even though the loop's result never differs between calls. `Stream.Read`
// only ever WRITES INTO this buffer; the read count `n` is tracked/returned
// separately by `streamRead` (see `readAllUtf8` below), so a stale tail past
// index `n` from a previous read is simply never looked at — safe to share
// as long as no two `readAllUtf8` calls are ever in flight at once. This
// package (and every caller of `getWithBearer`/`postJsonWithBearer` in
// `src/callbacks_client.l`, `src/v2_transport.l`, `src/tools.l`) declares no
// `async func`, thread, or parallel/scope primitive anywhere — the module
// doc above notes this is deliberately fully synchronous, matching
// `Mcp.Server`'s own synchronous `McpToolHandler.call` contract, so tool
// calls (and the transport reads they make) never overlap.
val sharedChunkBuf: slice[Byte] = zeroedChunk()

/// Decode a sequence of raw byte chunks as ONE logical UTF-8 byte stream
/// (#545) — concatenating every chunk into a single `slice[Byte]` first and
/// decoding it exactly ONCE, rather than decoding each chunk independently
/// (the previous design, which silently corrupts — not crashes — any
/// multi-byte UTF-8 sequence that happens to straddle a chunk boundary:
/// .NET's default UTF8 decode fallback substitutes a replacement character,
/// U+FFFD, per orphaned half rather than throwing). Pulled out of
/// `readAllUtf8`'s read loop into its own `pub` function purely so
/// `tests/transport_tests.l` can drive this exact accumulate-then-decode-
/// once step directly with synthetic chunks sized to straddle a boundary —
/// `readAllUtf8` itself takes a `NetStream`, which (per
/// `tests/github_api_tests.l`'s identical rationale for
/// `CloudAgents.GitHubApi`'s sibling `readAllUtf8`) this module can only
/// produce via a real HTTP round trip, so it is not invoked directly from
/// tests either. This is the same one-shot-decode shape the pre-#542
/// version of `readAllUtf8` used, just factored out and re-applied.
pub func decodeUtf8Chunks(chunks: in slice[slice[Byte]]): String {
  var acc: slice[Byte] = []
  var i = 0
  while i < chunks.length.toInt() {
    acc = acc.concat(chunks[i])
    i = i + 1
  }
  return encGetStringRange(utf8(), acc, 0, acc.length.toInt())
}

/// Read a response stream to a String, decoded as real UTF-8 (see module
/// doc — callback bodies carry human-authored text). Reads into a reused
/// fixed-size `slice[Byte]` chunk (`sharedChunkBuf`, #546) rather than
/// allocating a fresh one per call, collecting only the actually-read `n`
/// bytes of each chunk (`sharedChunkBuf.slice(0, take)` — never the reused
/// buffer's stale tail, and a fresh, independent copy per docs/lyric/
/// reference.md's "slice ops ... return a new slice" contract, so it's safe
/// to keep around across the next `streamRead` overwriting `sharedChunkBuf`)
/// capped at `maxResponseBytes` total exactly as before (a chunk that would
/// overshoot the cap is trimmed to `take` bytes before being collected),
/// then delegates the actual UTF-8 decoding to `decodeUtf8Chunks` (#545) —
/// one accumulate-then-decode-once pass over every collected chunk, instead
/// of decoding each chunk on its own as the read loop went.
func readAllUtf8(s: in NetStream): String {
  var chunks: slice[slice[Byte]] = []
  var total = 0
  var n = 1
  while n > 0 and total < maxResponseBytes {
    n = streamRead(s, sharedChunkBuf, 0, chunkSize)
    if n > 0 {
      var take = n
      if total + take > maxResponseBytes {
        take = maxResponseBytes - total
      }
      chunks = chunks.append(sharedChunkBuf.slice(0, take))
      total = total + take
    }
  }
  return decodeUtf8Chunks(chunks)
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
