//! CloudAgents.Ledger.Service — the session ledger's operations
//! (docs/session-ledger.md §6): what the agent-facing ledger_* tools and the
//! human-facing review API do, composed from the pure core
//! (CloudAgents.Ledger.Model / StateMachine / Policy / Summary) and the store
//! (CloudAgents.Ledger.Store).
//!
//! Transport-free: no Web types. Every operation returns
//! Result[T, LedgerFailure]; CloudAgents.LedgerHandlers maps failures onto
//! HTTP (human API) or onto the tool-result envelope the in-container shim
//! relays to the agent (agent API). Failure messages are written for the
//! reader who will act on them — for the agent, that means naming the fix.
package CloudAgents.Ledger.Service

import Std.Core
import CloudAgents.Sqlite
import CloudAgents.Repository
import CloudAgents.Capture
import CloudAgents.Capture.Render
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.StateMachine
import CloudAgents.Ledger.Policy
import CloudAgents.Ledger.Summary
import CloudAgents.Ledger.Schema
import CloudAgents.Ledger.Store
import CloudAgents.Ledger.RepoPolicy

// ── Failures ──────────────────────────────────────────────────────────────────
/// `status`: invalid (the caller must change the request), not_found,
/// conflict (a concurrent change won; retry), error (storage failure).
pub record LedgerFailure {
  pub status: String
  pub message: String
}

func invalid(msg: in String): LedgerFailure {
  return LedgerFailure(status = "invalid", message = msg)
}

func notFound(msg: in String): LedgerFailure {
  return LedgerFailure(status = "not_found", message = msg)
}

func dbFail(e: in CloudAgents.Sqlite.DbError): LedgerFailure {
  println("WARNING: session ledger storage failure: " + CloudAgents.Sqlite.dbErrorMessage(e))
  return LedgerFailure(status = "error", message = "the session ledger could not be updated; try again")
}

// ── Session context ───────────────────────────────────────────────────────────
/// Who owns a session and which GitHub repo (if any) it works on.
pub record SessionContext {
  pub sessionId: String
  pub ownerUserId: String
  pub ownerRepo: String
}

/// The context for `sessionId`, unscoped (the caller has already
/// authenticated the session: a container callback token, or an
/// owner-scoped lookup on the human path).
pub func sessionContext(sessionId: in String): Result[SessionContext, LedgerFailure] {
  match CloudAgents.Repository.sessionOwnerAndRepo(sessionId) {
    case Ok(Some(sr)) -> return Ok(
      value = SessionContext(
        sessionId = sessionId,
        ownerUserId = sr.userId,
        ownerRepo = ownerRepoOfRepoUrl(sr.repoUrl)
      )
    )
    case Ok(None) -> return Err(error = notFound("Session not found"))
    case Err(e) -> return Err(error = dbFail(e))
  }
}

// ── Agent-facing request / reply records (mirrored field-for-field by the
// shim's src/ledger_transport.l — keep the two in sync by hand) ──────────────
@generate(Json)
pub record RegisterItemInput {
  pub id: String
  pub title: String
  pub url: String
}

@generate(Json)
pub record RegisterItemsRequest {
  pub items: slice[RegisterItemInput]
}

@generate(Json)
pub record SetItemStatusRequest {
  pub item: String
  pub state: String
  pub reason: String
  pub blockedBy: slice[String]
  pub prerequisiteProposal: String
  pub recommendation: String
  pub prUrl: String
}

@generate(Json)
pub record RecordDecisionRequest {
  pub summary: String
  pub detail: String
  pub optionsConsidered: slice[String]
  pub chosen: String
  pub rationale: String
  pub recommendation: String
  pub reversible: String
  pub item: String
  pub tags: slice[String]
  pub files: slice[String]
  pub severity: String
  pub supersedes: String
}

@generate(Json)
pub record RecordDeviationRequest {
  pub kind: String
  pub summary: String
  pub detail: String
  pub recommendation: String
  pub reversible: String
  pub item: String
  pub tags: slice[String]
  pub files: slice[String]
  pub severity: String
  pub supersedes: String
}

@generate(Json)
pub record AskRequest {
  pub question: String
  pub detail: String
  pub options: slice[String]
  pub proceedingWith: String
  pub item: String
  pub severity: String
}

@generate(Json)
pub record NoteRequest {
  pub summary: String
  pub detail: String
  pub recommendation: String
  pub needsReview: String
  pub item: String
  pub tags: slice[String]
  pub files: slice[String]
}

@generate(Json)
pub record RegisterReply {
  pub registered: String
  pub total: String
  pub pendingFeedback: String
  pub hint: String
}

@generate(Json)
pub record StatusReply {
  pub item: String
  pub state: String
  pub unblocked: slice[String]
  pub pendingFeedback: String
  pub hint: String
}

