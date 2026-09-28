//! CloudAgents.Ledger.Policy — severity policy (docs/session-ledger.md §5).
//!
//! The agent proposes a severity; policy may RAISE it, never lower it. Policy
//! is data: the defaults below, plus the optional `.agent-ledger.json` from
//! the target repo's default branch, whose rules are APPENDED to the
//! defaults. Because evaluation is a max over every matching rule, a repo
//! policy can only ever add floors — it can never weaken a default rule.
//!
//! `.agent-ledger.json` format (spec §8):
//!
//!   { "rules": [
//!       { "match": { "kind": "shortcut" }, "minSeverity": "review" },
//!       { "match": { "tagsAny": ["deps"], "filesGlob": ["**/*.lock"] },
//!         "minSeverity": "blocking" } ] }
//!
//! `match` keys (all optional, AND-ed; an absent key matches anything):
//! `kind`, `reversible` (bool), `tagsAny` (string[]), `filesGlob`
//! (string[]; `**` crosses directories, `*` / `?` do not), `source`,
//! `undeclared` (bool). Unknown keys are rejected so a typo surfaces instead
//! of silently turning a narrow rule into a match-everything rule.
package CloudAgents.Ledger.Policy

import Std.Core
import Std.Collections
import Std.Json
import CloudAgents.Ledger.Model

/// One policy rule. Empty strings / slices are wildcards; `reversible` and
/// `undeclared` are "true" / "false" / "" (wildcard).
pub record PolicyRule {
  pub kind: String
  pub reversible: String
  pub tagsAny: slice[String]
  pub filesGlob: slice[String]
  pub source: String
  pub undeclared: String
  pub minSeverity: String
}

/// The facts about an entry that policy can match on.
pub record EntryFacts {
  pub kind: String
  pub reversible: String
  pub tags: slice[String]
  pub files: slice[String]
  pub source: String
  pub undeclared: Bool
}

func rule(
  kind: in String,
  reversible: in String,
  tagsAny: in slice[String],
  filesGlob: in slice[String],
  source: in String,
  undeclared: in String,
  min: in String,
): PolicyRule {
  return PolicyRule(
    kind = kind,
    reversible = reversible,
    tagsAny = tagsAny,
    filesGlob = filesGlob,
    source = source,
    undeclared = undeclared,
    minSeverity = min
  )
}

/// The built-in rules (spec §8's defaults, plus `question` -> review: a
/// question exists to get a human's input, so it belongs in the attention
/// queue even though the agent carries on with its default).
pub func defaultRules(): slice[PolicyRule] {
  val none: slice[String] = []
  return [
    rule("shortcut", "", none, none, "", "", "review"),
    rule("deviation", "", none, none, "", "", "review"),
    rule("question", "", none, none, "", "", "review"),
    rule("", "false", none, none, "", "", "review"),
    rule("", "", ["tests"], none, "", "", "review"),
    rule("", "", ["deps", "schema", "security", "api-change", "migration"], none, "", "", "review"),
    rule("blocker", "", none, none, "", "", "blocking"),
    rule("", "", none, ["**/*.lock", "**/migrations/**", ".github/workflows/**"], "", "", "review"),
    rule("", "", none, none, "observed", "true", "review")
  ]
}

/// The effective severity: the agent's `declared` severity ("" = none, taken
/// as info) raised to the highest `minSeverity` of every matching rule.
pub func effectiveSeverity(declared: in String, facts: in EntryFacts, rules: in slice[PolicyRule]): String {
  var sev = "info"
  if isValidSeverity(declared) {
    sev = declared
  }
  // Glob matching costs (pattern x path) per pair. When one entry's files
  // against every glob would exceed the budget, file globs are treated as
  // matching: the policy only ever raises severity, so the entry lands in
  // review rather than the request thread doing unbounded work.
  val globsAffordable = globWork(rules, facts.files) <= globWorkBudget
  var i = 0
  while i < rules.length.toInt() {
    if ruleMatchesWithin(rules[i], facts, globsAffordable) {
      sev = maxSeverity(sev, rules[i].minSeverity)
    }
    i = i + 1
  }
  return sev
}

/// The most glob-matching work (DP cells) one entry may cost.
pub val globWorkBudget: Int = 4000000

