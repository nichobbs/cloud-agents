package CloudAgents

import Std.Core
import Web
import CloudAgents.Crypto
import CloudAgents.Docker
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env
import extern System.String as DotNetString

func main(): Unit {
  // Ensure the SQLite tables (transcript/comments/todos/prompts/sessions)
  // exist before serving.
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: failed to initialise database schema: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Sessions stranded RUNNING/WARM by a crash/restart can never be claimed
  // again (the concurrency guard would 409 forever). Terminate any container
  // they still reference before blanking it, so nothing is orphaned, then
  // reset the rows to IDLE.
  match CloudAgents.SessionStore.strandedContainerIds() {
    case Ok(ids) -> {
      for cid in ids {
        match CloudAgents.Docker.terminateSessionContainer(cid) {
          case Ok(_) -> ()
          case Err(e) -> println("WARNING: could not terminate stranded container " + cid + ": " + e)
        }
      }
    }
    case Err(e) -> println("WARNING: could not list stranded containers: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.SessionStore.recoverDanglingSessions() {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: failed to recover dangling sessions: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Fail loudly at startup — not at first credential use — if ENCRYPTION_KEY
  // is set but unusable (wrong length, bad base64). A configured-but-broken
  // key would otherwise only surface when a user first stores a credential.
  if CloudAgents.Crypto.isConfigured() {
    match CloudAgents.Crypto.encrypt("startup-self-check") {
      case Ok(_) -> ()
      case Err(e) -> println("WARNING: ENCRYPTION_KEY is set but invalid — credential storage will fail: " + CloudAgents.Crypto.cryptoErrorMessage(e))
    }
  } else {
    println("NOTE: ENCRYPTION_KEY is not set — the credential store is disabled")
  }

  // One-time migration of sessions from the legacy env-var store.
  CloudAgents.SessionStore.importLegacyEnvSessions()

  var router = Web.create()

  // Register session routes
  router = Web.addGet(router, "/api/sessions", "CloudAgents.Handlers.listSessions")
  router = Web.addPost(router, "/api/sessions", "CloudAgents.Handlers.createSession")
  router = Web.addPost(router, "/api/sessions/{id}/messages", "CloudAgents.Handlers.sendMessage")
  router = Web.addDelete(router, "/api/sessions/{id}", "CloudAgents.Handlers.deleteSession")
  router = Web.addPost(router, "/api/sessions/{id}/model", "CloudAgents.Handlers.updateSessionModel")
  router = Web.addPost(router, "/api/sessions/{id}/profile", "CloudAgents.Handlers.setSessionProfileHandler")

  // Live output polling for an in-progress run
  router = Web.addGet(router, "/api/sessions/{id}/output", "CloudAgents.Handlers.getRunOutput")

  // Session lifecycle: cancel an in-flight run, run history, container reaping.
  router = Web.addPost(router, "/api/sessions/{id}/cancel", "CloudAgents.Handlers.cancelRun")
  router = Web.addGet(router, "/api/sessions/{id}/runs", "CloudAgents.Handlers.getRuns")
  router = Web.addPost(router, "/api/maintenance/reap", "CloudAgents.Handlers.reapContainers")

  // Transcript: addressable agent/user messages for a session
  router = Web.addGet(router, "/api/sessions/{id}/messages", "CloudAgents.Interactions.getMessages")

  // Comments anchored to a specific message
  router = Web.addPost(router, "/api/messages/{mid}/comments", "CloudAgents.Interactions.addCommentHandler")
  router = Web.addGet(router, "/api/messages/{mid}/comments", "CloudAgents.Interactions.getComments")

  // Todos / bookmarks, optionally linked back to a message
  router = Web.addGet(router, "/api/sessions/{id}/todos", "CloudAgents.Interactions.getTodos")
  router = Web.addPost(router, "/api/sessions/{id}/todos", "CloudAgents.Interactions.addTodoHandler")
  router = Web.addPost(router, "/api/todos/{tid}/toggle", "CloudAgents.Interactions.toggleTodoHandler")
  router = Web.addDelete(router, "/api/todos/{tid}", "CloudAgents.Interactions.deleteTodoHandler")

  // Prompt library: saved, reusable prompts
  router = Web.addGet(router, "/api/prompts", "CloudAgents.Prompts.listPromptsHandler")
  router = Web.addGet(router, "/api/prompts/popular", "CloudAgents.Prompts.listPopularPromptsHandler")
  router = Web.addPost(router, "/api/prompts", "CloudAgents.Prompts.addPromptHandler")
  router = Web.addPost(router, "/api/prompts/{pid}", "CloudAgents.Prompts.updatePromptHandler")
  router = Web.addPost(router, "/api/prompts/{pid}/use", "CloudAgents.Prompts.usePromptHandler")
  router = Web.addPost(router, "/api/prompts/{pid}/render", "CloudAgents.Prompts.renderPromptHandler")
  router = Web.addDelete(router, "/api/prompts/{pid}", "CloudAgents.Prompts.deletePromptHandler")

  // Credential store: per-user secrets injected into runner containers.
  // Write-only — values are never read back, only their names.
  router = Web.addGet(router, "/api/credentials", "CloudAgents.Credentials.listCredentialsHandler")
  router = Web.addPost(router, "/api/credentials", "CloudAgents.Credentials.putCredentialHandler")
  router = Web.addDelete(router, "/api/credentials/{name}", "CloudAgents.Credentials.deleteCredentialHandler")

  // Profiles: per-container policy (harness, network access, injected creds).
  router = Web.addGet(router, "/api/profiles", "CloudAgents.Profiles.listProfilesHandler")
  router = Web.addPost(router, "/api/profiles", "CloudAgents.Profiles.addProfileHandler")
  router = Web.addPost(router, "/api/profiles/{pid}", "CloudAgents.Profiles.updateProfileHandler")
  router = Web.addDelete(router, "/api/profiles/{pid}", "CloudAgents.Profiles.deleteProfileHandler")

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

  // CLI takes precedence; otherwise read from env var
  if DotNetString.IsNullOrEmpty(portStr) {
    portStr = Env.GetEnvironmentVariable("LYRIC_CONFIG_WEB_SERVER_PORT")
  }

  // Fallback to default port if not set
  if DotNetString.IsNullOrEmpty(portStr) {
    portStr = "8080"
  }

  // The Web.Server config range-checks this env var at startup and panics on
  // violation; validating here turns a typo into a warning instead of a crash.
  if not isValidPort(portStr) {
    println("WARNING: '" + portStr + "' is not a valid TCP port (1-65535); using 8080")
    portStr = "8080"
  }
  Env.SetEnvironmentVariable("LYRIC_CONFIG_WEB_SERVER_PORT", portStr)

  println("Starting Cloud Agents API Server on port " + portStr + "...")
  Web.start(router)
}

func digitValue(c: in String): Int {
  if c == "0" {
    return 0
  }
  if c == "1" {
    return 1
  }
  if c == "2" {
    return 2
  }
  if c == "3" {
    return 3
  }
  if c == "4" {
    return 4
  }
  if c == "5" {
    return 5
  }
  if c == "6" {
    return 6
  }
  if c == "7" {
    return 7
  }
  if c == "8" {
    return 8
  }
  if c == "9" {
    return 9
  }
  return -1
}

/// Whether `s` is a decimal TCP port in 1..65535.
pub func isValidPort(s: in String): Bool {
  if s.length == 0 or s.length > 5 {
    return false
  }
  var n = 0
  var i = 0
  while i < s.length {
    val d = digitValue(s.substring(i, 1))
    if d < 0 {
      return false
    }
    n = n * 10 + d
    i = i + 1
  }
  return n >= 1 and n <= 65535
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
