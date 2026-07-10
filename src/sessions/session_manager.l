package CloudAgents.SessionStore

import Std.Core
import CloudAgents.Auth
import CloudAgents.Db
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env
import extern System.String as DotNetString

@generate(Json)
pub record AgentSession {
  pub sessionId: String
  pub repoUrl: String
  pub branch: String
  pub containerId: String
  pub harness: String
  pub model: String
  pub nativeSessionId: String
}

/// Default model for each harness, used when a session is created without an
/// explicit model or when deserialising a legacy session that predates this field.
pub func defaultModelForHarness(harness: in String): String {
  if harness == "codex" {
    return "o4-mini"
  }
  if harness == "opencode" {
    return "claude-sonnet-4-6"
  }
  return "claude-opus-4-8"
}

pub func makeAgentSession(
  sessionId: in String,
  repoUrl: in String,
  branch: in String,
  containerId: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String,
): AgentSession {
  return AgentSession(
    sessionId = sessionId,
    repoUrl = repoUrl,
    branch = branch,
    containerId = containerId,
    harness = harness,
    model = model,
    nativeSessionId = nativeSessionId
  )
}


extern type Type = "System.Type"

extern type AgentSessionArray = "CloudAgents.SessionStore.AgentSession[]"

@externInstance
@externTarget("System.Object.GetType")
func getAgentSessionType(obj: in AgentSession): Type = ()

@externTarget("System.Array.CreateInstance")
func createSessionArray(elementType: in Type, length: in Int): AgentSessionArray = ()

@externTarget("System.Array.Copy")
func copySessionArray(
  sourceArray: in AgentSessionArray,
  sourceIndex: in Int,
  destinationArray: in AgentSessionArray,
  destinationIndex: in Int,
  length: in Int,
): Unit = ()

@externInstance
@externTarget("System.Array.get_Length")
pub func getSessionArrayLength(arr: in AgentSessionArray): Int = ()

@externInstance
@externTarget("System.Array.SetValue")
func setSessionArrayValue(arr: in AgentSessionArray, value: in AgentSession, index: in Int): Unit = ()

@externInstance
@externTarget("System.Array.GetValue")
pub func getSessionArrayValue(arr: in AgentSessionArray, index: in Int): AgentSession = ()

pub func appendSession(arr: in AgentSessionArray, item: in AgentSession): AgentSessionArray {
  val oldLen = getSessionArrayLength(arr)
  val sessionType = getAgentSessionType(item)
  val newArr = createSessionArray(sessionType, oldLen + 1)
  if oldLen > 0 {
    copySessionArray(arr, 0, newArr, 0, oldLen)
  }
  setSessionArrayValue(newArr, item, oldLen)
  return newArr
}

pub func createEmptySessionArray(): AgentSessionArray {
  val dummy = makeAgentSession("", "", "", "", "", "", "")
  val sessionType = getAgentSessionType(dummy)
  return createSessionArray(sessionType, 0)
}

/// First index of `needle` in `hay` at or after `from`, or -1 if not present.
func indexOfFrom(hay: in String, needle: in String, from: in Int): Int {
  val hayLen = hay.length.toInt()
  val needleLen = needle.length.toInt()
  if needleLen == 0 {
    return from
  }
  var i = from
  val last = hayLen - needleLen
  while i <= last {
    var j = 0
    var matched = true
    while j < needleLen {
      if hay.substring(i + j, 1) != needle.substring(j, 1) {
        matched = false
        j = needleLen
      } else {
        j = j + 1
      }
    }
    if matched {
      return i
    }
    i = i + 1
  }
  return -1
}

