//! Pure workspace-inspector logic: inspect-path validation, parsing of the
//! CLOUD_AGENTS_INSPECT_* marker protocol the docker/ entrypoint scripts print
//! in inspect mode, `git status --porcelain` / `git diff --numstat` parsing,
//! and assembly of the hand-built JSON the workspace endpoints return.
//!
//! This lives in its own package rather than CloudAgents.Docker (which runs
//! the inspect containers) so the logic is unit-testable: invoking ANY
//! function from an async-bearing package via the @test_module harness throws
//! "The signature is incorrect." (docs/lyric/gotchas.md), even for a pure
//! leaf function — the same reason CloudAgents.NetworkPolicy and
//! CloudAgents.RunnerEnv were split out of CloudAgents.Docker.
//!
//! Keep the marker literals here byte-for-byte in sync with the inspect-mode
//! block at the top of every docker/entrypoint*.sh.
package CloudAgents.Workspace

import Std.Core
import CloudAgents.Streaming
import CloudAgents.Text

// The entrypoint prints exactly one of these two markers first, then (for the
// OK case) one or more sections separated by the section marker, each on its
// own line. OK is deliberately not a prefix of ERR (and vice versa) so a
// plain substring search can never confuse them.
val okMarker = "CLOUD_AGENTS_INSPECT_OK"
val errMarker = "CLOUD_AGENTS_INSPECT_ERR"
val sectionMarker = "===CLOUD_AGENTS_SECTION==="

/// Cap on the number of entries the tree mode returns — must match the
/// `head -5000` in the entrypoints' inspect blocks; hitting it flips the
/// endpoint's `truncated` flag.
val treeCapCount = 5000

// ─── Inspect-path validation ─────────────────────────────────────────────────

/// Whether `path` is safe to hand to an inspect container as
/// CLOUD_AGENTS_INSPECT_PATH (a repo-relative file path). Rejects anything
/// empty, longer than 512 chars, absolute (leading '/'), traversing (a ".."
/// segment), starting with '-' (option-injection into shell tools), or
/// carrying a backslash, quote ('/"), backtick, '$', or any control
/// character. The env value is only ever used quoted in the entrypoint, but
/// the shell-metacharacter rejections keep the value inert even if a future
/// entrypoint edit drops a quote. Note "a..b" is fine — only a full ".."
/// SEGMENT traverses.
pub func validInspectPath(path: in String): Bool {
  val n = path.length.toInt()
  if n == 0 or n > 512 {
    return false
  }
  val first = path.substring(0, 1)
  if first == "/" or first == "-" {
    return false
  }
  var segStart = 0
  var i = 0
  while i <= n {
    if i == n or path.substring(i, 1) == "/" {
      if path.substring(segStart, i - segStart) == ".." {
        return false
      }
      segStart = i + 1
    }
    if i < n {
      val c = path.substring(i, 1)
      if c == "\\" or c == "'" or c == "\"" or c == "`" or c == "$" {
        return false
      }
      if CloudAgents.Text.isControlChar(c) {
        return false
      }
    }
    i = i + 1
  }
  return true
}

// ─── Marker-protocol parsing ─────────────────────────────────────────────────

/// The parsed shape of one inspect container's captured logs. Plain fields,
/// not a Result — storing a Result in a record field breaks match on
/// read-back (docs/lyric/gotchas.md, lyric-lang#6231). `ok` false with a
/// non-empty `err` is an entrypoint-reported failure (the text after
/// CLOUD_AGENTS_INSPECT_ERR); `ok` false with an empty `err` means neither
/// marker was found (the container never reached the inspect block — treat
/// as an infrastructure failure).
pub record InspectOutcome {
  pub ok: Bool
  pub err: String
  pub sections: slice[String]
}

/// One changed file in the workspace diff.
pub record WorkspaceDiffFile {
  pub path: String
  pub status: String
  pub additions: String
  pub deletions: String
}

