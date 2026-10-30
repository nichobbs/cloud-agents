//! HTTP handlers for importing findings about Claude Code cloud sessions that
//! cloud-agents did not run (docs/claude-session-import.md §5, §6, §7).
//!
//! `/api/imports/claude/*` is called by the importer, a Claude session
//! holding an import token: the auth middleware has already resolved the
//! token and stamped its user and tenant, and these handlers refuse any other
//! caller. `/api/imports/tokens*` and `/api/imports/tombstones/*` are for the
//! signed-in owner, to manage tokens and re-allow a deleted session.
//! Everything is off unless `CLOUDAGENTS_IMPORTS_ENABLED=1`.
package CloudAgents.ImportHandlers

import Std.Core
import Std.Environment
import Web
import CloudAgents.Auth
import CloudAgents.Scope
import CloudAgents.Streaming
import CloudAgents.Repository
import CloudAgents.Db
import CloudAgents.PgStore.Imports
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Reconcile
import CloudAgents.Ledger.Service
import CloudAgents.Ledger.Store
import CloudAgents.Ledger.Observer
import CloudAgents.Ledger.ToolArgs
import CloudAgents.Ledger.Import

@generate(Json)
pub record CreateImportTokenRequest {
  pub label: String
}

/// A response with its own status, for the findings POST, whose 409 carries
/// the stored cursor (§6.3).
pub record ImportHttpReply {
  pub status: Int
  pub body: String
}

// ── Config ───────────────────────────────────────────────────────────────────
func intEnv(name: in String, fallback: in Int): Int {
  val v = Std.Environment.getVarOrDefault(name, "").trim()
  if v.length.toInt() == 0 {
    return fallback
  }
  return match tryParseInt(v) {
    case Ok(n) -> if n > 0 then n else fallback
    case Err(_) -> fallback
  }
}

pub func importsEnabled(): Bool {
  return Std.Environment.getVarOrDefault("CLOUDAGENTS_IMPORTS_ENABLED", "") == "1"
}

func maxSessionsPerRun(): Int {
  return intEnv("CLOUDAGENTS_IMPORT_MAX_SESSIONS_PER_RUN", 5)
}

func maxEventsPerChunk(): Int {
  return intEnv("CLOUDAGENTS_IMPORT_MAX_EVENTS_PER_CHUNK", 200)
}

func settleMinutes(): Int {
  return intEnv("CLOUDAGENTS_IMPORT_SETTLE_MINUTES", 60)
}

func maxChunksPerHour(): Int {
  return intEnv("CLOUDAGENTS_IMPORT_MAX_CHUNKS_PER_HOUR", 120)
}

func restartCooldownHours(): Int {
  return intEnv("CLOUDAGENTS_IMPORT_RESTART_COOLDOWN_HOURS", 24)
}

func restartDedupPct(): Int {
  return intEnv("CLOUDAGENTS_IMPORT_RESTART_DEDUP_PCT", 50)
}

pub func maxBodyBytes(): Int {
  return intEnv("CLOUDAGENTS_IMPORT_MAX_BODY_BYTES", 524288)
}

/// How many existing findings a re-importing session lists (§4.3).
pub val maxKnownFindings: Int = 200

// ── JSON ─────────────────────────────────────────────────────────────────────
func str(s: in String): String {
  return "\"" + CloudAgents.Streaming.jsonEscape(s) + "\""
}

func boolJson(b: in Bool): String {
  return if b then "true" else "false"
}

func commaJoin(parts: in slice[String]): String {
  var acc = ""
  var i = 0
  while i < parts.length.toInt() {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + parts[i]
    i = i + 1
  }
  return acc
}

func errJson(message: in String): String {
  return "{\"error\":" + str(message) + "}"
}

func reply(status: in Int, body: in String): ImportHttpReply {
  return ImportHttpReply(status = status, body = body)
}

func dbReply(e: in CloudAgents.Db.DbError): ImportHttpReply {
  println("ERROR: claude session import store: " + CloudAgents.Db.dbErrorMessage(e))
  return reply(500, errJson("database unavailable"))
}

