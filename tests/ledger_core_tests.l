//! Offline tests for the pure session-ledger core (docs/session-ledger.md):
//! CloudAgents.Ledger.Model / StateMachine / Policy / Summary. No DB, no
//! network, no clock.
@test_module
package CloudAgents.LedgerCoreTests

import Std.Core
import Std.Testing
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.StateMachine
import CloudAgents.Ledger.Policy
import CloudAgents.Ledger.Summary

func item(id: in String, state: in String, blockedBy: in slice[String]): WorkItem {
  return itemWithReason(id, state, blockedBy, "")
}

func itemWithReason(id: in String, state: in String, blockedBy: in slice[String], reason: in String): WorkItem {
  return WorkItem(
    id = id,
    sessionId = "s1",
    title = "",
    url = "",
    state = state,
    blockedBy = blockedBy,
    blockedReason = reason,
    prerequisiteProposal = "",
    recommendation = "",
    prUrl = "",
    order = "0",
    createdAt = "1000",
    updatedAt = "1000",
    updatedSeq = "1"
  )
}

func noRefs(): slice[String] {
  val none: slice[String] = []
  return none
}

func change(to: in String, reason: in String, blockedBy: in slice[String], proposal: in String): StatusChange {
  return StatusChange(
    to = to,
    reason = reason,
    blockedBy = blockedBy,
    prerequisiteProposal = proposal,
    recommendation = "",
    prUrl = ""
  )
}

func entry(kind: in String, severity: in String, review: in String, createdAt: in String): LedgerEntry {
  return LedgerEntry(
    id = "e-" + kind + createdAt,
    sessionId = "s1",
    itemId = "",
    kind = kind,
    severity = severity,
    declaredSeverity = "",
    summary = kind,
    detail = "",
    optionsConsidered = noRefs(),
    chosen = "",
    rationale = "",
    recommendation = "",
    proceedingWith = "",
    reversible = "",
    files = noRefs(),
    tags = noRefs(),
    source = "declared",
    undeclared = "false",
    matchedEntryId = "",
    origin = "",
    supersedes = "",
    transcriptSeq = "",
    reviewState = review,
    reviewBy = "",
    reviewAt = "",
    reviewComment = "",
    createdAt = createdAt,
    createdSeq = "1",
    updatedSeq = "1"
  )
}

func facts(kind: in String, reversible: in String, tags: in slice[String], files: in slice[String]): EntryFacts {
  return EntryFacts(
    kind = kind,
    reversible = reversible,
    tags = tags,
    files = files,
    source = "declared",
    undeclared = false
  )
}

// ── State machine: every row of the spec §7 table ─────────────────────────────
func expectAllowed(from: in String, to: in String, actor: in String): Unit {
  assertTrue(transitionAllowed(from, to, actor), from + " -> " + to + " should be allowed for " + actor)
}

func expectDenied(from: in String, to: in String, actor: in String): Unit {
  assertTrue(not transitionAllowed(from, to, actor), from + " -> " + to + " should be denied for " + actor)
}

test "queued row: agent and human may start, block, skip or escalate" {
  val targets: slice[String] = ["in_progress", "blocked", "skipped", "needs_human"]
  var i = 0
  while i < targets.length.toInt() {
    expectAllowed("queued", targets[i], "agent")
    expectAllowed("queued", targets[i], "human")
    expectDenied("queued", targets[i], "github-sync")
    i = i + 1
  }
  expectDenied("queued", "done", "agent")
  expectDenied("queued", "pr_open", "agent")
}

test "in_progress row: agent only" {
  val targets: slice[String] = ["pr_open", "done", "blocked", "needs_human", "skipped"]
  var i = 0
  while i < targets.length.toInt() {
    expectAllowed("in_progress", targets[i], "agent")
    expectDenied("in_progress", targets[i], "human")
    expectDenied("in_progress", targets[i], "github-sync")
    i = i + 1
  }
  expectDenied("in_progress", "queued", "agent")
}

test "pr_open row: agent and github-sync" {
  expectAllowed("pr_open", "done", "agent")
  expectAllowed("pr_open", "in_progress", "agent")
  expectAllowed("pr_open", "done", "github-sync")
  expectAllowed("pr_open", "in_progress", "github-sync")
  expectDenied("pr_open", "done", "human")
  expectDenied("pr_open", "blocked", "agent")
}