/// Parallel porcelain-status/path slices — parallel slices rather than a
/// slice of records so the line-scanning parse loop only ever appends
/// STRINGS (record appends inside a hot loop miscompile under OSR,
/// lyric-lang#6322 — the planItemsOf pattern from
/// src/handlers/interactions.l).
pub record StatusList {
  pub statuses: slice[String]
  pub paths: slice[String]
}

/// Parallel numstat path/additions/deletions slices, same rationale as
/// StatusList.
pub record NumstatList {
  pub paths: slice[String]
  pub adds: slice[String]
  pub dels: slice[String]
}

func trimCr(s: in String): String {
  val n = s.length.toInt()
  if n > 0 and s.substring(n - 1, 1) == "\r" {
    return s.substring(0, n - 1)
  }
  return s
}

/// Strip the single leading newline left over from the preceding marker
/// line's own line ending, and the single trailing newline before the next
/// marker — interior newlines are content and stay.
func trimSectionEdges(s: in String): String {
  var start = 0
  var stop = s.length.toInt()
  if start < stop and s.substring(start, 1) == "\r" {
    start = start + 1
  }
  if start < stop and s.substring(start, 1) == "\n" {
    start = start + 1
  }
  if stop > start and s.substring(stop - 1, 1) == "\n" {
    stop = stop - 1
  }
  if stop > start and s.substring(stop - 1, 1) == "\r" {
    stop = stop - 1
  }
  return s.substring(start, stop - start)
}

func splitSections(body: in String): slice[String] {
  var sections: slice[String] = []
  val n = body.length.toInt()
  var start = 0
  var scanning = true
  while scanning {
    val d = CloudAgents.Text.indexOfFrom(body, sectionMarker, start)
    if d < 0 {
      sections = sections.append(trimSectionEdges(body.substring(start, n - start)))
      scanning = false
    } else {
      sections = sections.append(trimSectionEdges(body.substring(start, d - start)))
      start = d + sectionMarker.length.toInt()
    }
  }
  return sections
}

/// The text after the ERR marker on the marker's own line ("no workspace",
/// "not found", "bad mode"), with the separating space and any trailing \r
/// stripped.
func errLineOf(log: in String, errIdx: in Int): String {
  val n = log.length.toInt()
  var start = errIdx + errMarker.length.toInt()
  if start < n and log.substring(start, 1) == " " {
    start = start + 1
  }
  var stop = CloudAgents.Text.indexOfFrom(log, "\n", start)
  if stop < 0 {
    stop = n
  }
  return trimCr(log.substring(start, stop - start))
}

/// Parse an inspect container's captured logs into the marker protocol:
/// whichever of CLOUD_AGENTS_INSPECT_OK / CLOUD_AGENTS_INSPECT_ERR appears
/// first wins; after OK, the rest of the log is split on the section marker.
/// Substring-based (indexOfFrom + one substring copy per section) rather
/// than a char-accumulating line loop so a megabyte-scale patch or base64
/// body stays O(n), not O(n²).
pub func parseInspectLog(log: in String): InspectOutcome {
  val emptySections: slice[String] = []
  val okIdx = CloudAgents.Text.indexOfFrom(log, okMarker, 0)
  val errIdx = CloudAgents.Text.indexOfFrom(log, errMarker, 0)
  if errIdx >= 0 and (okIdx < 0 or errIdx < okIdx) {
    return InspectOutcome(ok = false, err = errLineOf(log, errIdx), sections = emptySections)
  }
  if okIdx < 0 {
    return InspectOutcome(ok = false, err = "", sections = emptySections)
  }
  val n = log.length.toInt()
  val markerEnd = okIdx + okMarker.length.toInt()
  val nl = CloudAgents.Text.indexOfFrom(log, "\n", markerEnd)
  if nl < 0 {
    // Marker with no line after it — an empty single section.
    return InspectOutcome(ok = true, err = "", sections = [""])
  }
  val bodyStart = nl + 1
  return InspectOutcome(ok = true, err = "", sections = splitSections(log.substring(bodyStart, n - bodyStart)))
}

