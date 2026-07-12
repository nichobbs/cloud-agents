package CloudAgents.Interactions

import Std.Core
import Web
import CloudAgents.Repository
import CloudAgents.Sqlite
import CloudAgents.Text

@generate(Json)
pub record AddCommentRequest {
  pub body: String
}

@generate(Json)
pub record AddTodoRequest {
  pub messageId: String
  pub note: String
}

val maxBodyLen: Nat = 32768

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
  match CloudAgents.Text.checkMaxLength(req.body, maxBodyLen, "body") {
    case Err(e) -> return Err(e)
    case Ok(_) -> ()
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
  match CloudAgents.Text.checkMaxLength(req.note, maxBodyLen, "note") {
    case Err(e) -> return Err(e)
    case Ok(_) -> ()
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
