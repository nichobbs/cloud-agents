//! CloudAgents.Ledger.Reconcile — the deterministic half of the observer
//! (docs/session-ledger.md §10). The observer agent only proposes candidates
//! (things the working agent did but did not declare); this package decides,
//! without any model in the loop, what becomes of each one:
//!   - dropped: below the confidence threshold;
//!   - duplicate: an earlier observation already covers it;
//!   - matched: a declared entry covers it (stored for audit, severity info);
//!   - undeclared: stored as an undeclared observation, which policy raises
//!     to at least review.
//! Pure: no I/O, so every rule is unit-tested on fixtures.
package CloudAgents.Ledger.Reconcile

import Std.Core
import CloudAgents.Ledger.Model

/// One candidate as the observer reported it, after field validation.
/// `seqStart`/`seqEnd` are the captured-event seqs (decimal) it rests on;
/// `confidence` is 0..1 as a decimal string; `itemId` is canonical or "".
pub record Candidate {
  pub kind: String
  pub summary: String
  pub detail: String
  pub itemId: String
  pub seqStart: String
  pub seqEnd: String
  pub tags: slice[String]
  pub files: slice[String]
  pub reversible: String
  pub confidence: String
  pub evidence: String
}

/// Tunables. `minConfidence` is in hundredths (50 = 0.5); `matchSlack` is how
/// many events either side of a candidate's range a declared entry's anchor
/// may sit (the anchor is taken when the agent records, which can lag the
/// work it describes by a poll tick).
pub record ReconcileConfig {
  pub minConfidence: Int
  pub matchSlack: Long
  pub notifyConfidence: Int
}

pub func defaultReconcileConfig(): ReconcileConfig {
  return ReconcileConfig(minConfidence = 50, matchSlack = 30.toLong(), notifyConfidence = 80)
}

/// What to do with a candidate: `action` is "drop", "duplicate", "matched" or
/// "undeclared"; `entryId` names the declared entry matched, or the earlier
/// observation duplicated.
pub record Verdict {
  pub action: String
  pub entryId: String
  pub reason: String
}

/// The kinds an observer may report. Notes are the agent's own asides, so
/// there is nothing undeclared about one.
pub func isObservableKind(k: in String): Bool {
  return k == "decision" or k == "deviation" or k == "shortcut" or k == "blocker" or k == "question"
}

/// Kinds that describe the same kind of thing for matching: a declared
/// deviation covers an observed shortcut and the reverse, a declared question
/// covers an observed blocker.
pub func kindFamily(k: in String): String {
  if k == "deviation" or k == "shortcut" {
    return "deviation"
  }
  if k == "blocker" or k == "question" {
    return "blocker"
  }
  return k
}

/// 0..1 as hundredths (0..100), or -1 when it isn't a number in range. Accepts
/// "1", "0", "0.5", ".75", "0.834" (truncated to hundredths).
pub func confidencePct(s: in String): Int {
  val t = s.trim()
  if t.length.toInt() == 0 {
    return -1
  }
  var whole = 0
  var frac = 0
  var fracDigits = 0
  var seenDot = false
  var digits = 0
  var i = 0
  while i < t.length.toInt() {
    val c = t.substring(i, 1)
    if c == "." {
      if seenDot {
        return -1
      }
      seenDot = true
    } else {
      val d = digitValue(c)
      if d < 0 {
        return -1
      }
      digits = digits + 1
      if seenDot {
        if fracDigits < 2 {
          frac = frac * 10 + d
          fracDigits = fracDigits + 1
        }
      } else {
        if whole > 1 {
          return -1
        }
        whole = whole * 10 + d
      }
    }
    i = i + 1
  }
  if digits == 0 {
    return -1
  }
  if fracDigits == 1 {
    frac = frac * 10
  }
  val pct = whole * 100 + frac
  if pct > 100 {
    return -1
  }
  return pct
}

func digitValue(c: in String): Int {
  val digits = "0123456789"
  var d = 0
  while d < 10 {
    if digits.substring(d, 1) == c {
      return d
    }
    d = d + 1
  }
  return -1
}

