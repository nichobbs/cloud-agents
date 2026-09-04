@test_module
package CloudAgents.GitHubApiTests

import Std.Core
import Std.Testing
import CloudAgents.GitHubApi

// PR #512 fixed a fatal AccessViolationException in readAllUtf8's byte-array/
// Type FFI plumbing (getByteType's @externInstance + System.Object.GetType()
// on a boxed Byte — see docs/lyric/gotchas.md's matching entry), replacing it
// with typeFromName's static System.Type.GetType(string) call. That PR's own
// test plan noted no test coverage existed for CloudAgents.GitHubApi to
// extend for a regression test (#514) — the first version of this file was
// that follow-up, and it caught a second, previously-undetected bug in the
// same area: the Array.CreateInstance + Encoding.GetString(bytes, index,
// count) block-read design readAllUtf8 used never actually worked at all —
// "Method not found: ...Encoding.GetString(System.Object, Int32, Int32)" —
// because an `extern type = "System.Byte[]"` value marshals as System.Object,
// which satisfies System.Array-typed methods (get_Length/GetValue/SetValue,
// as sqlite_driver.l/main.l/auth.l's String[] helpers use) but not
// Encoding.GetString, which needs a genuine byte[]. See src/github_api.l's
// module comment on readAllUtf8's sibling bindings for the full account and
// the replacement design (charFromCode + Encoding.Latin1/UTF8 round trip,
// reusing only binding shapes already proven correct elsewhere).
//
// UPDATE (#649): readAllUtf8 itself now IS invoked directly below, via
// memoryStreamOf (src/github_api.l) — a real System.IO.MemoryStream narrowed
// to the NetStream return type, the same idiom createRequest uses for
// WebRequest.Create. This closes the gap the PR #618 description flagged:
// that PR's own note said "readAllUtf8/readAll themselves are still NOT
// invoked directly here" because the only NetStream this module could
// previously produce was getResponseStream(getResponse(...)) — a real HTTP
// round trip, which CloudAgents.OAuth's module doc documents this suite
// deliberately avoids. A MemoryStream needs no network at all, so the actual
// production code path (not just the FFI chain it's built from) now has
// direct coverage. The FFI-chain tests below are kept: they're still the
// right level for the specific Latin1/UTF8-roundtrip regression #514 caught.

test "charFromCode converts a Unicode code point to its single-character string (#514)" {
  assertEqual(charFromCode(72), "H", "72 -> 'H'")
  assertEqual(charFromCode(101), "e", "101 -> 'e'")
  assertEqual(charFromCode(48), "0", "48 -> '0'")
  // readAllUtf8's sibling readAll widens each byte (0-255) through this exact
  // function; the low end of that range (including control bytes, which have
  // no Lyric string-literal escape) must convert without crashing.
  assertEqualInt(charFromCode(0).length.toInt(), 1, "code point 0 converts to a single-character string")
  assertEqualInt(charFromCode(255).length.toInt(), 1, "code point 255 (top of the byte range) converts cleanly")
}

test "the Latin1-roundtrip + UTF8-decode chain reconstructs raw bytes accumulated via charFromCode (#514)" {
  // Mirrors readAllUtf8's exact per-byte accumulation for a real 3-byte UTF-8
  // sequence: 0xE2 0x82 0xAC is the euro sign (U+20AC) in UTF-8. Each raw
  // byte value is folded through charFromCode individually (as
  // streamReadByte would deliver it one byte at a time), then the whole
  // accumulated Latin-1 string is round-tripped back to real bytes and
  // decoded as UTF-8 — the same two-step chain readAllUtf8 runs at the end
  // of its read loop.
  val raw = charFromCode(0xE2) + charFromCode(0x82) + charFromCode(0xAC)
  val bytes = encGetBytes(latin1(), raw)
  assertEqualInt(bytes.length.toInt(), 3, "Latin1 round-trip preserves the exact byte count")
  val decoded = encGetStringBytes(utf8(), bytes)
  assertEqual(decoded, "€", "the 3-byte UTF-8 sequence decodes to the euro sign")
}

test "the Latin1/UTF8 chain round-trips a plain ASCII string unchanged (#514)" {
  val raw = charFromCode(72) + charFromCode(105)
  val bytes = encGetBytes(latin1(), raw)
  val decoded = encGetStringBytes(utf8(), bytes)
  assertEqual(decoded, "Hi", "pure-ASCII bytes decode back to the original string")
}

