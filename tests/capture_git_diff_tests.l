//! Offline unit tests for CloudAgents.Capture.GitDiff (docs/capture-git-diff.md).
//! No Docker, no git — the fixtures are REAL `git diff` output (captured from a
//! throwaway repo: a modify, a delete, an add, and a rename), pasted verbatim.
@test_module
package CloudAgents.CaptureGitDiffTests

import Std.Core
import Std.Collections
import Std.Testing
import CloudAgents.Capture.GitDiff
import Testamur.CheckpointFormat.Model

// A real `git diff --cached` over: a.txt modified (one replace + one append),
// b.txt deleted, c.txt added. Verbatim, joined with "\n".
func mixedDiff(): String {
  return "diff --git a/a.txt b/a.txt\n" +
    "index 83db48f..e0c9b5e 100644\n" +
    "--- a/a.txt\n" +
    "+++ b/a.txt\n" +
    "@@ -1,3 +1,4 @@\n" +
    " line1\n" +
    "-line2\n" +
    "+CHANGED\n" +
    " line3\n" +
    "+line4\n" +
    "diff --git a/b.txt b/b.txt\n" +
    "deleted file mode 100644\n" +
    "index 2fa992c..0000000\n" +
    "--- a/b.txt\n" +
    "+++ /dev/null\n" +
    "@@ -1 +0,0 @@\n" +
    "-keep\n" +
    "diff --git a/c.txt b/c.txt\n" +
    "new file mode 100644\n" +
    "index 0000000..fa49b07\n" +
    "--- /dev/null\n" +
    "+++ b/c.txt\n" +
    "@@ -0,0 +1 @@\n" +
    "+new file\n"
}

// Assert a HunkRange's (start, lines).
func assertHunk(h: in HunkRange, start: in Int, lines: in Int, label: in String) {
  assertEqualInt(h.start.toInt(), start, label + " start")
  assertEqualInt(h.lines.toInt(), lines, label + " lines")
}

// ── parseHunkNewRange ─────────────────────────────────────────────────────────
test "parseHunkNewRange extracts the NEW-side range with count" {
  match parseHunkNewRange("@@ -1,3 +1,4 @@") {
    case Some(h) -> assertHunk(h, 1, 4, "modify")
    case None -> assertTrue(false, "a well-formed hunk header must parse")
  }
}

test "parseHunkNewRange defaults an omitted count to 1" {
  // git elides ",1": `@@ -2 +2 @@` means one line at 2.
  match parseHunkNewRange("@@ -2 +2 @@ line1") {
    case Some(h) -> assertHunk(h, 2, 1, "single-line")
    case None -> assertTrue(false, "an omitted count must default to 1")
  }
}

test "parseHunkNewRange handles a pure-append and a pure-deletion range" {
  match parseHunkNewRange("@@ -3,0 +4 @@ line3") {
    case Some(h) -> assertHunk(h, 4, 1, "append")
    case None -> assertTrue(false, "append hunk must parse")
  }
  // A deletion has +c,0 — a zero-length new-side range at c.
  match parseHunkNewRange("@@ -1 +0,0 @@") {
    case Some(h) -> assertHunk(h, 0, 0, "deletion")
    case None -> assertTrue(false, "deletion hunk must parse")
  }
}

test "parseHunkNewRange rejects non-hunk lines" {
  match parseHunkNewRange("index 83db48f..e0c9b5e 100644") {
    case Some(_) -> assertTrue(false, "an index line is not a hunk header")
    case None -> assertTrue(true, "non-hunk -> None")
  }
  match parseHunkNewRange(" line1") {
    case Some(_) -> assertTrue(false, "a context line is not a hunk header")
    case None -> assertTrue(true, "context line -> None")
  }
}