/// A non-negative decimal as a Long, or -1 when it isn't one.
pub func decimalLong(s: in String): Long {
  if s.length.toInt() == 0 or s.length.toInt() > 18 {
    return -1.toLong()
  }
  var acc = 0.toLong()
  var i = 0
  while i < s.length.toInt() {
    val d = digitValue(s.substring(i, 1))
    if d < 0 {
      return -1.toLong()
    }
    acc = acc * 10.toLong() + d.toLong()
    i = i + 1
  }
  return acc
}

// ── Summary similarity ────────────────────────────────────────────────────────
val stopWords = " the and for with from that this into when then than was were has have had not but its are "

/// The distinctive words of a summary: lowercase ASCII letters and digits,
/// three characters or more, stop words dropped, each once.
pub func summaryWords(s: in String): slice[String] {
  val lower = asciiLower(s)
  var words: slice[String] = []
  var cur = ""
  var i = 0
  while i <= lower.length.toInt() {
    var c = " "
    if i < lower.length.toInt() {
      c = lower.substring(i, 1)
    }
    if "abcdefghijklmnopqrstuvwxyz0123456789".contains(c) {
      cur = cur + c
    } else {
      if cur.length.toInt() >= 3 and not stopWords.contains(" " + cur + " ") and not containsString(words, cur) {
        words = words.append(cur)
      }
      cur = ""
    }
    i = i + 1
  }
  return words
}

/// Jaccard similarity of two summaries' word sets, in hundredths.
pub func similarityPct(a: in String, b: in String): Int {
  val wa = summaryWords(a)
  val wb = summaryWords(b)
  if wa.length.toInt() == 0 or wb.length.toInt() == 0 {
    return 0
  }
  var shared = 0
  var i = 0
  while i < wa.length.toInt() {
    if containsString(wb, wa[i]) {
      shared = shared + 1
    }
    i = i + 1
  }
  val union = wa.length.toInt() + wb.length.toInt() - shared
  return shared * 100 / union
}

// ── Rules ─────────────────────────────────────────────────────────────────────
func itemsCompatible(candidateItem: in String, entryItem: in String): Bool {
  return candidateItem.length.toInt() == 0 or entryItem.length.toInt() == 0 or candidateItem == entryItem
}

/// How far a declared entry's anchor sits from a range: 0 inside it, the gap
/// outside it, or -1 when the entry has no anchor.
func distanceTo(anchor: in String, start: in Long, finish: in Long): Long {
  val a = decimalLong(anchor)
  if a < 0.toLong() {
    return -1.toLong()
  }
  if a < start {
    return start - a
  }
  if a > finish {
    return a - finish
  }
  return 0.toLong()
}

/// The declared entry that covers a range of the transcript, if any: same kind
/// family, compatible work item, and either anchored within `slack` events of
/// the range and about the same thing (some shared wording or a shared file),
/// or (unanchored) a near-identical summary. The nearest wins.
pub func findDeclaredMatch(
  kind: in String,
  itemId: in String,
  summary: in String,
  files: in slice[String],
  start: in Long,
  finish: in Long,
  declared: in slice[LedgerEntry],
  slack: in Long,
): String {
  var best = ""
  var bestDistance = -1.toLong()
  var i = 0
  while i < declared.length.toInt() {
    val d = declared[i]
    if d.source != "observed" and kindFamily(d.kind) == kindFamily(kind) and itemsCompatible(itemId, d.itemId) {
      val distance = distanceTo(d.transcriptSeq, start, finish)
      var candidateDistance = -1.toLong()
      // Near in the transcript is necessary but not enough: two different
      // deviations can sit a few events apart. It must also be about the same
      // thing, by wording or by a file both name.
      val related = similarityPct(summary, d.summary) >= 20 or sharesFile(files, d.files)
      if distance >= 0.toLong() and distance <= slack and related {
        candidateDistance = distance
      } else if distance < 0.toLong() and similarityPct(summary, d.summary) >= 60 {
        candidateDistance = slack
      }
      if candidateDistance >= 0.toLong() and (bestDistance < 0.toLong() or candidateDistance < bestDistance) {
        best = d.id
        bestDistance = candidateDistance
      }
    }
    i = i + 1
  }
  return best
}

