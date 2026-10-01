//! CloudAgents.Ledger.Model — the session ledger's domain vocabulary and
//! boundary validation (docs/session-ledger.md §3).
//!
//! Pure and synchronous, with no dependency on storage, HTTP, Docker, or any
//! other cloud-agents package except the equally pure CloudAgents.Text: this
//! package, together with CloudAgents.Ledger.StateMachine /
//! CloudAgents.Ledger.Policy / CloudAgents.Ledger.Summary, is the unit meant
//! to port to Testamur later (docs/session-ledger.md §8).
//!
//! Vocabularies (entry kinds, severities, work-item states, …) are plain
//! strings validated here at every trust boundary rather than Lyric unions:
//! every one of them round-trips through text columns and JSON wire
//! records, the rest of this codebase models status literals the same way,
//! and a bare union case name that collides with an imported one silently
//! emits invalid IL in the current toolchain (see testamur AGENTS.md's
//! `Warn`/`Allow` note). The `isValid*` predicates are the single source of
//! truth for each vocabulary.
package CloudAgents.Ledger.Model

import Std.Core
import CloudAgents.Text

// ── Vocabularies ──────────────────────────────────────────────────────────────
/// decision | deviation | shortcut | blocker | question | note
pub func isValidEntryKind(k: in String): Bool {
  return k == "decision" or k == "deviation" or k == "shortcut" or k == "blocker" or k == "question" or k == "note"
}

/// info | review | blocking
pub func isValidSeverity(s: in String): Bool {
  return s == "info" or s == "review" or s == "blocking"
}

/// Numeric rank used for raise-only comparison; unknown ranks lowest.
pub func severityRank(s: in String): Int {
  if s == "blocking" {
    return 2
  }
  if s == "review" {
    return 1
  }
  return 0
}

/// The more severe of two severities.
pub func maxSeverity(a: in String, b: in String): String {
  if severityRank(b) > severityRank(a) {
    return b
  }
  return a
}

/// declared (the agent reported it), observed (an observer extracted it —
/// reserved for the Phase 4 observer), system (written by the ledger itself,
/// e.g. an auto-unblock note).
pub func isValidEntrySource(s: in String): Bool {
  return s == "declared" or s == "observed" or s == "system"
}

/// pending | approved | rejected | commented | not_required | resolved.
/// `resolved` is this implementation's addition to the spec's set: an
/// automatically created blocker entry is resolved (and leaves the attention
/// queue) once its work item leaves blocked / needs_human.
pub func isValidReviewState(s: in String): Bool {
  return s == "pending" or s == "approved" or s == "rejected" or s == "commented" or s == "not_required" or
    s == "resolved"
}

/// queued | in_progress | pr_open | done | blocked | needs_human | skipped
pub func isValidItemState(s: in String): Bool {
  return s == "queued" or s == "in_progress" or s == "pr_open" or s == "done" or s == "blocked" or s == "needs_human" or
    s == "skipped"
}

/// Every work-item state, in display order.
pub func allItemStates(): slice[String] {
  return ["queued", "in_progress", "pr_open", "done", "blocked", "needs_human", "skipped"]
}

/// agent | human | github-sync
pub func isValidActor(a: in String): Bool {
  return a == "agent" or a == "human" or a == "github-sync"
}

/// approve | reject | comment | directive
pub func isValidFeedbackKind(k: in String): Bool {
  return k == "approve" or k == "reject" or k == "comment" or k == "directive"
}

/// Whether a feedback kind must carry a non-empty body.
pub func feedbackKindRequiresBody(k: in String): Bool {
  return k == "reject" or k == "comment" or k == "directive"
}

/// The review state an entry moves to when a human reviews it with `kind`
/// (approve | reject | comment). "" for any other kind.
pub func reviewStateForKind(kind: in String): String {
  if kind == "approve" {
    return "approved"
  }
  if kind == "reject" {
    return "rejected"
  }
  if kind == "comment" {
    return "commented"
  }
  return ""
}

// ── Limits ────────────────────────────────────────────────────────────────────
//
// Kept as literals in each check rather than cross-package `pub val`s: a
// cross-package constant read can miscompile in the current toolchain
// (lyric-lang#6232 / #6134 — see docs/lyric/gotchas.md).
/// Maximum `summary` length in characters (spec: one line, <= 140 chars).
pub func maxSummaryChars(): Int {
  return 140
}

