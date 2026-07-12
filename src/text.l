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

/// True when `s`'s character length is at or under `max` — shared by every
/// request-field length cap in sessions.l/interactions.l (#43/#365) so the
/// comparison logic can't drift between call sites. Deliberately returns
/// `Bool`, not a `Web.ApiError`-carrying
/// `Result`: this package has no `[nuget]` dependencies (scripts/verify.sh
/// compiles it into a scratch manifest with no `[nuget]` table at all, by
/// design — see that script's header comment), so pulling in `Web` here
/// would break that. Callers build their own message from the same `max`
/// they passed in, so the constant and the message still can't drift apart.
///
/// `max` is deliberately `Int`, not `Nat` (#361): a `Nat`-typed cross-package
/// argument here reproducibly crashed `CloudAgents.InteractionsTests` at
/// runtime with `InvalidProgramException` — the same crash signature #354
/// tracks for `Web.Request` construction, but triggered here purely by a
/// `Nat` value crossing the `Interactions` → `Text` package boundary in a
/// function call, no `Web` involved at all. `s.length.toInt()` normalizes
/// the (genuinely `Nat`) `.length` down to `Int` before comparing, matching
/// `indexOfFrom`'s existing workaround just above.
pub func withinMaxLength(s: in String, max: Int): Bool {
  return s.length.toInt() <= max
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