pub func parseJsonField(objStr: in String, fieldName: in String): String {
  val target = "\"" + fieldName + "\""
  val objLen = objStr.length.toInt()
  val pos = indexOfFrom(objStr, target, 0)
  if pos < 0 {
    return ""
  }

  // Find colon after the target field name
  var colonPos = 0
  var foundColon = false
  var i = pos + target.length.toInt()
  while i < objLen {
    if objStr.substring(i, 1) == ":" {
      colonPos = i
      foundColon = true
      i = objLen // break
    } else {
      i = i + 1
    }
  }
  if not foundColon {
    return ""
  }

  // Find opening quote for the value
  var quoteStart = 0
  var foundQuoteStart = false
  i = colonPos + 1
  while i < objLen {
    val c = objStr.substring(i, 1)
    if c == "\"" {
      quoteStart = i
      foundQuoteStart = true
      i = objLen // break
    } else {
      i = i + 1
    }
  }
  if not foundQuoteStart {
    return ""
  }

  // Scan forward to the closing quote, unescaping as we go. Forward scanning
  // (consume the char after every backslash) is the only correct way to find
  // the closing quote: a look-behind check misreads a value ending in an
  // escaped backslash (`"a\\"`) as an escaped quote and overruns the value.
  var acc = ""
  i = quoteStart + 1
  while i < objLen {
    val c = objStr.substring(i, 1)
    if c == "\\" {
      if i + 1 >= objLen {
        return "" // dangling backslash: malformed
      }
      val esc = objStr.substring(i + 1, 1)
      if esc == "n" {
        acc = acc + "\n"
        i = i + 2
      } else if esc == "r" {
        acc = acc + "\r"
        i = i + 2
      } else if esc == "t" {
        acc = acc + "\t"
        i = i + 2
      } else if esc == "u" {
        // Unescape the \u00XX control escapes jsonEscapeField emits; any
        // other or malformed \u sequence keeps the old literal-'u' behaviour.
        var code = -1
        if i + 5 < objLen {
          val h1 = hexValue(objStr.substring(i + 2, 1))
          val h2 = hexValue(objStr.substring(i + 3, 1))
          val h3 = hexValue(objStr.substring(i + 4, 1))
          val h4 = hexValue(objStr.substring(i + 5, 1))
          if h1 >= 0 and h2 >= 0 and h3 >= 0 and h4 >= 0 {
            code = h1 * 4096 + h2 * 256 + h3 * 16 + h4
          }
        }
        if code >= 0 and code < 32 {
          acc = acc + charFromCode(code)
          i = i + 6
        } else {
          acc = acc + esc
          i = i + 2
        }
      } else {
        acc = acc + esc // \" -> ", \\ -> \; anything else kept literally
        i = i + 2
      }
    } else if c == "\"" {
      return acc
    } else {
      acc = acc + c
      i = i + 1
    }
  }
  return "" // no closing quote: malformed
}