// ── Domain records ────────────────────────────────────────────────────────────
/// One ledger entry. Every scalar is a string (the store's text form, JSON
/// wire convention of this codebase); `reversible` is "true" / "false" / ""
/// (unstated). `createdSeq` / `updatedSeq` are the session ledger's change
/// cursor (a monotonic per-session counter) at creation / last change.
/// `origin` is "" or "transition" (an entry the state machine created
/// automatically on a move into blocked / needs_human). `undeclared` ("true"
/// / "false") and `matchedEntryId` are the observer's reconciliation result
/// (docs/session-ledger.md §10); declared entries carry "false" / "". An
/// observed entry also carries the captured-event range it rests on
/// (`observedFrom`..`transcriptSeq`), the observer's `confidence` (0..1) and
/// `evidence` (a short quote), and `provisional` "true" while it came from a
/// mid-run pass the agent may yet declare.
@generate(Json)
pub record LedgerEntry {
  pub id: String
  pub sessionId: String
  pub itemId: String
  pub kind: String
  pub severity: String
  pub declaredSeverity: String
  pub summary: String
  pub detail: String
  pub optionsConsidered: slice[String]
  pub chosen: String
  pub rationale: String
  pub recommendation: String
  pub proceedingWith: String
  pub reversible: String
  pub files: slice[String]
  pub tags: slice[String]
  pub source: String
  pub undeclared: String
  pub matchedEntryId: String
  pub origin: String
  pub supersedes: String
  pub transcriptSeq: String
  pub reviewState: String
  pub reviewBy: String
  pub reviewAt: String
  pub reviewComment: String
  pub createdAt: String
  pub createdSeq: String
  pub updatedSeq: String
  pub observedFrom: String
  pub confidence: String
  pub evidence: String
  pub provisional: String
}

/// One work item in a session's batch. `id` is a canonical ref
/// ("gh:owner/repo#123" or "local:<slug>"), unique within the session.
@generate(Json)
pub record WorkItem {
  pub id: String
  pub sessionId: String
  pub title: String
  pub url: String
  pub state: String
  pub blockedBy: slice[String]
  pub blockedReason: String
  pub prerequisiteProposal: String
  pub recommendation: String
  pub prUrl: String
  pub order: String
  pub createdAt: String
  pub updatedAt: String
  pub updatedSeq: String
}

/// One persisted work-item transition.
@generate(Json)
pub record WorkItemTransition {
  pub itemId: String
  pub fromState: String
  pub toState: String
  pub actor: String
  pub reason: String
  pub at: String
}

/// Human → agent feedback. `deliveredVia` is "" (undelivered) or
/// "mcp_poll" (the agent collected it with ledger_check_feedback).
@generate(Json)
pub record Feedback {
  pub id: String
  pub sessionId: String
  pub entryId: String
  pub itemId: String
  pub kind: String
  pub body: String
  pub createdBy: String
  pub createdAt: String
  pub deliveredAt: String
  pub deliveredVia: String
  pub updatedSeq: String
}

// ── Work-item refs ────────────────────────────────────────────────────────────
func isAsciiDigit(c: in String): Bool {
  return c == "0" or c == "1" or c == "2" or c == "3" or c == "4" or c == "5" or c == "6" or c == "7" or c == "8" or
    c == "9"
}

func isAsciiLetter(c: in String): Bool {
  return "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".contains(c)
}

/// [A-Za-z0-9._-]
func isNameChar(c: in String): Bool {
  return isAsciiLetter(c) or isAsciiDigit(c) or c == "." or c == "_" or c == "-"
}

func allNameChars(s: in String): Bool {
  if s.length.toInt() == 0 {
    return false
  }
  var i = 0
  val n = s.length.toInt()
  while i < n {
    if not isNameChar(s.substring(i, 1)) {
      return false
    }
    i = i + 1
  }
  return true
}

func allDigits(s: in String): Bool {
  if s.length.toInt() == 0 {
    return false
  }
  var i = 0
  val n = s.length.toInt()
  while i < n {
    if not isAsciiDigit(s.substring(i, 1)) {
      return false
    }
    i = i + 1
  }
  return true
}

