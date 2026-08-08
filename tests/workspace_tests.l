@test_module
package CloudAgents.WorkspaceTests

import Std.Core
import Std.Testing
import CloudAgents.Workspace

// ── validInspectPath ─────────────────────────────────────────────────────────

test "validInspectPath accepts ordinary repo-relative paths" {
  assertTrue(validInspectPath("README.md"), "bare filename")
  assertTrue(validInspectPath("src/main.l"), "nested path")
  assertTrue(validInspectPath("a..b/c.txt"), "dots inside a segment are not traversal")
  assertTrue(validInspectPath("docs/x-y_z.1.md"), "hyphens/underscores/dots after the first char")
}

test "validInspectPath rejects unsafe shapes" {
  assertFalse(validInspectPath(""), "empty")
  assertFalse(validInspectPath("/etc/passwd"), "absolute")
  assertFalse(validInspectPath("-rf"), "leading dash (option injection)")
  assertFalse(validInspectPath(".."), "bare traversal segment")
  assertFalse(validInspectPath("../secret"), "leading traversal segment")
  assertFalse(validInspectPath("src/../secret"), "interior traversal segment")
  assertFalse(validInspectPath("a/.."), "trailing traversal segment")
  assertFalse(validInspectPath("a\\b"), "backslash")
  assertFalse(validInspectPath("a'b"), "single quote")
  assertFalse(validInspectPath("a\"b"), "double quote")
  assertFalse(validInspectPath("a`b"), "backtick")
  assertFalse(validInspectPath("a$b"), "dollar")
  assertFalse(validInspectPath("a\nb"), "control character")
}

test "validInspectPath enforces the 512-char cap" {
  // 32 chars, doubled four times -> 512; still valid at exactly the cap.
  var p = "abcdefghijklmnopqrstuvwxyz012345"
  p = p + p
  p = p + p
  p = p + p
  p = p + p
  assertEqualInt(p.length.toInt(), 512, "cap-length fixture")
  assertTrue(validInspectPath(p), "exactly 512 chars is allowed")
  assertFalse(validInspectPath(p + "x"), "513 chars is rejected")
}

// ── parseInspectLog (marker protocol) ────────────────────────────────────────

test "parseInspectLog splits an OK log into sections" {
  val log = "CLOUD_AGENTS_INSPECT_OK\n M src/a.l\n?? new.txt\n===CLOUD_AGENTS_SECTION===\n3\t1\tsrc/a.l\n===CLOUD_AGENTS_SECTION===\ndiff --git a/src/a.l b/src/a.l\n"
  val outcome = parseInspectLog(log)
  assertTrue(outcome.ok, "OK marker parsed")
  assertEqual(outcome.err, "", "no error text on OK")
  assertEqualInt(outcome.sections.length.toInt(), 3, "three sections")
  assertEqual(outcome.sections[0], " M src/a.l\n?? new.txt", "first section keeps interior newlines")
  assertEqual(outcome.sections[1], "3\t1\tsrc/a.l", "second section is the numstat body")
  assertEqual(outcome.sections[2], "diff --git a/src/a.l b/src/a.l", "third section is the patch")
}

test "parseInspectLog surfaces the ERR line's message" {
  val outcome = parseInspectLog("some docker noise\nCLOUD_AGENTS_INSPECT_ERR no workspace\n")
  assertFalse(outcome.ok, "ERR marker parsed")
  assertEqual(outcome.err, "no workspace", "text after the marker, space stripped")
}

test "parseInspectLog treats a marker-free log as infrastructure failure" {
  val outcome = parseInspectLog("container never reached the inspect block")
  assertFalse(outcome.ok, "no marker means not ok")
  assertEqual(outcome.err, "", "empty err distinguishes missing-marker from entrypoint ERR")
}

test "parseInspectLog lets whichever marker appears first win" {
  // An ERR whose message is echoed into a later section must not be
  // mistaken for the outcome when OK came first — and vice versa.
  val okFirst = parseInspectLog("CLOUD_AGENTS_INSPECT_OK\nCLOUD_AGENTS_INSPECT_ERR not found\n")
  assertTrue(okFirst.ok, "OK before ERR is OK")
  val errFirst = parseInspectLog("CLOUD_AGENTS_INSPECT_ERR bad mode\nCLOUD_AGENTS_INSPECT_OK\n")
  assertFalse(errFirst.ok, "ERR before OK is ERR")
  assertEqual(errFirst.err, "bad mode", "ERR line text kept")
}

test "parseInspectLog handles an OK marker with an empty body" {
  // tree mode against an empty repo: marker line, then nothing.
  val outcome = parseInspectLog("CLOUD_AGENTS_INSPECT_OK\n")
  assertTrue(outcome.ok, "bare OK is ok")
  assertEqualInt(outcome.sections.length.toInt(), 1, "one empty section")
  assertEqual(outcome.sections[0], "", "empty section body")
}

// ── git status --porcelain parsing ───────────────────────────────────────────

test "parsePorcelain maps XY codes and keeps rename targets" {
  val text = " M src/a.l\n?? new.txt\nR  old.txt -> new2.txt\nA  added.l\nT  weird.l\n"
  val status = parsePorcelain(text)
  assertEqualInt(status.paths.length.toInt(), 5, "five entries")
  assertEqual(status.statuses[0], "M", "worktree-only modify falls back to the Y char")
  assertEqual(status.paths[0], "src/a.l", "path after the XY+space prefix")
  assertEqual(status.statuses[1], "U", "?? is untracked")
  assertEqual(status.statuses[2], "R", "rename status")
  assertEqual(status.paths[2], "new2.txt", "rename keeps the NEW path")
  assertEqual(status.statuses[3], "A", "added status")
  assertEqual(status.statuses[4], "X", "unmapped codes collapse to X")
}