test "blocked row: agent, human and github-sync" {
  val targets: slice[String] = ["queued", "in_progress", "skipped"]
  var i = 0
  while i < targets.length.toInt() {
    expectAllowed("blocked", targets[i], "agent")
    expectAllowed("blocked", targets[i], "human")
    expectAllowed("blocked", targets[i], "github-sync")
    i = i + 1
  }
  expectDenied("blocked", "done", "agent")
  expectDenied("blocked", "needs_human", "agent")
}

test "needs_human row: human only" {
  val targets: slice[String] = ["queued", "in_progress", "skipped"]
  var i = 0
  while i < targets.length.toInt() {
    expectAllowed("needs_human", targets[i], "human")
    expectDenied("needs_human", targets[i], "agent")
    expectDenied("needs_human", targets[i], "github-sync")
    i = i + 1
  }
}

test "skipped row: human requeue only" {
  expectAllowed("skipped", "queued", "human")
  expectDenied("skipped", "queued", "agent")
  expectDenied("skipped", "in_progress", "human")
}

test "done row: human reopen only" {
  expectAllowed("done", "in_progress", "human")
  expectDenied("done", "in_progress", "agent")
  expectDenied("done", "queued", "human")
}

test "an invalid transition is a readable error naming the allowed targets" {
  match planStatusChange(item("gh:a/b#1", "queued", noRefs()), change("done", "", noRefs(), ""), "agent") {
    case Ok(_) -> assertTrue(false, "queued -> done must be rejected")
    case Err(msg) -> {
      assertTrue(msg.contains("cannot move gh:a/b#1 from queued to done"), "names the move: " + msg)
      assertTrue(msg.contains("in_progress"), "lists an allowed target: " + msg)
    }
  }
}

test "a same-state update is a field update, not a transition" {
  val c = StatusChange(
    to = "in_progress",
    reason = "",
    blockedBy = noRefs(),
    prerequisiteProposal = "",
    recommendation = "merge after #3",
    prUrl = ""
  )
  match planStatusChange(item("gh:a/b#1", "in_progress", noRefs()), c, "agent") {
    case Ok(p) -> {
      assertTrue(not p.stateChanged, "same state is not a transition")
      assertEqual(p.item.recommendation, "merge after #3", "field updated")
      assertEqual(p.blockerSummary, "", "no blocker entry")
    }
    case Err(msg) -> assertTrue(false, "unexpected error: " + msg)
  }
}

test "blocked requires a reason" {
  match planStatusChange(item("gh:a/b#1", "in_progress", noRefs()), change("blocked", "", ["gh:a/b#2"], ""), "agent") {
    case Ok(_) -> assertTrue(false, "must require a reason")
    case Err(msg) -> assertTrue(msg.contains("reason is required"), msg)
  }
}

test "blocked requires blockedBy or a prerequisite proposal" {
  match planStatusChange(item("gh:a/b#1", "in_progress", noRefs()), change("blocked", "waiting", noRefs(), ""), "agent") {
    case Ok(_) -> assertTrue(false, "must require blockedBy or prerequisiteProposal")
    case Err(msg) -> assertTrue(msg.contains("blockedBy"), msg)
  }
  match planStatusChange(item("gh:a/b#1", "in_progress", noRefs()), change("blocked", "waiting", noRefs(), "add the auth module first"), "agent") {
    case Ok(p) -> assertTrue(p.stateChanged, "a proposal alone is enough")
    case Err(msg) -> assertTrue(false, "unexpected error: " + msg)
  }
}

test "moving to blocked plans a blocking blocker entry" {
  match planStatusChange(item("gh:a/b#1", "in_progress", noRefs()), change("blocked", "needs the schema from #2", ["gh:a/b#2"], ""), "agent") {
    case Ok(p) -> {
      assertEqual(p.item.state, "blocked", "state")
      assertEqual(p.item.blockedReason, "needs the schema from #2", "reason kept")
      assertTrue(p.blockerSummary.startsWith("Blocked: gh:a/b#1"), "blocker summary: " + p.blockerSummary)
      assertTrue(p.blockerDetail.contains("gh:a/b#2"), "detail names the blocker")
      assertTrue(p.blockerSummary.length.toInt() <= 140, "summary fits the limit")
    }
    case Err(msg) -> assertTrue(false, "unexpected error: " + msg)
  }
}

