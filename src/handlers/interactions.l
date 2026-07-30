package CloudAgents.Interactions

import Std.Core
import Web
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.Streaming
import CloudAgents.Text
import extern System.Environment as Env
import extern System.String as DotNetString

@generate(Json)
pub record AddCommentRequest {
  pub body: String
}

@generate(Json)
pub record AddTodoRequest {
  pub messageId: String
  pub note: String
}

val maxBodyLen = 32768

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

/// Return a session's full transcript (user prompts and agent replies), each
/// with a stable id so the client can anchor comments and todos to it.
pub func getMessages(id: in String): Result[MessageList, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  match listMessages(id) {
    case Ok(msgs) -> return Ok(MessageList(messages = msgs))
    case Err(e) -> return Err(dbError(e))
  }
}

/// Attach a comment to a specific message.
pub func addCommentHandler(mid: in String, req: in AddCommentRequest): Result[Comment, Web.ApiError] {
  if mid.length == 0 {
    return Err(Web.badRequest("message id is required"))
  }
  if req.body.length == 0 {
    return Err(Web.badRequest("body is required"))
  }
  // maxBodyLen bounds actual payload/storage size (memory pressure), so it
  // must be checked against UTF-8 byte size, not character count — a
  // char-count check alone lets a multi-byte-heavy body (CJK, emoji) land up
  // to ~4x over the stated budget (#64).
  if not CloudAgents.Text.withinMaxByteLength(req.body, maxBodyLen) {
    return Err(Web.badRequest("body is too long (max " + toString(maxBodyLen) + " bytes)"))
  }
  // Derive sessionId from the stored message rather than trusting the client.
  val sessionId = match getMessageSessionId(mid) {
    case Ok(Some(sid)) -> sid
    case Ok(None) -> return Err(Web.notFound("message not found"))
    case Err(e) -> return Err(dbError(e))
  }
  match addComment(mid, sessionId, req.body) {
    case Ok(c) -> return Ok(c)
    case Err(e) -> return Err(dbError(e))
  }
}

/// List comments on a message.
pub func getComments(mid: in String): Result[CommentList, Web.ApiError] {
  if mid.length == 0 {
    return Err(Web.badRequest("message id is required"))
  }
  match listComments(mid) {
    case Ok(cs) -> return Ok(CommentList(comments = cs))
    case Err(e) -> return Err(dbError(e))
  }
}

/// List a session's todos / bookmarks.
pub func getTodos(id: in String): Result[TodoList, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  match listTodos(id) {
    case Ok(ts) -> return Ok(TodoList(todos = ts))
    case Err(e) -> return Err(dbError(e))
  }
}

/// Create a todo / bookmark, optionally linked to a source message.
pub func addTodoHandler(id: in String, req: in AddTodoRequest): Result[Todo, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if req.note.length == 0 {
    return Err(Web.badRequest("note is required"))
  }
  // Same UTF-8-byte-size rationale as addCommentHandler above (#64).
  if not CloudAgents.Text.withinMaxByteLength(req.note, maxBodyLen) {
    return Err(Web.badRequest("note is too long (max " + toString(maxBodyLen) + " bytes)"))
  }
  // When the todo is anchored to a message, the anchor must exist and belong
  // to this session — otherwise todos can point at other sessions' transcripts
  // (or at nothing).
  if req.messageId.length > 0 {
    val ownerSid = match getMessageSessionId(req.messageId) {
      case Ok(Some(sid)) -> sid
      case Ok(None) -> return Err(Web.notFound("message not found"))
      case Err(e) -> return Err(dbError(e))
    }
    if ownerSid != id {
      return Err(Web.badRequest("messageId does not belong to this session"))
    }
  }
  match addTodo(id, req.messageId, req.note) {
    case Ok(t) -> return Ok(t)
    case Err(e) -> return Err(dbError(e))
  }
}

@generate(Json)
pub record SetTodoStatusRequest {
  pub status: String
}

/// Whether `s` is a valid three-state todo status literal. Shared by the
/// user-originated handler below and CloudAgents.Callbacks' container-
/// originated one.
pub func isValidTodoStatus(s: in String): Bool {
  return s == "pending" or s == "in_progress" or s == "done"
}

