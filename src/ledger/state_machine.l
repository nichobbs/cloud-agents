//! CloudAgents.Ledger.StateMachine — work-item transitions
//! (docs/session-ledger.md §4).
//!
//! Pure: every function takes the current state as values and returns a
//! decision; persistence applies it. This is the "business rules live in the
//! core" seam — the store never decides whether a transition is legal.
//!
//! Allowed transitions (spec §7):
//!
//!   from         to                                             actors
//!   queued       in_progress, blocked, skipped, needs_human      agent, human
//!   in_progress  pr_open, done, blocked, needs_human, skipped    agent
//!   pr_open      done, in_progress                              agent, github-sync
//!   blocked      queued, in_progress, skipped                   agent, human, github-sync
//!   needs_human  queued, in_progress, skipped                   human
//!   skipped      queued                                         human
//!   done         in_progress                                    human (reopen)
//!
//! A "transition" to the item's current state is not a transition: it is a
//! field update (recommendation, PR URL, blockers, …) and is always allowed
//! for the agent and the human.
package CloudAgents.Ledger.StateMachine

import Std.Core
import CloudAgents.Ledger.Model

func isOneOf(s: in String, xs: in slice[String]): Bool {
  return containsString(xs, s)
}

/// Whether `actor` may move an item from `from` to `to` (from != to).
pub func transitionAllowed(from: in String, to: in String, actor: in String): Bool {
  if from == "queued" {
    return isOneOf(to, ["in_progress", "blocked", "skipped", "needs_human"]) and isOneOf(actor, ["agent", "human"])
  }
  if from == "in_progress" {
    return isOneOf(to, ["pr_open", "done", "blocked", "needs_human", "skipped"]) and actor == "agent"
  }
  if from == "pr_open" {
    return isOneOf(to, ["done", "in_progress"]) and isOneOf(actor, ["agent", "github-sync"])
  }
  if from == "blocked" {
    return isOneOf(to, ["queued", "in_progress", "skipped"]) and isOneOf(actor, ["agent", "human", "github-sync"])
  }
  if from == "needs_human" {
    return isOneOf(to, ["queued", "in_progress", "skipped"]) and actor == "human"
  }
  if from == "skipped" {
    return to == "queued" and actor == "human"
  }
  if from == "done" {
    return to == "in_progress" and actor == "human"
  }
  return false
}

/// The states `actor` may move an item in state `from` to, for error
/// messages and UI affordances.
pub func allowedTargets(from: in String, actor: in String): slice[String] {
  var acc: slice[String] = []
  val all = allItemStates()
  var i = 0
  while i < all.length.toInt() {
    if all[i] != from and transitionAllowed(from, all[i], actor) {
      acc = acc.append(all[i])
    }
    i = i + 1
  }
  return acc
}

/// A requested status change. Empty strings / empty slices mean "leave the
/// item's current value alone" — except `reason`, which is per-transition.
@generate(Json)
pub record StatusChange {
  pub to: String
  pub reason: String
  pub blockedBy: slice[String]
  pub prerequisiteProposal: String
  pub recommendation: String
  pub prUrl: String
}

/// What applying a StatusChange means. `item` is the updated item (its
/// `updatedAt` / `updatedSeq` are left for the store to stamp).
/// `stateChanged` is false for a same-state field update.
/// `blockerSummary` is non-empty when the move must write an automatic
/// blocking `blocker` entry (a move INTO blocked / needs_human).
/// `resolvesBlockers` is true when the move takes the item OUT of blocked /
/// needs_human, so its automatic blocker entries are resolved.
pub record TransitionPlan {
  pub item: WorkItem
  pub fromState: String
  pub stateChanged: Bool
  pub blockerSummary: String
  pub blockerDetail: String
  pub resolvesBlockers: Bool
}

func isStuckState(s: in String): Bool {
  return s == "blocked" or s == "needs_human"
}

func orElse(value: in String, fallback: in String): String {
  if value.length.toInt() > 0 {
    return value
  }
  return fallback
}

func truncateSummary(s: in String): String {
  val max = maxSummaryChars()
  if s.length.toInt() <= max {
    return s
  }
  return s.substring(0, max - 1) + "…"
}

func joinRefs(xs: in slice[String]): String {
  var acc = ""
  var i = 0
  while i < xs.length.toInt() {
    if i > 0 {
      acc = acc + ", "
    }
    acc = acc + xs[i]
    i = i + 1
  }
  return acc
}