// The index of the first occurrence of `c` in `s`, or -1.
func indexOfChar(s: in String, c: in String): Int {
  var i = 0
  val n = s.length.toInt()
  while i < n {
    if s.substring(i, 1) == c {
      return i
    }
    i = i + 1
  }
  return -1
}

/// Whether `ownerRepo` is exactly "owner/repo" with GitHub-safe name
/// characters on both sides.
pub func isValidOwnerRepo(ownerRepo: in String): Bool {
  val slash = indexOfChar(ownerRepo, "/")
  if slash <= 0 {
    return false
  }
  val n = ownerRepo.length.toInt()
  val owner = ownerRepo.substring(0, slash)
  val repo = ownerRepo.substring(slash + 1, n - slash - 1)
  return owner.length.toInt() <= 100 and repo.length.toInt() <= 100 and allNameChars(owner) and allNameChars(repo)
}

/// Whether `ref` is a canonical work-item ref:
///   gh:<owner>/<repo>#<number>   a GitHub issue or PR
///   local:<slug>                 work not tracked anywhere else (slug is
///                                1-64 of [A-Za-z0-9._-])
pub func isCanonicalItemRef(ref: in String): Bool {
  if ref.startsWith("local:") {
    val slug = ref.substring(6, ref.length.toInt() - 6)
    return slug.length.toInt() <= 64 and allNameChars(slug)
  }
  if ref.startsWith("gh:") {
    val rest = ref.substring(3, ref.length.toInt() - 3)
    val hash = indexOfChar(rest, "#")
    if hash <= 0 {
      return false
    }
    val num = rest.substring(hash + 1, rest.length.toInt() - hash - 1)
    return isValidOwnerRepo(rest.substring(0, hash)) and allDigits(num) and num.length.toInt() <= 10
  }
  return false
}

/// Normalise the forms an agent naturally writes into a canonical ref:
///   "gh:owner/repo#12" / "local:x"  unchanged (if valid)
///   "owner/repo#12"                 -> "gh:owner/repo#12"
///   "#12" or "12"                   -> "gh:<defaultRepo>#12" (needs a
///                                      valid `defaultRepo`, the session's
///                                      own "owner/repo")
///   "https://github.com/owner/repo/issues/12" (or /pull/12)
///                                   -> "gh:owner/repo#12"
/// Anything else is an error naming the accepted forms, which the agent sees
/// verbatim as a tool error and can correct.
pub func normalizeItemRef(raw: in String, defaultRepo: in String): Result[String, String] {
  val parsed = parseItemRef(raw, defaultRepo)?
  return Ok(value = canonicalGhRef(parsed))
}

// GitHub owner/repo names are case-insensitive and "#012" is issue 12, so a
// gh: ref is folded to one spelling: owner/repo lowercased, the number
// without leading zeros. Without this the same issue written two ways would
// be two items, and a blockedBy edge on one would never auto-unblock.
func canonicalGhRef(ref: in String): String {
  if not ref.startsWith("gh:") {
    return ref
  }
  val rest = ref.substring(3, ref.length.toInt() - 3)
  val hash = indexOfChar(rest, "#")
  if hash < 0 {
    return ref
  }
  val num = rest.substring(hash + 1, rest.length.toInt() - hash - 1)
  return "gh:" + asciiLower(rest.substring(0, hash)) + "#" + stripLeadingZeros(num)
}

/// ASCII-only lowercase (owner/repo names are ASCII by construction).
pub func asciiLower(s: in String): String {
  val upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  val lower = "abcdefghijklmnopqrstuvwxyz"
  var acc = ""
  var i = 0
  while i < s.length.toInt() {
    val c = s.substring(i, 1)
    val at = indexOfChar(upper, c)
    if at >= 0 {
      acc = acc + lower.substring(at, 1)
    } else {
      acc = acc + c
    }
    i = i + 1
  }
  return acc
}

func stripLeadingZeros(num: in String): String {
  var i = 0
  while i < num.length.toInt() - 1 and num.substring(i, 1) == "0" {
    i = i + 1
  }
  return num.substring(i, num.length.toInt() - i)
}

