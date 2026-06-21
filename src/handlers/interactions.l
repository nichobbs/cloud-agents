package CloudAgents.Interactions

import Std.Core
import Web
import CloudAgents.Repository
import CloudAgents.Sqlite

@generate(Json)
pub record AddCommentRequest {
  pub sessionId: String
  pub body: String
}

@generate(Json)
pub record AddTodoRequest {
  pub messageId: String
  pub note: String
}

func dbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

/// Return a session's full transcript (user prompts and agent replies), each
/// with a stable id so the client can anchor comments and todos to it.
@get("/api/sessions/{id}/messages")
pub func getMessages(id: in String): Result[MessageList, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  match listMessages(id) {
    case Ok(msgs) -> return Ok(MessageList(messages = msgs))
    case Err(e)   -> return Err(dbError(e))
  }
}

/// Attach a comment to a specific message.
@post("/api/messages/{mid}/comments")
pub func addCommentHandler(
  mid: in String,
  @body req: in AddCommentRequest
): Result[Comment, Web.ApiError] {
  if mid.length == 0 {
    return Err(Web.badRequest("message id is required"))
  }
  if req.body.length == 0 {
    return Err(Web.badRequest("body is required"))
  }
  match addComment(mid, req.sessionId, req.body) {
    case Ok(c)  -> return Ok(c)
    case Err(e) -> return Err(dbError(e))
  }
}

/// List comments on a message.
@get("/api/messages/{mid}/comments")
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
@get("/api/sessions/{id}/todos")
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
@post("/api/sessions/{id}/todos")
pub func addTodoHandler(
  id: in String,
  @body req: in AddTodoRequest
): Result[Todo, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if req.note.length == 0 {
    return Err(Web.badRequest("note is required"))
  }
  match addTodo(id, req.messageId, req.note) {
    case Ok(t)  -> return Ok(t)
    case Err(e) -> return Err(dbError(e))
  }
}

/// Toggle a todo's done flag.
@post("/api/todos/{tid}/toggle")
pub func toggleTodoHandler(tid: in String): Result[Unit, Web.ApiError] {
  if tid.length == 0 {
    return Err(Web.badRequest("todo id is required"))
  }
  match toggleTodo(tid) {
    case Ok(_)  -> return Ok(())
    case Err(e) -> return Err(dbError(e))
  }
}

/// Delete a todo.
@delete("/api/todos/{tid}")
pub func deleteTodoHandler(tid: in String): Result[Unit, Web.ApiError] {
  if tid.length == 0 {
    return Err(Web.badRequest("todo id is required"))
  }
  match deleteTodo(tid) {
    case Ok(_)  -> return Ok(())
    case Err(e) -> return Err(dbError(e))
  }
}