/// Set a todo's status directly (pending/in_progress/done) — the three-state
/// counterpart of toggleTodoHandler, used by the session todo panel.
pub func setTodoStatusHandler(tid: in String, req: in SetTodoStatusRequest): Result[Unit, Web.ApiError] {
  if tid.length == 0 {
    return Err(Web.badRequest("todo id is required"))
  }
  if not isValidTodoStatus(req.status) {
    return Err(Web.badRequest("status must be one of: pending, in_progress, done"))
  }
  match setTodoStatus(tid, req.status) {
    case Ok(_) -> return Ok(())
    case Err(e) -> return Err(dbError(e))
  }
}

/// Toggle a todo's done flag.
pub func toggleTodoHandler(tid: in String): Result[Unit, Web.ApiError] {
  if tid.length == 0 {
    return Err(Web.badRequest("todo id is required"))
  }
  match toggleTodo(tid) {
    case Ok(_) -> return Ok(())
    case Err(e) -> return Err(dbError(e))
  }
}

/// Delete a todo.
pub func deleteTodoHandler(tid: in String): Result[Unit, Web.ApiError] {
  if tid.length == 0 {
    return Err(Web.badRequest("todo id is required"))
  }
  match deleteTodo(tid) {
    case Ok(_) -> return Ok(())
    case Err(e) -> return Err(dbError(e))
  }
}

// ─── Agent checkbox-plan ingestion ─────────────────────────────────────────────
//
// Harness output often carries the agent's plan as a markdown checkbox list
// (`- [ ]` pending / `- [~]` in progress / `- [x]` done) — the shape
// docker/session-tools-guide.md prescribes as the fallback when the MCP
// todo tools aren't available or weren't called (older images, git-tracked
// config repos where the token guard skips registration), and the shape
// OpenCode's own todo tool renders. The frontend already
// parses it display-only (frontend/src/lib/agentPlan.ts); this is the
// server-side counterpart that materializes the LAST such list in a
// just-persisted agent message into real `todos` rows.
//
// Conservative by design:
//   - OFF unless CLOUD_AGENTS_INGEST_AGENT_PLAN=1 (the false-positive rate
//     of checkbox parsing on arbitrary agent output isn't established yet).
//   - Only lists of >= 2 items count (a lone checkbox is more likely quoted
//     output than a plan) — mirroring the frontend parser exactly.
//   - Ingested rows carry source='plan' and each re-ingest REPLACES only the
//     session's prior source='plan' rows; human- and tool-created todos
//     (source '') are never touched.
/// One parsed plan step, pre-storage.
pub record PlanItem {
  pub note: String
  /// 'pending' | 'in_progress' | 'done'
  pub status: String
}

func isDigit(c: in String): Bool {
  return c >= "0" and c <= "9"
}

func trimPlanSpaces(s: in String): String {
  var start = 0
  var stop = s.length.toInt()
  while start < stop {
    val c = s.substring(start, 1)
    if c == " " or c == "\t" or c == "\r" {
      start = start + 1
    } else {
      return trimPlanSpacesEnd(s, start, stop)
    }
  }
  return ""
}

func trimPlanSpacesEnd(s: in String, start: in Int, stopIn: in Int): String {
  var stop = stopIn
  while stop > start {
    val c = s.substring(stop - 1, 1)
    if c == " " or c == "\t" or c == "\r" {
      stop = stop - 1
    } else {
      return s.substring(start, stop - start)
    }
  }
  return ""
}