// ── parseUnifiedDiff ──────────────────────────────────────────────────────────
test "parseUnifiedDiff yields one FileDelta per changed file, in order" {
  val files = parseUnifiedDiff(mixedDiff())
  assertEqualInt(files.count, 3, "three changed files")
  assertEqual(files[0].path, "a.txt", "modified file path (from +++ b/)")
  assertEqual(files[1].path, "b.txt", "deleted file path (from --- a/, since +++ is /dev/null)")
  assertEqual(files[2].path, "c.txt", "added file path (from +++ b/, since --- is /dev/null)")
}

test "parseUnifiedDiff captures the new-side hunk ranges" {
  val files = parseUnifiedDiff(mixedDiff())
  assertEqualInt(files[0].hunks.count, 1, "a.txt has one hunk")
  assertHunk(files[0].hunks[0], 1, 4, "a.txt hunk")
  assertEqualInt(files[1].hunks.count, 1, "b.txt has one hunk")
  assertHunk(files[1].hunks[0], 0, 0, "b.txt deletion hunk")
  assertEqualInt(files[2].hunks.count, 1, "c.txt has one hunk")
  assertHunk(files[2].hunks[0], 1, 1, "c.txt add hunk")
}

test "parseUnifiedDiff leaves blob hashes None (attribution needs only ranges)" {
  val files = parseUnifiedDiff(mixedDiff())
  match files[0].beforeSha256 {
    case Some(_) -> assertTrue(false, "beforeSha256 is not populated (SHA-1 blob ids would mislabel)")
    case None -> assertTrue(true, "beforeSha256 None")
  }
  match files[0].afterSha256 {
    case Some(_) -> assertTrue(false, "afterSha256 is not populated")
    case None -> assertTrue(true, "afterSha256 None")
  }
}

test "parseUnifiedDiff handles multiple hunks in one file (unified=0)" {
  // `git diff -U0` splits the a.txt change into two hunks.
  val u0 = "diff --git a/a.txt b/a.txt\n" +
    "index 83db48f..e0c9b5e 100644\n" +
    "--- a/a.txt\n" +
    "+++ b/a.txt\n" +
    "@@ -2 +2 @@ line1\n" +
    "-line2\n" +
    "+CHANGED\n" +
    "@@ -3,0 +4 @@ line3\n" +
    "+line4\n"
  val files = parseUnifiedDiff(u0)
  assertEqualInt(files.count, 1, "one file")
  assertEqualInt(files[0].hunks.count, 2, "two hunks")
  assertHunk(files[0].hunks[0], 2, 1, "first hunk (replace)")
  assertHunk(files[0].hunks[1], 4, 1, "second hunk (append)")
}

test "parseUnifiedDiff handles a rename-only change (no hunks)" {
  val rename = "diff --git a/old.txt b/new.txt\n" +
    "similarity index 100%\n" +
    "rename from old.txt\n" +
    "rename to new.txt\n"
  val files = parseUnifiedDiff(rename)
  assertEqualInt(files.count, 1, "one renamed file")
  assertEqual(files[0].path, "new.txt", "rename target path (from the diff --git b/ token)")
  assertEqualInt(files[0].hunks.count, 0, "a pure rename has no hunks")
}

test "parseUnifiedDiff handles a binary file (no hunks)" {
  // A binary change has a "Binary files … differ" line and no @@ hunks.
  val bin = "diff --git a/logo.png b/logo.png\n" +
    "index 1a2b3c4..5d6e7f8 100644\n" +
    "Binary files a/logo.png and b/logo.png differ\n"
  val files = parseUnifiedDiff(bin)
  assertEqualInt(files.count, 1, "one binary file")
  assertEqual(files[0].path, "logo.png", "binary file path (from the diff --git header)")
  assertEqualInt(files[0].hunks.count, 0, "a binary file has no line hunks")
}

test "parseUnifiedDiff on an empty or non-diff input yields no files" {
  assertEqualInt(parseUnifiedDiff("").count, 0, "empty diff -> no files")
  assertEqualInt(parseUnifiedDiff("not a diff at all\njust text\n").count, 0, "non-diff text -> no files")
}