func parseItemRef(raw: in String, defaultRepo: in String): Result[String, String] {
  val r = raw.trim()
  if r.length.toInt() == 0 {
    return Err(error = "item ref is empty")
  }
  if isCanonicalItemRef(r) {
    return Ok(value = r)
  }
  if r.startsWith("#") or allDigits(r) {
    val num = if r.startsWith("#") then r.substring(1, r.length.toInt() - 1) else r
    if not allDigits(num) {
      return Err(error = invalidRefMessage(raw))
    }
    if not isValidOwnerRepo(defaultRepo) {
      return Err(
        error = "item ref '" + raw +
          "' needs an owner/repo (this session has no GitHub repo); use gh:owner/repo#N or local:<slug>"
      )
    }
    return Ok(value = "gh:" + defaultRepo + "#" + num)
  }
  val ghPrefix = "https://github.com/"
  if r.startsWith(ghPrefix) {
    val rest = r.substring(ghPrefix.length.toInt(), r.length.toInt() - ghPrefix.length.toInt())
    val parts = splitOn(rest, "/")
    if parts.length.toInt() >= 4 and (parts[2] == "issues" or parts[2] == "pull") and allDigits(parts[3]) {
      val candidate = "gh:" + parts[0] + "/" + parts[1] + "#" + parts[3]
      if isCanonicalItemRef(candidate) {
        return Ok(value = candidate)
      }
    }
    return Err(error = invalidRefMessage(raw))
  }
  val candidate = "gh:" + r
  if isCanonicalItemRef(candidate) {
    return Ok(value = candidate)
  }
  return Err(error = invalidRefMessage(raw))
}

func invalidRefMessage(raw: in String): String {
  return "invalid item ref '" + raw +
    "': use gh:owner/repo#N, owner/repo#N, #N (this session's repo), a GitHub issue/PR URL, or local:<slug> (1-64 of A-Z a-z 0-9 . _ -)"
}

/// Split `s` on single-character separator `sep` (no trimming, empties kept).
pub func splitOn(s: in String, sep: in String): slice[String] {
  var parts: slice[String] = []
  var start = 0
  var i = 0
  val n = s.length.toInt()
  while i < n {
    if s.substring(i, 1) == sep {
      parts = parts.append(s.substring(start, i - start))
      start = i + 1
    }
    i = i + 1
  }
  parts = parts.append(s.substring(start, n - start))
  return parts
}

/// The GitHub issue/PR URL for a gh: ref, or "" for any other ref.
pub func urlForItemRef(ref: in String): String {
  if not ref.startsWith("gh:") or not isCanonicalItemRef(ref) {
    return ""
  }
  val rest = ref.substring(3, ref.length.toInt() - 3)
  val hash = indexOfChar(rest, "#")
  return "https://github.com/" + rest.substring(0, hash) + "/issues/" +
    rest.substring(hash + 1, rest.length.toInt() - hash - 1)
}

/// The session's own "owner/repo" from its repo URL
/// ("https://github.com/owner/repo(.git)"), or "" when it isn't a GitHub
/// repo URL.
pub func ownerRepoOfRepoUrl(repoUrl: in String): String {
  val prefix = "https://github.com/"
  if not repoUrl.startsWith(prefix) {
    return ""
  }
  var rest = repoUrl.substring(prefix.length.toInt(), repoUrl.length.toInt() - prefix.length.toInt())
  if rest.endsWith("/") {
    rest = rest.substring(0, rest.length.toInt() - 1)
  }
  if rest.endsWith(".git") {
    rest = rest.substring(0, rest.length.toInt() - 4)
  }
  if isValidOwnerRepo(rest) {
    return asciiLower(rest)
  }
  return ""
}

// ── Field validation ──────────────────────────────────────────────────────────
/// A required one-line summary: non-empty after trimming, <= 140 characters,
/// no control characters (which also excludes newlines).
pub func validateSummary(field: in String, s: in String): Result[Unit, String] {
  if s.trim().length.toInt() == 0 {
    return Err(error = field + " is required")
  }
  if s.length.toInt() > maxSummaryChars() {
    return Err(
      error = field + " must be at most 140 characters (got " + toString(s.length.toInt()) +
        "); put detail in 'detail'"
    )
  }
  if CloudAgents.Text.containsControlChar(s) {
    return Err(error = field + " must be a single line")
  }
  return Ok(())
}