func dbError(e: in CloudAgents.Db.DbError): Web.ApiError {
  println("ERROR: claude session import store: " + CloudAgents.Db.dbErrorMessage(e))
  return Web.internalError("database unavailable")
}

func tokenJson(t: in ImportTokenInfo): String {
  return "{\"id\":" + str(t.id) + ",\"label\":" + str(t.label) + ",\"createdAt\":" + str(t.createdAt) + ",\"lastUsedAt\":" +
    str(t.lastUsedAt) +
    ",\"revoked\":" +
    boolJson(t.revoked) +
    "}"
}

// ── Guards ───────────────────────────────────────────────────────────────────
/// A CCR session id as the importer sends it: `session_…` or `cse_…`, then
/// letters, digits and underscores, at most 100 characters.
pub func isValidCcrSessionId(id: in String): Bool {
  if id.length.toInt() > 100 or not (id.startsWith("session_") or id.startsWith("cse_")) {
    return false
  }
  val allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
  var i = 0
  while i < id.length.toInt() {
    if not allowed.contains(id.substring(i, 1)) {
      return false
    }
    i = i + 1
  }
  return true
}

/// The session a request would change, when it is one an imported (read-only)
/// session must refuse (§7.1): sending a message, starting or cancelling a
/// run, branching, changing the model, profile or repos, opening a PR, and
/// the ledger actions that act on a live run. Archiving, grouping, marking
/// viewed and reviewing ledger entries stay allowed. "" for anything else.
pub func readOnlyGuardedSessionId(method: in String, path: in String): String {
  if method != "POST" and method != "PUT" and method != "PATCH" {
    return ""
  }
  val prefix = "/api/sessions/"
  if not path.startsWith(prefix) {
    return ""
  }
  val rest = path.substring(prefix.length.toInt(), path.length.toInt() - prefix.length.toInt())
  val slash = rest.indexOf("/")
  if slash <= 0 {
    return ""
  }
  val sessionId = rest.substring(0, slash)
  val action = rest.substring(slash + 1, rest.length.toInt() - slash - 1)
  val guarded = [
    "messages", "cancel", "restart", "branch", "model", "profile", "repos", "open-pr", "todos", "highlights/refresh",
    "ledger/observe", "ledger/sync", "ledger/items", "ledger/item-state", "ledger/feedback"
  ]
  var k = 0
  while k < guarded.length.toInt() {
    if action == guarded[k] {
      return sessionId
    }
    k = k + 1
  }
  return ""
}

/// None when the request may proceed; otherwise the refusal. Called by the
/// auth middleware once the caller is known.
pub func readOnlyRefusal(method: in String, path: in String): Option[Web.ApiError] {
  val sid = readOnlyGuardedSessionId(method, path)
  if sid.length.toInt() == 0 {
    return None
  }
  return match isImportedSession(CloudAgents.Auth.requestScope(), sid) {
    case Ok(true) -> Some(value = Web.conflict("this session was imported from Claude Code and is read-only"))
    case Ok(false) -> None
    case Err(e) -> Some(value = dbError(e))
  }
}

func requireImporter(): Result[String, Web.ApiError] {
  if not importsEnabled() {
    return Err(error = Web.notFound("not found"))
  }
  val tokenId = CloudAgents.Auth.currentImportTokenId()
  if tokenId.length.toInt() == 0 {
    return Err(error = Web.forbidden("this endpoint needs an import token"))
  }
  return Ok(value = tokenId)
}

func requireOwner(): Result[Unit, Web.ApiError] {
  if not importsEnabled() {
    return Err(error = Web.notFound("not found"))
  }
  if CloudAgents.Auth.currentImportTokenId().length.toInt() > 0 {
    return Err(error = Web.forbidden("an import token cannot manage imports"))
  }
  return Ok(value = ())
}

