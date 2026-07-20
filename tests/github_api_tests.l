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
// NOTE: readAllUtf8/readAll themselves are still NOT invoked directly here.
// Both take a NetStream (`extern type NetStream = "System.IO.Stream"`, the
// abstract base type), and the only way this module can produce one is
// getResponseStream(getResponse(...)) — i.e. a real HTTP round trip.
// CloudAgents.OAuth's module doc already documents this same constraint and
// deliberately does not perform real network calls from a test. Instead,
// this suite exercises the exact FFI sequence readAllUtf8 chains together
// (charFromCode -> encGetBytes(latin1()) -> encGetStringBytes(utf8())),
// which is precisely the step the block-read redesign replaced, and
// requires no stream/network at all.

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

test "the Latin1/UTF8 chain handles an empty byte sequence (#514)" {
  val bytes = encGetBytes(latin1(), "")
  assertEqualInt(bytes.length.toInt(), 0, "empty input produces zero bytes")
  assertEqual(encGetStringBytes(utf8(), bytes), "", "decoding zero bytes yields the empty string")
}
