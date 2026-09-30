//! CloudAgents.Ledger.Observer — the host side of an observer pass
//! (docs/session-ledger.md §10). An observer is another agent session; it
//! reads a window of the observed session through `observer_get_window` and
//! answers with `observer_report`. This package builds that window and turns a
//! report into ledger entries: every candidate is validated, then
//! CloudAgents.Ledger.Reconcile decides (deterministically, not the model)
//! whether it is dropped, a duplicate, matched to a declared entry, or stored
//! as an undeclared observation.
//!
//! The cursor only moves when a report is accepted, so a pass that fails or
//! never reports is simply covered by the next one.
package CloudAgents.Ledger.Observer

import Std.Core
import CloudAgents.Pg
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.Capture
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Policy
import CloudAgents.Ledger.Store
import CloudAgents.Ledger.Reconcile
import CloudAgents.Ledger.ObserverWindow
import CloudAgents.Ledger.Service

/// Events and characters one window may carry.
pub val windowMaxEvents: Int = 400

pub val windowMaxChars: Int = 60000

/// The declared and observed entries a window lists, newest last.
pub val windowMaxEntries: Int = 80

/// What `observer_get_window` returns. `final` is "true" when the observed
/// run has ended (its observations are not provisional); `more` is "true"
/// when events remain after `toSeq` for another window; `empty` when there is
/// nothing new to read.
@generate(Json)
pub record ObserverWindowView {
  pub session: String
  pub fromSeq: String
  pub toSeq: String
  pub empty: String
  pub more: String
  pub final: String
  pub transcript: String
  pub workItems: slice[String]
  pub entries: slice[String]
  pub diff: String
}

/// What `observer_report` returns.
@generate(Json)
pub record ObserverReportReply {
  pub undeclared: String
  pub matched: String
  pub duplicates: String
  pub dropped: String
  pub more: String
}

func fail(msg: in String): LedgerFailure {
  return LedgerFailure(status = "invalid", message = msg)
}

func dbFailure(e: in CloudAgents.Sqlite.DbError): LedgerFailure {
  return LedgerFailure(status = "error", message = CloudAgents.Sqlite.dbErrorMessage(e))
}

/// Build the next window after the cursor and remember where it ends, so the
/// report can be checked against it. `final` says the observed run is over;
/// `diff` is the observed workspace diff ("" unless the profile grants it).
pub func buildWindow(
  target: in SessionContext, final: in Bool, diff: in String
): Result[ObserverWindowView, LedgerFailure] {
  val st = match observerState(target.sessionId, target.tenantScope) {
    case Ok(s) -> s
    case Err(e) -> return Err(error = dbFailure(e))
  }
  val events = match CloudAgents.Repository.sessionEventsAfterSeqLimited(target.sessionId, target.tenantScope, st.cursorSeq, windowMaxEvents) {
    case Ok(es) -> es
    case Err(e) -> return Err(error = dbFailure(e))
  }
  val rendered = renderWindow(events, windowMaxChars)
  val more = rendered.events > 0 and eventsAfter(target, rendered.lastSeq)
  val items = match listItems(target.sessionId, target.tenantScope) {
    case Ok(xs) -> xs
    case Err(e) -> return Err(error = dbFailure(e))
  }
  val entries = match listEntries(target.sessionId, target.tenantScope) {
    case Ok(es) -> es
    case Err(e) -> return Err(error = dbFailure(e))
  }
  val next = ObserverState(
    sessionId = st.sessionId,
    observerSessionId = st.observerSessionId,
    cursorSeq = st.cursorSeq,
    windowEnd = rendered.lastSeq,
    pending = st.pending,
    passDay = st.passDay,
    passesToday = st.passesToday,
    lastPassAt = st.lastPassAt,
    configHash = st.configHash,
    lastError = st.lastError
  )
  match saveObserverState(target.tenantScope, next) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = dbFailure(e))
  }
  return Ok(
    value = ObserverWindowView(
      session = target.sessionId,
      fromSeq = rendered.firstSeq,
      toSeq = rendered.lastSeq,
      empty = boolWord(rendered.events == 0),
      more = boolWord(more),
      final = boolWord(final),
      transcript = rendered.text,
      workItems = itemLines(items),
      entries = entryLines(entries),
      diff = diff
    )
  )
}

func eventsAfter(target: in SessionContext, seq: in String): Bool {
  return match CloudAgents.Repository.sessionEventsAfterSeqLimited(target.sessionId, target.tenantScope, seq, 1) {
    case Ok(es) -> es.length.toInt() > 0
    case Err(_) -> false
  }
}

func boolWord(b: in Bool): String {
  if b {
    return "true"
  }
  return "false"
}

