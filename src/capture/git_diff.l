//! CloudAgents.Capture.GitDiff — parse `git diff` unified output into the
//! checkpoint-format `FileDelta`s a `file_change` step carries
//! (docs/capture-git-diff.md; Testamur ADR-0008 §capture-completeness; Q4 arc).
//!
//! Q4 (which PR hunk did which step produce?) attributes a hunk via the graph's
//! `line_attribution`, which testamur derives from a checkpoint's **`file_change`**
//! steps (their new-side hunk ranges + step origins). The stream-json transcript
//! carries no diffs, so a stream-json-only session gets no line attribution and
//! Q4 returns `None` (ADR-0008). Answering Q4 on a real runner session therefore
//! needs the runner to also capture the workspace `git diff` as `file_change`
//! steps. This module is the PURE, offline first piece of that arc: it turns
//! `git diff` text into `List[FileDelta]` (path + new-side hunk ranges). Wiring it
//! into the checkpoint bridge (a testamur contract change: `file_change` steps in
//! the frontier) and capturing the diff in the runner are the sequenced follow-ups.
//!
//! Scope of THIS module (deliberately minimal, fully unit-testable):
//! - new-side hunk ranges from `@@ -a,b +c,d @@` (the ranges Q4 attributes);
//! - path from the `+++ b/…` header (or the `--- a/…` header for a deletion);
//! - add / modify / delete / rename / binary files.
//! `beforeSha256`/`afterSha256` are left `None` here: the `index <old>..<new>`
//! line carries git BLOB ids that are SHA-1 in a normal repo (not SHA-256), so
//! populating the sha256-named fields with them would misrepresent the hash —
//! and Q4 attribution needs only the hunk ranges + origins, not the blob hashes.
//! Capturing real blob hashes (from a sha256-object repo, or a separate channel)
//! is a later refinement, not needed for attribution.
@runtime_checked
package CloudAgents.Capture.GitDiff

import Std.Core
import Std.Collections
import CloudAgents.Text
import Testamur.CheckpointFormat.Model

// Decimal value of a one-char string, or -1 when not an ASCII digit. String
// comparison (no `Std.Char`/`toInt(s[i])`, a documented runtime landmine).
func digitValue(c: in String): Int {
  if c == "0" { return 0 }
  if c == "1" { return 1 }
  if c == "2" { return 2 }
  if c == "3" { return 3 }
  if c == "4" { return 4 }
  if c == "5" { return 5 }
  if c == "6" { return 6 }
  if c == "7" { return 7 }
  if c == "8" { return 8 }
  if c == "9" { return 9 }
  return -1
}

// Split `s` on "\n" into lines (a trailing newline does NOT produce a final empty
// line). Uses the proven forward `indexOfFrom` char-scan idiom.
func splitLines(s: in String): List[String] {
  val lines: List[String] = newList()
  val n = s.length.toInt()
  var start = 0
  while start <= n {
    val nl = CloudAgents.Text.indexOfFrom(s, "\n", start)
    if nl < 0 {
      if start < n {
        lines.add(s.substring(start, n - start))
      }
      return lines
    }
    lines.add(s.substring(start, nl - start))
    start = nl + 1
  }
  return lines
}

// Strip a leading "a/" or "b/" (git's default diff prefixes) from a diff path.
func stripAbPrefix(p: in String): String {
  if p.startsWith("a/") or p.startsWith("b/") {
    return p.substring(2, p.length.toInt() - 2)
  }
  return p
}