/// The DP cells matching every file against every glob would take.
pub func globWork(rules: in slice[PolicyRule], files: in slice[String]): Int {
  var pathCells = 0
  var i = 0
  while i < files.length.toInt() {
    pathCells = pathCells + files[i].length.toInt() + 1
    i = i + 1
  }
  var patternCells = 0
  var r = 0
  while r < rules.length.toInt() {
    var g = 0
    while g < rules[r].filesGlob.length.toInt() {
      patternCells = patternCells + rules[r].filesGlob[g].length.toInt() + 1
      g = g + 1
    }
    r = r + 1
  }
  if pathCells == 0 or patternCells == 0 {
    return 0
  }
  // Both factors are capped by validation (policy globs, entry files), so
  // the product stays well inside Int.
  return pathCells * patternCells
}

/// The initial review state for an entry of effective severity `sev`.
pub func initialReviewState(sev: in String): String {
  if sev == "info" {
    return "not_required"
  }
  return "pending"
}

func boolText(b: in Bool): String {
  if b {
    return "true"
  }
  return "false"
}

pub func ruleMatches(r: in PolicyRule, f: in EntryFacts): Bool {
  return ruleMatchesWithin(r, f, true)
}

func ruleMatchesWithin(r: in PolicyRule, f: in EntryFacts, globsAffordable: in Bool): Bool {
  if r.kind.length.toInt() > 0 and r.kind != f.kind {
    return false
  }
  if r.reversible.length.toInt() > 0 and r.reversible != f.reversible {
    return false
  }
  if r.source.length.toInt() > 0 and r.source != f.source {
    return false
  }
  if r.undeclared.length.toInt() > 0 and r.undeclared != boolText(f.undeclared) {
    return false
  }
  if r.tagsAny.length.toInt() > 0 and not anyShared(r.tagsAny, f.tags) {
    return false
  }
  if r.filesGlob.length.toInt() > 0 and globsAffordable and not anyFileMatches(r.filesGlob, f.files) {
    return false
  }
  return true
}

func anyShared(a: in slice[String], b: in slice[String]): Bool {
  var i = 0
  while i < a.length.toInt() {
    if containsString(b, a[i]) {
      return true
    }
    i = i + 1
  }
  return false
}

func anyFileMatches(globs: in slice[String], files: in slice[String]): Bool {
  var i = 0
  while i < files.length.toInt() {
    var j = 0
    while j < globs.length.toInt() {
      if globMatch(globs[j], normalizePath(files[i])) {
        return true
      }
      j = j + 1
    }
    i = i + 1
  }
  return false
}

// Strip a leading "./" or "/" so repo-relative globs match however the agent
// spelled the path.
func normalizePath(p: in String): String {
  var s = p
  while s.startsWith("./") {
    s = s.substring(2, s.length.toInt() - 2)
  }
  while s.startsWith("/") {
    s = s.substring(1, s.length.toInt() - 1)
  }
  return s
}

/// Glob match over '/'-separated paths: `**` matches any run of characters
/// including '/', and `**/` additionally matches nothing (so `**/*.lock`
/// matches a root-level `Cargo.lock`); `*` matches any run without '/'; `?`
/// matches one non-'/' character; everything else is literal.
pub func globMatch(pattern: in String, path: in String): Bool {
  // Dynamic programming over (pattern index, path index), one pattern row
  // at a time from the end, so a pattern with many wildcards (repo policy
  // files are untrusted input) costs O(pattern x path), never exponential.
  // Each row is stored reversed: row[sn - si] is the match from path index si.
  val pn = pattern.length.toInt()
  val sn = path.length.toInt()
  var r1: List[Bool] = newList()
  var si = sn
  while si >= 0 {
    r1.add(si == sn)
    si = si - 1
  }
  var r2: List[Bool] = newList()
  var r3: List[Bool] = newList()
  var pi = pn - 1
  while pi >= 0 {
    val row: List[Bool] = newList()
    val c = pattern.substring(pi, 1)
    val isDouble = c == "*" and pi + 1 < pn and pattern.substring(pi + 1, 1) == "*"
    // "**/" may also match zero directories.
    val zeroDirs = isDouble and pi + 2 < pn and pattern.substring(pi + 2, 1) == "/"
    si = sn
    while si >= 0 {
      var v = false
      if isDouble {
        v = r2[sn - si]
        if not v and si < sn {
          v = row[sn - si - 1]
        }
        // "**/" matches zero directories only at a segment start, so
        // "**/test.py" never matches "src/latest.py".
        if not v and zeroDirs and (si == 0 or path.substring(si - 1, 1) == "/") {
          v = r3[sn - si]
        }
      } else {
        if c == "*" {
          v = r1[sn - si]
          if not v and si < sn {
            if path.substring(si, 1) != "/" {
              v = row[sn - si - 1]
            }
          }
        } else {
          if si < sn {
            val sc = path.substring(si, 1)
            if c == "?" {
              v = sc != "/" and r1[sn - si - 1]
            } else {
              v = c == sc and r1[sn - si - 1]
            }
          }
        }
      }
      row.add(v)
      si = si - 1
    }
    r3 = r2
    r2 = r1
    r1 = row
    pi = pi - 1
  }
  return r1[sn]
}