// ── Importer endpoints ───────────────────────────────────────────────────────
func cursorJson(c: in ImportCursor, known: in slice[KnownFinding]): String {
  var acc = "{\"ccrSessionId\":" + str(c.ccrSessionId) + ",\"throughEventId\":" + str(c.throughEventId) + ",\"throughOrdinal\":" +
    toString(c.throughOrdinal) +
    ",\"lastEventAt\":" +
    str(c.lastEventAt) +
    ",\"restarting\":" +
    boolJson(c.restartUntilOrdinal >= 0.toLong()) +
    ",\"deleted\":" +
    boolJson(c.deleted)
  if c.restartUntilOrdinal >= 0.toLong() {
    var parts: slice[String] = []
    for f in known {
      parts = parts.append("{\"kind\":" + str(f.kind) + ",\"summary\":" + str(f.summary) + "}")
    }
    acc = acc + ",\"knownFindings\":[" + commaJoin(parts) + "]"
  }
  return acc + "}"
}

/// `GET /api/imports/claude/state` (§6.1): budgets and every imported
/// session's cursor.
pub func importStateHandler(): Result[String, Web.ApiError] {
  requireImporter()?
  val sc = CloudAgents.Auth.requestScope()
  val cursors = match listImportCursors(sc) {
    case Ok(v) -> v
    case Err(e) -> return Err(error = dbError(e))
  }
  var parts: slice[String] = []
  for c in cursors {
    var known: slice[KnownFinding] = []
    if c.restartUntilOrdinal >= 0.toLong() and c.sessionId.length.toInt() > 0 {
      known = match knownFindings(sc, c.sessionId, maxKnownFindings) {
        case Ok(v) -> v
        case Err(e) -> return Err(error = dbError(e))
      }
    }
    parts = parts.append(cursorJson(c, known))
  }
  return Ok(
    value = "{\"budgets\":{\"maxSessionsPerRun\":" + toString(maxSessionsPerRun()) + ",\"maxEventsPerChunk\":" +
      toString(maxEventsPerChunk()) +
      ",\"settleMinutes\":" +
      toString(settleMinutes()) +
      "},\"sessions\":[" +
      commaJoin(parts) +
      "]}"
  )
}

/// `GET /api/imports/claude/prompt` (§6.2): the extraction instructions.
pub func importPromptHandler(): Result[String, Web.ApiError] {
  requireImporter()?
  return Ok(value = importerPrompt())
}

func parseOrdinal(s: in String): Long {
  if s.length.toInt() == 0 {
    return -1.toLong()
  }
  return match tryParseLong(s) {
    case Ok(v) -> v
    case Err(_) -> -1.toLong()
  }
}

func countsJson(sessionId: in String, d: in ImportDecision, through: in Long): String {
  return "{\"localSessionId\":" + str(sessionId) + ",\"undeclared\":" + toString(d.undeclared) + ",\"duplicates\":" +
    toString(d.duplicates) +
    ",\"dropped\":" +
    toString(d.dropped) +
    ",\"throughOrdinal\":" +
    toString(through) +
    "}"
}

func conflictJson(message: in String, c: in Option[ImportCursor]): String {
  return match c {
    case Some(x) -> "{\"error\":" + str(message) + ",\"throughEventId\":" + str(x.throughEventId) + ",\"throughOrdinal\":" +
      toString(x.throughOrdinal) +
      "}"
    case None -> "{\"error\":" + str(message) + ",\"throughEventId\":\"\",\"throughOrdinal\":-1}"
  }
}

/// Whether a restart started at `lastRestartAtMs` (epoch-millisecond text,
/// "" for never) is still inside the cooldown.
pub func inRestartCooldown(lastRestartAtMs: in String, nowMs: in Long, cooldownHours: in Int): Bool {
  if lastRestartAtMs.length.toInt() == 0 {
    return false
  }
  val last = parseOrdinal(lastRestartAtMs)
  if last < 0.toLong() {
    return false
  }
  return nowMs - last < cooldownHours.toLong() * 3600000.toLong()
}