@generate(Json)
pub record RecordReply {
  pub id: String
  pub severity: String
  pub review: String
  pub pendingFeedback: String
  pub hint: String
}

@generate(Json)
pub record FeedbackView {
  pub id: String
  pub kind: String
  pub entrySummary: String
  pub entryId: String
  pub item: String
  pub body: String
}

@generate(Json)
pub record CheckFeedbackReply {
  pub feedback: slice[FeedbackView]
  pub instruction: String
}

func feedbackHint(pending: in Int): String {
  if pending > 0 {
    return toString(pending) +
      " feedback item(s) from the human are waiting: call ledger_check_feedback before your next step."
  }
  return ""
}

func pendingCount(sessionId: in String): Result[Int, LedgerFailure] {
  match pendingFeedbackCount(sessionId) {
    case Ok(n) -> return Ok(value = n)
    case Err(e) -> return Err(error = dbFail(e))
  }
}

// ── Items ─────────────────────────────────────────────────────────────────────
/// Normalise an item ref against the session's repo, as the agent or human
/// wrote it.
func normalizeRef(ctx: in SessionContext, raw: in String): Result[String, LedgerFailure] {
  match normalizeItemRef(raw, ctx.ownerRepo) {
    case Ok(r) -> return Ok(value = r)
    case Err(msg) -> return Err(error = invalid(msg))
  }
}

/// Make sure `itemId` exists (registering it queued if not) and return it.
func ensureItem(ctx: in SessionContext, itemId: in String, title: in String): Result[WorkItem, LedgerFailure] {
  match getItem(ctx.sessionId, itemId) {
    case Ok(Some(w)) -> return Ok(value = w)
    case Ok(None) -> ()
    case Err(e) -> return Err(error = dbFail(e))
  }
  val ids: slice[String] = [itemId]
  val titles: slice[String] = [title]
  val urls: slice[String] = [urlForItemRef(itemId)]
  match registerItems(ctx.sessionId, ids, titles, urls) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = dbFail(e))
  }
  match getItem(ctx.sessionId, itemId) {
    case Ok(Some(w)) -> return Ok(value = w)
    case Ok(None) -> return Err(error = LedgerFailure(status = "error", message = "item registration did not persist"))
    case Err(e) -> return Err(error = dbFail(e))
  }
}

/// ledger_register_items / the human "add item" action.
pub func registerBatch(ctx: in SessionContext, req: in RegisterItemsRequest): Result[RegisterReply, LedgerFailure] {
  if req.items.length.toInt() == 0 {
    return Err(error = invalid("items is empty: pass at least one {id, title?, url?}"))
  }
  if req.items.length.toInt() > 200 {
    return Err(error = invalid("too many items in one call (max 200)"))
  }
  var ids: slice[String] = []
  var titles: slice[String] = []
  var urls: slice[String] = []
  var i = 0
  while i < req.items.length.toInt() {
    val input = req.items[i]
    val ref = normalizeRef(ctx, input.id)?
    match validateLine("title", input.title, 300) {
      case Ok(_) -> ()
      case Err(msg) -> return Err(error = invalid(msg))
    }
    match validateLine("url", input.url, 500) {
      case Ok(_) -> ()
      case Err(msg) -> return Err(error = invalid(msg))
    }
    if not containsString(ids, ref) {
      ids = ids.append(ref)
      titles = titles.append(input.title)
      var url = input.url
      if url.length.toInt() == 0 {
        url = urlForItemRef(ref)
      }
      urls = urls.append(url)
    }
    i = i + 1
  }
  val added = match registerItems(ctx.sessionId, ids, titles, urls) {
    case Ok(n) -> n
    case Err(e) -> return Err(error = dbFail(e))
  }
  val total = match listItems(ctx.sessionId) {
    case Ok(items) -> items.length.toInt()
    case Err(e) -> return Err(error = dbFail(e))
  }
  val pending = pendingCount(ctx.sessionId)?
  return Ok(
    value = RegisterReply(
      registered = toString(added),
      total = toString(total),
      pendingFeedback = toString(pending),
      hint = feedbackHint(pending)
    )
  )
}

