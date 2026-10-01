//! CloudAgents.Ledger.Sync — GitHub reconciliation for one session
//! (docs/session-ledger.md §9, Phase 3).
//!
//! One pass, for each GitHub-backed item that changed since it was last
//! synced or is waiting on GitHub:
//!   1. inbound: read the item's issue (and, for a pr_open item, its PR; for
//!      a blocked item, each blocking issue) and apply what GitHub asks
//!      (CloudAgents.Ledger.GitHubSync.inboundChange);
//!   2. outbound: make the issue carry exactly the item's `agent:*` label,
//!      and keep the one structured blocker comment current (edited in
//!      place, found by its hidden marker).
//! Idempotent: labels are planned against the issue's actual labels, and a
//! comment is written only when its content hash changed. Every GitHub call
//! counts against the pass's budget; items left over wait for the next pass.
//! Failures are recorded per item and retried next pass; they never fail
//! the pass or touch the ledger.
package CloudAgents.Ledger.Sync

import Std.Core
import CloudAgents.Repository
import CloudAgents.Crypto
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Store
import CloudAgents.Ledger.Service
import CloudAgents.Ledger.GitHubSync
import CloudAgents.Ledger.GitHubPort

/// What one session's pass did.
pub record SyncOutcome {
  pub items: Int
  pub transitions: Int
  pub calls: Int
  pub errors: slice[String]
}

// Issue facts fetched this pass, keyed by item ref (parallel slices: record
// appends in a hot loop can miscompile, docs/lyric/gotchas.md).
record FactsCache {
  pub var refs: slice[String]
  pub var states: slice[String]
  pub var labelLists: slice[String]
  pub var errors: slice[String]
}

// The per-pass mutable counters.
record Pass {
  pub var calls: Int
  pub var budget: Int
  pub var transitions: Int
  pub var errors: slice[String]
  pub var ensured: slice[String]
}

func spend(pass: in Pass): Bool {
  if pass.calls >= pass.budget {
    return false
  }
  pass.calls = pass.calls + 1
  return true
}

func stuck(state: in String): Bool {
  return state == "blocked" or state == "needs_human"
}

/// Whether an item needs this pass: never synced, changed since, or
/// waiting on GitHub.
pub func needsSync(item: in WorkItem, row: in Option[SyncRow]): Bool {
  if stuck(item.state) or item.state == "pr_open" {
    return true
  }
  match row {
    case Some(r) -> return r.lastError.length.toInt() > 0 or decimalLess(r.syncedAt, item.updatedAt)
    case _ -> return true
  }
}

// a < b for non-negative decimal strings without leading zeros ("" is
// smallest). Compared digit by digit: epoch millis overflow Int.
func decimalLess(a: in String, b: in String): Bool {
  if a.length.toInt() != b.length.toInt() {
    return a.length.toInt() < b.length.toInt()
  }
  var i = 0
  while i < a.length.toInt() {
    val da = digitOf(a.substring(i, 1))
    val db = digitOf(b.substring(i, 1))
    if da != db {
      return da < db
    }
    i = i + 1
  }
  return false
}