pub func parseSessionsJson(json: in String): AgentSessionArray {
  var list = createEmptySessionArray()
  val jsonLen = json.length.toInt()

  // Find where "[" begins
  val arrayStart = indexOfFrom(json, "[", 0)
  if arrayStart < 0 {
    return list
  }

  // Now we scan objects inside the array
  // Each object starts with '{' and ends with '}'
  var idx = arrayStart + 1
  while idx < jsonLen {
    // Find next '{'
    var objStart = 0
    var foundObjStart = false
    var scan = idx
    while scan < jsonLen {
      if json.substring(scan, 1) == "{" {
        objStart = scan
        foundObjStart = true
        scan = jsonLen // break
      } else {
        scan = scan + 1
      }
    }

    if not foundObjStart {
      return list // no more objects
    }

    // Find matching '}'. String literals are skipped wholesale so braces
    // inside field values (a repoUrl containing '{', say) cannot desync the
    // depth count.
    var objEnd = 0
    var foundObjEnd = false
    scan = objStart + 1
    var depth = 1
    while scan < jsonLen {
      val c = json.substring(scan, 1)
      if c == "\"" {
        scan = scan + 1
        var closed = false
        while scan < jsonLen and not closed {
          val sc = json.substring(scan, 1)
          if sc == "\\" {
            scan = scan + 2
          } else if sc == "\"" {
            closed = true
            scan = scan + 1
          } else {
            scan = scan + 1
          }
        }
      } else if c == "{" {
        depth = depth + 1
        scan = scan + 1
      } else if c == "}" {
        depth = depth - 1
        if depth == 0 {
          objEnd = scan
          foundObjEnd = true
          scan = jsonLen // break
        } else {
          scan = scan + 1
        }
      } else {
        scan = scan + 1
      }
    }

    if not foundObjEnd {
      return list // mismatched braces, invalid
    }

    // We extracted one session object string
    val objStr = json.substring(objStart, objEnd - objStart + 1)

    // Parse fields — new fields default gracefully for sessions created before this change
    val sessionId = parseJsonField(objStr, "sessionId")
    val repoUrl = parseJsonField(objStr, "repoUrl")
    val branch = parseJsonField(objStr, "branch")
    val containerId = parseJsonField(objStr, "containerId")
    val rawHarness = parseJsonField(objStr, "harness")
    val rawModel = parseJsonField(objStr, "model")
    val rawNativeId = parseJsonField(objStr, "nativeSessionId")

    // Default harness to "claude" for legacy sessions
    val harness = if rawHarness.length == 0 { "claude" } else { rawHarness }
    // Default model to the harness's canonical default so legacy sessions don't
    // pass an empty MODEL env var to the container (which would error).
    val model = if rawModel.length == 0 { defaultModelForHarness(harness) } else { rawModel }
    // Default nativeSessionId to sessionId so legacy sessions can resume
    val nativeSessionId = if rawNativeId.length == 0 { sessionId } else { rawNativeId }

    val session = AgentSession(
      sessionId = sessionId,
      repoUrl = repoUrl,
      branch = branch,
      containerId = containerId,
      harness = harness,
      model = model,
      nativeSessionId = nativeSessionId
    )
    list = appendSession(list, session)

    idx = objEnd + 1
  }

  return list
}

// ─── SQLite-backed store ──────────────────────────────────────────────────────
//
// Sessions live in the same SQLite database as the transcript (schema created
// by CloudAgents.Repository.initSchema), so they survive restarts and two
// concurrent requests cannot lose each other's writes — both defects of the
// previous CLOUD_AGENTS_SESSIONS_JSON env-var store. The env-var JSON
// helpers below are retained for the one-time legacy import at startup (and
// their tests).
func colAt(cols: in CloudAgents.Sqlite.StringArray, i: in Int): String {
  val len = CloudAgents.Sqlite.getStringArrayLength(cols)
  if i < len {
    return CloudAgents.Sqlite.getStringArrayValue(cols, i)
  }
  return ""
}

// Column order matches CloudAgents.Db's sessionColumns:
// id, user_id, repo_url, branch, container_id, harness, model,
// native_session_id, status, created_at, last_message_at.
func rowToSession(r: in CloudAgents.Sqlite.Row): AgentSession {
  return AgentSession(
    sessionId = colAt(r.cols, 0),
    repoUrl = colAt(r.cols, 2),
    branch = colAt(r.cols, 3),
    containerId = colAt(r.cols, 4),
    harness = colAt(r.cols, 5),
    model = colAt(r.cols, 6),
    nativeSessionId = colAt(r.cols, 7)
  )
}

/// All of the current user's sessions, most recently active first.
pub func getSessions(): Result[AgentSessionArray, CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.listSessionsByUserSql(CloudAgents.Auth.currentUserId()))?
  var list = createEmptySessionArray()
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    list = appendSession(list, rowToSession(CloudAgents.Sqlite.getRowArrayValue(rows, i)))
    i = i + 1
  }
  return Ok(value = list)
}

// ── Control-character helpers ─────────────────────────────────────────────────
// Same approach as CloudAgents.Streaming / Lyric.Docker: JSON forbids raw
// control characters in string literals, and Lyric literals cannot express
// them, so detection/construction goes through the BCL.
@externTarget("System.String.CompareOrdinal")
func strCompareOrdinal(a: in String, b: in String): Int = ()