// #649: readAllUtf8, driven directly against a real in-memory Stream (no
// network). Covers exactly the code path PR #618's own description says was
// rewritten (the two-line StreamReader.new(s).ReadToEnd()-equivalent) and
// left untested — including the multi-byte UTF-8 decode this suite's older
// FFI-chain tests only ever exercised indirectly.
test "readAllUtf8 decodes a real multi-byte UTF-8 stream (#649)" {
  val bytes = encGetBytes(utf8(), "Hi €, résumé")
  val decoded = readAllUtf8(memoryStreamOf(bytes))
  assertEqual(decoded, "Hi €, résumé", "multi-byte UTF-8 sequences decode correctly through a real Stream")
}

test "readAllUtf8 decodes plain ASCII unchanged (#649)" {
  val bytes = encGetBytes(utf8(), "plain ascii, no surprises")
  val decoded = readAllUtf8(memoryStreamOf(bytes))
  assertEqual(decoded, "plain ascii, no surprises", "pure ASCII round-trips through readAllUtf8 unchanged")
}

test "readAllUtf8 on an empty stream returns the empty string (#649)" {
  val bytes: slice[Byte] = []
  val decoded = readAllUtf8(memoryStreamOf(bytes))
  assertEqual(decoded, "", "an empty stream decodes to the empty string")
}

test "readAllUtf8 handles a payload spanning multiple internal 1KB flush chunks (#649)" {
  // readAllUtf8 flushes its accumulator into `raw` every 1024 characters
  // (src/github_api.l); a payload long enough to cross that boundary at least
  // once exercises the flush/reset path, not just the final tail append.
  var longAscii = ""
  var i = 0
  while i < 50 {
    longAscii = longAscii + "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    i = i + 1
  }
  // Also verify the flush boundary itself doesn't corrupt a multi-byte
  // character straddling it, by appending one right where a chunk flush lands.
  val payload = longAscii + "€" + longAscii
  val bytes = encGetBytes(utf8(), payload)
  val decoded = readAllUtf8(memoryStreamOf(bytes))
  assertEqual(decoded, payload, "a payload spanning multiple 1KB flush chunks decodes byte-for-byte")
}

test "the Latin1/UTF8 chain handles an empty byte sequence (#514)" {
  val bytes = encGetBytes(latin1(), "")
  assertEqualInt(bytes.length.toInt(), 0, "empty input produces zero bytes")
  assertEqual(encGetStringBytes(utf8(), bytes), "", "decoding zero bytes yields the empty string")
}

// #1025: httpPostJsonWithBearerTimeout's own module doc / docs/capture-runtime-
// handoff.md §5.2 explain WHY AllowAutoRedirect is disabled (a 3xx must not
// replay the Authorization bearer to another host), but nothing previously
// asserted it actually IS disabled on the request production sends. Proving a
// redirect is really not FOLLOWED end-to-end would need a real HTTP server
// (out of reach offline — unlike readAllUtf8 above, a redirect round trip
// needs two distinct listening endpoints, not just a readable byte buffer, so
// the memoryStreamOf trick doesn't extend here); instead, buildBearerPostRequest
// is the exact request-construction seam httpPostJsonWithBearerTimeout calls
// before ever touching the network (no GetRequestStream/GetResponse —
// building an HttpWebRequest and reading a property off it opens no
// connection), so this exercises the real production code path with zero
// network I/O.
test "buildBearerPostRequest disables AllowAutoRedirect, so a 3xx can't replay the bearer token (#1025)" {
  val req = buildBearerPostRequest("http://127.0.0.1:1/ingest", "secret-token", "cloud-agents-test/1.0", 5000)
  assertFalse(getAllowAutoRedirect(req), "the bearer-leak defense: redirects must not be auto-followed")
}

test "buildBearerPostRequest still allows a request with no bearer token (empty string means 'send none')" {
  // Just confirms the empty-token branch doesn't crash building the request;
  // the no-redirect property is independent of whether a token is set.
  val req = buildBearerPostRequest("http://127.0.0.1:1/ingest", "", "cloud-agents-test/1.0", 5000)
  assertFalse(getAllowAutoRedirect(req), "no-redirect still applies with no bearer token set")
}
