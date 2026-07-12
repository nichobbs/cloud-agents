//! Shared string utilities that were previously copy-pasted across packages
//! (#28, #169, #263). Pure and sync, so it can sit below every consumer in the
//! package order and be unit-tested directly (no async in this package means no
//! "signature is incorrect" test limitation — see docs/lyric/gotchas.md).
package CloudAgents.Text

import Std.Core
import Web

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

/// Rejects `s` when its character length exceeds `max`, with a 400 message
/// naming `fieldName` and `max` — shared by every request-body length cap so
/// the constant and its error message can't drift apart (#43).
pub func checkMaxLength(s: in String, max: Nat, fieldName: in String): Result[Unit, Web.ApiError] {
  // .toInt() normalizes both sides before comparing — bare `s.length > max`
  // fails to type-check here (T0033: "got Int and Nat") even though both are
  // documented Nat, matching indexOfFrom's existing workaround just above.
  if s.length.toInt() > max.toInt() {
    return Err(Web.badRequest(fieldName + " is too long (max " + max.toString() + " characters)"))
  }
  return Ok(())
}

/// Constant-time string equality, for comparing an untrusted `candidate`
/// against a trusted `expected` secret (an API token, an HMAC tag, ...).
/// The loop iterates over `expected`'s length only, never `candidate`'s — so
/// the number of comparisons (and thus the running time) does not depend on
/// the attacker-controlled candidate at all. Bounding the loop by
/// `max(candidate, expected)` instead produces a timing "elbow" as the
/// candidate grows past `expected` that leaks the secret's length (#212) —
/// a candidate shorter, equal, or longer than the secret must all cost the
/// same. A length mismatch is folded into `diff` up front so a
/// right-length-wrong-content and a wrong-length candidate both fail.
///
/// Shared by the API-token bearer check (CloudAgents.Auth) and the
/// AES-CBC+HMAC tag verification (CloudAgents.Crypto) — previously two
/// independently maintained near-duplicates that had already drifted, one
/// of which (the HMAC-tag check) still had the `max`-bounded shape #212 had
/// already fixed away from in the other (#204).
pub func constantTimeEquals(candidate: in String, expected: in String): Bool {
  val candLen = candidate.length.toInt()
  val expectedLen = expected.length.toInt()
  var diff = if candLen == expectedLen then 0 else 1
  var i = 0
  while i < expectedLen {
    val ce = expected.substring(i, 1)
    // Past the candidate's end, compare `ce` against itself so the step is a
    // no-op: the length mismatch is already recorded in `diff`, and this keeps
    // per-iteration work uniform without introducing a content-dependent branch.
    val cc = if i < candLen then candidate.substring(i, 1) else ce
    if cc != ce {
      diff = 1
    }
    i = i + 1
  }
  return diff == 0
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