// ── Repo policy file ──────────────────────────────────────────────────────────
val jsonKindObject = 1

val jsonKindArray = 2

val jsonKindString = 3

val jsonKindTrue = 5

val jsonKindFalse = 6

/// Parse `.agent-ledger.json` into rules (to append to defaultRules()).
/// Errors name the offending rule index / key so a repo owner can fix the
/// file; the caller falls back to the defaults alone.
pub func parseRepoPolicy(json: in String): Result[slice[PolicyRule], String] {
  val doc = match Std.Json.tryParseJson(json) {
    case Ok(d) -> d
    case Err(e) -> return Err(error = "not valid JSON: " + e)
  }
  defer {
    Std.Json.disposeJson(doc)
  }
  return try {
    parseRoot(Std.Json.rootElement(doc))
  } catch Bug as b {
    Err(error = "unreadable policy: " + b.message)
  }
}

func parseRoot(root: in JsonElement): Result[slice[PolicyRule], String] {
  if Std.Json.valueKind(root) != jsonKindObject {
    return Err(error = "top level must be an object with a \"rules\" array")
  }
  val rulesEl = match Std.Json.tryGetProperty(root, "rules") {
    case Some(r) -> r
    case None -> return Err(error = "missing \"rules\" array")
  }
  if Std.Json.valueKind(rulesEl) != jsonKindArray {
    return Err(error = "\"rules\" must be an array")
  }
  var kinds: slice[String] = []
  var revs: slice[String] = []
  var tagLists: slice[String] = []
  var globLists: slice[String] = []
  var sources: slice[String] = []
  var undecls: slice[String] = []
  var mins: slice[String] = []
  var totalGlobs = 0
  var cur = Std.Json.enumerateArray(rulesEl)
  var idx = 0
  while Std.Json.arrayMoveNext(cur) {
    if idx >= 100 {
      return Err(error = "too many rules (max 100)")
    }
    val el = Std.Json.arrayCurrent(cur)
    val at = "rules[" + toString(idx) + "]"
    if Std.Json.valueKind(el) != jsonKindObject {
      return Err(error = at + " must be an object")
    }
    val minEl = match Std.Json.tryGetProperty(el, "minSeverity") {
      case Some(m) -> m
      case None -> return Err(error = at + " is missing minSeverity")
    }
    val min = stringOf(minEl)
    if not isValidSeverity(min) {
      return Err(error = at + ".minSeverity must be info, review or blocking")
    }
    var kind = ""
    var rev = ""
    var tags = ""
    var globs = ""
    var source = ""
    var undecl = ""
    match Std.Json.tryGetProperty(el, "match") {
      case None -> ()
      case Some(m) -> {
        if Std.Json.valueKind(m) != jsonKindObject {
          return Err(error = at + ".match must be an object")
        }
        var pc = Std.Json.enumerateObject(m)
        while Std.Json.objectMoveNext(pc) {
          val prop = Std.Json.objectCurrent(pc)
          val key = Std.Json.propertyName(prop)
          val v = Std.Json.propertyValue(prop)
          if key == "kind" {
            kind = stringOf(v)
            if not isValidEntryKind(kind) {
              return Err(error = at + ".match.kind must be decision, deviation, shortcut, blocker, question or note")
            }
          } else if key == "reversible" {
            rev = boolOf(v)
            if rev.length.toInt() == 0 {
              return Err(error = at + ".match.reversible must be true or false")
            }
          } else if key == "undeclared" {
            undecl = boolOf(v)
            if undecl.length.toInt() == 0 {
              return Err(error = at + ".match.undeclared must be true or false")
            }
          } else if key == "source" {
            source = stringOf(v)
            if not isValidEntrySource(source) {
              return Err(error = at + ".match.source must be declared, observed or system")
            }
          } else if key == "tagsAny" {
            val parsed = stringList(v, at + ".match.tagsAny", maxTagsPerRule, 32)
            tags = parsed?
            val bad = firstInvalidTag(splitList(tags))
            if bad.length.toInt() > 0 {
              return Err(
                error = at + ".match.tagsAny has invalid tag \"" + bad +
                  "\": tags are 1-32 of a-z 0-9 -, as agents record them"
              )
            }
          } else if key == "filesGlob" {
            val parsed = stringList(v, at + ".match.filesGlob", maxGlobsPerRule, maxGlobChars)
            globs = parsed?
            totalGlobs = totalGlobs + splitList(globs).length.toInt()
            if totalGlobs > maxGlobsPerPolicy {
              return Err(error = "too many filesGlob patterns across all rules (max " + toString(maxGlobsPerPolicy) + ")")
            }
          } else {
            return Err(error = at + ".match has unknown key \"" + key + "\"")
          }
        }
      }
    }
    kinds = kinds.append(kind)
    revs = revs.append(rev)
    tagLists = tagLists.append(tags)
    globLists = globLists.append(globs)
    sources = sources.append(source)
    undecls = undecls.append(undecl)
    mins = mins.append(min)
    idx = idx + 1
  }
  return Ok(value = zipRules(kinds, revs, tagLists, globLists, sources, undecls, mins))
}

