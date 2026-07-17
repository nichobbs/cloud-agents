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
//! responses where non-ASCII content matters.
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

@externTarget("System.Text.Encoding.get_UTF8")
func utf8(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetBytes")
func encGetBytes(enc: in Encoding, s: in String): slice[Byte] = []

@externTarget("System.Char.ConvertFromUtf32")
func charFromCode(code: in Int): String = ()

val requestTimeoutMillis = 15000

/// Read a response stream to a string, one byte per char (see module doc for
/// the deliberate ASCII-only guarantee). NB: `out` is a reserved keyword in
/// Lyric (P0051), hence `acc`.
func readAll(s: in NetStream): String {
  var acc = ""
  var b = streamReadByte(s)
  while b >= 0 {
    acc = acc + charFromCode(b)
    b = streamReadByte(s)
  }
  return acc
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
    setUserAgent(req, userAgent)
    setAccept(req, "application/json")
    headerSet(getHeaders(req), "Authorization", "Bearer " + bearerToken)
    val resp = getResponse(req)
    val stream = getResponseStream(resp)
    val body = readAll(stream)
    streamDispose(stream)
    responseDispose(resp)
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
    setUserAgent(req, userAgent)
    setAccept(req, "application/json")
    setContentType(req, "application/x-www-form-urlencoded")
    val bytes = encGetBytes(utf8(), formBody)
    val reqStream = getRequestStream(req)
    streamWrite(reqStream, bytes, 0, bytes.length.toInt())
    streamDispose(reqStream)
    val resp = getResponse(req)
    val respStream = getResponseStream(resp)
    val body = readAll(respStream)
    streamDispose(respStream)
    responseDispose(resp)
    Ok(value = body)
  } catch Bug as b {
    Err(error = "POST " + url + " failed: " + b.message)
  }
}