/// Apply a status change with the given actor, re-planning on a concurrent
/// change (up to 3 attempts). Returns the item as updated.
func changeStatus(
  ctx: in SessionContext, itemId: in String, change: in StatusChange, actor: in String
): Result[WorkItem, LedgerFailure] {
  var attempt = 0
  while attempt < 3 {
    val current = match getItem(ctx.sessionId, itemId) {
      case Ok(Some(w)) -> w
      case Ok(None) -> return Err(error = notFound("item " + itemId + " is not registered in this session"))
      case Err(e) -> return Err(error = dbFail(e))
    }
    val plan = match planStatusChange(current, change, actor) {
      case Ok(p) -> p
      case Err(msg) -> return Err(error = invalid(msg))
    }
    var auto = AutoEntry(kind = "", severity = "", source = "", summary = "", detail = "")
    if plan.blockerSummary.length.toInt() > 0 {
      var source = "declared"
      if actor == "human" {
        source = "system"
      }
      auto = AutoEntry(
        kind = "blocker",
        severity = "blocking",
        source = source,
        summary = plan.blockerSummary,
        detail = plan.blockerDetail
      )
    }
    val applied = match applyItemUpdate(ctx.sessionId, plan.item, current.updatedSeq, plan.fromState, plan.stateChanged, actor, change.reason, auto, plan.resolvesBlockers) {
      case Ok(a) -> a
      case Err(e) -> return Err(error = dbFail(e))
    }
    if applied {
      if plan.blockerSummary.length.toInt() > 0 {
        notifyOwner(ctx, "blocked", plan.blockerSummary)
      }
      return Ok(value = plan.item)
    }
    attempt = attempt + 1
  }
  return Err(
    error = LedgerFailure(
      status = "conflict",
      message = "item " + itemId + " changed concurrently; read it again and retry"
    )
  )
}