/// Parse one trimmed line as a checkbox plan item: a REQUIRED list bullet
/// (`-`/`*`/`+`, or `1.`/`1)` numbering — trailing space optional, matching
/// the frontend regex's `\s*`), then `[<marker>]`, at least one whitespace
/// (also matching the frontend's `\s+`), and non-empty item text. None for
/// anything else — in particular a bare `[ ] item` with no bullet is
/// rejected, exactly as the frontend's mandatory `(?:[-*+]|\d+[.)])` group
/// rejects it (#790): a bullet-less checkbox is more likely quoted code
/// than a plan, and the two parsers must agree on what gets ingested vs
/// displayed. Marker mapping mirrors the frontend parser: ' ' pending, '~'
/// in progress, x/X/✓ done. Kept aligned with frontend/src/lib/agentPlan.ts
/// (#784) — change both together.
func parsePlanLine(line: in String): Option[PlanItem] {
  var i = 0
  val n = line.length.toInt()
  // REQUIRED bullet: a single '-'/'*'/'+' or digits followed by "." or ")".
  if n >= 1 and (line.substring(0, 1) == "-" or line.substring(0, 1) == "*" or line.substring(0, 1) == "+") {
    i = 1
  } else {
    var d = 0
    while d < n and isDigit(line.substring(d, 1)) {
      d = d + 1
    }
    if d > 0 and d < n and (line.substring(d, 1) == "." or line.substring(d, 1) == ")") {
      i = d + 1
    } else {
      return None
    }
  }
  // Optional whitespace between bullet and the checkbox — spaces AND tabs,
  // matching the frontend's `\s*` (#807).
  while i < n and (line.substring(i, 1) == " " or line.substring(i, 1) == "\t") {
    i = i + 1
  }
  if i + 2 >= n or line.substring(i, 1) != "[" {
    return None
  }
  val marker = line.substring(i + 1, 1)
  if line.substring(i + 2, 1) != "]" {
    return None
  }
  val status = if marker == " " {
    "pending"
  } else if marker == "~" {
    "in_progress"
  } else if marker == "x" or marker == "X" or marker == "✓" {
    "done"
  } else {
    return None
  }
  // At least one whitespace between "]" and the text (frontend's `\s+`):
  // "[x]crammed" is more likely quoted code than a plan item.
  if i + 3 >= n {
    return None
  }
  val after = line.substring(i + 3, 1)
  if after != " " and after != "\t" {
    return None
  }
  val text = trimPlanSpaces(line.substring(i + 3, n - i - 3))
  if text.length == 0 {
    return None
  }
  return Some(value = PlanItem(note = text, status = status))
}

/// Strip ANSI SGR escape sequences (ESC '[' [0-9;]* 'm' — exactly the
/// frontend's /\x1b\[[0-9;]*m/ pattern, #794) from `s`. Agent output is
/// stored WITH its ANSI codes (CloudAgents.Streaming deliberately leaves
/// them for the frontend to render), so a colorized checkbox line would
/// otherwise fail to parse server-side while parsing fine client-side. A
/// non-SGR escape (no terminating 'm') is kept literally, matching the
/// regex. ESC can't appear in a Lyric string literal, so it comes from
/// CloudAgents.Streaming.charFromCode — the same helper streaming's own
/// control-character handling uses. Two-level accumulation keeps this
/// linear-ish on full-run logs (the readAll idiom, #423).
func stripAnsiSgr(s: in String): String {
  val esc = CloudAgents.Streaming.charFromCode(27)
  var acc = ""
  var chunk = ""
  var i = 0
  val n = s.length.toInt()
  while i < n {
    val c = s.substring(i, 1)
    if c == esc and i + 1 < n and s.substring(i + 1, 1) == "[" {
      var j = i + 2
      while j < n and (isDigit(s.substring(j, 1)) or s.substring(j, 1) == ";") {
        j = j + 1
      }
      if j < n and s.substring(j, 1) == "m" {
        i = j + 1
        continue
      }
    }
    chunk = chunk + c
    if chunk.length >= 1024 {
      acc = acc + chunk
      chunk = ""
    }
    i = i + 1
  }
  return acc + chunk
}

/// Only the LAST maxPlanScanChars of a message are scanned (#809): the
/// session-tools guide tells agents to restate their plan at the END of
/// each response, a full run log can be megabytes, and the frontend parser
/// applies the same cap so the two stay in lockstep on what counts as "the
/// plan". Keep in sync with agentPlan.ts's PLAN_SCAN_TAIL_CHARS.
val maxPlanScanChars = 32768

func planScanTail(content: in String): String {
  val n = content.length.toInt()
  if n <= maxPlanScanChars {
    return content
  }
  return content.substring(n - maxPlanScanChars, maxPlanScanChars)
}

/// Zip parallel note/status slices back into PlanItem records. Split out of
/// parseAgentPlan as a compiler-bug workaround, not style: `slice[record]
/// .append` inside a method whose loop runs long enough for .NET OSR
/// promotion miscompiles and crashes (OverflowException / IndexOutOfRange /
/// fatal AccessViolation in StelemRef —
/// https://github.com/nichobbs/lyric-lang/issues/6322). The char-scan loop
/// in parseAgentPlan iterates up to maxPlanScanChars times, comfortably
/// past the OSR threshold, so it must only append STRINGS (unaffected);
/// the record appends live here, where the loop is bounded by the plan's
/// item count and never gets promoted.
func planItemsOf(notes: in slice[String], statuses: in slice[String]): slice[PlanItem] {
  var items: slice[PlanItem] = []
  var i = 0
  while i < notes.length and i < statuses.length {
    items = items.append(PlanItem(note = notes[i], status = statuses[i]))
    i = i + 1
  }
  return items
}