func digitOf(c: in String): Int {
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

func rowFor(rows: in slice[SyncRow], itemId: in String): Option[SyncRow] {
  var i = 0
  while i < rows.length.toInt() {
    if rows[i].itemId == itemId {
      return Some(value = rows[i])
    }
    i = i + 1
  }
  return None
}

func itemById(items: in slice[WorkItem], id: in String): Option[WorkItem] {
  var i = 0
  while i < items.length.toInt() {
    if items[i].id == id {
      return Some(value = items[i])
    }
    i = i + 1
  }
  return None
}

// The issue facts for `ref`, fetched once per pass. None when it can't be
// read (budget spent, not a GitHub ref, or GitHub refused); a refusal is
// recorded in `cache.errors` for the item to report.
func factsFor(port: in GitHubPort, pass: in Pass, cache: in FactsCache, ref: in String): Option[IssueFacts] {
  var i = 0
  while i < cache.refs.length.toInt() {
    if cache.refs[i] == ref {
      if cache.errors[i].length.toInt() > 0 {
        return None
      }
      return Some(value = IssueFacts(state = cache.states[i], labels = splitLabels(cache.labelLists[i])))
    }
    i = i + 1
  }
  val issue = match issueRefOf(ref) { case Some(r) -> r; case _ -> return None }
  if not spend(pass) {
    return None
  }
  match port.getIssue(issue.ownerRepo, issue.number) {
    case Ok(f) -> {
      cache.refs = cache.refs.append(ref)
      cache.states = cache.states.append(f.state)
      cache.labelLists = cache.labelLists.append(joinLabels(f.labels))
      cache.errors = cache.errors.append("")
      return Some(value = f)
    }
    case Err(e) -> {
      cache.refs = cache.refs.append(ref)
      cache.states = cache.states.append("")
      cache.labelLists = cache.labelLists.append("")
      cache.errors = cache.errors.append(e)
      return None
    }
  }
}

func cachedError(cache: in FactsCache, ref: in String): String {
  var i = 0
  while i < cache.refs.length.toInt() {
    if cache.refs[i] == ref {
      return cache.errors[i]
    }
    i = i + 1
  }
  return ""
}

func joinLabels(labels: in slice[String]): String {
  var acc = ""
  var i = 0
  while i < labels.length.toInt() {
    if i > 0 {
      acc = acc + "\n"
    }
    acc = acc + labels[i]
    i = i + 1
  }
  return acc
}

func splitLabels(joined: in String): slice[String] {
  if joined.length.toInt() == 0 {
    val none: slice[String] = []
    return none
  }
  return splitOn(joined, "\n")
}

/// Sync one session. `budget` caps the GitHub calls this pass may make.
pub func syncSession(ctx: in SessionContext, port: in GitHubPort, budget: in Int): SyncOutcome {
  val none: slice[String] = []
  val pass = Pass(calls = 0, budget = budget, transitions = 0, errors = none, ensured = none)
  val cache = FactsCache(refs = none, states = none, labelLists = none, errors = none)
  val items = match listItems(ctx.sessionId, ctx.tenantScope) {
    case Ok(xs) -> xs
    case Err(e) -> return failed(pass, "reading items: " + CloudAgents.Db.dbErrorMessage(e))
  }
  val rows = match syncRows(ctx.sessionId, ctx.tenantScope) {
    case Ok(rs) -> rs
    case Err(e) -> return failed(pass, "reading sync state: " + CloudAgents.Db.dbErrorMessage(e))
  }
  val owned = match ownedIssueItems(ctx.sessionId, ctx.tenantScope) {
    case Ok(xs) -> xs
    case Err(e) -> return failed(pass, "reading issue ownership: " + CloudAgents.Db.dbErrorMessage(e))
  }
  val due = dueInOrder(items, rows, owned)

  // Item by item, least recently attempted first, so a pass that runs out
  // of budget, or items that keep failing, leave the rest their turn. Each item is
  // re-read before each half: an inbound move (and its auto-unblock) changes
  // what the rest of the pass sees.
  var synced = 0
  var k = 0
  while k < due.length.toInt() and pass.calls < pass.budget {
    val current = match listItems(ctx.sessionId, ctx.tenantScope) { case Ok(xs) -> xs; case Err(_) -> items }
    match itemById(current, due[k]) {
      case Some(item) -> inbound(ctx, port, pass, cache, item, current, rowFor(rows, item.id))
      case _ -> ()
    }
    val after = match listItems(ctx.sessionId, ctx.tenantScope) { case Ok(xs) -> xs; case Err(_) -> current }
    match itemById(after, due[k]) {
      case Some(item) -> {
        if outbound(ctx, port, pass, cache, item, rowFor(rows, item.id)) {
          synced = synced + 1
        }
      }
      case _ -> ()
    }
    k = k + 1
  }
  return SyncOutcome(items = synced, transitions = pass.transitions, calls = pass.calls, errors = pass.errors)
}

// The due items this session owns on GitHub, never-attempted first, then by
// last attempt (ties in batch order). Selects stamp by stamp rather than sorting in
// place: n appends and O(n^2) comparisons for a batch of at most 1000.
func dueInOrder(items: in slice[WorkItem], rows: in slice[SyncRow], owned: in slice[String]): slice[String] {
  var ids: slice[String] = []
  var stamps: slice[String] = []
  var i = 0
  while i < items.length.toInt() {
    val row = rowFor(rows, items[i].id)
    if containsString(owned, items[i].id) and needsSync(items[i], row) {
      ids = ids.append(items[i].id)
      stamps = stamps.append(match row { case Some(r) -> r.attemptedAt; case _ -> "" })
    }
    i = i + 1
  }
  var ordered: slice[String] = []
  var prev = ""
  var first = true
  while ordered.length.toInt() < ids.length.toInt() {
    var min = ""
    var found = false
    var j = 0
    while j < stamps.length.toInt() {
      if (first or decimalLess(prev, stamps[j])) and (not found or decimalLess(stamps[j], min)) {
        min = stamps[j]
        found = true
      }
      j = j + 1
    }
    if not found {
      return ordered
    }
    var m = 0
    while m < ids.length.toInt() {
      if stamps[m] == min {
        ordered = ordered.append(ids[m])
      }
      m = m + 1
    }
    prev = min
    first = false
  }
  return ordered
}

func failed(pass: in Pass, message: in String): SyncOutcome {
  return SyncOutcome(items = 0, transitions = 0, calls = pass.calls, errors = [message])
}

func inbound(
  ctx: in SessionContext,
  port: in GitHubPort,
  pass: in Pass,
  cache: in FactsCache,
  item: in WorkItem,
  items: in slice[WorkItem],
  row: in Option[SyncRow],
): Unit {
  val own = factsFor(port, pass, cache, item.id)
  var prMerged = false
  if item.state == "pr_open" {
    match pullRefOf(item.prUrl) {
      case Some(pr) -> {
        if spend(pass) {
          match port.pullMerged(pr.ownerRepo, pr.number) {
            case Ok(m) -> {
              prMerged = m
            }
            case Err(e) -> {
              pass.errors = pass.errors.append(item.id + ": reading its PR: " + e)
            }
          }
        }
      }
      case _ -> ()
    }
  }
  var resolved = false
  if item.state == "blocked" {
    resolved = blockersResolved(item.blockedBy, items, closedBlockers(port, pass, cache, item, items))
  }
  val syncedLabel = match row { case Some(r) -> r.syncedLabel; case _ -> "" }
  val change = inboundChange(item, own, syncedLabel, resolved, prMerged)
  if change.to.length.toInt() > 0 {
    match syncSetStatus(ctx, item.id, change.to, change.reason, change.actor) {
      case Ok(_) -> {
        pass.transitions = pass.transitions + 1
      }
      case Err(f) -> {
        pass.errors = pass.errors.append(item.id + ": " + f.message)
      }
    }
  }
}

// The blocking refs GitHub reports closed. In-batch refs already done
// aren't fetched: they resolve without GitHub.
func closedBlockers(
  port: in GitHubPort,
  pass: in Pass,
  cache: in FactsCache,
  item: in WorkItem,
  items: in slice[WorkItem],
): slice[String] {
  var closed: slice[String] = []
  var i = 0
  while i < item.blockedBy.length.toInt() {
    val ref = item.blockedBy[i]
    val inBatchDone = match itemById(items, ref) { case Some(b) -> b.state == "done"; case _ -> false }
    if not inBatchDone {
      match factsFor(port, pass, cache, ref) {
        case Some(f) -> if f.state == "closed" { closed = closed.append(ref) }
        case _ -> ()
      }
    }
    i = i + 1
  }
  return closed
}

// Make the issue match the item; returns true when it now does.
func outbound(
  ctx: in SessionContext,
  port: in GitHubPort,
  pass: in Pass,
  cache: in FactsCache,
  item: in WorkItem,
  row: in Option[SyncRow],
): Bool {
  val issue = match issueRefOf(item.id) { case Some(r) -> r; case _ -> return false }
  var saved = match row { case Some(r) -> r; case _ -> emptySyncRow(item.id) }
  val facts = match factsFor(port, pass, cache, item.id) {
    case Some(f) -> f
    case _ -> {
      val why = cachedError(cache, item.id)
      if why.length.toInt() > 0 {
        persist(ctx, saved, why)
        pass.errors = pass.errors.append(item.id + ": " + why)
      }
      return false
    }
  }

  // Labels.
  val plan = planLabels(facts.labels, item.state)
  var k = 0
  while k < plan.add.length.toInt() {
    val label = plan.add[k]
    if not containsString(pass.ensured, issue.ownerRepo + "|" + label) {
      if not spend(pass) {
        return false
      }
      match port.ensureLabel(issue.ownerRepo, label) {
        case Ok(_) -> {
          pass.ensured = pass.ensured.append(issue.ownerRepo + "|" + label)
        }
        case Err(e) -> return fail(ctx, pass, saved, item.id, "creating label " + label + ": " + e)
      }
    }
    if not spend(pass) {
      return false
    }
    match port.addLabel(issue.ownerRepo, issue.number, label) {
      case Ok(_) -> ()
      case Err(e) -> return fail(ctx, pass, saved, item.id, "adding label " + label + ": " + e)
    }
    k = k + 1
  }
  var r = 0
  while r < plan.remove.length.toInt() {
    if not spend(pass) {
      return false
    }
    match port.removeLabel(issue.ownerRepo, issue.number, plan.remove[r]) {
      case Ok(_) -> ()
      case Err(e) -> return fail(ctx, pass, saved, item.id, "removing label " + plan.remove[r] + ": " + e)
    }
    r = r + 1
  }
  saved = withLabel(saved, labelForState(item.state))

  // The blocker comment: current while stuck, marked resolved after.
  var body = ""
  if stuck(item.state) {
    body = blockerComment(ctx.sessionId, item)
  } else if saved.commentId.length.toInt() > 0 {
    body = resolvedComment(ctx.sessionId, item)
  }
  if body.length.toInt() > 0 {
    val hash = CloudAgents.Crypto.sha256Hex(body)
    if hash != saved.commentHash {
      val written = writeComment(port, pass, issue, commentMarker(ctx.sessionId, item.id), saved.commentId, body)
      match written {
        case Ok(id) -> {
          saved = withComment(saved, id, hash)
        }
        case Err(e) -> return fail(ctx, pass, saved, item.id, "writing the blocker comment: " + e)
      }
    }
  }
  persist(ctx, saved, "")
  return true
}

// Edit the known comment, or find it by marker, or post it. Returns its id.
func writeComment(
  port: in GitHubPort,
  pass: in Pass,
  issue: in IssueRef,
  marker: in String,
  knownId: in String,
  body: in String,
): Result[String, String] {
  var id = knownId
  if id.length.toInt() == 0 {
    if not spend(pass) {
      return Err(error = "sync budget spent")
    }
    id = port.findComment(issue.ownerRepo, issue.number, marker)?
  }
  if id.length.toInt() > 0 {
    if not spend(pass) {
      return Err(error = "sync budget spent")
    }
    match port.updateComment(issue.ownerRepo, id, body) {
      case Ok(_) -> return Ok(value = id)
      case Err(e) -> {
        // Deleted on GitHub: post a fresh one below.
        if not e.contains("(404)") {
          return Err(error = e)
        }
      }
    }
  }
  if not spend(pass) {
    return Err(error = "sync budget spent")
  }
  return port.createComment(issue.ownerRepo, issue.number, body)
}

func withLabel(r: in SyncRow, label: in String): SyncRow {
  return SyncRow(
    itemId = r.itemId,
    syncedLabel = label,
    commentId = r.commentId,
    commentHash = r.commentHash,
    lastError = r.lastError,
    syncedAt = r.syncedAt,
    attemptedAt = r.attemptedAt
  )
}

func withComment(r: in SyncRow, id: in String, hash: in String): SyncRow {
  return SyncRow(
    itemId = r.itemId,
    syncedLabel = r.syncedLabel,
    commentId = id,
    commentHash = hash,
    lastError = r.lastError,
    syncedAt = r.syncedAt,
    attemptedAt = r.attemptedAt
  )
}

func fail(ctx: in SessionContext, pass: in Pass, saved: in SyncRow, itemId: in String, message: in String): Bool {
  pass.errors = pass.errors.append(itemId + ": " + message)
  persist(ctx, saved, message)
  return false
}

// Persist the row. Every attempt stamps attempted_at (so a failing item goes
// to the back of the next pass); only a clean one stamps synced_at, so a
// failed item stays due and is retried.
func persist(ctx: in SessionContext, row: in SyncRow, error: in String): Unit {
  val now = CloudAgents.Repository.nowMillis()
  var at = row.syncedAt
  if error.length.toInt() == 0 {
    at = now
  }
  val toSave = SyncRow(
    itemId = row.itemId,
    syncedLabel = row.syncedLabel,
    commentId = row.commentId,
    commentHash = row.commentHash,
    lastError = error,
    syncedAt = at,
    attemptedAt = now
  )
  match saveSyncRow(ctx.sessionId, ctx.tenantScope, toSave) {
    case Ok(_) -> ()
    case Err(e) -> println(
      "WARNING: ledger sync state for " + row.itemId + " not saved: " + CloudAgents.Db.dbErrorMessage(e)
    )
  }
}