// Built in a separate, never-hot function from parallel string slices
// (docs/lyric/gotchas.md: record appends inside a loop can miscompile once
// the loop is hot). The list fields travel as "\n"-joined strings.
func zipRules(
  kinds: in slice[String],
  revs: in slice[String],
  tagLists: in slice[String],
  globLists: in slice[String],
  sources: in slice[String],
  undecls: in slice[String],
  mins: in slice[String],
): slice[PolicyRule] {
  var acc: slice[PolicyRule] = []
  var i = 0
  while i < kinds.length.toInt() {
    acc = acc.append(
      rule(kinds[i], revs[i], splitList(tagLists[i]), splitList(globLists[i]), sources[i], undecls[i], mins[i])
    )
    i = i + 1
  }
  return acc
}

func splitList(joined: in String): slice[String] {
  if joined.length.toInt() == 0 {
    val none: slice[String] = []
    return none
  }
  return splitOn(joined, "\n")
}

func stringOf(v: in JsonElement): String {
  if Std.Json.valueKind(v) != jsonKindString {
    return ""
  }
  return Std.Json.getString(v)
}

func boolOf(v: in JsonElement): String {
  val k = Std.Json.valueKind(v)
  if k == jsonKindTrue {
    return "true"
  }
  if k == jsonKindFalse {
    return "false"
  }
  return ""
}

/// Caps on a repo policy's match lists. With the per-entry `files` cap they
/// bound glob matching (see globWork); a file over them is rejected with a
/// message naming the limit, never silently truncated.
pub val maxTagsPerRule: Int = 10

pub val maxGlobsPerRule: Int = 20

pub val maxGlobsPerPolicy: Int = 50

pub val maxGlobChars: Int = 256

// A JSON array of 1..maxItems non-empty, newline-free strings of at most
// maxChars each, joined with "\n". Errors name `field` and the rule broken.
func stringList(v: in JsonElement, field: in String, maxItems: in Int, maxChars: in Int): Result[String, String] {
  if Std.Json.valueKind(v) != jsonKindArray {
    return Err(error = field + " must be an array of strings")
  }
  var acc = ""
  var n = 0
  var cur = Std.Json.enumerateArray(v)
  while Std.Json.arrayMoveNext(cur) {
    val el = Std.Json.arrayCurrent(cur)
    val at = field + "[" + toString(n) + "]"
    if Std.Json.valueKind(el) != jsonKindString {
      return Err(error = at + " must be a string")
    }
    val s = Std.Json.getString(el)
    if s.length.toInt() == 0 {
      return Err(error = at + " must not be empty")
    }
    if s.contains("\n") {
      return Err(error = at + " must be a single line")
    }
    if s.length.toInt() > maxChars {
      return Err(error = at + " is too long (max " + toString(maxChars) + " characters)")
    }
    if n >= maxItems {
      return Err(error = field + " has too many entries (max " + toString(maxItems) + ")")
    }
    if n > 0 {
      acc = acc + "\n"
    }
    acc = acc + s
    n = n + 1
  }
  if n == 0 {
    return Err(error = field + " must not be empty")
  }
  return Ok(value = acc)
}

// The first entry that isn't a valid entry tag, or "".
func firstInvalidTag(tags: in slice[String]): String {
  var i = 0
  while i < tags.length.toInt() {
    if not isValidTag(tags[i]) {
      return tags[i]
    }
    i = i + 1
  }
  return ""
}