/// `POST /api/imports/claude/sessions/{ccrSessionId}/findings` (§6.3).
pub func importFindingsHandler(ccrSessionId: in String, body: in String): ImportHttpReply {
  val tokenId = match requireImporter() {
    case Ok(t) -> t
    case Err(e) -> return reply(e.status, errJson(e.message))
  }
  if body.length.toInt() > maxBodyBytes() {
    return reply(413, errJson("the request body is over " + toString(maxBodyBytes()) + " bytes; split the chunk and retry"))
  }
  if not isValidCcrSessionId(ccrSessionId) {
    return reply(400, errJson("ccrSessionId must be a Claude Code session id (session_… or cse_…)"))
  }
  val env = match decodeImportEnvelope(body) {
    case Ok(v) -> v
    case Err(e) -> return reply(400, errJson(e))
  }
  val candidates = match decodeObserverReport(body) {
    case Ok(v) -> v
    case Err(e) -> return reply(422, errJson(e))
  }
  val from = parseOrdinal(env.fromOrdinal)
  val through = parseOrdinal(env.throughOrdinal)
  if from < 0.toLong() or through < from {
    return reply(400, errJson("fromOrdinal and throughOrdinal must be ordinals with fromOrdinal <= throughOrdinal"))
  }
  if through - from + 1.toLong() > maxEventsPerChunk().toLong() {
    return reply(400, errJson("a chunk covers at most " + toString(maxEventsPerChunk()) + " events"))
  }
  if env.throughEventId.length.toInt() == 0 {
    return reply(400, errJson("throughEventId is required"))
  }
  if env.resync != "" and env.resync != "realign" and env.resync != "restart" {
    return reply(400, errJson("resync must be \"realign\" or \"restart\""))
  }
  val sc = CloudAgents.Auth.requestScope()
  val stored = match getImportCursor(sc, ccrSessionId) {
    case Ok(v) -> v
    case Err(e) -> return dbReply(e)
  }
  var oldThrough = -1.toLong()
  var restartUntil = -1.toLong()
  var lastRestartAt = ""
  var storedEventId = ""
  match stored {
    case Some(c) -> {
      if c.deleted {
        return reply(410, errJson("this session's import was deleted; skip it"))
      }
      // A replay of the chunk last accepted changes nothing.
      if c.throughEventId == env.throughEventId and c.throughOrdinal == through and c.lastCounts.length.toInt() > 0 {
        return reply(200, c.lastCounts)
      }
      oldThrough = c.throughOrdinal
      restartUntil = c.restartUntilOrdinal
      lastRestartAt = c.lastRestartAt
      storedEventId = c.throughEventId
    }
    case None -> ()
  }
  var restarting = false
  var startedRestart = false
  if env.resync == "restart" {
    if from != 0.toLong() {
      return reply(400, errJson("a restart starts at fromOrdinal 0"))
    }
    if inRestartCooldown(lastRestartAt, CloudAgents.Repository.nowMillisLong(), restartCooldownHours()) {
      return reply(429, errJson("this session was restarted recently; try again after the cooldown"))
    }
    restarting = true
    startedRestart = oldThrough >= 0.toLong()
  } else if env.resync == "realign" {
    if storedEventId.length.toInt() == 0 or env.afterEventId != storedEventId {
      return reply(409, conflictJson("realign needs afterEventId to be the stored throughEventId", stored))
    }
  } else if from != oldThrough + 1.toLong() {
    return reply(409, conflictJson("expected fromOrdinal " + toString(oldThrough + 1.toLong()), stored))
  } else {
    restarting = restartUntil >= 0.toLong() and from <= restartUntil
  }
  match takeChunkSlot(tokenId, maxChunksPerHour()) {
    case Ok(true) -> ()
    case Ok(false) -> return reply(429, errJson("this import token is over its hourly chunk cap"))
    case Err(e) -> return dbReply(e)
  }
  val info = ImportedSessionInfo(
    title = env.title,
    repoUrl = env.repoUrl,
    branch = env.branch,
    createdAt = env.createdAt,
    updatedAt = env.updatedAt
  )
  val sessionId = match ensureImportedSession(sc, ccrSessionId, info) {
    case Ok(v) -> v
    case Err(e) -> return dbReply(e)
  }
  val target = SessionContext(sessionId = sessionId, ownerUserId = sc.userId, ownerRepo = "", tenantScope = sc)
  val existing = match listEntries(sessionId, sc) {
    case Ok(v) -> v
    case Err(e) -> return dbReply(e)
  }
  val chunk = ImportChunk(
    fromOrdinal = from,
    throughOrdinal = through,
    restarting = restarting,
    backfill = env.backfill == "true",
    candidates = candidates
  )
  val decision = acceptImportChunk(target, chunk, existing, defaultReconcileConfig(), restartDedupPct())
  if decision.problem.length.toInt() > 0 {
    return reply(422, errJson(decision.problem))
  }
  for e in decision.toInsert {
    match insertEntry(sc, e) {
      case Ok(_) -> ()
      case Err(err) -> return dbReply(err)
    }
  }
  for c in decision.notify {
    notify(target, c)
  }
  // The re-import ends once it has caught up with the old cursor.
  var nextRestartUntil = -2.toLong()
  if startedRestart {
    nextRestartUntil = if through >= oldThrough then -1.toLong() else oldThrough
  } else if restartUntil >= 0.toLong() and through >= restartUntil {
    nextRestartUntil = -1.toLong()
  }
  val counts = countsJson(sessionId, decision, through)
  match advanceImportCursor(sc, ccrSessionId, env.throughEventId, through, env.lastEventAt, counts, nextRestartUntil, startedRestart) {
    case Ok(_) -> ()
    case Err(e) -> return dbReply(e)
  }
  return reply(200, counts)
}