@externTarget("System.Char.ConvertFromUtf32")
func charFromCode(code: in Int): String = ()

func isControlChar(c: in String): Bool {
  return strCompareOrdinal(c, " ") < 0
}

func hexDigit(n: in Int): String {
  if n == 10 {
    return "a"
  }
  if n == 11 {
    return "b"
  }
  if n == 12 {
    return "c"
  }
  if n == 13 {
    return "d"
  }
  if n == 14 {
    return "e"
  }
  if n == 15 {
    return "f"
  }
  return toString(n)
}

/// Value of one hex digit character, or -1.
func hexValue(c: in String): Int {
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
  if c == "a" or c == "A" {
    return 10
  }
  if c == "b" or c == "B" {
    return 11
  }
  if c == "c" or c == "C" {
    return 12
  }
  if c == "d" or c == "D" {
    return 13
  }
  if c == "e" or c == "E" {
    return 14
  }
  if c == "f" or c == "F" {
    return 15
  }
  return -1
}

/// The `\u00XX` escape for a control character (code point below 0x20).
func controlEscape(c: in String): String {
  var code = 0
  while code < 32 {
    if charFromCode(code) == c {
      if code < 16 {
        return "\\u000" + hexDigit(code)
      }
      return "\\u001" + hexDigit(code - 16)
    }
    code = code + 1
  }
  return c // unreachable: isControlChar guarantees code < 32
}

/// Escape a field value for embedding in the session-store JSON. Without this,
/// a quote or backslash in any user-supplied field (repoUrl, branch, model...)
/// corrupts the whole store — or forges sibling fields on re-parse. Control
/// characters are escaped as `\u00XX` like the streaming and Docker layers:
/// the handler boundary rejects them today, but the store must not depend on
/// every future writer remembering to validate.
pub func jsonEscapeField(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    if c == "\"" {
      acc = acc + "\\\""
    } else if c == "\\" {
      acc = acc + "\\\\"
    } else if c == "\n" {
      acc = acc + "\\n"
    } else if c == "\r" {
      acc = acc + "\\r"
    } else if c == "\t" {
      acc = acc + "\\t"
    } else if isControlChar(c) {
      acc = acc + controlEscape(c)
    } else {
      acc = acc + c
    }
    i = i + 1
  }
  return acc
}

pub func agentSessionToJson(s: in AgentSession): String {
  return "{\"sessionId\":\"" + jsonEscapeField(s.sessionId) + "\",\"repoUrl\":\"" + jsonEscapeField(s.repoUrl) +
    "\",\"branch\":\"" +
    jsonEscapeField(s.branch) +
    "\",\"containerId\":\"" +
    jsonEscapeField(s.containerId) +
    "\",\"harness\":\"" +
    jsonEscapeField(s.harness) +
    "\",\"model\":\"" +
    jsonEscapeField(s.model) +
    "\",\"nativeSessionId\":\"" +
    jsonEscapeField(s.nativeSessionId) +
    "\"}"
}

/// Persist a new session (status starts IDLE, owned by the current user).
pub func addSession(session: in AgentSession): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(
    CloudAgents.Db.insertSessionSql(
      session.sessionId,
      CloudAgents.Auth.currentUserId(),
      session.repoUrl,
      session.branch,
      session.containerId,
      session.harness,
      session.model,
      session.nativeSessionId,
      CloudAgents.Repository.nowMillis()
    )
  )?
  return Ok(value = ())
}

/// A single session owned by the current user, or None.
pub func getSession(sessionId: in String): Result[Option[AgentSession], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(
    CloudAgents.Db.selectSessionByIdSql(sessionId, CloudAgents.Auth.currentUserId())
  )?
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  if len == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = rowToSession(CloudAgents.Sqlite.getRowArrayValue(rows, 0))))
}