/// Parse the NEW-side range of a unified-diff hunk header
/// (`@@ -old[,n] +newStart[,newCount] @@ …`) into a `HunkRange{start, lines}`.
/// `newCount` defaults to 1 when omitted (git elides `,1`). Returns `None` for a
/// line that is not a well-formed hunk header. The new side is what Q4 attributes
/// (lines that exist in the post-change file); a pure deletion (`+c,0`) yields a
/// zero-length hunk at `c`.
pub func parseHunkNewRange(line: in String): Option[HunkRange] {
  if not line.startsWith("@@ ") {
    return None
  }
  // The new range begins at the first '+' (the old range begins at '-').
  val plus = CloudAgents.Text.indexOfFrom(line, "+", 0)
  if plus < 0 {
    return None
  }
  val n = line.length.toInt()
  // start digits
  var i = plus + 1
  var start = 0.toLong()
  var sawStart = false
  var goStart = true
  while goStart and i < n {
    val d = digitValue(line.substring(i, 1))
    if d < 0 {
      goStart = false
    } else {
      start = start * 10.toLong() + d.toLong()
      sawStart = true
      i = i + 1
    }
  }
  if not sawStart {
    return None
  }
  // optional ",count"
  var count = 1.toLong()
  if i < n and line.substring(i, 1) == "," {
    i = i + 1
    var c = 0.toLong()
    var sawCount = false
    var goCount = true
    while goCount and i < n {
      val d = digitValue(line.substring(i, 1))
      if d < 0 {
        goCount = false
      } else {
        c = c * 10.toLong() + d.toLong()
        sawCount = true
        i = i + 1
      }
    }
    if sawCount {
      count = c
    }
  }
  return Some(value = HunkRange(start = start, lines = count))
}

// The new-file path from a "diff --git a/X b/Y" header (best-effort fallback used
// until a +++/--- line refines it — e.g. for a rename-only change with no hunks).
// Takes the token after " b/" to end of line; falls back to "" if absent.
func pathFromDiffGit(line: in String): String {
  val marker = " b/"
  val idx = CloudAgents.Text.indexOfFrom(line, marker, 0)
  if idx < 0 {
    return ""
  }
  val from = idx + marker.length.toInt()
  return line.substring(from, line.length.toInt() - from)
}

/// Parse a `git diff` unified-format text into one `FileDelta` per changed file,
/// in file order, each with its new-side hunk ranges. Total: never throws; a
/// malformed or empty diff yields an empty list (or partial deltas for the files
/// it could parse). `beforeSha256`/`afterSha256` are `None` (see the module doc).
pub func parseUnifiedDiff(diff: in String): List[FileDelta] {
  val files: List[FileDelta] = newList()
  val lines = splitLines(diff)
  var curPath = ""
  var curHunks: List[HunkRange] = newList()
  var haveFile = false
  var i = 0
  while i < lines.count {
    val line = lines[i]
    if line.startsWith("diff --git ") {
      if haveFile {
        files.add(FileDelta(path = curPath, beforeSha256 = None, afterSha256 = None, hunks = curHunks))
      }
      curPath = pathFromDiffGit(line)
      curHunks = newList()
      haveFile = true
    } else if haveFile and line.startsWith("--- ") {
      val p = line.substring(4, line.length.toInt() - 4)
      if p != "/dev/null" {
        curPath = stripAbPrefix(p)
      }
    } else if haveFile and line.startsWith("+++ ") {
      // Processed after "---", so a present new path (add/modify/rename) wins;
      // for a deletion ("+++ /dev/null") the "--- a/path" already set curPath.
      val p = line.substring(4, line.length.toInt() - 4)
      if p != "/dev/null" {
        curPath = stripAbPrefix(p)
      }
    } else if haveFile and line.startsWith("rename to ") {
      // A rename-only change has no +++/--- lines; git emits the target path
      // UNAMBIGUOUSLY here (verbatim, no `a/`/`b/` prefix), so prefer it over the
      // `diff --git a/X b/Y` header split, which is ambiguous for paths that
      // themselves contain " b/" (security review #980).
      curPath = line.substring(10, line.length.toInt() - 10)
    } else if haveFile and line.startsWith("@@ ") {
      match parseHunkNewRange(line) {
        case Some(h) -> curHunks.add(h)
        case None -> ()
      }
    }
    i = i + 1
  }
  if haveFile {
    files.add(FileDelta(path = curPath, beforeSha256 = None, afterSha256 = None, hunks = curHunks))
  }
  return files
}
