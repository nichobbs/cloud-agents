@test_module
package CloudAgents.TextTests

import Std.Core
import Std.Testing
import CloudAgents.Text

test "indexOfFrom finds needles, respects the start offset, and reports absence" {
  assertEqualInt(indexOfFrom("hello world", "world", 0), 6, "finds a substring")
  assertEqualInt(indexOfFrom("hello", "hello", 0), 0, "matches at the start")
  assertEqualInt(indexOfFrom("abcabc", "abc", 1), 3, "skips a match before `from`")
  assertEqualInt(indexOfFrom("hello", "xyz", 0), -1, "reports -1 when absent")
  // An empty needle returns `from` unchanged (matches the documented contract
  // relied on by the JSON field scanners).
  assertEqualInt(indexOfFrom("hello", "", 2), 2, "empty needle returns from")
  assertEqualInt(indexOfFrom("hi", "hello", 0), -1, "needle longer than haystack is absent")
}

test "isControlChar flags units below U+0020 and passes printable text" {
  assertFalse(isControlChar("a"), "a printable letter is not a control char")
  assertFalse(isControlChar(" "), "space (U+0020) is the boundary and not a control char")
  // \t (U+0009), \n (U+000A), \r (U+000D) are all below U+0020.
  assertTrue(isControlChar("\t"), "tab is a control char")
  assertTrue(isControlChar("\n"), "newline is a control char")
  assertTrue(isControlChar("\r"), "carriage return is a control char")
}

test "containsControlChar detects an embedded control char anywhere in the string" {
  assertFalse(containsControlChar("https://github.com/owner/repo"), "a clean URL has no control chars")
  assertFalse(containsControlChar(""), "the empty string has no control chars")
  assertTrue(containsControlChar("main\tbranch"), "a tab in the middle is detected")
  assertTrue(containsControlChar("trailing\n"), "a trailing newline is detected")
}

test "withinMaxLength allows values at or under the cap and rejects values over it (#43)" {
  assertTrue(withinMaxLength("short", 10), "value under the cap is within it")
  assertTrue(withinMaxLength("0123456789", 10), "value exactly at the cap is within it")
  assertFalse(withinMaxLength("0123456789X", 10), "value over the cap is not within it")
}

test "withinMaxByteLength measures UTF-8 byte size, not character count (#64)" {
  // Plain ASCII: one byte per character, so byte length and char length agree.
  assertTrue(withinMaxByteLength("short", 10), "ASCII value under the cap is within it")
  assertTrue(withinMaxByteLength("0123456789", 10), "ASCII value exactly at the cap is within it")
  assertFalse(withinMaxByteLength("0123456789X", 10), "ASCII value over the cap is not within it")

  // U+3042 (HIRAGANA A) is one .NET/Lyric character but three UTF-8 bytes —
  // exactly the divergence #64 is about. "あああ" is 3 characters / 9 bytes.
  val threeWide = "あああ"
  assertEqualInt(threeWide.length.toInt(), 3, "sanity: three multi-byte characters")
  // A char-count cap of 3 would let this through (that's the bug #64 flags);
  // the byte-count cap correctly rejects it once the true size (9) is over.
  assertTrue(withinMaxLength(threeWide, 3), "char-count check alone is fooled by multi-byte characters")
  assertFalse(withinMaxByteLength(threeWide, 3), "byte-count check catches what the char-count check misses")
  assertTrue(withinMaxByteLength(threeWide, 9), "byte-count check allows the value at its true byte size")
  assertFalse(withinMaxByteLength(threeWide, 8), "byte-count check rejects one byte under the true size")
}

test "constantTimeEquals matches equal strings and rejects differing ones, any length (#204/#366)" {
  assertTrue(constantTimeEquals("abc", "abc"), "equal strings match")
  assertTrue(constantTimeEquals("", ""), "empty equals empty")
  assertFalse(constantTimeEquals("abc", "abd"), "differing content differs")
  assertFalse(constantTimeEquals("abc", "abcd"), "candidate shorter than expected differs")
  assertFalse(constantTimeEquals("abcde", "abc"), "candidate longer than expected differs")
  assertFalse(constantTimeEquals("", "x"), "empty candidate vs non-empty expected differs")
  assertFalse(constantTimeEquals("x", ""), "non-empty candidate vs empty expected differs")
}
