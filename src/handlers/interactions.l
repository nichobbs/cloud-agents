package CloudAgents.Interactions

import Std.Core
import Web
import CloudAgents.Repository
import CloudAgents.Sqlite
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
// docker/session-tools-guide.md prescribes for harnesses without the MCP
// shim, and the shape OpenCode's own todo tool renders. The frontend already
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

/// Parse one trimmed line as a checkbox plan item: an optional list bullet
/// (`- `, `* `, `+ `, or `1.`/`1)` numbering), then `[<marker>]`, a space,
/// and the item text. None for anything else. Marker mapping mirrors the
/// frontend parser: ' ' pending, '~' in progress, x/X/✓ done.
func parsePlanLine(line: in String): Option[PlanItem] {
  var i = 0
  val n = line.length.toInt()
  // Optional bullet: "- " / "* " / "+ " or digits followed by "." or ")".
  if n >= 2 and (line.substring(0, 2) == "- " or line.substring(0, 2) == "* " or line.substring(0, 2) == "+ ") {
    i = 2
  } else {
    var d = 0
    while d < n and isDigit(line.substring(d, 1)) {
      d = d + 1
    }
    if d > 0 and d < n and (line.substring(d, 1) == "." or line.substring(d, 1) == ")") {
      i = d + 1
    }
  }
  // Optional spaces between bullet and the checkbox.
  while i < n and line.substring(i, 1) == " " {
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
  val text = trimPlanSpaces(line.substring(i + 3, n - i - 3))
  if text.length == 0 {
    return None
  }
  return Some(value = PlanItem(note = text, status = status))
}

/// The LAST contiguous checkbox list in `content`, or [] when none (or when
/// the last list has fewer than 2 items). "Last" because agents restate
/// their plan as they update it — the final statement is the current one.
/// Blank lines inside a list are tolerated; any other line ends it. Pure and
/// unit-tested; mirrors frontend/src/lib/agentPlan.ts.
pub func parseAgentPlan(content: in String): slice[PlanItem] {
  var last: slice[PlanItem] = []
  var current: slice[PlanItem] = []
  var lineStart = 0
  val n = content.length.toInt()
  var i = 0
  while i <= n {
    if i == n or content.substring(i, 1) == "\n" {
      val line = trimPlanSpaces(content.substring(lineStart, i - lineStart))
      lineStart = i + 1
      match parsePlanLine(line) {
        case Some(item) -> {
          current = current.append(item)
        }
        case None -> {
          if current.length > 0 and line.length > 0 {
            if current.length >= 2 {
              last = current
            }
            current = []
          }
        }
      }
    }
    i = i + 1
  }
  if current.length >= 2 {
    last = current
  }
  return last
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
/// `todos` rows: parse (>= 2 items or nothing happens), replace the
/// session's prior source='plan' rows, insert the new ones anchored to
/// `messageId`. Returns how many items were ingested. The caller
/// (CloudAgents.Handlers' post-run persist path) treats this as best-effort.
pub func ingestAgentPlan(
  sessionId: in String, messageId: in String, content: in String
): Result[Int, CloudAgents.Sqlite.DbError] {
  val items = parseAgentPlan(content)
  if items.length < 2 {
    return Ok(value = 0)
  }
  CloudAgents.Repository.deletePlanTodos(sessionId)?
  var i = 0
  while i < items.length {
    val it = items[i]
    CloudAgents.Repository.addPlanTodo(sessionId, messageId, it.note, it.status)?
    i = i + 1
  }
  return Ok(value = items.length.toInt())
}