// ─── git status --porcelain parsing ──────────────────────────────────────────

/// Normalize a porcelain two-char XY code to the endpoint's single-letter
/// status: "??" is U (untracked); otherwise the first char (falling back to
/// the second when the first is the ' ' of a worktree-only change) maps
/// M/A/D/R through and anything else (C copies, T typechanges, U unmerged,
/// ...) is X.
func statusCharOf(xy: in String): String {
  if xy == "??" {
    return "U"
  }
  var c = xy.substring(0, 1)
  if c == " " {
    c = xy.substring(1, 1)
  }
  if c == "M" or c == "A" or c == "D" or c == "R" {
    return c
  }
  return "X"
}

/// Parse `git status --porcelain` output (lines of `XY path`, renames as
/// `R  old -> new` — the NEW path is kept) into parallel status/path slices.
pub func parsePorcelain(text: in String): StatusList {
  var statuses: slice[String] = []
  var paths: slice[String] = []
  val n = text.length.toInt()
  var start = 0
  while start < n {
    var lineEnd = CloudAgents.Text.indexOfFrom(text, "\n", start)
    if lineEnd < 0 {
      lineEnd = n
    }
    val line = trimCr(text.substring(start, lineEnd - start))
    start = lineEnd + 1
    // `XY<space>` + at least one path char.
    if line.length.toInt() >= 4 {
      val status = statusCharOf(line.substring(0, 2))
      var p = line.substring(3, line.length.toInt() - 3)
      if status == "R" {
        val arrow = CloudAgents.Text.indexOfFrom(p, " -> ", 0)
        if arrow >= 0 {
          p = p.substring(arrow + 4, p.length.toInt() - arrow - 4)
        }
      }
      if p.length > 0 {
        statuses = statuses.append(status)
        paths = paths.append(p)
      }
    }
  }
  return StatusList(statuses = statuses, paths = paths)
}

// ─── git diff --numstat parsing ──────────────────────────────────────────────

/// Resolve a numstat path that may carry a rename ("old => new" or the
/// brace-collapsed "prefix{old => new}suffix") to the NEW path.
func numstatPath(raw: in String): String {
  val n = raw.length.toInt()
  val arrow = CloudAgents.Text.indexOfFrom(raw, " => ", 0)
  if arrow < 0 {
    return raw
  }
  val braceOpen = CloudAgents.Text.indexOfFrom(raw, "{", 0)
  if braceOpen >= 0 and braceOpen < arrow {
    val braceClose = CloudAgents.Text.indexOfFrom(raw, "}", arrow)
    if braceClose > arrow {
      return raw.substring(0, braceOpen) + raw.substring(arrow + 4, braceClose - arrow - 4) +
        raw.substring(braceClose + 1, n - braceClose - 1)
    }
  }
  return raw.substring(arrow + 4, n - arrow - 4)
}

/// Parse `git diff --numstat` output (lines of `adds<TAB>dels<TAB>path`,
/// binary files as `-<TAB>-<TAB>path`) into parallel slices. A '-' count
/// becomes "" (unknown), matching the endpoint contract.
pub func parseNumstat(text: in String): NumstatList {
  var paths: slice[String] = []
  var adds: slice[String] = []
  var dels: slice[String] = []
  val n = text.length.toInt()
  var start = 0
  while start < n {
    var lineEnd = CloudAgents.Text.indexOfFrom(text, "\n", start)
    if lineEnd < 0 {
      lineEnd = n
    }
    val line = trimCr(text.substring(start, lineEnd - start))
    start = lineEnd + 1
    val lineLen = line.length.toInt()
    val t1 = CloudAgents.Text.indexOfFrom(line, "\t", 0)
    if t1 >= 1 {
      val t2 = CloudAgents.Text.indexOfFrom(line, "\t", t1 + 1)
      if t2 > t1 and t2 + 1 < lineLen {
        var a = line.substring(0, t1)
        var d = line.substring(t1 + 1, t2 - t1 - 1)
        if a == "-" {
          a = ""
        }
        if d == "-" {
          d = ""
        }
        paths = paths.append(numstatPath(line.substring(t2 + 1, lineLen - t2 - 1)))
        adds = adds.append(a)
        dels = dels.append(d)
      }
    }
  }
  return NumstatList(paths = paths, adds = adds, dels = dels)
}

