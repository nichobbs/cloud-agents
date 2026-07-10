package CloudAgents.SessionStore

import Std.Core
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
      } else if esc == "r" {
        acc = acc + "\r"
      } else if esc == "t" {
        acc = acc + "\t"
      } else {
        acc = acc + esc // \" -> ", \\ -> \; anything else kept literally
      }
      i = i + 2
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

pub func getSessions(): AgentSessionArray {
  val json = Env.GetEnvironmentVariable("CLOUD_AGENTS_SESSIONS_JSON")
  if DotNetString.IsNullOrEmpty(json) {
    return createEmptySessionArray()
  }
  return parseSessionsJson(json)
}

/// Escape a field value for embedding in the session-store JSON. Without this,
/// a quote or backslash in any user-supplied field (repoUrl, branch, model...)
/// corrupts the whole store — or forges sibling fields on re-parse.
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

pub func saveSessions(sessions: in AgentSessionArray): Unit {
  var json = "{\"sessions\":["
  var i = 0
  val len = getSessionArrayLength(sessions)
  while i < len {
    val s = getSessionArrayValue(sessions, i)
    val sJson = agentSessionToJson(s)
    json = json + sJson
    if i < len - 1 {
      json = json + ","
    }
    i = i + 1
  }
  json = json + "]}"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_SESSIONS_JSON", json)
}

pub func addSession(session: in AgentSession): Unit {
  val sessions = getSessions()
  saveSessions(appendSession(sessions, session))
}

pub func getSession(sessionId: in String): Option[AgentSession] {
  val sessions = getSessions()
  var i = 0
  val len = getSessionArrayLength(sessions)
  while i < len {
    val s = getSessionArrayValue(sessions, i)
    if s.sessionId == sessionId {
      return Some(value = s)
    }
    i = i + 1
  }
  return None
}

pub func updateSessionContainer(sessionId: in String, containerId: in String): Unit {
  val sessions = getSessions()
  var updated = createEmptySessionArray()
  var i = 0
  val len = getSessionArrayLength(sessions)
  while i < len {
    val s = getSessionArrayValue(sessions, i)
    if s.sessionId == sessionId {
      updated = appendSession(
        updated,
        AgentSession(
          sessionId = s.sessionId,
          repoUrl = s.repoUrl,
          branch = s.branch,
          containerId = containerId,
          harness = s.harness,
          model = s.model,
          nativeSessionId = s.nativeSessionId
        )
      )
    } else {
      updated = appendSession(updated, s)
    }
    i = i + 1
  }
  saveSessions(updated)
}

pub func updateSessionModel(sessionId: in String, model: in String): Unit {
  val sessions = getSessions()
  var updated = createEmptySessionArray()
  var i = 0
  val len = getSessionArrayLength(sessions)
  while i < len {
    val s = getSessionArrayValue(sessions, i)
    if s.sessionId == sessionId {
      updated = appendSession(
        updated,
        AgentSession(
          sessionId = s.sessionId,
          repoUrl = s.repoUrl,
          branch = s.branch,
          containerId = s.containerId,
          harness = s.harness,
          model = model,
          nativeSessionId = s.nativeSessionId
        )
      )
    } else {
      updated = appendSession(updated, s)
    }
    i = i + 1
  }
  saveSessions(updated)
}

pub func removeSession(sessionId: in String): Option[AgentSession] {
  val sessions = getSessions()
  var updated = createEmptySessionArray()
  var removed: Option[AgentSession] = None
  var i = 0
  val len = getSessionArrayLength(sessions)
  while i < len {
    val s = getSessionArrayValue(sessions, i)
    if s.sessionId == sessionId {
      removed = Some(value = s)
    } else {
      updated = appendSession(updated, s)
    }
    i = i + 1
  }
  saveSessions(updated)
  return removed
}