pub func updateSessionContainer(sessionId: in String, containerId: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(
    CloudAgents.Db.updateSessionContainerSql(sessionId, CloudAgents.Auth.currentUserId(), containerId)
  )?
  return Ok(value = ())
}

pub func updateSessionModel(sessionId: in String, model: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(
    CloudAgents.Db.updateSessionModelSql(sessionId, CloudAgents.Auth.currentUserId(), model)
  )?
  return Ok(value = ())
}

/// Remove a session, returning the record that was removed (None when it did
/// not exist or is not owned by the current user).
pub func removeSession(sessionId: in String): Result[Option[AgentSession], CloudAgents.Sqlite.DbError] {
  val existing = getSession(sessionId)?
  match existing {
    case None -> return Ok(value = None)
    case Some(_) -> ()
  }
  CloudAgents.Sqlite.execute(CloudAgents.Db.deleteSessionSql(sessionId, CloudAgents.Auth.currentUserId()))?
  return Ok(value = existing)
}

// ─── Run status ───────────────────────────────────────────────────────────────
/// Atomically claim a session for a run. Ok(false) means another run is
/// already in progress (the caller should respond 409); the single UPDATE
/// with a status guard makes two concurrent sends unable to both win.
pub func tryBeginRun(sessionId: in String): Result[Bool, CloudAgents.Sqlite.DbError] {
  val n = CloudAgents.Sqlite.execute(
    CloudAgents.Db.tryBeginRunSql(sessionId, CloudAgents.Auth.currentUserId(), CloudAgents.Repository.nowMillis())
  )?
  return Ok(value = n > 0)
}

/// Return a session to IDLE after a run (success or failure) and record the
/// activity time.
pub func endRun(sessionId: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(
    CloudAgents.Db.endRunSql(sessionId, CloudAgents.Auth.currentUserId(), CloudAgents.Repository.nowMillis())
  )?
  return Ok(value = ())
}

/// Reset sessions stranded RUNNING/WARM by a crash or restart back to IDLE.
/// Called once at startup, after the schema is created.
pub func recoverDanglingSessions(): Result[Int, CloudAgents.Sqlite.DbError] {
  return CloudAgents.Sqlite.execute(CloudAgents.Db.recoverDanglingSessionsSql())
}

// ─── Legacy env-var store import ──────────────────────────────────────────────
/// One-time migration: sessions created before the SQLite store lived as JSON
/// in CLOUD_AGENTS_SESSIONS_JSON. Import any that aren't already in the
/// database, then clear the env var so this never re-runs. Best-effort — a
/// failed import leaves the env var in place and warns rather than aborting
/// startup.
pub func importLegacyEnvSessions(): Unit {
  val json = Env.GetEnvironmentVariable("CLOUD_AGENTS_SESSIONS_JSON")
  if DotNetString.IsNullOrEmpty(json) {
    return ()
  }
  val sessions = parseSessionsJson(json)
  val len = getSessionArrayLength(sessions)
  var i = 0
  var failures = 0
  while i < len {
    val s = getSessionArrayValue(sessions, i)
    match getSession(s.sessionId) {
      case Ok(Some(_)) -> ()
      case Ok(None) -> match addSession(s) {
        case Ok(_) -> ()
        case Err(e) -> {
          failures = failures + 1
          println("WARNING: failed to import legacy session " + s.sessionId + ": " + CloudAgents.Sqlite.dbErrorMessage(e))
        }
      }
      case Err(e) -> {
        failures = failures + 1
        println("WARNING: failed to check legacy session " + s.sessionId + ": " + CloudAgents.Sqlite.dbErrorMessage(e))
      }
    }
    i = i + 1
  }
  if failures == 0 {
    Env.SetEnvironmentVariable("CLOUD_AGENTS_SESSIONS_JSON", "")
    if len > 0 {
      println("Imported " + toString(len) + " legacy session(s) from CLOUD_AGENTS_SESSIONS_JSON into SQLite")
    }
  }
}
