package CloudAgents

import Std.Core
import Web

func main(): Unit {
  var router = Web.create()

  // Register session routes
  router = Web.addPost(router,   "/api/sessions",             "CloudAgents.Handlers.createSession")
  router = Web.addPost(router,   "/api/sessions/{id}/messages", "CloudAgents.Handlers.sendMessage")
  router = Web.addDelete(router, "/api/sessions/{id}",        "CloudAgents.Handlers.deleteSession")

  // Register health route
  router = Web.addGet(router,    "/api/health",               "CloudAgents.Handlers.checkHealth")

  println("Starting Cloud Agents API Server on port 8080...")
  Web.start(router)
}

