@test_module
package CloudAgents.TextTests

import Std.Core
import Std.Testing
import CloudAgents.Text

test "indexOfFrom finds needles, respects the start offset, and reports absence" {
  assertEqual(indexOfFrom("hello world", "world", 0), 6, "finds a substring")
  assertEqual(indexOfFrom("hello", "hello", 0), 0, "matches at the start")
  assertEqual(indexOfFrom("abcabc", "abc", 1), 3, "skips a match before `from`")
  assertEqual(indexOfFrom("hello", "xyz", 0), -1, "reports -1 when absent")
  // An empty needle returns `from` unchanged (matches the documented contract
  // relied on by the JSON field scanners).
  assertEqual(indexOfFrom("hello", "", 2), 2, "empty needle returns from")
  assertEqual(indexOfFrom("hi", "hello", 0), -1, "needle longer than haystack is absent")
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