/// Fire-and-forget "needs you" notification through the existing notify
/// channel (docs/phase7-autonomy.md §5); a failure is logged, never fatal.
func notifyOwner(ctx: in SessionContext, level: in String, summary: in String): Unit {
  match CloudAgents.Repository.createNotification(ctx.sessionId, level, "Ledger: " + summary) {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: ledger notification failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

/// After an item reaches `done`, requeue every blocked item whose in-batch
/// blockers are now all done (spec §7), writing an info entry for each.
func autoUnblock(ctx: in SessionContext, actor: in String): Result[slice[String], LedgerFailure] {
  val items = match listItems(ctx.sessionId) { case Ok(xs) -> xs; case Err(e) -> return Err(error = dbFail(e)) }
  val candidates = unblockCandidates(items)
  var done: slice[String] = []
  var i = 0
  while i < candidates.length.toInt() {
    val id = candidates[i]
    val change = StatusChange(
      to = "queued",
      reason = "all blockers are done",
      blockedBy = emptyStrings(),
      prerequisiteProposal = "",
      recommendation = "",
      prUrl = ""
    )
    match changeStatus(ctx, id, change, actor) {
      case Ok(_) -> {
        done = done.append(id)
        writeSystemNote(ctx, id, "Unblocked " + id + ": every item it was blocked by is done")
      }
      case Err(f) -> println("WARNING: auto-unblock of " + id + " skipped: " + f.message)
    }
    i = i + 1
  }
  return Ok(value = done)
}

func emptyStrings(): slice[String] {
  val none: slice[String] = []
  return none
}

func writeSystemNote(ctx: in SessionContext, itemId: in String, summary: in String): Unit {
  val d = simpleDraft("note", truncate(summary, 140), itemId)
  match insertEntry(materialize(ctx.sessionId, d, itemId, "info", "not_required", "", "system")) {
    case Ok(_) -> ()
    case Err(err) -> println("WARNING: ledger system note failed: " + CloudAgents.Sqlite.dbErrorMessage(err))
  }
}

func truncate(s: in String, max: in Int): String {
  if s.length.toInt() <= max {
    return s
  }
  return s.substring(0, max - 1) + "…"
}

/// ledger_set_item_status (actor agent).
pub func agentSetStatus(ctx: in SessionContext, req: in SetItemStatusRequest): Result[StatusReply, LedgerFailure] {
  val itemId = normalizeRef(ctx, req.item)?
  var blockedBy: slice[String] = []
  var i = 0
  while i < req.blockedBy.length.toInt() {
    val ref = normalizeRef(ctx, req.blockedBy[i])?
    if not containsString(blockedBy, ref) {
      blockedBy = blockedBy.append(ref)
    }
    i = i + 1
  }
  ensureItem(ctx, itemId, "")?
  val change = StatusChange(
    to = req.state,
    reason = req.reason,
    blockedBy = blockedBy,
    prerequisiteProposal = req.prerequisiteProposal,
    recommendation = req.recommendation,
    prUrl = req.prUrl
  )
  val updated = changeStatus(ctx, itemId, change, "agent")?
  var unblocked = emptyStrings()
  if updated.state == "done" {
    unblocked = autoUnblock(ctx, "agent")?
  }
  val pending = pendingCount(ctx.sessionId)?
  var hint = feedbackHint(pending)
  if hint.length.toInt() == 0 and (updated.state == "blocked" or updated.state == "needs_human") {
    hint = "Recorded; the human has been notified. Move on to the next queued item rather than waiting."
  }
  return Ok(
    value = StatusReply(
      item = itemId,
      state = updated.state,
      unblocked = unblocked,
      pendingFeedback = toString(pending),
      hint = hint
    )
  )
}

/// The human "change state" action (unblock, skip, requeue, reopen).
pub func humanSetStatus(
  ctx: in SessionContext, itemId: in String, to: in String, reason: in String
): Result[WorkItem, LedgerFailure] {
  match getItem(ctx.sessionId, itemId) {
    case Ok(Some(_)) -> ()
    case Ok(None) -> return Err(error = notFound("item not found"))
    case Err(e) -> return Err(error = dbFail(e))
  }
  val change = StatusChange(
    to = to,
    reason = reason,
    blockedBy = emptyStrings(),
    prerequisiteProposal = "",
    recommendation = "",
    prUrl = ""
  )
  return changeStatus(ctx, itemId, change, "human")
}

// ── Entries ───────────────────────────────────────────────────────────────────
/// What a declared entry says, before the ledger classifies and anchors it.
/// `itemRef` is the raw ref as written ("" = session level).
pub record DraftEntry {
  pub itemRef: String
  pub kind: String
  pub summary: String
  pub detail: String
  pub optionsConsidered: slice[String]
  pub chosen: String
  pub rationale: String
  pub recommendation: String
  pub proceedingWith: String
  pub reversible: String
  pub tags: slice[String]
  pub files: slice[String]
  pub declaredSeverity: String
  pub supersedes: String
}

/// The stored form of `d` (ids / timestamps / cursors are assigned by the
/// store on insert).
func materialize(
  sessionId: in String,
  d: in DraftEntry,
  itemId: in String,
  severity: in String,
  reviewState: in String,
  transcriptSeq: in String,
  source: in String,
): LedgerEntry {
  return LedgerEntry(
    id = "",
    sessionId = sessionId,
    itemId = itemId,
    kind = d.kind,
    severity = severity,
    declaredSeverity = d.declaredSeverity,
    summary = d.summary,
    detail = d.detail,
    optionsConsidered = d.optionsConsidered,
    chosen = d.chosen,
    rationale = d.rationale,
    recommendation = d.recommendation,
    proceedingWith = d.proceedingWith,
    reversible = d.reversible,
    files = d.files,
    tags = d.tags,
    source = source,
    undeclared = "false",
    matchedEntryId = "",
    origin = "",
    supersedes = d.supersedes,
    transcriptSeq = transcriptSeq,
    reviewState = reviewState,
    reviewBy = "",
    reviewAt = "",
    reviewComment = "",
    createdAt = "",
    createdSeq = "",
    updatedSeq = ""
  )
}

func simpleDraft(kind: in String, summary: in String, itemRef: in String): DraftEntry {
  return DraftEntry(
    itemRef = itemRef,
    kind = kind,
    summary = summary,
    detail = "",
    optionsConsidered = emptyStrings(),
    chosen = "",
    rationale = "",
    recommendation = "",
    proceedingWith = "",
    reversible = "",
    tags = emptyStrings(),
    files = emptyStrings(),
    declaredSeverity = "",
    supersedes = ""
  )
}

func check(r: in Result[Unit, String]): Result[Unit, LedgerFailure] {
  match r {
    case Ok(_) -> return Ok(())
    case Err(msg) -> return Err(error = invalid(msg))
  }
}

/// The session's effective rules: defaults plus the repo policy (fetched
/// once per session from the repo's default branch, then cached).
pub func rulesFor(ctx: in SessionContext): slice[PolicyRule] {
  val base = defaultRules()
  val cache = match getPolicyCache(ctx.sessionId) {
    case Ok(c) -> c
    case Err(e) -> {
      println("WARNING: reading the ledger policy cache failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      return base
    }
  }
  var status = cache.status
  var json = cache.json
  // "unavailable" is a transient GitHub failure, not an answer: retry it on
  // the next entry rather than pinning the session to the defaults.
  if status.length.toInt() == 0 or status == "unavailable" {
    val fetched = fetchRepoPolicy(ctx.ownerUserId, ctx.ownerRepo)
    status = fetched.status
    json = fetched.json
    match setPolicyCache(ctx.sessionId, fetched.status, fetched.json, fetched.error) {
      case Ok(_) -> ()
      case Err(e) -> println("WARNING: caching the ledger policy failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
    }
  }
  if status != "loaded" {
    return base
  }
  match parseRepoPolicy(json) {
    case Ok(extra) -> {
      var all = base
      var i = 0
      while i < extra.length.toInt() {
        all = all.append(extra[i])
        i = i + 1
      }
      return all
    }
    case Err(_) -> return base
  }
}

/// Validate, classify (policy), anchor to the transcript, and store a
/// declared entry.
func recordDeclared(ctx: in SessionContext, e: in DraftEntry): Result[RecordReply, LedgerFailure] {
  check(validateSummary("summary", e.summary))?
  check(validateText("detail", e.detail, 16000))?
  check(validateText("rationale", e.rationale, 8000))?
  check(validateText("recommendation", e.recommendation, 8000))?
  check(validateLine("chosen", e.chosen, 500))?
  check(validateLine("proceedingWith", e.proceedingWith, 500))?
  check(validateLines("optionsConsidered", e.optionsConsidered, 20, 500))?
  check(validateLines("files", e.files, 100, 500))?
  check(validateTags(e.tags))?
  check(validateReversible(e.reversible))?
  check(validateDeclaredSeverity(e.declaredSeverity))?
  var itemId = ""
  if e.itemRef.trim().length.toInt() > 0 {
    itemId = normalizeRef(ctx, e.itemRef)?
    ensureItem(ctx, itemId, "")?
  }
  if e.supersedes.length.toInt() > 0 {
    match getEntry(ctx.sessionId, e.supersedes) {
      case Ok(Some(_)) -> ()
      case Ok(None) -> return Err(error = invalid("supersedes names an entry that does not exist in this session: " + e.supersedes))
      case Err(err) -> return Err(error = dbFail(err))
    }
  }
  val facts = EntryFacts(
    kind = e.kind,
    reversible = e.reversible,
    tags = e.tags,
    files = e.files,
    source = "declared",
    undeclared = false
  )
  val severity = effectiveSeverity(e.declaredSeverity, facts, rulesFor(ctx))
  val transcriptSeq = match CloudAgents.Repository.latestSessionEventSeq(ctx.sessionId) {
    case Ok(s) -> s
    case Err(_) -> ""
  }
  val toStore = materialize(ctx.sessionId, e, itemId, severity, initialReviewState(severity), transcriptSeq, "declared")
  val stored = match insertEntry(toStore) { case Ok(s) -> s; case Err(err) -> return Err(error = dbFail(err)) }
  if severity == "blocking" {
    notifyOwner(ctx, "blocked", stored.summary)
  }
  val pending = pendingCount(ctx.sessionId)?
  var hint = feedbackHint(pending)
  if hint.length.toInt() == 0 and severity != "info" {
    hint = "Recorded for human review. Carry on; you will get their response via ledger_check_feedback."
  }
  return Ok(
    value = RecordReply(
      id = stored.id,
      severity = severity,
      review = stored.reviewState,
      pendingFeedback = toString(pending),
      hint = hint
    )
  )
}

pub func recordDecision(ctx: in SessionContext, req: in RecordDecisionRequest): Result[RecordReply, LedgerFailure] {
  if req.chosen.trim().length.toInt() == 0 {
    return Err(error = invalid("chosen is required: name the option you went with"))
  }
  if req.rationale.trim().length.toInt() == 0 {
    return Err(error = invalid("rationale is required: say why a reviewer should accept this choice"))
  }
  return recordDeclared(
    ctx,
    DraftEntry(
      itemRef = req.item,
      kind = "decision",
      summary = req.summary,
      detail = req.detail,
      optionsConsidered = req.optionsConsidered,
      chosen = req.chosen,
      rationale = req.rationale,
      recommendation = req.recommendation,
      proceedingWith = "",
      reversible = req.reversible,
      tags = req.tags,
      files = req.files,
      declaredSeverity = req.severity,
      supersedes = req.supersedes
    )
  )
}

pub func recordDeviation(ctx: in SessionContext, req: in RecordDeviationRequest): Result[RecordReply, LedgerFailure] {
  if req.kind != "deviation" and req.kind != "shortcut" {
    return Err(
      error = invalid(
        "kind must be deviation (departing from the issue/spec/plan) or shortcut (doing less than ideal)"
      )
    )
  }
  return recordDeclared(
    ctx,
    DraftEntry(
      itemRef = req.item,
      kind = req.kind,
      summary = req.summary,
      detail = req.detail,
      optionsConsidered = emptyStrings(),
      chosen = "",
      rationale = "",
      recommendation = req.recommendation,
      proceedingWith = "",
      reversible = req.reversible,
      tags = req.tags,
      files = req.files,
      declaredSeverity = req.severity,
      supersedes = req.supersedes
    )
  )
}

pub func ask(ctx: in SessionContext, req: in AskRequest): Result[RecordReply, LedgerFailure] {
  if req.proceedingWith.trim().length.toInt() == 0 {
    return Err(
      error = invalid(
        "proceedingWith is required: name the default you are carrying on with while you wait (use ask_user instead if you truly cannot continue)"
      )
    )
  }
  return recordDeclared(
    ctx,
    DraftEntry(
      itemRef = req.item,
      kind = "question",
      summary = req.question,
      detail = req.detail,
      optionsConsidered = req.options,
      chosen = "",
      rationale = "",
      recommendation = "",
      proceedingWith = req.proceedingWith,
      reversible = "",
      tags = emptyStrings(),
      files = emptyStrings(),
      declaredSeverity = req.severity,
      supersedes = ""
    )
  )
}

pub func note(ctx: in SessionContext, req: in NoteRequest): Result[RecordReply, LedgerFailure] {
  if req.needsReview != "" and req.needsReview != "true" and req.needsReview != "false" {
    return Err(error = invalid("needsReview must be true or false"))
  }
  var declared = ""
  if req.needsReview == "true" {
    declared = "review"
  }
  return recordDeclared(
    ctx,
    DraftEntry(
      itemRef = req.item,
      kind = "note",
      summary = req.summary,
      detail = req.detail,
      optionsConsidered = emptyStrings(),
      chosen = "",
      rationale = "",
      recommendation = req.recommendation,
      proceedingWith = "",
      reversible = "",
      tags = req.tags,
      files = req.files,
      declaredSeverity = declared,
      supersedes = ""
    )
  )
}

// ── Feedback (agent side) ─────────────────────────────────────────────────────
func summaryOfEntry(entries: in slice[LedgerEntry], id: in String): String {
  var i = 0
  while i < entries.length.toInt() {
    if entries[i].id == id {
      return entries[i].summary
    }
    i = i + 1
  }
  return ""
}

/// ledger_check_feedback: claim and return every undelivered feedback item.
pub func checkFeedback(ctx: in SessionContext): Result[CheckFeedbackReply, LedgerFailure] {
  val claimed = match collectFeedback(ctx.sessionId, "mcp_poll") {
    case Ok(fs) -> fs
    case Err(e) -> return Err(error = dbFail(e))
  }
  val entries = match listEntries(ctx.sessionId) { case Ok(es) -> es; case Err(e) -> return Err(error = dbFail(e)) }
  var views: slice[FeedbackView] = []
  var i = 0
  while i < claimed.length.toInt() {
    val f = claimed[i]
    views = views.append(
      FeedbackView(
        id = f.id,
        kind = f.kind,
        entrySummary = summaryOfEntry(entries, f.entryId),
        entryId = f.entryId,
        item = f.itemId,
        body = f.body
      )
    )
    i = i + 1
  }
  var instruction = "No feedback is waiting. Continue."
  if views.length.toInt() > 0 {
    instruction = "Apply this feedback before continuing. A 'reject' means undo or redo that choice; a 'directive' is an instruction. If it changes your plan, record a decision (set supersedes to the entry id when revising one)."
  }
  return Ok(value = CheckFeedbackReply(feedback = views, instruction = instruction))
}

/// ledger_get_state.
pub func agentStateOf(ctx: in SessionContext): Result[AgentStateView, LedgerFailure] {
  val items = match listItems(ctx.sessionId) { case Ok(xs) -> xs; case Err(e) -> return Err(error = dbFail(e)) }
  val entries = match listEntries(ctx.sessionId) { case Ok(es) -> es; case Err(e) -> return Err(error = dbFail(e)) }
  val pending = pendingCount(ctx.sessionId)?
  return Ok(value = agentState(items, entries, pending))
}

// ── Human side ────────────────────────────────────────────────────────────────
/// Everything the session view needs, or only what changed after `after`.
/// `unchanged` is "true" (with empty lists) when nothing changed.
@generate(Json)
pub record LedgerSnapshot {
  pub cursor: String
  pub unchanged: String
  pub full: String
  pub summary: LedgerSummary
  pub items: slice[WorkItem]
  pub entries: slice[LedgerEntry]
  pub feedback: slice[Feedback]
  pub policyStatus: String
  pub policyError: String
}

func noItems(): slice[WorkItem] {
  val none: slice[WorkItem] = []
  return none
}

func noEntries(): slice[LedgerEntry] {
  val none: slice[LedgerEntry] = []
  return none
}

func noFeedback(): slice[Feedback] {
  val none: slice[Feedback] = []
  return none
}

func isZeroCursor(after: in String): Bool {
  return after.length.toInt() == 0 or after == "0"
}

func isDecimal(s: in String): Bool {
  if s.length.toInt() == 0 or s.length.toInt() > 18 {
    return false
  }
  var i = 0
  while i < s.length.toInt() {
    if not "0123456789".contains(s.substring(i, 1)) {
      return false
    }
    i = i + 1
  }
  return true
}

pub func snapshot(ctx: in SessionContext, after: in String): Result[LedgerSnapshot, LedgerFailure] {
  if after.length.toInt() > 0 and not isDecimal(after) {
    return Err(error = invalid("after must be a non-negative integer cursor"))
  }
  val cursor = match currentSeq(ctx.sessionId) { case Ok(c) -> c; case Err(e) -> return Err(error = dbFail(e)) }
  val items = match listItems(ctx.sessionId) { case Ok(xs) -> xs; case Err(e) -> return Err(error = dbFail(e)) }
  val entries = match listEntries(ctx.sessionId) { case Ok(es) -> es; case Err(e) -> return Err(error = dbFail(e)) }
  val pending = pendingCount(ctx.sessionId)?
  val summary = summarize(ctx.sessionId, items, entries, pending)
  val policy = match getPolicyCache(ctx.sessionId) { case Ok(p) -> p; case Err(e) -> return Err(error = dbFail(e)) }
  if not isZeroCursor(after) and after == cursor {
    return Ok(
      value = LedgerSnapshot(
        cursor = cursor,
        unchanged = "true",
        full = "false",
        summary = summary,
        items = noItems(),
        entries = noEntries(),
        feedback = noFeedback(),
        policyStatus = policy.status,
        policyError = policy.error
      )
    )
  }
  if isZeroCursor(after) {
    return fullSnapshot(ctx, cursor, summary, items, entries, policy)
  }
  val changedItems = match itemsChangedAfter(ctx.sessionId, after) {
    case Ok(xs) -> xs
    case Err(e) -> return Err(error = dbFail(e))
  }
  val changedEntries = match entriesChangedAfter(ctx.sessionId, after) {
    case Ok(es) -> es
    case Err(e) -> return Err(error = dbFail(e))
  }
  val changedFeedback = match feedbackChangedAfter(ctx.sessionId, after) {
    case Ok(fs) -> fs
    case Err(e) -> return Err(error = dbFail(e))
  }
  // A delta at a query cap may have dropped rows the client would then never
  // see (its cursor jumps past them); send a full snapshot instead.
  if changedItems.length.toInt() >= itemRowCap or changedEntries.length.toInt() >= entryRowCap or changedFeedback.length.toInt() >= feedbackRowCap {
    return fullSnapshot(ctx, cursor, summary, items, entries, policy)
  }
  return Ok(
    value = LedgerSnapshot(
      cursor = cursor,
      unchanged = "false",
      full = "false",
      summary = summary,
      items = changedItems,
      entries = changedEntries,
      feedback = changedFeedback,
      policyStatus = policy.status,
      policyError = policy.error
    )
  )
}

func fullSnapshot(
  ctx: in SessionContext,
  cursor: in String,
  summary: in LedgerSummary,
  items: in slice[WorkItem],
  entries: in slice[LedgerEntry],
  policy: in PolicyCache,
): Result[LedgerSnapshot, LedgerFailure] {
  val feedback = match listFeedback(ctx.sessionId) { case Ok(fs) -> fs; case Err(e) -> return Err(error = dbFail(e)) }
  return Ok(
    value = LedgerSnapshot(
      cursor = cursor,
      unchanged = "false",
      full = "true",
      summary = summary,
      items = items,
      entries = entries,
      feedback = feedback,
      policyStatus = policy.status,
      policyError = policy.error
    )
  )
}

/// One entry with its review history, item transitions, and the transcript
/// just before it was recorded.
@generate(Json)
pub record EntryDetail {
  pub ledgerEntry: LedgerEntry
  pub feedback: slice[Feedback]
  pub transitions: slice[WorkItemTransition]
  pub transcriptExcerpt: String
  pub supersededBy: slice[String]
}

func parseDecimal(s: in String): Int {
  var n = 0
  var i = 0
  while i < s.length.toInt() and i < 9 {
    val c = s.substring(i, 1)
    val digits = "0123456789"
    var d = 0
    while d < 10 and digits.substring(d, 1) != c {
      d = d + 1
    }
    if d == 10 {
      return n
    }
    n = n * 10 + d
    i = i + 1
  }
  return n
}

/// The rendered assistant text of the 40 captured events up to and
/// including `endSeq`, keeping the last 4000 characters.
func transcriptExcerpt(sessionId: in String, endSeq: in String): String {
  if not isDecimal(endSeq) {
    return ""
  }
  val last = parseDecimal(endSeq)
  var start = last - 40
  if start < -1 {
    start = -1
  }
  match CloudAgents.Repository.sessionEventsInRange(sessionId, toString(start), toString(last)) {
    case Ok(events) -> {
      val text = CloudAgents.Capture.Render.renderDisplayText(events)
      if text.length.toInt() > 4000 {
        return "…" + text.substring(text.length.toInt() - 4000, 4000)
      }
      return text
    }
    case Err(e) -> {
      println("WARNING: reading the ledger transcript excerpt failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      return ""
    }
  }
}

pub func entryDetail(ctx: in SessionContext, entryId: in String): Result[EntryDetail, LedgerFailure] {
  val e = match getEntry(ctx.sessionId, entryId) {
    case Ok(Some(x)) -> x
    case Ok(None) -> return Err(error = notFound("entry not found"))
    case Err(err) -> return Err(error = dbFail(err))
  }
  val allFeedback = match listFeedback(ctx.sessionId) {
    case Ok(fs) -> fs
    case Err(err) -> return Err(error = dbFail(err))
  }
  var fb: slice[Feedback] = []
  var i = 0
  while i < allFeedback.length.toInt() {
    if allFeedback[i].entryId == entryId {
      fb = fb.append(allFeedback[i])
    }
    i = i + 1
  }
  var transitions: slice[WorkItemTransition] = []
  if e.itemId.length.toInt() > 0 {
    transitions = match listTransitions(ctx.sessionId, e.itemId) {
      case Ok(ts) -> ts
      case Err(err) -> return Err(error = dbFail(err))
    }
  }
  val entries = match listEntries(ctx.sessionId) { case Ok(es) -> es; case Err(err) -> return Err(error = dbFail(err)) }
  var supersededBy: slice[String] = []
  var k = 0
  while k < entries.length.toInt() {
    if entries[k].supersedes == entryId {
      supersededBy = supersededBy.append(entries[k].id)
    }
    k = k + 1
  }
  return Ok(
    value = EntryDetail(
      ledgerEntry = e,
      feedback = fb,
      transitions = transitions,
      transcriptExcerpt = transcriptExcerpt(ctx.sessionId, e.transcriptSeq),
      supersededBy = supersededBy
    )
  )
}

/// A human review (approve / reject / comment) of an entry.
pub func review(
  ctx: in SessionContext, entryId: in String, kind: in String, body: in String, by: in String
): Result[Feedback, LedgerFailure] {
  val state = reviewStateForKind(kind)
  if state.length.toInt() == 0 {
    return Err(error = invalid("kind must be approve, reject or comment"))
  }
  check(validateFeedback(kind, body))?
  val e = match getEntry(ctx.sessionId, entryId) {
    case Ok(Some(x)) -> x
    case Ok(None) -> return Err(error = notFound("entry not found"))
    case Err(err) -> return Err(error = dbFail(err))
  }
  match reviewEntry(ctx.sessionId, e, state, kind, body, by) {
    case Ok(f) -> return Ok(value = f)
    case Err(err) -> return Err(error = dbFail(err))
  }
}

/// Session- or item-level human feedback (directive / comment).
pub func giveFeedback(
  ctx: in SessionContext, itemRef: in String, kind: in String, body: in String, by: in String
): Result[Feedback, LedgerFailure] {
  if kind != "directive" and kind != "comment" {
    return Err(error = invalid("kind must be directive or comment"))
  }
  check(validateFeedback(kind, body))?
  var itemId = ""
  if itemRef.trim().length.toInt() > 0 {
    itemId = normalizeRef(ctx, itemRef)?
    match getItem(ctx.sessionId, itemId) {
      case Ok(Some(_)) -> ()
      case Ok(None) -> return Err(error = notFound("item not found"))
      case Err(e) -> return Err(error = dbFail(e))
    }
  }
  match addFeedback(ctx.sessionId, itemId, kind, body, by) {
    case Ok(f) -> return Ok(value = f)
    case Err(e) -> return Err(error = dbFail(e))
  }
}

/// Pending undelivered feedback, for the next-run nudge.
pub func undeliveredFeedbackCount(sessionId: in String): Int {
  match pendingFeedbackCount(sessionId) {
    case Ok(n) -> return n
    case Err(e) -> {
      println("WARNING: counting ledger feedback failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      return 0
    }
  }
}

/// The prefix for the next run's prompt: a feedback nudge when the human
/// left undelivered feedback AND the session's profile exposes
/// ledger_check_feedback (an 'all'-mode profile, or 'selected' including
/// it), else "". The cloud-agents runner cannot inject a message into a
/// running agent, so the start of the next run is the push point
/// (docs/session-ledger.md §7). Best-effort: any lookup failure yields "".
pub func nextRunPromptPrefix(sessionId: in String, userId: in String, profileId: in String): String {
  val pending = undeliveredFeedbackCount(sessionId)
  if pending <= 0 {
    return ""
  }
  val enabled = match CloudAgents.Repository.enabledToolsForProfile(userId, profileId) {
    case Ok(v) -> v
    case Err(_) -> return ""
  }
  if enabled.length.toInt() > 0 and not containsString(splitOn(enabled, ","), "ledger_check_feedback") {
    return ""
  }
  return feedbackNudge(pending)
}

/// The line prepended to the next prompt when feedback is waiting, or "".
pub func feedbackNudge(pending: in Int): String {
  if pending <= 0 {
    return ""
  }
  return "[Session ledger] " + toString(pending) +
    " feedback item(s) from the human are waiting. Call ledger_check_feedback before doing anything else and apply them.\n\n"
}

@generate(Json)
pub record InboxView {
  pub entries: slice[InboxEntry]
}

pub func inbox(userId: in String): Result[InboxView, LedgerFailure] {
  match inboxForUser(userId) {
    case Ok(xs) -> return Ok(value = InboxView(entries = xs))
    case Err(e) -> return Err(error = dbFail(e))
  }
}
