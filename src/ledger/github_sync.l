//! CloudAgents.Ledger.GitHubSync — the pure rules of GitHub reconciliation
//! (docs/session-ledger.md §9, Phase 3): which `agent:*` label an item's
//! issue should carry, how its structured blocker comment reads, and which
//! GitHub-side changes move an item. No I/O: the sync service
//! (CloudAgents.Ledger.Sync) feeds it facts read through a GitHubPort and
//! applies what it decides.
package CloudAgents.Ledger.GitHubSync

import Std.Core
import CloudAgents.Ledger.Model

// ── Labels ────────────────────────────────────────────────────────────────────
/// The `agent:*` label for an item state ("" for skipped: a skipped item's
/// issue carries no agent label).
pub func labelForState(state: in String): String {
  if state == "queued" {
    return "agent:queued"
  }
  if state == "in_progress" {
    return "agent:in-progress"
  }
  if state == "pr_open" {
    return "agent:pr-open"
  }
  if state == "blocked" {
    return "agent:blocked"
  }
  if state == "needs_human" {
    return "agent:needs-human"
  }
  if state == "done" {
    return "agent:done"
  }
  return ""
}

/// Every label the ledger manages.
pub func agentLabels(): slice[String] {
  return ["agent:queued", "agent:in-progress", "agent:pr-open", "agent:blocked", "agent:needs-human", "agent:done"]
}

/// Colour (hex, no '#') and description for creating a managed label.
pub func labelColor(label: in String): String {
  if label == "agent:blocked" {
    return "d73a4a"
  }
  if label == "agent:needs-human" {
    return "e99695"
  }
  if label == "agent:done" {
    return "0e8a16"
  }
  if label == "agent:pr-open" {
    return "5319e7"
  }
  if label == "agent:in-progress" {
    return "1d76db"
  }
  return "c5def5"
}

pub func labelDescription(label: in String): String {
  return "Session ledger: the agent's state for this issue (" + label.substring(6, label.length.toInt() - 6) + ")"
}

/// Labels to add and remove so an issue carries exactly the label for
/// `state` among the managed ones; other labels are never touched.
pub record LabelPlan {
  pub add: slice[String]
  pub remove: slice[String]
}

pub func planLabels(current: in slice[String], state: in String): LabelPlan {
  val want = labelForState(state)
  var add: slice[String] = []
  var remove: slice[String] = []
  if want.length.toInt() > 0 and not containsString(current, want) {
    add = add.append(want)
  }
  val managed = agentLabels()
  var i = 0
  while i < current.length.toInt() {
    if containsString(managed, current[i]) and current[i] != want and not containsString(remove, current[i]) {
      remove = remove.append(current[i])
    }
    i = i + 1
  }
  return LabelPlan(add = add, remove = remove)
}

// ── Refs ──────────────────────────────────────────────────────────────────────
/// A GitHub issue or pull request: "owner/repo" and its number.
pub record IssueRef {
  pub ownerRepo: String
  pub number: String
}

/// The issue a `gh:owner/repo#N` item id names; None for any other ref.
pub func issueRefOf(itemId: in String): Option[IssueRef] {
  if not itemId.startsWith("gh:") or not isCanonicalItemRef(itemId) {
    return None
  }
  val rest = itemId.substring(3, itemId.length.toInt() - 3)
  val parts = splitOn(rest, "#")
  if parts.length.toInt() != 2 {
    return None
  }
  return Some(value = IssueRef(ownerRepo = parts[0], number = parts[1]))
}

/// The pull request a `https://github.com/owner/repo/pull/N` URL names.
pub func pullRefOf(prUrl: in String): Option[IssueRef] {
  val prefix = "https://github.com/"
  if not prUrl.startsWith(prefix) {
    return None
  }
  val parts = splitOn(prUrl.substring(prefix.length.toInt(), prUrl.length.toInt() - prefix.length.toInt()), "/")
  if parts.length.toInt() < 4 or parts[2] != "pull" or parts[3].length.toInt() == 0 or not allDecimal(parts[3]) {
    return None
  }
  val candidate = "gh:" + parts[0] + "/" + parts[1] + "#" + parts[3]
  if not isCanonicalItemRef(candidate) {
    return None
  }
  return Some(value = IssueRef(ownerRepo = asciiLower(parts[0] + "/" + parts[1]), number = parts[3]))
}

func allDecimal(s: in String): Bool {
  var i = 0
  while i < s.length.toInt() {
    if not "0123456789".contains(s.substring(i, 1)) {
      return false
    }
    i = i + 1
  }
  return true
}

// ── Blocker comment ───────────────────────────────────────────────────────────
/// The hidden marker that identifies the ledger's one comment per item, so
/// it is found and edited in place rather than posted again.
pub func commentMarker(sessionId: in String, itemId: in String): String {
  return "<!-- agent-ledger:session=" + sessionId + ";item=" + itemId + " -->"
}