test "parsePorcelain ignores blank and too-short lines" {
  val status = parsePorcelain("\n M a\nxx\n")
  assertEqualInt(status.paths.length.toInt(), 1, "only the real entry survives")
  assertEqual(status.paths[0], "a", "single-char path parsed")
}

// ── git diff --numstat parsing ───────────────────────────────────────────────

test "parseNumstat parses counts, binary markers, and renames" {
  val text = "3\t1\tsrc/a.l\n-\t-\tbin.png\n2\t0\tsrc/{old => new}/x.l\n1\t1\told.txt => new2.txt\n"
  val stats = parseNumstat(text)
  assertEqualInt(stats.paths.length.toInt(), 4, "four entries")
  assertEqual(stats.adds[0], "3", "additions")
  assertEqual(stats.dels[0], "1", "deletions")
  assertEqual(stats.adds[1], "", "binary '-' becomes empty")
  assertEqual(stats.dels[1], "", "binary '-' becomes empty")
  assertEqual(stats.paths[2], "src/new/x.l", "brace-collapsed rename resolves to the new path")
  assertEqual(stats.paths[3], "new2.txt", "plain rename resolves to the new path")
}

test "diffFilesOf joins porcelain entries with numstat counts by path" {
  val status = parsePorcelain(" M src/a.l\n?? new.txt\n")
  val stats = parseNumstat("3\t1\tsrc/a.l\n")
  val files = diffFilesOf(status, stats)
  assertEqualInt(files.length.toInt(), 2, "one file per porcelain entry")
  assertEqual(files[0].path, "src/a.l", "path from porcelain")
  assertEqual(files[0].status, "M", "status from porcelain")
  assertEqual(files[0].additions, "3", "additions joined from numstat")
  assertEqual(files[0].deletions, "1", "deletions joined from numstat")
  assertEqual(files[1].additions, "", "untracked file has no numstat row")
  assertEqual(files[1].deletions, "", "untracked file has no numstat row")
}

// ── Tree / file-mode helpers ─────────────────────────────────────────────────

test "nonEmptyLines drops blanks and trims carriage returns" {
  val lines = nonEmptyLines("a\n\r\nb\r\n")
  assertEqualInt(lines.length.toInt(), 2, "blank and CR-only lines dropped")
  assertEqual(lines[0], "a", "first line")
  assertEqual(lines[1], "b", "CR trimmed")
}

test "treeTruncated flips exactly at the entrypoint's head cap" {
  assertFalse(treeTruncated(4999), "below the cap")
  assertTrue(treeTruncated(5000), "at the cap")
}

test "parseSizeLine extracts one whitespace-tolerant digit run" {
  assertEqual(parseSizeLine(" 1234\n"), "1234", "wc -c style output")
  assertEqual(parseSizeLine("0"), "0", "zero-byte file")
  assertEqual(parseSizeLine("12a4"), "", "non-digit rejects the line")
  assertEqual(parseSizeLine(""), "", "empty line")
}

test "sizeExceedsCap compares digit strings against the 1 MiB cap" {
  assertFalse(sizeExceedsCap("1048576"), "exactly the cap is not truncated")
  assertTrue(sizeExceedsCap("1048577"), "one past the cap")
  assertFalse(sizeExceedsCap("999999"), "shorter digit string is under")
  assertTrue(sizeExceedsCap("10485760"), "longer digit string is over without Int parsing")
  assertFalse(sizeExceedsCap(""), "unknown size is not flagged truncated")
}

test "joinBase64 collapses wrapped base64 output into one string" {
  assertEqual(joinBase64("QUJD\nREVG\r\nR0hJ\n"), "QUJDREVGR0hJ", "newlines and CRs stripped")
  assertEqual(joinBase64(""), "", "empty body")
}

// ── JSON assembly ────────────────────────────────────────────────────────────

test "diffJson emits files, patch, and the clean flag" {
  val status = parsePorcelain(" M a\"b.l\n")
  val stats = parseNumstat("1\t2\ta\"b.l\n")
  val files = diffFilesOf(status, stats)
  val json = diffJson(files, "diff --git")
  assertEqual(
    json,
    "{\"files\":[{\"path\":\"a\\\"b.l\",\"status\":\"M\",\"additions\":\"1\",\"deletions\":\"2\"}],\"patch\":\"diff --git\",\"clean\":\"false\"}",
    "one-file diff JSON with the path's quote escaped"
  )
  val noFiles = diffFilesOf(parsePorcelain(""), parseNumstat(""))
  assertEqual(
    diffJson(noFiles, ""),
    "{\"files\":[],\"patch\":\"\",\"clean\":\"true\"}",
    "empty diff is clean"
  )
}

test "fileListJson emits paths and the truncated flag" {
  val paths = nonEmptyLines("README.md\nsrc/main.l\n")
  assertEqual(
    fileListJson(paths, false),
    "{\"files\":[{\"path\":\"README.md\"},{\"path\":\"src/main.l\"}],\"truncated\":\"false\"}",
    "two-entry file list"
  )
  val none = nonEmptyLines("")
  assertEqual(
    fileListJson(none, true),
    "{\"files\":[],\"truncated\":\"true\"}",
    "empty capped list keeps the truncated flag"
  )
}

test "fileContentJson emits path, content, size, and truncated" {
  assertEqual(
    fileContentJson("src/main.l", "QUJD", "3", false),
    "{\"path\":\"src/main.l\",\"contentBase64\":\"QUJD\",\"size\":\"3\",\"truncated\":\"false\"}",
    "file content JSON"
  )
}