/// An optional free-text field bounded to `maxBytes` UTF-8 bytes.
pub func validateText(field: in String, s: in String, maxBytes: in Int): Result[Unit, String] {
  if not CloudAgents.Text.withinMaxByteLength(s, maxBytes) {
    return Err(error = field + " is too long (max " + toString(maxBytes) + " bytes)")
  }
  return Ok(())
}

/// An optional single-line field (<= `maxChars`, no control characters).
pub func validateLine(field: in String, s: in String, maxChars: in Int): Result[Unit, String] {
  if s.length.toInt() > maxChars {
    return Err(error = field + " is too long (max " + toString(maxChars) + " characters)")
  }
  if CloudAgents.Text.containsControlChar(s) {
    return Err(error = field + " must be a single line")
  }
  return Ok(())
}

/// An optional link the PWA renders as a clickable href: "" or an absolute
/// http(s) URL. Anything else (javascript:, data:, relative) is rejected so
/// agent-supplied text can never become a script URL in the owner's browser.
pub func validateLink(field: in String, s: in String): Result[Unit, String] {
  validateLine(field, s, 500)?
  if s.length.toInt() == 0 {
    return Ok(())
  }
  val lowered = asciiLower(s)
  if lowered.startsWith("https://") or lowered.startsWith("http://") {
    if s.contains(" ") {
      return Err(error = field + " must not contain spaces")
    }
    return Ok(())
  }
  return Err(error = field + " must be an http(s) URL")
}

/// A list of single-line strings: at most `maxItems`, each <= `maxChars`.
pub func validateLines(field: in String, xs: in slice[String], maxItems: in Int, maxChars: in Int): Result[Unit, String] {
  if xs.length.toInt() > maxItems {
    return Err(error = field + " has too many entries (max " + toString(maxItems) + ")")
  }
  var i = 0
  while i < xs.length.toInt() {
    validateLine(field + " entry", xs[i], maxChars)?
    i = i + 1
  }
  return Ok(())
}

/// Tags: at most 10, each 1-32 of [a-z0-9-].
pub func validateTags(tags: in slice[String]): Result[Unit, String] {
  if tags.length.toInt() > 10 {
    return Err(error = "tags has too many entries (max 10)")
  }
  var i = 0
  while i < tags.length.toInt() {
    val t = tags[i]
    if t.length.toInt() == 0 or t.length.toInt() > 32 or not isTagChars(t) {
      return Err(
        error = "invalid tag '" + t +
          "': use 1-32 of a-z 0-9 - (e.g. tests, deps, schema, security, api-change, migration)"
      )
    }
    i = i + 1
  }
  return Ok(())
}

/// Whether `t` is a valid entry tag: 1-32 of a-z 0-9 -.
pub func isValidTag(t: in String): Bool {
  return t.length.toInt() > 0 and t.length.toInt() <= 32 and isTagChars(t)
}

func isTagChars(t: in String): Bool {
  var i = 0
  val n = t.length.toInt()
  while i < n {
    val c = t.substring(i, 1)
    if not ("abcdefghijklmnopqrstuvwxyz".contains(c) or isAsciiDigit(c) or c == "-") {
      return false
    }
    i = i + 1
  }
  return true
}

/// "true" / "false" / "" only.
pub func validateReversible(r: in String): Result[Unit, String] {
  if r == "true" or r == "false" or r == "" {
    return Ok(())
  }
  return Err(error = "reversible must be true or false")
}

/// Validate a severity the agent proposed ("" = none proposed).
pub func validateDeclaredSeverity(s: in String): Result[Unit, String] {
  if s == "" or isValidSeverity(s) {
    return Ok(())
  }
  return Err(error = "severity must be one of info, review, blocking")
}

/// A feedback / review body: required for reject / comment / directive,
/// bounded to 8000 bytes.
pub func validateFeedback(kind: in String, body: in String): Result[Unit, String] {
  if not isValidFeedbackKind(kind) {
    return Err(error = "kind must be one of approve, reject, comment, directive")
  }
  if feedbackKindRequiresBody(kind) and body.trim().length.toInt() == 0 {
    return Err(error = "body is required for " + kind)
  }
  return validateText("body", body, 8000)
}

/// Whether `xs` contains `x`.
pub func containsString(xs: in slice[String], x: in String): Bool {
  var i = 0
  while i < xs.length.toInt() {
    if xs[i] == x {
      return true
    }
    i = i + 1
  }
  return false
}