// ── Owner endpoints ──────────────────────────────────────────────────────────
/// `GET /api/imports/tokens`: the caller's import tokens in the current organisation.
pub func listImportTokensHandler(): Result[String, Web.ApiError] {
  requireOwner()?
  val sc = CloudAgents.Auth.requestScope()
  val tokens = match listImportTokens(sc.userId, sc.tenantId) {
    case Ok(v) -> v
    case Err(e) -> return Err(error = dbError(e))
  }
  var parts: slice[String] = []
  for t in tokens {
    parts = parts.append(tokenJson(t))
  }
  return Ok(value = "{\"tokens\":[" + commaJoin(parts) + "]}")
}

/// `POST /api/imports/tokens`: a new token, shown once.
pub func createImportTokenHandler(req: in CreateImportTokenRequest): Result[String, Web.ApiError] {
  requireOwner()?
  val label = req.label.trim()
  if label.length.toInt() == 0 or label.length.toInt() > maxLabelLen {
    return Err(error = Web.badRequest("label must be 1 to " + toString(maxLabelLen) + " characters"))
  }
  val sc = CloudAgents.Auth.requestScope()
  return match createImportToken(sc.userId, sc.tenantId, label) {
    case Ok(Some(c)) -> Ok(value = "{\"token\":" + tokenJson(c.info) + ",\"secret\":" + str(c.token) + "}")
    case Ok(None) -> Err(error = Web.forbidden("you are not an active member of this organisation"))
    case Err(e) -> Err(error = dbError(e))
  }
}

/// `DELETE /api/imports/tokens/{id}`: revoke one of the caller's tokens.
pub func revokeImportTokenHandler(id: in String): Result[Unit, Web.ApiError] {
  requireOwner()?
  val sc = CloudAgents.Auth.requestScope()
  return match revokeImportToken(sc.userId, sc.tenantId, id) {
    case Ok(true) -> Ok(value = ())
    case Ok(false) -> Err(error = Web.notFound("no such import token"))
    case Err(e) -> Err(error = dbError(e))
  }
}

/// `DELETE /api/imports/tombstones/{ccrSessionId}`: let a deleted imported
/// session be imported again.
pub func clearImportTombstoneHandler(ccrSessionId: in String): Result[Unit, Web.ApiError] {
  requireOwner()?
  return match clearImportTombstone(CloudAgents.Auth.requestScope(), ccrSessionId) {
    case Ok(true) -> Ok(value = ())
    case Ok(false) -> Err(error = Web.notFound("no deleted import for that session"))
    case Err(e) -> Err(error = dbError(e))
  }
}