/// Decide a status change for `current` requested by `actor`. `blockedBy`
/// refs must already be normalised (CloudAgents.Ledger.Model.
/// normalizeItemRef). Errors are phrased for the agent to read and correct.
pub func planStatusChange(
  current: in WorkItem, change: in StatusChange, actor: in String
): Result[TransitionPlan, String] {
  if not isValidActor(actor) {
    return Err(error = "unknown actor '" + actor + "'")
  }
  if not isValidItemState(change.to) {
    return Err(error = "state must be one of queued, in_progress, pr_open, done, blocked, needs_human, skipped")
  }
  validateLine("reason", change.reason, 2000)?
  validateText("prerequisiteProposal", change.prerequisiteProposal, 8000)?
  validateText("recommendation", change.recommendation, 8000)?
  validateLine("prUrl", change.prUrl, 500)?
  validateLines("blockedBy", change.blockedBy, 50, 200)?
  var i = 0
  while i < change.blockedBy.length.toInt() {
    if change.blockedBy[i] == current.id {
      return Err(error = "an item cannot be blocked by itself")
    }
    i = i + 1
  }
  val from = current.state
  val stateChanged = from != change.to
  if stateChanged and not transitionAllowed(from, change.to, actor) {
    val targets = allowedTargets(from, actor)
    var hint = "allowed from " + from + " for " + actor + ": " + joinRefs(targets)
    if targets.length.toInt() == 0 {
      hint = "no transitions are available to " + actor + " from " + from
    }
    return Err(error = "cannot move " + current.id + " from " + from + " to " + change.to + " (" + hint + ")")
  }

  val entering = stateChanged and (change.to == "blocked" or change.to == "needs_human")
  // Entering blocked starts a fresh blocker: what the agent says now is the
  // whole story, never a stale edge left from an earlier block. An update
  // while already blocked keeps whatever it does not restate.
  var blockedBy = current.blockedBy
  var proposal = orElse(change.prerequisiteProposal, current.prerequisiteProposal)
  if entering {
    blockedBy = change.blockedBy
    proposal = change.prerequisiteProposal
  } else {
    if change.blockedBy.length.toInt() > 0 {
      blockedBy = change.blockedBy
    }
  }
  val recommendation = orElse(change.recommendation, current.recommendation)
  val prUrl = orElse(change.prUrl, current.prUrl)

  var blockedReason = current.blockedReason
  var blockerSummary = ""
  var blockerDetail = ""
  if change.to == "blocked" or change.to == "needs_human" {
    // Spec §7: a move to blocked needs a reason and at least one of
    // blockedBy / prerequisiteProposal; needs_human needs a reason.
    if stateChanged or change.reason.length.toInt() > 0 {
      if change.reason.trim().length.toInt() == 0 {
        return Err(error = "reason is required when moving an item to " + change.to)
      }
      blockedReason = change.reason
    }
    if change.to == "blocked" and blockedBy.length.toInt() == 0 and proposal.trim().length.toInt() == 0 {
      return Err(
        error = "moving an item to blocked needs blockedBy (the issue refs it waits on) and/or prerequisiteProposal (the work needed first)"
      )
    }
    if stateChanged {
      var label = "Needs human: "
      if change.to == "blocked" {
        label = "Blocked: "
      }
      blockerSummary = truncateSummary(label + current.id + " - " + blockedReason)
      var d = "**Reason:** " + blockedReason
      if blockedBy.length.toInt() > 0 {
        d = d + "\n\n**Blocked by:** " + joinRefs(blockedBy)
      }
      if proposal.length.toInt() > 0 {
        d = d + "\n\n**Proposed prerequisite work:** " + proposal
      }
      blockerDetail = d
    }
  } else {
    if stateChanged {
      // Leaving blocked / needs_human (or never in it): the blocker
      // bookkeeping no longer applies.
      blockedReason = ""
      val none: slice[String] = []
      blockedBy = none
      proposal = ""
    }
  }
  val updated = WorkItem(
    id = current.id,
    sessionId = current.sessionId,
    title = current.title,
    url = current.url,
    state = change.to,
    blockedBy = blockedBy,
    blockedReason = blockedReason,
    prerequisiteProposal = proposal,
    recommendation = recommendation,
    prUrl = prUrl,
    order = current.order,
    createdAt = current.createdAt,
    updatedAt = current.updatedAt,
    updatedSeq = current.updatedSeq
  )
  return Ok(
    value = TransitionPlan(
      item = updated,
      fromState = from,
      stateChanged = stateChanged,
      blockerSummary = blockerSummary,
      blockerDetail = blockerDetail,
      resolvesBlockers = stateChanged and isStuckState(from) and not isStuckState(change.to)
    )
  )
}

/// Ids of `blocked` items whose every `blockedBy` ref is an item in this
/// batch that is now `done` (spec §7's auto-unblock rule). An item with no
/// `blockedBy` (only a prerequisite proposal), or with any ref outside the
/// batch, is never auto-unblocked here: out-of-batch refs need GitHub
/// reconciliation (docs/session-ledger.md §9, a follow-up phase).
pub func unblockCandidates(items: in slice[WorkItem]): slice[String] {
  var acc: slice[String] = []
  var i = 0
  while i < items.length.toInt() {
    val item = items[i]
    if item.state == "blocked" and item.blockedBy.length.toInt() > 0 and allRefsDone(item.blockedBy, items) {
      acc = acc.append(item.id)
    }
    i = i + 1
  }
  return acc
}

func allRefsDone(refs: in slice[String], items: in slice[WorkItem]): Bool {
  var i = 0
  while i < refs.length.toInt() {
    if stateOf(refs[i], items) != "done" {
      return false
    }
    i = i + 1
  }
  return true
}

func stateOf(ref: in String, items: in slice[WorkItem]): String {
  var i = 0
  while i < items.length.toInt() {
    if items[i].id == ref {
      return items[i].state
    }
    i = i + 1
  }
  return ""
}
