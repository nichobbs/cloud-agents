@test_module
package CloudAgents.GitHubApiTests

import Std.Core
import Std.Testing
import CloudAgents.GitHubApi

// PR #512 fixed a fatal AccessViolationException in readAllUtf8's byte-array/
// Type FFI plumbing (getByteType/intToByte's @externInstance +
// System.Object.GetType() on a boxed Byte — see docs/lyric/gotchas.md's
// matching entry), replacing it with typeFromName's static
// System.Type.GetType(string) call. That PR's own test plan noted no test
// coverage existed for CloudAgents.GitHubApi to extend for a regression test
// (#514); this file is that follow-up.
//
// NOTE: readAllUtf8/readAll themselves are NOT invoked directly here. Both
// take a NetStream (`extern type NetStream = "System.IO.Stream"`, the
// abstract base type), and the only way this module can produce one is
// getResponseStream(getResponse(...)) — i.e. a real HTTP round trip.
// CloudAgents.OAuth's module doc already documents this same constraint
// ("the network itself lives in CloudAgents.GitHubApi (sync, also
// import-safe for tests, though tests never invoke the calls)") and
// deliberately does not perform real network calls from a test. Instead,
// this suite exercises the exact FFI sequence readAllUtf8 chains together
// (typeFromName -> createByteArray -> encGetStringRange, decoding with the
// same utf8() Encoding) directly, which is precisely the step PR #512's fix
// touched and requires no stream/network at all.

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

test "typeFromName + createByteArray + encGetStringRange complete readAllUtf8's Type/array/decode chain without crashing (#514, regression for PR #512's AccessViolationException fix)" {
  // This is the exact sequence readAllUtf8 runs before it ever calls
  // streamRead: acquire System.Type for "System.Byte" via the static
  // Type.GetType(string) call (the fix; the pre-#512 code used an
  // @externInstance GetType() on a boxed Byte instead, which crashed the
  // whole process with AccessViolationException), then Array.CreateInstance
  // to allocate the byte buffer.
  val byteType = typeFromName("System.Byte")
  val buf = createByteArray(byteType, 64)

  // A freshly allocated byte[] is zero-initialized by the CLR, so decoding a
  // non-empty range is real UTF-8 decode work (5 NUL bytes -> a 5-character
  // string), not a trivial zero-length no-op — without needing to construct
  // arbitrary Byte values in Lyric, which has no documented literal syntax
  // for Byte (see docs/lyric/gotchas.md's Byte-specific FFI landmine
  // entries; readAllUtf8 itself only ever fills this buffer via streamRead,
  // never a manual per-index write).
  val decoded = encGetStringRange(utf8(), buf, 0, 5)
  assertEqualInt(decoded.length.toInt(), 5, "decodes exactly the requested byte range")

  // A zero-length decode (the shape readAllUtf8 would produce for a
  // zero-byte response body) must also complete cleanly.
  assertEqual(encGetStringRange(utf8(), buf, 0, 0), "", "decoding a zero-length range yields the empty string")
}
