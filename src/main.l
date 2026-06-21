package CloudAgents

import Std.Core
import Web
import CloudAgents.Repository
import CloudAgents.Sqlite

func main(): Unit {
  // Ensure the SQLite transcript/comments/todos tables exist before serving.
  match CloudAgents.Repository.initSchema() {
    case Ok(_)  -> ()
    case Err(e) -> println("WARNING: failed to initialise database schema: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  var router = Web.create()

  // Register session routes
  router = Web.addPost(router,   "/api/sessions",             "CloudAgents.Handlers.createSession")
  router = Web.addPost(router,   "/api/sessions/{id}/messages", "CloudAgents.Handlers.sendMessage")
  router = Web.addDelete(router, "/api/sessions/{id}",        "CloudAgents.Handlers.deleteSession")

  // Transcript: addressable agent/user messages for a session
  router = Web.addGet(router,    "/api/sessions/{id}/messages", "CloudAgents.Interactions.getMessages")

  // Comments anchored to a specific message
  router = Web.addPost(router,   "/api/messages/{mid}/comments", "CloudAgents.Interactions.addCommentHandler")
  router = Web.addGet(router,    "/api/messages/{mid}/comments", "CloudAgents.Interactions.getComments")

  // Todos / bookmarks, optionally linked back to a message
  router = Web.addGet(router,    "/api/sessions/{id}/todos",  "CloudAgents.Interactions.getTodos")
  router = Web.addPost(router,   "/api/sessions/{id}/todos",  "CloudAgents.Interactions.addTodoHandler")
  router = Web.addPost(router,   "/api/todos/{tid}/toggle",   "CloudAgents.Interactions.toggleTodoHandler")
  router = Web.addDelete(router, "/api/todos/{tid}",          "CloudAgents.Interactions.deleteTodoHandler")

  // Register health route
  router = Web.addGet(router,    "/api/health",               "CloudAgents.Handlers.checkHealth")

  println("Starting Cloud Agents API Server on port 8080...")
  Web.start(router)
}