/// The LAST contiguous checkbox list in `content`, or [] when none (or when
/// the last list has fewer than 2 items). "Last" because agents restate
/// their plan as they update it — the final statement is the current one.
/// Blank lines inside a list are tolerated; any other line ends it. Only
/// the message tail is scanned (#809) and ANSI SGR codes are stripped
/// first, exactly like the frontend (#794). Pure and unit-tested; mirrors
/// frontend/src/lib/agentPlan.ts.
/// Accumulates parallel STRING slices in the scan loop and zips them into
/// records only afterwards (planItemsOf) — see lyric-lang#6322 for why a
/// record append inside this hot loop would crash at runtime.
pub func parseAgentPlan(rawContent: in String): slice[PlanItem] {
  val content = stripAnsiSgr(planScanTail(rawContent))
  var lastNotes: slice[String] = []
  var lastStatuses: slice[String] = []
  var currentNotes: slice[String] = []
  var currentStatuses: slice[String] = []
  var lineStart = 0
  val n = content.length.toInt()
  var i = 0
  while i <= n {
    if i == n or content.substring(i, 1) == "\n" {
      val line = trimPlanSpaces(content.substring(lineStart, i - lineStart))
      lineStart = i + 1
      match parsePlanLine(line) {
        case Some(item) -> {
          currentNotes = currentNotes.append(item.note)
          currentStatuses = currentStatuses.append(item.status)
        }
        case None -> {
          if currentNotes.length > 0 and line.length > 0 {
            if currentNotes.length >= 2 {
              lastNotes = currentNotes
              lastStatuses = currentStatuses
            }
            currentNotes = []
            currentStatuses = []
          }
        }
      }
    }
    i = i + 1
  }
  if currentNotes.length >= 2 {
    lastNotes = currentNotes
    lastStatuses = currentStatuses
  }
  return planItemsOf(lastNotes, lastStatuses)
}

/// Whether server-side plan ingestion is enabled (off by default — see the
/// section comment above).
pub func planIngestEnabled(): Bool {
  val raw = Env.GetEnvironmentVariable("CLOUD_AGENTS_INGEST_AGENT_PLAN")
  if DotNetString.IsNullOrEmpty(raw) {
    return false
  }
  return raw == "1"
}

/// Materialize the checkbox plan in a just-persisted agent message into
/// `todos` rows: parse (>= 2 items or nothing happens), then replace the
/// session's prior source='plan' rows with the new ones (anchored to
/// `messageId`) in one transaction — a partial failure can never leave the
/// plan half-replaced (#791). Returns how many items were ingested. The
/// caller (CloudAgents.Handlers' post-run persist path) treats this as
/// best-effort.
/// Ingestion-side storage caps (#825): the display parser stays uncapped
/// (parity with the frontend), but rows headed for the todos table respect
/// the same note byte limit the todo handlers enforce, and a "plan" longer
/// than this many steps is treated as parser noise, not a plan.
val maxPlanIngestItems = 50

pub func ingestAgentPlan(
  sessionId: in String, messageId: in String, content: in String
): Result[Int, CloudAgents.Sqlite.DbError] {
  val items = parseAgentPlan(content)
  if items.length < 2 {
    return Ok(value = 0)
  }
  // Storage-bound filtering (#825): drop over-long notes (same maxBodyLen
  // the addTodo handlers enforce, byte-measured) and cap the item count.
  var notes: slice[String] = []
  var statuses: slice[String] = []
  var i = 0
  var kept = 0
  while i < items.length and kept < maxPlanIngestItems {
    if CloudAgents.Text.withinMaxByteLength(items[i].note, maxBodyLen) {
      notes = notes.append(items[i].note)
      statuses = statuses.append(items[i].status)
      kept = kept + 1
    }
    i = i + 1
  }
  if kept < 2 {
    return Ok(value = 0)
  }
  CloudAgents.Repository.replacePlanTodos(sessionId, messageId, notes, statuses)?
  return Ok(value = kept)
}
