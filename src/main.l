package CloudAgents

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Crypto
import CloudAgents.Docker
import CloudAgents.Handlers
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env
import extern System.String as DotNetString

// SPIKE (Lyric.Web 0.4.26): the framework replaced string-based route
// registration ("addGet(router, pattern, handlerName)") with a Handler-interface
// model ("addGet(router, pattern, handler: Handler)"). This adapter bridges one
// existing handler function (checkHealth) into the new Handler shape to prove the
// dispatch model builds and serves before migrating all ~40 routes.
record HealthHandler {}

impl Web.Handler for HealthHandler {
  func handle(req: in Web.Request): Web.Response {
    match CloudAgents.Handlers.checkHealth() {
      case Ok(msg) -> return Web.json(200, "{\"status\":\"" + msg + "\"}")
      case Err(e) -> return Web.errorResponse(e)
    }
  }
}

// SPIKE: the auth-enforcement seam the whole 0.4.26 adoption is for (#78/#211).
// Reads the Authorization header (now exposed by Lyric.Web) and runs it through
// the existing, already-unit-tested CloudAgents.Auth.authorize. With no
// CLOUD_AGENTS_API_TOKEN configured, authorize() returns Allowed, so this stays
// open until a token is set — no lockout. (The real migration will exclude
// genuinely-public routes like /api/health; applied router-wide here only to
// prove the middleware wiring compiles and dispatches.)
record AuthMiddleware {}

impl Web.Middleware for AuthMiddleware {
  func wrap(req: in Web.Request, next: in Web.Handler): Web.Response {
    var apiToken = Env.GetEnvironmentVariable("CLOUD_AGENTS_API_TOKEN")
    if DotNetString.IsNullOrEmpty(apiToken) {
      apiToken = ""
    }
    val authHeader = match Web.header(req, "Authorization") {
      case Some(h) -> h
      case None -> ""
    }
    match CloudAgents.Auth.authorize(authHeader, apiToken) {
      case Allowed(_) -> return next.handle(req)
      case Denied(_) -> return Web.errorResponse(Web.unauthorized("authentication required"))
    }
  }
}

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

  // SPIKE (Lyric.Web 0.4.26 migration): wire ONLY /api/health through the new
  // Handler-interface model to prove the dispatch model builds and serves. The
  // other ~39 routes still exist as annotated handler functions but are not
  // registered here yet — they'll be migrated to Handler adapters once this
  // slice is confirmed green end-to-end.
  var router = Web.create()
  router = Web.addGet(router, "/api/health", HealthHandler())
  router = Web.withMiddleware(router, AuthMiddleware())

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
