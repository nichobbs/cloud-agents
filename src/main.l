package CloudAgents

import Std.Core
import Web
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env
import extern System.String as DotNetString

func main(): Unit {
  // Ensure the SQLite transcript/comments/todos tables exist before serving.
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: failed to initialise database schema: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  var router = Web.create()

  // Register session routes
  router = Web.addPost(router, "/api/sessions", "CloudAgents.Handlers.createSession")
  router = Web.addPost(router, "/api/sessions/{id}/messages", "CloudAgents.Handlers.sendMessage")
  router = Web.addDelete(router, "/api/sessions/{id}", "CloudAgents.Handlers.deleteSession")
  router = Web.addPost(router, "/api/sessions/{id}/model", "CloudAgents.Handlers.updateSessionModel")

  // Transcript: addressable agent/user messages for a session
  router = Web.addGet(router, "/api/sessions/{id}/messages", "CloudAgents.Interactions.getMessages")

  // Comments anchored to a specific message
  router = Web.addPost(router, "/api/messages/{mid}/comments", "CloudAgents.Interactions.addCommentHandler")
  router = Web.addGet(router, "/api/messages/{mid}/comments", "CloudAgents.Interactions.getComments")

  // Todos / bookmarks, optionally linked back to a message
  router = Web.addGet(router, "/api/sessions/{id}/todos", "CloudAgents.Interactions.getTodos")
  router = Web.addPost(router, "/api/sessions/{id}/todos", "CloudAgents.Interactions.addTodoHandler")
  router = Web.addPost(router, "/api/sessions/{id}/todos", "CloudAgents.Interactions.addTodoHandler")
  router = Web.addPost(router, "/api/todos/{tid}/toggle", "CloudAgents.Interactions.toggleTodoHandler")
  router = Web.addDelete(router, "/api/todos/{tid}", "CloudAgents.Interactions.deleteTodoHandler")

  // Register health route
  router = Web.addGet(router, "/api/health", "CloudAgents.Handlers.checkHealth")

  // Parse command line arguments for --port or -p
  val cmdLine = Env.get_CommandLine()
  val args = parseCommandLine(cmdLine)
  val argsLen = getStringArrayLength(args)
  var portStr = ""

  var idx = 1
  while idx < argsLen {
    val arg = getStringArrayValue(args, idx)
    if arg == "--port" or arg == "-p" {
      if idx + 1 < argsLen {
        portStr = getStringArrayValue(args, idx + 1)
      }
    }
    idx = idx + 1
  }

  // If set via CLI, override the environment variable
  if not DotNetString.IsNullOrEmpty(portStr) {
    Env.SetEnvironmentVariable("LYRIC_CONFIG_WEB_SERVER_PORT", portStr)
  } else {
    // Otherwise read from env var
    portStr = Env.GetEnvironmentVariable("LYRIC_CONFIG_WEB_SERVER_PORT")
  }

  // Fallback to default port if not set
  if DotNetString.IsNullOrEmpty(portStr) {
    portStr = "8080"
  }

  println("Starting Cloud Agents API Server on port " + portStr + "...")
  Web.start(router)
}

pub func parseCommandLine(cmdLine: in String): StringArray {
  var entries = createEmptyStringArray()
  var current = ""
  var i = 0
  while i < cmdLine.length {
    val c = cmdLine.substring(i, 1)
    if c == " " {
      val trimmed = current.trim()
      if trimmed.length > 0 {
        entries = appendString(entries, trimmed)
      }
      current = ""
    } else {
      current = current + c
    }
    i = i + 1
  }
  val lastTrimmed = current.trim()
  if lastTrimmed.length > 0 {
    entries = appendString(entries, lastTrimmed)
  }
  return entries
}

pub func appendString(arr: in StringArray, item: in String): StringArray {
  val oldLen = getStringArrayLength(arr)
  val stringType = getStringType("")
  val newArr = createStringArray(stringType, oldLen + 1)
  if oldLen > 0 {
    copyStringArray(arr, 0, newArr, 0, oldLen)
  }
  setStringArrayValue(newArr, item, oldLen)
  return newArr
}

pub func createEmptyStringArray(): StringArray {
  val stringType = getStringType("")
  return createStringArray(stringType, 0)
}

extern type Type = "System.Type"

extern type StringArray = "System.String[]"


@externInstance
@externTarget("System.Array.get_Length")
func getStringArrayLength(arr: in StringArray): Int = ()

@externInstance
@externTarget("System.Array.GetValue")
func getStringArrayValue(arr: in StringArray, index: in Int): String = ()

@externInstance
@externTarget("System.Array.SetValue")
func setStringArrayValue(arr: in StringArray, value: in String, index: in Int): Unit = ()

@externTarget("System.Array.CreateInstance")
func createStringArray(elementType: in Type, length: in Int): StringArray = ()

@externTarget("System.Array.Copy")
func copyStringArray(
  sourceArray: in StringArray,
  sourceIndex: in Int,
  destinationArray: in StringArray,
  destinationIndex: in Int,
  length: in Int,
): Unit = ()

@externInstance
@externTarget("System.Object.GetType")
func getStringType(obj: in String): Type = ()