test "needs_human requires a reason and plans a blocker entry" {
  match planStatusChange(item("gh:a/b#1", "queued", noRefs()), change("needs_human", "", noRefs(), ""), "agent") {
    case Ok(_) -> assertTrue(false, "needs a reason")
    case Err(msg) -> assertTrue(msg.contains("reason is required"), msg)
  }
  match planStatusChange(item("gh:a/b#1", "queued", noRefs()), change("needs_human", "which API version?", noRefs(), ""), "agent") {
    case Ok(p) -> assertTrue(p.blockerSummary.startsWith("Needs human:"), p.blockerSummary)
    case Err(msg) -> assertTrue(false, "unexpected error: " + msg)
  }
}

test "leaving blocked resolves blockers and clears the reason" {
  val blocked = itemWithReason("gh:a/b#1", "blocked", ["gh:a/b#2"], "waiting")
  match planStatusChange(blocked, change("queued", "", noRefs(), ""), "human") {
    case Ok(p) -> {
      assertTrue(p.resolvesBlockers, "resolves")
      assertEqual(p.item.blockedReason, "", "reason cleared")
      assertEqualInt(p.item.blockedBy.length.toInt(), 0, "blockedBy cleared")
    }
    case Err(msg) -> assertTrue(false, "unexpected error: " + msg)
  }
}

test "leaving blocked clears the prerequisite proposal too" {
  match planStatusChange(item("gh:a/b#1", "in_progress", noRefs()), change("blocked", "needs auth", noRefs(), "add the auth module first"), "agent") {
    case Ok(p) -> {
      match planStatusChange(p.item, change("in_progress", "", noRefs(), ""), "agent") {
        case Ok(q) -> assertEqual(q.item.prerequisiteProposal, "", "proposal cleared")
        case Err(msg) -> assertTrue(false, "unexpected error: " + msg)
      }
    }
    case Err(msg) -> assertTrue(false, "unexpected error: " + msg)
  }
}

test "entering blocked takes what the agent says now, not a stale edge" {
  // An item still carrying an old edge (a row written before edges were
  // cleared on leave) is blocked afresh on a proposal alone.
  val stale = item("gh:a/b#1", "in_progress", ["gh:a/b#2"])
  match planStatusChange(stale, change("blocked", "needs auth", noRefs(), "add auth first"), "agent") {
    case Ok(p) -> {
      assertEqualInt(p.item.blockedBy.length.toInt(), 0, "no stale edge")
      assertTrue(not p.blockerDetail.contains("gh:a/b#2"), p.blockerDetail)
    }
    case Err(msg) -> assertTrue(false, "unexpected error: " + msg)
  }
  // An update while already blocked keeps an edge it does not restate.
  val blocked = itemWithReason("gh:a/b#1", "blocked", ["gh:a/b#2"], "waiting")
  match planStatusChange(blocked, change("blocked", "", noRefs(), ""), "agent") {
    case Ok(p) -> assertEqualInt(p.item.blockedBy.length.toInt(), 1, "edge kept")
    case Err(msg) -> assertTrue(false, "unexpected error: " + msg)
  }
}

test "an item cannot block itself" {
  match planStatusChange(item("gh:a/b#1", "in_progress", noRefs()), change("blocked", "x", ["gh:a/b#1"], ""), "agent") {
    case Ok(_) -> assertTrue(false, "self-block must be rejected")
    case Err(msg) -> assertTrue(msg.contains("itself"), msg)
  }
}