func sharesFile(a: in slice[String], b: in slice[String]): Bool {
  var i = 0
  while i < a.length.toInt() {
    if a[i].length.toInt() > 0 and containsString(b, a[i]) {
      return true
    }
    i = i + 1
  }
  return false
}

func rangesOverlap(aStart: in Long, aEnd: in Long, bStart: in Long, bEnd: in Long): Bool {
  return aStart <= bEnd and bStart <= aEnd
}

/// An earlier observation this candidate restates: same kind family and item,
/// and either the same wording or an overlapping range with similar wording.
pub func findDuplicate(c: in Candidate, start: in Long, finish: in Long, observed: in slice[LedgerEntry]): String {
  var i = 0
  while i < observed.length.toInt() {
    val o = observed[i]
    if o.source == "observed" and kindFamily(o.kind) == kindFamily(c.kind) and o.itemId == c.itemId {
      val sim = similarityPct(c.summary, o.summary)
      if sim >= 90 {
        return o.id
      }
      val oStart = decimalLong(o.observedFrom)
      val oEnd = decimalLong(o.transcriptSeq)
      if oStart >= 0.toLong() and oEnd >= 0.toLong() and rangesOverlap(start, finish, oStart, oEnd) and sim >= 50 {
        return o.id
      }
    }
    i = i + 1
  }
  return ""
}

/// The verdict on one candidate against the session's current entries
/// (declared and observed, as stored).
pub func reconcile(c: in Candidate, entries: in slice[LedgerEntry], cfg: in ReconcileConfig): Verdict {
  val pct = confidencePct(c.confidence)
  if pct < cfg.minConfidence {
    return Verdict(action = "drop", entryId = "", reason = "confidence " + c.confidence + " is below the threshold")
  }
  val start = decimalLong(c.seqStart)
  val finish = decimalLong(c.seqEnd)
  val dup = findDuplicate(c, start, finish, entries)
  if dup.length.toInt() > 0 {
    return Verdict(action = "duplicate", entryId = dup, reason = "already observed")
  }
  val matched = findDeclaredMatch(c.kind, c.itemId, c.summary, c.files, start, finish, entries, cfg.matchSlack)
  if matched.length.toInt() > 0 {
    return Verdict(action = "matched", entryId = matched, reason = "declared by the agent")
  }
  return Verdict(action = "undeclared", entryId = "", reason = "")
}

/// Whether an undeclared observation should notify the owner rather than wait
/// in the panel: a confident shortcut, or anything the agent can't undo.
pub func shouldNotify(c: in Candidate, cfg: in ReconcileConfig): Bool {
  if confidencePct(c.confidence) < cfg.notifyConfidence {
    return false
  }
  return c.kind == "shortcut" or c.reversible == "false"
}

/// A provisional (mid-run) undeclared observation that a declared entry now
/// covers, because the agent declared it later in the same run.
pub record RetroMatch {
  pub observedId: String
  pub declaredId: String
}

pub func retroMatches(entries: in slice[LedgerEntry], cfg: in ReconcileConfig): slice[RetroMatch] {
  var acc: slice[RetroMatch] = []
  var i = 0
  while i < entries.length.toInt() {
    val o = entries[i]
    if o.source == "observed" and o.undeclared == "true" and o.provisional == "true" {
      val start = decimalLong(o.observedFrom)
      val finish = decimalLong(o.transcriptSeq)
      val m = findDeclaredMatch(o.kind, o.itemId, o.summary, o.files, start, finish, entries, cfg.matchSlack)
      if m.length.toInt() > 0 {
        acc = acc.append(RetroMatch(observedId = o.id, declaredId = m))
      }
    }
    i = i + 1
  }
  return acc
}