/// Zip the matched parallel slices into WorkspaceDiffFile records. Split out
/// of diffFilesOf the way planItemsOf is split out of parseAgentPlan
/// (lyric-lang#6322): the record appends live here, where the loop is bounded
/// by the changed-file count and contains no nested scan.
func zipDiffFiles(
  statuses: in slice[String],
  paths: in slice[String],
  adds: in slice[String],
  dels: in slice[String],
): slice[WorkspaceDiffFile] {
  var files: slice[WorkspaceDiffFile] = []
  var i = 0
  while i < paths.length {
    files = files.append(
      WorkspaceDiffFile(path = paths[i], status = statuses[i], additions = adds[i], deletions = dels[i])
    )
    i = i + 1
  }
  return files
}

/// Join porcelain entries with their numstat counts by path: one
/// WorkspaceDiffFile per porcelain entry, additions/deletions "" when
/// numstat has no row for the path (untracked files) or reported '-'
/// (binary). The nested path-matching loop only appends STRINGS
/// (lyric-lang#6322); records are zipped afterwards in zipDiffFiles.
pub func diffFilesOf(status: in StatusList, numstats: in NumstatList): slice[WorkspaceDiffFile] {
  var adds: slice[String] = []
  var dels: slice[String] = []
  var i = 0
  while i < status.paths.length {
    var a = ""
    var d = ""
    var j = 0
    while j < numstats.paths.length {
      if numstats.paths[j] == status.paths[i] {
        a = numstats.adds[j]
        d = numstats.dels[j]
        j = numstats.paths.length.toInt()
      } else {
        j = j + 1
      }
    }
    adds = adds.append(a)
    dels = dels.append(d)
    i = i + 1
  }
  return zipDiffFiles(status.statuses, status.paths, adds, dels)
}

// ─── Tree / file-mode helpers ────────────────────────────────────────────────

/// The non-empty lines of a section (tree mode's file list), \r-trimmed.
pub func nonEmptyLines(text: in String): slice[String] {
  var lines: slice[String] = []
  val n = text.length.toInt()
  var start = 0
  while start < n {
    var lineEnd = CloudAgents.Text.indexOfFrom(text, "\n", start)
    if lineEnd < 0 {
      lineEnd = n
    }
    val line = trimCr(text.substring(start, lineEnd - start))
    start = lineEnd + 1
    if line.length > 0 {
      lines = lines.append(line)
    }
  }
  return lines
}

/// Whether a tree listing of `count` entries hit the entrypoint's
/// `head -5000` cap (and may therefore be incomplete).
pub func treeTruncated(count: in Int): Bool {
  return count >= treeCapCount
}

/// Extract the decimal byte count from a `wc -c` output line, tolerating
/// leading/trailing whitespace. "" when the line carries anything other than
/// one run of digits.
pub func parseSizeLine(s: in String): String {
  var digits = ""
  val n = s.length.toInt()
  var i = 0
  while i < n {
    val c = s.substring(i, 1)
    if c >= "0" and c <= "9" {
      digits = digits + c
    } else if c == " " or c == "\t" or c == "\r" or c == "\n" {
      if digits.length > 0 {
        return digits
      }
    } else {
      return ""
    }
    i = i + 1
  }
  return digits
}

// The file-content cap, as a digit string — must match the entrypoints'
// `head -c 1048576`. Compared digit-string-wise below so no Long arithmetic
// is needed for files over Int range.
val fileCapDigits = "1048576"