/// The structured comment for a blocked / needs_human item.
pub func blockerComment(sessionId: in String, item: in WorkItem): String {
  var label = "**Blocked:** "
  if item.state == "needs_human" {
    label = "**Needs a human:** "
  }
  var body = commentMarker(sessionId, item.id) + "\n" + label + oneLine(item.blockedReason)
  if item.blockedBy.length.toInt() > 0 {
    body = body + "\n**Blocked by:** " + refsForGitHub(item.blockedBy, item.id)
  }
  if item.prerequisiteProposal.length.toInt() > 0 {
    body = body + "\n**Proposed prerequisite work:** " + item.prerequisiteProposal
  }
  if item.recommendation.length.toInt() > 0 {
    body = body + "\n**Agent recommendation:** " + item.recommendation
  }
  return body + "\n\n_Recorded by the agent's session ledger; edited in place as the item changes._"
}

/// The same comment once the item is no longer stuck.
pub func resolvedComment(sessionId: in String, item: in WorkItem): String {
  return commentMarker(sessionId, item.id) + "\n**Resolved:** no longer blocked (now " + stateWords(item.state) +
    ").\n\n_Recorded by the agent's session ledger._"
}

func stateWords(state: in String): String {
  if state == "in_progress" {
    return "in progress"
  }
  if state == "pr_open" {
    return "PR open"
  }
  return state
}

func oneLine(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length.toInt() {
    val c = s.substring(i, 1)
    if c == "\n" or c == "\r" {
      acc = acc + " "
    } else {
      acc = acc + c
    }
    i = i + 1
  }
  return acc
}

// "#12" for an issue in the same repo as `itemId`, "owner/repo#12" for
// another repo, the slug for a local ref.
func refsForGitHub(refs: in slice[String], itemId: in String): String {
  val own = match issueRefOf(itemId) { case Some(r) -> r.ownerRepo; case _ -> "" }
  var acc = ""
  var i = 0
  while i < refs.length.toInt() {
    if i > 0 {
      acc = acc + ", "
    }
    acc = acc + githubRef(refs[i], own)
    i = i + 1
  }
  return acc
}

func githubRef(ref: in String, ownRepo: in String): String {
  match issueRefOf(ref) {
    case Some(r) -> {
      if r.ownerRepo == ownRepo {
        return "#" + r.number
      }
      return r.ownerRepo + "#" + r.number
    }
    case _ -> {
      if ref.startsWith("local:") {
        return ref.substring(6, ref.length.toInt() - 6) + " (not a GitHub issue)"
      }
      return ref
    }
  }
}

// ── Inbound ───────────────────────────────────────────────────────────────────
/// What GitHub says about an item's own issue.
pub record IssueFacts {
  pub state: String
  pub labels: slice[String]
}

/// A change GitHub asks of an item: `to` "" means none.
pub record InboundChange {
  pub to: String
  pub actor: String
  pub reason: String
}

pub func noChange(): InboundChange {
  return InboundChange(to = "", actor = "", reason = "")
}

/// Whether every blocker of a blocked item is resolved: an in-batch item
/// that is done, or a GitHub issue that is closed. A local ref resolves only
/// through its in-batch item; an item with no blockedBy (prerequisite work
/// only) is never auto-unblocked.
pub func blockersResolved(
  blockedBy: in slice[String], items: in slice[WorkItem], closedOnGitHub: in slice[String]
): Bool {
  if blockedBy.length.toInt() == 0 {
    return false
  }
  var i = 0
  while i < blockedBy.length.toInt() {
    val ref = blockedBy[i]
    if not (stateIn(ref, items) == "done" or containsString(closedOnGitHub, ref)) {
      return false
    }
    i = i + 1
  }
  return true
}

func stateIn(ref: in String, items: in slice[WorkItem]): String {
  var i = 0
  while i < items.length.toInt() {
    if items[i].id == ref {
      return items[i].state
    }
    i = i + 1
  }
  return ""
}

/// The change GitHub's state asks of `item`, if any.
///   - a pr_open item whose PR merged is done;
///   - a human removing the stuck label the ledger put on the issue (or
///     adding agent:queued) requeues a blocked / needs_human item;
///   - a blocked item whose blockers are all resolved is requeued.
/// `syncedLabel` is the label the ledger last applied: only a label the
/// ledger put there and is now gone counts as a human removing it.
pub func inboundChange(
  item: in WorkItem,
  own: in Option[IssueFacts],
  syncedLabel: in String,
  resolved: in Bool,
  prMerged: in Bool,
): InboundChange {
  if item.state == "pr_open" and prMerged {
    return InboundChange(to = "done", actor = "github-sync", reason = "its pull request was merged on GitHub")
  }
  if item.state == "blocked" or item.state == "needs_human" {
    val stuckLabel = labelForState(item.state)
    match own {
      case Some(facts) -> {
        if syncedLabel == stuckLabel and not containsString(facts.labels, stuckLabel) {
          return InboundChange(to = "queued", actor = "human", reason = stuckLabel + " label removed on GitHub")
        }
        // Only an agent:queued the ledger didn't put there itself: before
        // the outbound pass swaps labels, a just-blocked item's issue still
        // carries the agent:queued the ledger applied earlier.
        if containsString(facts.labels, "agent:queued") and syncedLabel != "agent:queued" {
          return InboundChange(to = "queued", actor = "human", reason = "agent:queued label added on GitHub")
        }
      }
      case _ -> ()
    }
    if item.state == "blocked" and resolved {
      return InboundChange(to = "queued", actor = "github-sync", reason = "every blocker is done or closed on GitHub")
    }
  }
  return noChange()
}