test "auto-unblock: all in-batch blockers done" {
  val items: slice[WorkItem] = [
    item("gh:a/b#1", "blocked", ["gh:a/b#2", "gh:a/b#3"]),
    item("gh:a/b#2", "done", noRefs()),
    item("gh:a/b#3", "done", noRefs()),
    item("gh:a/b#4", "blocked", ["gh:a/b#2", "gh:a/b#5"]),
    item("gh:a/b#5", "in_progress", noRefs()),
    item("gh:a/b#6", "blocked", ["gh:other/repo#9"]),
    item("gh:a/b#7", "blocked", noRefs())
  ]
  val ids = unblockCandidates(items)
  assertEqualInt(ids.length.toInt(), 1, "only #1 is unblockable")
  assertEqual(ids[0], "gh:a/b#1", "#1 unblocks")
}

// ── Refs ──────────────────────────────────────────────────────────────────────
func expectRef(raw: in String, expected: in String): Unit {
  match normalizeItemRef(raw, "acme/shop") {
    case Ok(r) -> assertEqual(r, expected, "normalize " + raw)
    case Err(msg) -> assertTrue(false, "unexpected error for " + raw + ": " + msg)
  }
}

test "item refs normalise from the forms agents write" {
  expectRef("gh:acme/shop#412", "gh:acme/shop#412")
  expectRef("acme/shop#412", "gh:acme/shop#412")
  expectRef("#412", "gh:acme/shop#412")
  expectRef("412", "gh:acme/shop#412")
  expectRef("https://github.com/acme/api/issues/7", "gh:acme/api#7")
  expectRef("https://github.com/acme/api/pull/8", "gh:acme/api#8")
  expectRef("local:refactor-auth", "local:refactor-auth")
}

test "malformed refs are rejected with guidance" {
  val bad: slice[String] = ["", "gh:acme#1", "local:", "local:has space", "acme/shop#x", "gh:a/b#1; drop"]
  var i = 0
  while i < bad.length.toInt() {
    match normalizeItemRef(bad[i], "acme/shop") {
      case Ok(r) -> assertTrue(false, "'" + bad[i] + "' should be rejected, got " + r)
      case Err(_) -> ()
    }
    i = i + 1
  }
  match normalizeItemRef("#3", "") {
    case Ok(_) -> assertTrue(false, "#N needs a session repo")
    case Err(msg) -> assertTrue(msg.contains("owner/repo"), msg)
  }
}

test "repo url -> owner/repo and ref -> url" {
  assertEqual(ownerRepoOfRepoUrl("https://github.com/acme/shop.git"), "acme/shop", ".git stripped")
  assertEqual(ownerRepoOfRepoUrl("https://github.com/acme/shop"), "acme/shop", "plain")
  assertEqual(ownerRepoOfRepoUrl("https://gitlab.com/acme/shop"), "", "non-GitHub")
  assertEqual(urlForItemRef("gh:acme/shop#12"), "https://github.com/acme/shop/issues/12", "issue url")
  assertEqual(urlForItemRef("local:x"), "", "no url for local")
}

test "summary validation enforces one line of <= 140 chars" {
  match validateSummary("summary", "") {
    case Ok(_) -> assertTrue(false, "empty rejected")
    case Err(_) -> ()
  }
  var long = ""
  var i = 0
  while i < 141 {
    long = long + "x"
    i = i + 1
  }
  match validateSummary("summary", long) {
    case Ok(_) -> assertTrue(false, "141 chars rejected")
    case Err(msg) -> assertTrue(msg.contains("140"), msg)
  }
  match validateSummary("summary", long.substring(0, 140)) {
    case Ok(_) -> ()
    case Err(msg) -> assertTrue(false, "140 chars accepted: " + msg)
  }
}

test "feedback body is required for reject, comment and directive" {
  val needBody: slice[String] = ["reject", "comment", "directive"]
  var i = 0
  while i < needBody.length.toInt() {
    match validateFeedback(needBody[i], "  ") {
      case Ok(_) -> assertTrue(false, needBody[i] + " without body must be rejected")
      case Err(_) -> ()
    }
    i = i + 1
  }
  match validateFeedback("approve", "") {
    case Ok(_) -> ()
    case Err(msg) -> assertTrue(false, "approve needs no body: " + msg)
  }
  match validateFeedback("veto", "x") {
    case Ok(_) -> assertTrue(false, "unknown kind rejected")
    case Err(_) -> ()
  }
}