func itemLines(items: in slice[WorkItem]): slice[String] {
  var acc: slice[String] = []
  var i = 0
  while i < items.length.toInt() {
    val w = items[i]
    var line = w.id + " [" + w.state + "]"
    if w.title.length.toInt() > 0 {
      line = line + " " + w.title
    }
    acc = acc.append(line)
    i = i + 1
  }
  return acc
}

// The newest entries, oldest first, as one line each so the observer can see
// what is already declared (or already observed) and not report it again.
func entryLines(entries: in slice[LedgerEntry]): slice[String] {
  var acc: slice[String] = []
  var start = entries.length.toInt() - windowMaxEntries
  if start < 0 {
    start = 0
  }
  var i = start
  while i < entries.length.toInt() {
    val e = entries[i]
    if e.source != "system" {
      var line = "[seq " + e.transcriptSeq + "] " + e.kind
      if e.source == "observed" {
        line = line + " (observed)"
      }
      if e.itemId.length.toInt() > 0 {
        line = line + " " + e.itemId
      }
      acc = acc.append(line + ": " + e.summary)
    }
    i = i + 1
  }
  return acc
}

// ── Reports ───────────────────────────────────────────────────────────────────
/// The most notifications one report may raise.
pub val maxNotificationsPerReport: Int = 3

/// The most words of evidence kept (a short quote, not the transcript).
pub val evidenceMaxWords: Int = 30

pub func clipEvidence(s: in String): String {
  var words = 0
  var acc = ""
  var inWord = false
  var i = 0
  while i < s.length.toInt() {
    val c = s.substring(i, 1)
    val space = c == " " or c == "\n" or c == "\r" or c == "\t"
    if space {
      if inWord {
        inWord = false
      }
      if acc.length.toInt() > 0 and not acc.endsWith(" ") {
        acc = acc + " "
      }
    } else {
      if not inWord {
        inWord = true
        words = words + 1
        if words > evidenceMaxWords {
          return acc.trim() + " …"
        }
      }
      acc = acc + c
    }
    i = i + 1
  }
  return acc.trim()
}

/// A candidate's problem ("" when it is acceptable). `low` is the cursor the
/// window starts after and `high` its last seq.
func candidateProblem(c: in Candidate, low: in Long, high: in Long): String {
  if not isObservableKind(c.kind) {
    return "kind must be one of: decision, deviation, shortcut, blocker, question"
  }
  match validateSummary("summary", c.summary) {
    case Err(e) -> return e
    case Ok(_) -> ()
  }
  match validateText("detail", c.detail, 8000) {
    case Err(e) -> return e
    case Ok(_) -> ()
  }
  match validateLines("files", c.files, 100, 500) {
    case Err(e) -> return e
    case Ok(_) -> ()
  }
  match validateTags(c.tags) {
    case Err(e) -> return e
    case Ok(_) -> ()
  }
  match validateReversible(c.reversible) {
    case Err(e) -> return e
    case Ok(_) -> ()
  }
  if confidencePct(c.confidence) < 0 {
    return "confidence must be a number from 0 to 1"
  }
  val s = decimalLong(c.seqStart)
  val t = decimalLong(c.seqEnd)
  if s < 0.toLong() or t < 0.toLong() or s > t {
    return "seqStart and seqEnd must be event seqs with seqStart <= seqEnd"
  }
  if s <= low or t > high {
    return "seqStart..seqEnd must lie inside this window (" + toString(low + 1.toLong()) + ".." + toString(high) + ")"
  }
  return ""
}

func withItem(c: in Candidate, itemId: in String): Candidate {
  return Candidate(
    kind = c.kind,
    summary = c.summary,
    detail = c.detail,
    itemId = itemId,
    seqStart = c.seqStart,
    seqEnd = c.seqEnd,
    tags = c.tags,
    files = c.files,
    reversible = c.reversible,
    confidence = c.confidence,
    evidence = clipEvidence(c.evidence)
  )
}

