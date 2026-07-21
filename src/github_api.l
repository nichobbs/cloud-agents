//! Outbound HTTPS for the GitHub OAuth flow, via direct BCL bindings
//! (System.Net.HttpWebRequest) — the same extern approach as
//! CloudAgents.Crypto and CloudAgents.Repository.nowMillis.
//!
//! Why not Std.Http: its documented surface (docs/lyric/stdlib.md) exposes
//! `client.get(url)` / `client.post(url, body)` with no way to set a request
//! header, and both GitHub calls here require one (`Authorization` on
//! /user, `Accept: application/json` on the code exchange). HttpWebRequest
//! sets headers through properties and is fully synchronous, which also
//! keeps this package free of `async func`s — so tests can import it
//! directly (docs/lyric/gotchas.md's @test_module restriction).
//!
//! Response bodies are read byte-by-byte and widened char-per-byte, so
//! non-ASCII UTF-8 sequences arrive mangled. That is acceptable here by
//! design: every field the OAuth flow extracts (access_token, id, login,
//! error) is ASCII, and extraction is by substring search, so mangled bytes
//! elsewhere in the body cannot corrupt it. Do not reuse this module for
//! responses where non-ASCII content matters — the proxy endpoints
//! (CloudAgents.Proxy), which pass provider JSON through to the browser
//! verbatim, use httpGetWithHeaders/readAllUtf8 below instead, which decode
//! the response as real UTF-8.
package CloudAgents.GitHubApi

import Std.Core

extern type HttpWebRequest = "System.Net.HttpWebRequest"
extern type WebResponse = "System.Net.WebResponse"
extern type NetStream = "System.IO.Stream"
extern type WebHeaderCollection = "System.Net.WebHeaderCollection"
extern type Encoding = "System.Text.Encoding"

// WebRequest.Create is the BCL's static factory for HttpWebRequest (there is
// no constructor-binding form of @externTarget in this toolchain — all object
// creation goes through static factories, same as Aes.Create in crypto.l).
// The declared return type narrows the BCL's WebRequest to HttpWebRequest,
// the same way sqlite_driver.l narrows Array.GetValue's Object return.
@externTarget("System.Net.WebRequest.Create")
func createRequest(url: in String): HttpWebRequest = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_Method")
func setMethod(req: in HttpWebRequest, method: in String): Unit = ()