// ── Policy ────────────────────────────────────────────────────────────────────
test "policy raises but never lowers" {
  val rules = defaultRules()
  assertEqual(
    effectiveSeverity("", facts("decision", "true", noRefs(), noRefs()), rules),
    "info",
    "plain decision is info"
  )
  assertEqual(
    effectiveSeverity("blocking", facts("decision", "true", noRefs(), noRefs()), rules),
    "blocking",
    "declared blocking is never lowered"
  )
  assertEqual(
    effectiveSeverity("info", facts("shortcut", "true", noRefs(), noRefs()), rules),
    "review",
    "shortcut raised to review"
  )
  assertEqual(
    effectiveSeverity("info", facts("blocker", "", noRefs(), noRefs()), rules),
    "blocking",
    "blocker raised to blocking"
  )
  assertEqual(
    effectiveSeverity("", facts("decision", "false", noRefs(), noRefs()), rules),
    "review",
    "irreversible raised"
  )
  assertEqual(effectiveSeverity("", facts("decision", "", ["deps"], noRefs()), rules), "review", "deps tag raised")
  assertEqual(
    effectiveSeverity("", facts("note", "", noRefs(), ["package-lock.lock"]), rules),
    "review",
    "root lock file raised"
  )
  assertEqual(
    effectiveSeverity("", facts("note", "", noRefs(), ["db/migrations/0036.sql"]), rules),
    "review",
    "migration raised"
  )
  assertEqual(
    effectiveSeverity("", facts("note", "", noRefs(), ["./.github/workflows/ci.yml"]), rules),
    "review",
    "workflow raised"
  )
  assertEqual(effectiveSeverity("", facts("question", "", noRefs(), noRefs()), rules), "review", "question in queue")
  assertEqual(
    effectiveSeverity("", facts("note", "", noRefs(), ["src/app.ts"]), rules),
    "info",
    "ordinary note stays info"
  )
}

test "observed undeclared entries are raised to review" {
  val f = EntryFacts(
    kind = "decision",
    reversible = "",
    tags = noRefs(),
    files = noRefs(),
    source = "observed",
    undeclared = true
  )
  assertEqual(effectiveSeverity("info", f, defaultRules()), "review", "undeclared raised")
  val matched = EntryFacts(
    kind = "decision",
    reversible = "",
    tags = noRefs(),
    files = noRefs(),
    source = "observed",
    undeclared = false
  )
  assertEqual(effectiveSeverity("info", matched, defaultRules()), "info", "matched observation stays info")
}

test "initial review state follows severity" {
  assertEqual(initialReviewState("info"), "not_required", "info")
  assertEqual(initialReviewState("review"), "pending", "review")
  assertEqual(initialReviewState("blocking"), "pending", "blocking")
}

test "glob semantics" {
  assertTrue(globMatch("**/*.lock", "Cargo.lock"), "** matches zero dirs")
  assertTrue(globMatch("**/*.lock", "a/b/yarn.lock"), "** crosses dirs")
  assertTrue(not globMatch("*.lock", "a/yarn.lock"), "* does not cross /")
  assertTrue(globMatch("src/?.l", "src/a.l"), "? one char")
  assertTrue(not globMatch("src/?.l", "src/ab.l"), "? exactly one")
  assertTrue(globMatch(".github/workflows/**", ".github/workflows/ci.yml"), "trailing **")
  assertTrue(not globMatch("docs/*.md", "src/docs/a.md"), "anchored")
  assertTrue(globMatch("", ""), "empty matches empty")
  assertTrue(not globMatch("", "a"), "empty matches only empty")
  assertTrue(globMatch("**", "a/b/c"), "bare **")
  assertTrue(globMatch("a/**/b", "a/b"), "**/ zero dirs mid-pattern")
  assertTrue(globMatch("a/**/b", "a/x/y/b"), "**/ many dirs mid-pattern")
  // Backtracking would take exponential time here; the DP is linear-ish.
  var long = ""
  var i = 0
  while i < 200 {
    long = long + "a"
    i = i + 1
  }
  assertTrue(not globMatch("*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b", long), "pathological pattern")
  assertTrue(globMatch("**a**a**a**a**a**a**a**a**a**a**a**", long), "pathological ** pattern")
}

