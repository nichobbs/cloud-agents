@test_module
package CloudAgents.Shim.TransportTests

//! Regression tests for CloudAgents.Shim.Transport's readAllUtf8 fixes:
//!
//! #545 — readAllUtf8 used to decode each 8 KiB read chunk independently
//! via encGetStringRange, which silently corrupts (never throws) any
//! multi-byte UTF-8 sequence that happens to straddle a chunk boundary:
//! .NET's default UTF8 decode fallback substitutes a replacement character
//! (U+FFFD) per orphaned half instead of raising an error.
//!
//! #546 — the fixed-size read buffer used to be rebuilt via zeroedChunk()'s
//! O(chunkSize^2) append loop fresh on every single readAllUtf8 call
//! (i.e. every shim<->host HTTP round trip) instead of once.
//!
//! readAllUtf8 itself takes a NetStream (`extern type NetStream =
//! "System.IO.Stream"`), and the only way this module can produce one is a
//! real HTTP round trip (getResponseStream(getResponse(...))) — the exact
//! same constraint tests/github_api_tests.l documents for
//! CloudAgents.GitHubApi's sibling readAllUtf8, and the reason that suite
//! never invokes readAllUtf8 directly either. Instead, this suite drives
//! decodeUtf8Chunks directly — the pure, pub helper readAllUtf8's read loop
//! now delegates to for the accumulate-then-decode-once step (#545) — with
//! synthetic byte chunks split exactly where a real chunk boundary could
//! land mid-character. That requires no stream/network at all, and is the
//! part of readAllUtf8 that #545 actually changed; the read-loop plumbing
//! around it (chunking via streamRead, capping at maxResponseBytes, reusing
//! sharedChunkBuf for #546) still can only be exercised via a real socket.

import Std.Core
import Std.Testing
import CloudAgents.Shim.Transport

test "decodeUtf8Chunks reconstructs a multi-byte UTF-8 character split across a chunk boundary (#545)" {
  // Euro sign (U+20AC) is the 3-byte UTF-8 sequence 0xE2 0x82 0xAC (the same
  // sequence tests/github_api_tests.l's #514 regression test uses). Split
  // it 2 bytes / 1 byte across two separate chunks — exactly the shape a
  // real 8 KiB streamRead boundary landing mid-character would produce.
  val prefix = encGetBytes(utf8(), "price: ")
  val euro = encGetBytes(utf8(), "€")
  assertEqualInt(euro.length.toInt(), 3, "sanity check: the euro sign is 3 bytes in UTF-8")
  val suffix = encGetBytes(utf8(), " exactly")

  val chunk1 = prefix.concat(euro.slice(0, 2))
  val chunk2 = euro.slice(2, 3).concat(suffix)

  val chunks: slice[slice[Byte]] = [chunk1, chunk2]
  val decoded = decodeUtf8Chunks(chunks)
  assertEqual(decoded, "price: € exactly", "the euro sign survives a chunk split when decoded once over the accumulated bytes")

  // Demonstrate the bug the fix replaces: decoding each chunk independently
  // (the old per-chunk design readAllUtf8 used before #545) mangles the
  // exact same input, because each half is an incomplete UTF-8 sequence on
  // its own.
  val brokenPart1 = encGetStringRange(utf8(), chunk1, 0, chunk1.length.toInt())
  val brokenPart2 = encGetStringRange(utf8(), chunk2, 0, chunk2.length.toInt())
  val broken = brokenPart1 + brokenPart2
  assertFalse(broken == decoded, "per-chunk decoding (the old, buggy behavior) produces different, corrupted output for the same bytes")
}

test "decodeUtf8Chunks handles a single chunk (no split) correctly" {
  val bytes = encGetBytes(utf8(), "no split needed: café")
  val chunks: slice[slice[Byte]] = [bytes]
  assertEqual(decodeUtf8Chunks(chunks), "no split needed: café", "single-chunk input decodes unchanged")
}

test "decodeUtf8Chunks handles more than two chunks, none splitting a character" {
  // Not every read produces exactly one or two chunks — a long callback
  // body can span several. Three ASCII-only chunks, each a clean multiple
  // of a whole character, is the control case: no boundary-splitting
  // involved, just confirming multi-chunk concatenation itself is correct.
  val a = encGetBytes(utf8(), "one ")
  val b = encGetBytes(utf8(), "two ")
  val c = encGetBytes(utf8(), "three")
  val chunks: slice[slice[Byte]] = [a, b, c]
  assertEqual(decodeUtf8Chunks(chunks), "one two three", "three chunks concatenate and decode in order")
}

test "decodeUtf8Chunks handles an empty chunk list" {
  val chunks: slice[slice[Byte]] = []
  assertEqual(decodeUtf8Chunks(chunks), "", "no chunks decodes to the empty string")
}

// ── #546 (buffer reuse) sanity check ────────────────────────────────────────
// zeroedChunk() itself is unchanged by #546 (still builds one 8 KiB
// zero-filled slice via .append()) — the fix is calling it once at module
// load (sharedChunkBuf) instead of once per readAllUtf8 call. That
// call-site change isn't independently unit-testable without a real
// NetStream (same constraint as readAllUtf8 above), but zeroedChunk()'s own
// output shape is: exactly chunkSize bytes, all zero. Confirm that much
// stays correct, since sharedChunkBuf's only initializer is
// zeroedChunk() and every readAllUtf8 caller depends on it being the right
// length for streamRead's `count` argument.
test "zeroedChunk produces an 8192-byte all-zero buffer (#546)" {
  val buf = zeroedChunk()
  assertEqualInt(buf.length.toInt(), 8192, "zeroedChunk's output is exactly chunkSize bytes")
  assertTrue(buf[0] == 0.toByte(), "first byte is zero")
  assertTrue(buf[8191] == 0.toByte(), "last byte is zero")
}