// UserAgent/Accept/ContentType are "restricted" headers on the Headers
// collection and must be set through their dedicated properties.
@externInstance
@externTarget("System.Net.HttpWebRequest.set_UserAgent")
func setUserAgent(req: in HttpWebRequest, ua: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_Accept")
func setAccept(req: in HttpWebRequest, accept: in String): Unit = ()

@externInstance
@externTarget("System.Net.HttpWebRequest.set_ContentType")
func setContentType(req: in HttpWebRequest, contentType: in String): Unit = ()

/// Milliseconds before GetResponse gives up.
@externInstance
@externTarget("System.Net.HttpWebRequest.set_Timeout")
func setTimeout(req: in HttpWebRequest, millis: in Int): Unit = ()

/// Milliseconds a body read/write may stall. Timeout above only bounds
/// GetResponse(); without this, body reads default to .NET's 5-minute
/// ReadWriteTimeout and a slow peer could pin a request thread far longer
/// than the 15s the connect timeout suggests (#427).
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

/// Next byte of the stream (0-255), or -1 at end of stream.
@externInstance
@externTarget("System.IO.Stream.ReadByte")
func streamReadByte(s: in NetStream): Int = 0

@externInstance
@externTarget("System.IDisposable.Dispose")
func streamDispose(s: in NetStream): Unit = ()

@externInstance
@externTarget("System.IDisposable.Dispose")
func responseDispose(r: in WebResponse): Unit = ()

// pub (#514) so the regression test can decode via the exact same Encoding
// readAllUtf8 uses.
@externTarget("System.Text.Encoding.get_UTF8")
pub func utf8(): Encoding = ()

// pub (#514) so the regression test can drive the exact same round trip.
@externInstance
@externTarget("System.Text.Encoding.GetBytes")
pub func encGetBytes(enc: in Encoding, s: in String): slice[Byte] = []

// pub (#514) so the regression test can decode via the exact chain
// readAllUtf8 uses. Full-array form, mirroring crypto.l's encGetString —
// slice[Byte] as an argument (not an in-place-mutated buffer) is the
// direction already proven to marshal correctly.
@externInstance
@externTarget("System.Text.Encoding.GetString")
pub func encGetStringBytes(enc: in Encoding, bytes: in slice[Byte]): String = ""

// pub (#514) so tests/github_api_tests.l can cover it directly — see that
// file's NOTE on why readAllUtf8/readAll themselves stay untested.
@externTarget("System.Char.ConvertFromUtf32")
pub func charFromCode(code: in Int): String = ()

// ─── UTF-8 body reading (proxy endpoints) ────────────────────────────────────
// The byte-per-char readAll below mangles non-ASCII, which is fine for the
// OAuth flow's ASCII fields but not for passthrough proxying (repo
// descriptions, model display names). These bindings use a real .NET
// StreamReader to read the stream and decode it as real UTF-8.
extern type StreamReader = "System.IO.StreamReader"

@externInstance
@externTarget("System.IO.StreamReader.Read")
pub func readerRead(reader: in StreamReader): Int = -1

val maxProxyResponseBytes = 1048576

/// Read a response stream to a string, decoding it as UTF-8 (unlike readAll,
/// which widens byte-per-char and mangles non-ASCII), capped at maxProxyResponseBytes.
func readAllUtf8(s: in NetStream): String {
  val reader = StreamReader.new(s)
  var total = 0
  var raw = ""
  var chunk = ""
  var c = readerRead(reader)
  while c >= 0 and total < maxProxyResponseBytes {
    if c >= 55296 and c <= 56319 {
      // High surrogate: read the next character for low surrogate
      val nextC = readerRead(reader)
      if nextC >= 56320 and nextC <= 57343 {
        val codePoint = (c - 55296) * 1024 + (nextC - 56320) + 65536
        chunk = chunk + charFromCode(codePoint)
        total = total + 2
      } else {
        // Orphan high surrogate: output replacement character (0xFFFD)
        chunk = chunk + charFromCode(65533)
        total = total + 1
        // We also need to process nextC if it's non-negative
        c = nextC
        continue
      }
    } else if c >= 56320 and c <= 57343 {
      // Orphan low surrogate: output replacement character (0xFFFD)
      chunk = chunk + charFromCode(65533)
      total = total + 1
    } else {
      chunk = chunk + charFromCode(c)
      total = total + 1
    }

    if chunk.length >= 1024 {
      raw = raw + chunk
      chunk = ""
    }
    c = readerRead(reader)
  }
  raw = raw + chunk
  return raw
}

// Keep latin1() and encGetStringBytes so tests/github_api_tests.l can compile
// and run its FFI sequence checks.
@externTarget("System.Text.Encoding.get_Latin1")
pub func latin1(): Encoding = ()

val requestTimeoutMillis = 15000

// GitHub's exchange and /user responses are ~1-2 KB; anything past this cap
// is not a response this module should be parsing (#423).
val maxResponseBytes = 65536

/// Read a response stream to a string, one byte per char (see module doc for
/// the deliberate ASCII-only guarantee), capped at maxResponseBytes. A
/// two-level accumulator (flush a small chunk into the result every 1 KB)
/// keeps the concatenation cost linear-ish instead of O(n²) (#423). NB:
/// `out` is a reserved keyword in Lyric (P0051), hence `acc`.
func readAll(s: in NetStream): String {
  var acc = ""
  var chunk = ""
  var total = 0
  var b = streamReadByte(s)
  while b >= 0 and total < maxResponseBytes {
    chunk = chunk + charFromCode(b)
    total = total + 1
    if chunk.length >= 1024 {
      acc = acc + chunk
      chunk = ""
    }
    b = streamReadByte(s)
  }
  return acc + chunk
}


/// GET `url` setting each (headerNames[i], headerValues[i]) pair on the
/// request's header collection, reading the response as real UTF-8
/// (readAllUtf8) — the variant the proxy endpoints use for passthrough
/// bodies. Authorization, x-api-key, anthropic-version and x-goog-api-key
/// are all settable via Headers.Set; Accept/User-Agent are "restricted"
/// headers and stay property-set, exactly like the functions above. Extra
/// entries in the longer slice are ignored when the lengths differ.
pub func httpGetWithHeaders(
  url: in String, headerNames: in slice[String], headerValues: in slice[String], userAgent: in String
): Result[String, String] {
  return try {
    val req = createRequest(url)
    setMethod(req, "GET")
    setTimeout(req, requestTimeoutMillis)
    setReadWriteTimeout(req, requestTimeoutMillis)
    setUserAgent(req, userAgent)
    setAccept(req, "application/json")
    val hdrs = getHeaders(req)
    var i = 0
    while i < headerNames.length and i < headerValues.length {
      headerSet(hdrs, headerNames[i], headerValues[i])
      i = i + 1
    }
    val resp = getResponse(req)
    // Same defer-based disposal as httpGetWithBearer (#421): runs on ALL
    // scope exits, stream before response.
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

/// GET `url` with an Authorization bearer header. GitHub's API additionally
/// requires a User-Agent on every request, so callers name themselves.
/// Any transport failure or non-2xx status (GetResponse throws on both)
/// surfaces as Err with the platform's message.
pub func httpGetWithBearer(url: in String, bearerToken: in String, userAgent: in String): Result[String, String] {
  return try {
    val req = createRequest(url)
    setMethod(req, "GET")
    setTimeout(req, requestTimeoutMillis)
    setReadWriteTimeout(req, requestTimeoutMillis)
    setUserAgent(req, userAgent)
    setAccept(req, "application/json")
    headerSet(getHeaders(req), "Authorization", "Bearer " + bearerToken)
    val resp = getResponse(req)
    // defer runs on ALL scope exits, including a Bug thrown mid-read, so the
    // response/stream can't leak on exception paths (#421). Reverse
    // declaration order disposes the stream before the response.
    defer {
      responseDispose(resp)
    }
    val stream = getResponseStream(resp)
    defer {
      streamDispose(stream)
    }
    val body = readAll(stream)
    Ok(value = body)
  } catch Bug as b {
    Err(error = "GET " + url + " failed: " + b.message)
  }
}

/// POST a form-encoded body to `url`, asking for a JSON response (GitHub's
/// token-exchange endpoint returns form-encoding unless Accept says JSON).
pub func httpPostForm(url: in String, formBody: in String, userAgent: in String): Result[String, String] {
  return try {
    val req = createRequest(url)
    setMethod(req, "POST")
    setTimeout(req, requestTimeoutMillis)
    setReadWriteTimeout(req, requestTimeoutMillis)
    setUserAgent(req, userAgent)
    setAccept(req, "application/json")
    setContentType(req, "application/x-www-form-urlencoded")
    val bytes = encGetBytes(utf8(), formBody)
    val reqStream = getRequestStream(req)
    // The request stream must be closed BEFORE GetResponse (it finalises the
    // request body), hence the explicit dispose after the write. The defer is
    // the exception-path guard: if streamWrite throws mid-body, the stream
    // still gets released (Stream.Dispose is idempotent, so the double
    // dispose on the success path is harmless) (#421).
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
    val body = readAll(respStream)
    Ok(value = body)
  } catch Bug as b {
    Err(error = "POST " + url + " failed: " + b.message)
  }
}