/// Accept an observer's report on the window it was handed: validate every
/// candidate (any problem rejects the whole report, naming it, so the
/// observer can correct and resend), reconcile each against the ledger, store
/// what is new, then move the cursor past the window. `provisional` marks a
/// mid-run pass.
pub func acceptReport(
  target: in SessionContext,
  candidates: in slice[Candidate],
  provisional: in Bool,
  cfg: in ReconcileConfig,
): Result[ObserverReportReply, LedgerFailure] {
  val st = match observerState(target.sessionId, target.tenantScope) {
    case Ok(s) -> s
    case Err(e) -> return Err(error = dbFailure(e))
  }
  if st.windowEnd.length.toInt() == 0 {
    return Err(error = fail("call observer_get_window before observer_report"))
  }
  var low = decimalLong(st.cursorSeq)
  if st.cursorSeq.length.toInt() == 0 {
    low = -1.toLong()
  }
  val high = decimalLong(st.windowEnd)
  // Validate everything first: a report is accepted whole or not at all.
  var ready: slice[Candidate] = []
  var i = 0
  while i < candidates.length.toInt() {
    val c = candidates[i]
    val problem = candidateProblem(c, low, high)
    if problem.length.toInt() > 0 {
      return Err(error = fail("candidates[" + toString(i) + "]: " + problem))
    }
    var itemId = ""
    if c.itemId.length.toInt() > 0 {
      itemId = match normalizeItemRef(c.itemId, target.ownerRepo) {
        case Ok(r) -> r
        case Err(e) -> return Err(error = fail("candidates[" + toString(i) + "]: " + e))
      }
    }
    ready = ready.append(withItem(c, itemId))
    i = i + 1
  }
  var entries = match listEntries(target.sessionId, target.tenantScope) {
    case Ok(es) -> es
    case Err(e) -> return Err(error = dbFailure(e))
  }
  val rules = rulesFor(target)
  var undeclared = 0
  var notified = 0
  var matched = 0
  var duplicates = 0
  var dropped = 0
  var j = 0
  while j < ready.length.toInt() {
    val c = ready[j]
    val verdict = reconcile(c, entries, cfg)
    if verdict.action == "drop" {
      dropped = dropped + 1
    } else if verdict.action == "duplicate" {
      duplicates = duplicates + 1
    } else {
      val isUndeclared = verdict.action == "undeclared"
      val stored = match insertEntry(target.tenantScope, observedEntry(target, c, verdict, isUndeclared, provisional, rules)) {
        case Ok(e) -> e
        case Err(e) -> return Err(error = dbFailure(e))
      }
      entries = entries.append(stored)
      if isUndeclared {
        undeclared = undeclared + 1
        // Capped per report: every finding is in the ledger either way, and a
        // confused or manipulated observer must not flood the owner.
        if shouldNotify(c, cfg) and notified < maxNotificationsPerReport {
          notify(target, c)
          notified = notified + 1
        }
      } else {
        matched = matched + 1
      }
    }
    j = j + 1
  }
  // A later declaration covers an earlier mid-run observation; and once the
  // run is over nothing observed is provisional any more.
  val retro = retroMatches(entries, cfg)
  var r = 0
  while r < retro.length.toInt() {
    match applyRetroMatch(target.sessionId, target.tenantScope, retro[r].observedId, retro[r].declaredId) {
      case Ok(_) -> ()
      case Err(e) -> return Err(error = dbFailure(e))
    }
    r = r + 1
  }
  if not provisional {
    match settleProvisional(target.sessionId, target.tenantScope) {
      case Ok(_) -> ()
      case Err(e) -> return Err(error = dbFailure(e))
    }
  }
  val advanced = ObserverState(
    sessionId = st.sessionId,
    observerSessionId = st.observerSessionId,
    cursorSeq = st.windowEnd,
    windowEnd = "",
    pending = st.pending,
    passDay = st.passDay,
    passesToday = st.passesToday,
    lastPassAt = st.lastPassAt,
    configHash = st.configHash,
    lastError = ""
  )
  match saveObserverState(target.tenantScope, advanced) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = dbFailure(e))
  }
  val remaining = eventsAfter(target, st.windowEnd)
  return Ok(
    value = ObserverReportReply(
      undeclared = toString(undeclared),
      matched = toString(matched),
      duplicates = toString(duplicates),
      dropped = toString(dropped),
      more = boolWord(remaining)
    )
  )
}

func observedEntry(
  target: in SessionContext,
  c: in Candidate,
  verdict: in Verdict,
  isUndeclared: in Bool,
  provisional: in Bool,
  rules: in slice[PolicyRule],
): LedgerEntry {
  var severity = "info"
  if isUndeclared {
    val facts = EntryFacts(
      kind = c.kind,
      reversible = c.reversible,
      tags = c.tags,
      files = c.files,
      source = "observed",
      undeclared = true
    )
    severity = effectiveSeverity("", facts, rules)
  }
  val none: slice[String] = []
  return LedgerEntry(
    id = "",
    sessionId = target.sessionId,
    itemId = c.itemId,
    kind = c.kind,
    severity = severity,
    declaredSeverity = "",
    summary = c.summary,
    detail = c.detail,
    optionsConsidered = none,
    chosen = "",
    rationale = "",
    recommendation = "",
    proceedingWith = "",
    reversible = c.reversible,
    files = c.files,
    tags = c.tags,
    source = "observed",
    undeclared = boolWord(isUndeclared),
    matchedEntryId = verdict.entryId,
    origin = "",
    supersedes = "",
    transcriptSeq = c.seqEnd,
    reviewState = initialReviewState(severity),
    reviewBy = "",
    reviewAt = "",
    reviewComment = "",
    createdAt = "",
    createdSeq = "",
    updatedSeq = "",
    observedFrom = c.seqStart,
    confidence = c.confidence,
    evidence = c.evidence,
    provisional = boolWord(provisional and isUndeclared)
  )
}

