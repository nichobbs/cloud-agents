//! CloudAgents.Ledger.Summary — progress / attention summaries and the
//! compact agent re-orientation view (docs/session-ledger.md §4, §6).
//!
//! Pure: computed from the session's items and entries as values.
package CloudAgents.Ledger.Summary

import Std.Core
import CloudAgents.Ledger.Model

/// Progress + attention counts for one session. Counts are decimal strings
/// (this codebase's JSON wire convention).
@generate(Json)
pub record LedgerSummary {
  pub sessionId: String
  pub total: String
  pub queued: String
  pub inProgress: String
  pub prOpen: String
  pub done: String
  pub blocked: String
  pub needsHuman: String
  pub skipped: String
  pub pendingReview: String
  pub blockingCount: String
  pub undeclaredCount: String
  pub pendingFeedback: String
  pub lastActivityAt: String
}

/// Whether an entry is in the attention queue: it needs a human's review
/// and nobody has given one yet.
pub func needsAttention(e: in LedgerEntry): Bool {
  return e.reviewState == "pending" and (e.severity == "review" or e.severity == "blocking")
}

func countState(items: in slice[WorkItem], state: in String): Int {
  var n = 0
  var i = 0
  while i < items.length.toInt() {
    if items[i].state == state {
      n = n + 1
    }
    i = i + 1
  }
  return n
}

// The later of two epoch-millisecond decimal strings ("" is earliest).
func laterOf(a: in String, b: in String): String {
  val an = a.length.toInt()
  val bn = b.length.toInt()
  if bn != an {
    if bn > an {
      return b
    }
    return a
  }
  var i = 0
  while i < an {
    val ca = digitValue(a.substring(i, 1))
    val cb = digitValue(b.substring(i, 1))
    if cb != ca {
      if cb > ca {
        return b
      }
      return a
    }
    i = i + 1
  }
  return a
}

func digitValue(c: in String): Int {
  val digits = "0123456789"
  var i = 0
  while i < 10 {
    if digits.substring(i, 1) == c {
      return i
    }
    i = i + 1
  }
  return 0
}

pub func summarize(
  sessionId: in String,
  items: in slice[WorkItem],
  entries: in slice[LedgerEntry],
  pendingFeedback: in Int,
): LedgerSummary {
  var pending = 0
  var blocking = 0
  var undeclared = 0
  var last = ""
  var i = 0
  while i < entries.length.toInt() {
    val e = entries[i]
    if needsAttention(e) {
      pending = pending + 1
      if e.severity == "blocking" {
        blocking = blocking + 1
      }
    }
    if e.undeclared == "true" {
      undeclared = undeclared + 1
    }
    last = laterOf(last, e.createdAt)
    i = i + 1
  }
  var j = 0
  while j < items.length.toInt() {
    last = laterOf(last, items[j].updatedAt)
    j = j + 1
  }
  return LedgerSummary(
    sessionId = sessionId,
    total = toString(items.length.toInt()),
    queued = toString(countState(items, "queued")),
    inProgress = toString(countState(items, "in_progress")),
    prOpen = toString(countState(items, "pr_open")),
    done = toString(countState(items, "done")),
    blocked = toString(countState(items, "blocked")),
    needsHuman = toString(countState(items, "needs_human")),
    skipped = toString(countState(items, "skipped")),
    pendingReview = toString(pending),
    blockingCount = toString(blocking),
    undeclaredCount = toString(undeclared),
    pendingFeedback = toString(pendingFeedback),
    lastActivityAt = last
  )
}

// ── Agent re-orientation view (ledger_get_state) ─────────────────────────────
@generate(Json)
pub record AgentItemView {
  pub id: String
  pub title: String
  pub state: String
  pub blockedBy: slice[String]
  pub blockedReason: String
  pub prUrl: String
}

@generate(Json)
pub record AgentEntryView {
  pub id: String
  pub kind: String
  pub item: String
  pub summary: String
  pub severity: String
  pub review: String
}

/// What ledger_get_state returns: the batch, what is still open for review,
/// recent decisions, and how much feedback is waiting — compact enough to
/// re-orient an agent after context compaction without flooding it.
@generate(Json)
pub record AgentStateView {
  pub items: slice[AgentItemView]
  pub openForReview: slice[AgentEntryView]
  pub recentDecisions: slice[AgentEntryView]
  pub reviewedSinceRecorded: slice[AgentEntryView]
  pub pendingFeedback: String
  pub instruction: String
}

func itemView(w: in WorkItem): AgentItemView {
  return AgentItemView(
    id = w.id,
    title = w.title,
    state = w.state,
    blockedBy = w.blockedBy,
    blockedReason = w.blockedReason,
    prUrl = w.prUrl
  )
}

func entryView(e: in LedgerEntry): AgentEntryView {
  return AgentEntryView(
    id = e.id,
    kind = e.kind,
    item = e.itemId,
    summary = e.summary,
    severity = e.severity,
    review = e.reviewState
  )
}

/// Build the agent view. `entries` are in creation order (oldest first); the
/// view keeps at most 20 open-for-review entries, the 10 most recent
/// decisions / deviations / shortcuts, and the 20 most recent entries a
/// human has already approved / rejected / commented on.
pub func agentState(items: in slice[WorkItem], entries: in slice[LedgerEntry], pendingFeedback: in Int): AgentStateView {
  var itemViews: slice[AgentItemView] = []
  var i = 0
  while i < items.length.toInt() {
    itemViews = itemViews.append(itemView(items[i]))
    i = i + 1
  }
  var open: slice[AgentEntryView] = []
  var decisions: slice[AgentEntryView] = []
  var reviewed: slice[AgentEntryView] = []
  var k = entries.length.toInt() - 1
  while k >= 0 {
    val e = entries[k]
    if needsAttention(e) and open.length.toInt() < 20 {
      open = open.append(entryView(e))
    }
    if (e.kind == "decision" or e.kind == "deviation" or e.kind == "shortcut") and decisions.length.toInt() < 10 {
      decisions = decisions.append(entryView(e))
    }
    val wasReviewed = e.reviewState == "approved" or e.reviewState == "rejected" or e.reviewState == "commented"
    if wasReviewed and reviewed.length.toInt() < 20 {
      reviewed = reviewed.append(entryView(e))
    }
    k = k - 1
  }
  var instruction = "Continue with the next queued item. Record decisions, deviations and blockers as they happen."
  if pendingFeedback > 0 {
    instruction = "Call ledger_check_feedback now: " + toString(pendingFeedback) +
      " feedback item(s) from the human are waiting. Apply them before continuing."
  }
  return AgentStateView(
    items = itemViews,
    openForReview = open,
    recentDecisions = decisions,
    reviewedSinceRecorded = reviewed,
    pendingFeedback = toString(pendingFeedback),
    instruction = instruction
  )
}
