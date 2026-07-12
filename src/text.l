//! Shared string utilities that were previously copy-pasted across packages
//! (#28, #169, #263). Pure and sync, so it can sit below every consumer in the
//! package order and be unit-tested directly (no async in this package means no
//! "signature is incorrect" test limitation — see docs/lyric/gotchas.md).
package CloudAgents.Text

import Std.Core

// JSON forbids raw control characters and Lyric string literals cannot express
// them, so detection goes through the BCL ordinal compare rather than a literal.
@externTarget("System.String.CompareOrdinal")
func strCompareOrdinal(a: in String, b: in String): Int = ()

/// True for a single UTF-16 unit below U+0020. Ordinal comparison against " "
/// is exact here: any unit >= 0x20 (including lone surrogates) compares >= 0.
pub func isControlChar(c: in String): Bool {
  return strCompareOrdinal(c, " ") < 0
}

/// True when any character of `s` is a raw control character (below U+0020).
/// These have no place in a URL, ref name, or model id, and would otherwise
/// flow into the session store and the container environment.
pub func containsControlChar(s: in String): Bool {
  var i = 0
  while i < s.length {
    if isControlChar(s.substring(i, 1)) {
      return true
    }
    i = i + 1
  }
  return false
}

/// First index of `needle` in `hay` at or after `from`, or -1 if not present.
pub func indexOfFrom(hay: in String, needle: in String, from: in Int): Int {
  val hayLen = hay.length.toInt()
  val needleLen = needle.length.toInt()
  if needleLen == 0 {
    return from
  }
  var i = from
  val last = hayLen - needleLen
  while i <= last {
    var j = 0
    var matched = true
    while j < needleLen {
      if hay.substring(i + j, 1) != needle.substring(j, 1) {
        matched = false
        j = needleLen
      } else {
        j = j + 1
      }
    }
    if matched {
      return i
    }
    i = i + 1
  }
  return -1
}