func notify(target: in SessionContext, c: in Candidate): Unit {
  var what = "an undeclared " + c.kind
  if c.reversible == "false" {
    what = what + " that can't easily be undone"
  }
  match CloudAgents.Repository.createNotification(target.sessionId, target.tenantScope, "info", "Observer found " + what + ": " + c.summary) {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: observer notification failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── Triggers ──────────────────────────────────────────────────────────────────
/// The observer settings that apply to `sessionId`, or None when it isn't
/// observed: an observer session, an archived one, or one whose profile has
/// no enabled observer.
pub func observerSettingsForSession(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[ObserverSettings], CloudAgents.Sqlite.DbError] {
  val facts = match sessionRunFacts(sessionId, sc)? { case Some(f) -> f; case _ -> return Ok(value = None) }
  if facts.observesSessionId.length.toInt() > 0 or facts.isArchived == "1" {
    return Ok(value = None)
  }
  match observerSettingsFor(facts.profileId, sc)? {
    case Some(st) -> {
      if st.enabled == "true" {
        return Ok(value = Some(value = st))
      }
      return Ok(value = None)
    }
    case _ -> return Ok(value = None)
  }
}

/// A run of `sessionId` ended (succeeded, failed or cancelled): if it is
/// observed, ask for an end-of-run pass. Best-effort: never fails the run.
pub func onRunFinished(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Unit {
  match observerSettingsForSession(sessionId, sc) {
    case Ok(Some(_)) -> {
      match markObserverPending(sessionId, sc) {
        case Ok(_) -> ()
        case Err(e) -> println(
          "WARNING: queueing the observer for " + sessionId + " failed: " +
            CloudAgents.Sqlite.dbErrorMessage(e)
        )
      }
    }
    case Ok(_) -> ()
    case Err(e) -> println(
      "WARNING: reading the observer settings for " + sessionId + " failed: " +
        CloudAgents.Sqlite.dbErrorMessage(e)
    )
  }
}

/// Called from a running session's poll loop: ask for a mid-run pass once the
/// profile's interval has passed since the last pass (or the run's start).
pub func midRunTick(sessionId: in String, sc: in CloudAgents.Pg.TenantScope, runStartedAt: in String): Unit {
  val settings = match observerSettingsForSession(sessionId, sc) { case Ok(Some(st)) -> st; case _ -> return () }
  val st = match observerState(sessionId, sc) { case Ok(s) -> s; case Err(_) -> return () }
  var since = decimalLong(runStartedAt)
  val last = decimalLong(st.lastPassAt)
  if last > since {
    since = last
  }
  if st.pending != "1" and midRunDue(settings, since, CloudAgents.Repository.nowMillisLong()) {
    match markObserverPending(sessionId, sc) {
      case Ok(_) -> ()
      case Err(e) -> println(
        "WARNING: queueing a mid-run observer pass for " + sessionId + " failed: " +
          CloudAgents.Sqlite.dbErrorMessage(e)
      )
    }
  }
}

/// The message that starts an observer pass. The observer is a long-lived
/// session: this is what it is told each time it is woken.
pub func observerPrompt(final: in Bool): String {
  var stage = "The run you observe is still going; report what you can see so far."
  if final {
    stage = "The run you observe has ended."
  }
  return "You are the ledger observer for another agent's coding session. " + stage +
    "\n\n1. Call observer_get_window. If empty is true, stop." +
    "\n2. Read the transcript. Find what the agent did but did NOT record in its ledger (the window lists what it recorded): " +
    "decisions a reviewer might have made differently; deviations from the task, issue or plan, including changes outside the task's scope; " +
    "shortcuts such as skipping, deleting or weakening tests, lowering coverage thresholds, suppressing warnings or type errors " +
    "(eslint-disable, @ts-ignore, @SuppressWarnings, any casts), broad catch blocks, TODO or FIXME left behind, --no-verify, force pushes, " +
    "new or upgraded dependencies, and approaches abandoned after failures; and blockers it hit." +
    "\n3. Call observer_report once with a candidate for each, citing the [seq N] range and a short quote. Report only what the window shows; " +
    "if unsure, give a lower confidence rather than leaving it out. Send an empty candidates list when there is nothing to report." +
    "\n4. If the reply says more is true, go back to step 1." +
    "\n\nDo not change any files and do not run commands: you only read and report."
}