/// Whether a file's byte size (a digit string from parseSizeLine) exceeds
/// the 1 MiB content cap, i.e. the returned content was truncated. Pure
/// digit-string comparison — by length first, then digit by digit — so a
/// >2 GiB file can't overflow an Int parse.
pub func sizeExceedsCap(size: in String): Bool {
  val n = size.length.toInt()
  val capLen = fileCapDigits.length.toInt()
  if n > capLen {
    return true
  }
  if n < capLen {
    return false
  }
  var i = 0
  while i < capLen {
    val a = size.substring(i, 1)
    val b = fileCapDigits.substring(i, 1)
    if a > b {
      return true
    }
    if a < b {
      return false
    }
    i = i + 1
  }
  return false
}

/// Collapse `base64`'s 76-column-wrapped output into one contiguous base64
/// string (strips every \n/\r). Two-level accumulation (the stripAnsiSgr
/// idiom) keeps this linear-ish on megabyte bodies.
pub func joinBase64(s: in String): String {
  var acc = ""
  var chunk = ""
  val n = s.length.toInt()
  var start = 0
  while start < n {
    var lineEnd = CloudAgents.Text.indexOfFrom(s, "\n", start)
    if lineEnd < 0 {
      lineEnd = n
    }
    chunk = chunk + trimCr(s.substring(start, lineEnd - start))
    if chunk.length.toInt() > 8192 {
      acc = acc + chunk
      chunk = ""
    }
    start = lineEnd + 1
  }
  return acc + chunk
}

// ─── JSON assembly ───────────────────────────────────────────────────────────
//
// Hand-built JSON with every value a string, matching this codebase's
// hand-built-JSON convention (CONTRACT: "pendingCount":"2"-style). Escaping
// via CloudAgents.Streaming.jsonEscape, the battle-tested control-char-safe
// escaper the transcript path uses. additions/deletions are ""/digit strings
// by construction and are emitted verbatim.

/// {"files":[{"path":..,"status":..,"additions":..,"deletions":..}],"patch":..,"clean":"true|false"}
pub func diffJson(files: in slice[WorkspaceDiffFile], patch: in String): String {
  var json = "{\"files\":["
  var i = 0
  while i < files.length {
    if i > 0 {
      json = json + ","
    }
    json = json + "{\"path\":\"" + CloudAgents.Streaming.jsonEscape(files[i].path) + "\",\"status\":\"" +
      CloudAgents.Streaming.jsonEscape(files[i].status) +
      "\",\"additions\":\"" +
      files[i].additions +
      "\",\"deletions\":\"" +
      files[i].deletions +
      "\"}"
    i = i + 1
  }
  val cleanStr = if files.length == 0 then "true" else "false"
  return json + "],\"patch\":\"" + CloudAgents.Streaming.jsonEscape(patch) + "\",\"clean\":\"" + cleanStr + "\"}"
}

/// {"files":[{"path":"README.md"},...],"truncated":"false"}
pub func fileListJson(paths: in slice[String], truncated: in Bool): String {
  var json = "{\"files\":["
  var i = 0
  while i < paths.length {
    if i > 0 {
      json = json + ","
    }
    json = json + "{\"path\":\"" + CloudAgents.Streaming.jsonEscape(paths[i]) + "\"}"
    i = i + 1
  }
  val t = if truncated then "true" else "false"
  return json + "],\"truncated\":\"" + t + "\"}"
}

/// {"path":..,"contentBase64":..,"size":"1234","truncated":"false"}
pub func fileContentJson(path: in String, contentBase64: in String, size: in String, truncated: in Bool): String {
  val t = if truncated then "true" else "false"
  return "{\"path\":\"" + CloudAgents.Streaming.jsonEscape(path) + "\",\"contentBase64\":\"" +
    CloudAgents.Streaming.jsonEscape(contentBase64) +
    "\",\"size\":\"" +
    CloudAgents.Streaming.jsonEscape(size) +
    "\",\"truncated\":\"" +
    t +
    "\"}"
}