test "a repo policy appends raise-only rules" {
  val json = "{\"rules\":[{\"match\":{\"tagsAny\":[\"perf\"]},\"minSeverity\":\"blocking\"},{\"match\":{\"kind\":\"note\",\"filesGlob\":[\"infra/**\"]},\"minSeverity\":\"review\"}]}"
  match parseRepoPolicy(json) {
    case Ok(extra) -> {
      assertEqualInt(extra.length.toInt(), 2, "two rules")
      var rules = defaultRules()
      var i = 0
      while i < extra.length.toInt() {
        rules = rules.append(extra[i])
        i = i + 1
      }
      assertEqual(
        effectiveSeverity("", facts("decision", "", ["perf"], noRefs()), rules),
        "blocking",
        "perf raised to blocking"
      )
      assertEqual(
        effectiveSeverity("", facts("note", "", noRefs(), ["infra/main.tf"]), rules),
        "review",
        "infra note raised"
      )
      assertEqual(
        effectiveSeverity("", facts("decision", "", noRefs(), ["infra/main.tf"]), rules),
        "info",
        "kind AND files"
      )
      assertEqual(effectiveSeverity("", facts("shortcut", "", noRefs(), noRefs()), rules), "review", "defaults still apply")
    }
    case Err(msg) -> assertTrue(false, "valid policy rejected: " + msg)
  }
}

test "a repo policy with a typo or bad value is rejected with a pointer" {
  match parseRepoPolicy("{\"rules\":[{\"match\":{\"kinds\":\"note\"},\"minSeverity\":\"review\"}]}") {
    case Ok(_) -> assertTrue(false, "unknown key rejected")
    case Err(msg) -> assertTrue(msg.contains("rules[0].match has unknown key \"kinds\""), msg)
  }
  match parseRepoPolicy("{\"rules\":[{\"minSeverity\":\"urgent\"}]}") {
    case Ok(_) -> assertTrue(false, "bad severity rejected")
    case Err(msg) -> assertTrue(msg.contains("minSeverity"), msg)
  }
  match parseRepoPolicy("not json") {
    case Ok(_) -> assertTrue(false, "garbage rejected")
    case Err(msg) -> assertTrue(msg.contains("JSON"), msg)
  }
}

// ── Summary ───────────────────────────────────────────────────────────────────
test "summary counts states and the attention queue" {
  val items: slice[WorkItem] = [
    item("gh:a/b#1", "done", noRefs()),
    item("gh:a/b#2", "blocked", ["gh:a/b#1"]),
    item("gh:a/b#3", "queued", noRefs())
  ]
  val entries: slice[LedgerEntry] = [
    entry("decision", "info", "not_required", "1000"),
    entry("shortcut", "review", "pending", "2000"),
    entry("blocker", "blocking", "pending", "3000"),
    entry("deviation", "review", "approved", "4000"),
    entry("blocker", "blocking", "resolved", "5000")
  ]
  val s = summarize("s1", items, entries, 2)
  assertEqual(s.total, "3", "total")
  assertEqual(s.done, "1", "done")
  assertEqual(s.blocked, "1", "blocked")
  assertEqual(s.queued, "1", "queued")
  assertEqual(s.pendingReview, "2", "pending review excludes info, approved and resolved")
  assertEqual(s.blockingCount, "1", "blocking")
  assertEqual(s.pendingFeedback, "2", "feedback")
  assertEqual(s.lastActivityAt, "5000", "latest activity")
}

test "agent state view points at waiting feedback" {
  val items: slice[WorkItem] = [item("gh:a/b#1", "in_progress", noRefs())]
  val entries: slice[LedgerEntry] = [
    entry("decision", "info", "not_required", "1000"),
    entry("shortcut", "review", "rejected", "2000")
  ]
  val v = agentState(items, entries, 1)
  assertEqualInt(v.items.length.toInt(), 1, "items")
  assertEqualInt(v.recentDecisions.length.toInt(), 2, "decision + shortcut")
  assertEqual(v.recentDecisions[0].kind, "shortcut", "most recent first")
  assertEqualInt(v.reviewedSinceRecorded.length.toInt(), 1, "rejected shortcut surfaced")
  assertTrue(v.instruction.contains("ledger_check_feedback"), v.instruction)
}
