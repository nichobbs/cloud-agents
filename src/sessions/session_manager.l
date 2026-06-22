package CloudAgents.SessionStore

import Std.CollectionsHost.{List, newList}
import Std.Core

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
  if harness == "codex" { return "o4-mini" }
  if harness == "opencode" { return "claude-sonnet-4-6" }
  return "claude-opus-4-8"
}

pub func makeAgentSession(
  sessionId: in String,
  repoUrl: in String,
  branch: in String,
  containerId: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String
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

// ─── Concrete FFI for System.Environment storing JSON String ──────────────────
extern type Environment = "System.Environment"

@externTarget("System.Environment.GetEnvironmentVariable")
func getEnvVar(name: in String): String = ()

@externTarget("System.Environment.SetEnvironmentVariable")
func setEnvVar(name: in String, value: in String): Unit = ()

@externTarget("System.Object.ReferenceEquals")
func referenceEqualsStrings(a: in String, b: in String): Bool = ()

@externTarget("System.String.IsNullOrEmpty")
func isNullOrEmpty(s: in String): Bool = ()

pub func parseJsonField(objStr: in String, fieldName: in String): String {
  val target = "\"" + fieldName + "\""
  val maybePos = objStr.indexOf(target)
  if maybePos.isNone() {
    return ""
  }
  val pos = maybePos.unwrap()

  // Find colon after the target field name
  var colonPos = 0
  var foundColon = false
  var i = pos + target.length
  while i < objStr.length {
    if objStr.substring(i, 1) == ":" {
      colonPos = i
      foundColon = true
      i = objStr.length // break
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
  while i < objStr.length {
    val c = objStr.substring(i, 1)
    if c == "\"" {
      quoteStart = i
      foundQuoteStart = true
      i = objStr.length // break
    } else {
      i = i + 1
    }
  }
  if not foundQuoteStart {
    return ""
  }

  // Find closing quote
  var quoteEnd = 0
  var foundQuoteEnd = false
  i = quoteStart + 1
  while i < objStr.length {
    val c = objStr.substring(i, 1)
    if c == "\"" {
      if objStr.substring(i - 1, 1) != "\\" {
        quoteEnd = i
        foundQuoteEnd = true
        i = objStr.length // break
      } else {
        i = i + 1
      }
    } else {
      i = i + 1
    }
  }
  if not foundQuoteEnd {
    return ""
  }

  val valLen = quoteEnd - quoteStart - 1
  return objStr.substring(quoteStart + 1, valLen)
}

pub func parseSessionsJson(json: in String): List[AgentSession] {
  val list: List[AgentSession] = newList()

  // Find where "[" begins
  val maybeArrayStart = json.indexOf("[")
  if maybeArrayStart.isNone() {
    return list
  }
  val arrayStart = maybeArrayStart.unwrap()

  // Now we scan objects inside the array
  // Each object starts with '{' and ends with '}'
  var idx = arrayStart + 1
  while idx < json.length {
    // Find next '{'
    var objStart = 0
    var foundObjStart = false
    var scan = idx
    while scan < json.length {
      if json.substring(scan, 1) == "{" {
        objStart = scan
        foundObjStart = true
        scan = json.length // break
      } else {
        scan = scan + 1
      }
    }

    if not foundObjStart {
      return list // no more objects
    }

    // Find matching '}'
    var objEnd = 0
    var foundObjEnd = false
    scan = objStart + 1
    var depth = 1
    while scan < json.length {
      val c = json.substring(scan, 1)
      if c == "{" {
        depth = depth + 1
        scan = scan + 1
      } else if c == "}" {
        depth = depth - 1
        if depth == 0 {
          objEnd = scan
          foundObjEnd = true
          scan = json.length // break
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
    list.add(session)

    idx = objEnd + 1
  }

  return list
}

pub func getSessionsList(): List[AgentSession] {
  val json = getEnvVar("CLOUD_AGENTS_SESSIONS_JSON")
  if isNullOrEmpty(json) {
    return newList()
  }
  return parseSessionsJson(json)
}

pub func getSessionsSlice(): slice[AgentSession] {
  return getSessionsList().toArray()
}

pub func agentSessionToJson(s: in AgentSession): String {
  return "{\"sessionId\":\"" + s.sessionId +
    "\",\"repoUrl\":\"" + s.repoUrl +
    "\",\"branch\":\"" + s.branch +
    "\",\"containerId\":\"" + s.containerId +
    "\",\"harness\":\"" + s.harness +
    "\",\"model\":\"" + s.model +
    "\",\"nativeSessionId\":\"" + s.nativeSessionId + "\"}"
}

pub func saveSessions(sessions: in slice[AgentSession]): Unit {
  var json = "{\"sessions\":["
  var i = 0
  while i < sessions.length {
    val s = sessions[i]
    val sJson = agentSessionToJson(s)
    json = json + sJson
    if i < sessions.length - 1 {
      json = json + ","
    }
    i = i + 1
  }
  json = json + "]}"
  setEnvVar("CLOUD_AGENTS_SESSIONS_JSON", json)
}

pub func addSession(session: in AgentSession): Unit {
  val sessions = getSessionsList()
  sessions.add(session)
  saveSessions(sessions.toArray())
}

pub func getSession(sessionId: in String): Option[AgentSession] {
  val sessions = getSessionsSlice()
  var i = 0
  while i < sessions.length {
    val s = sessions[i]
    if s.sessionId == sessionId {
      return Some(value = s)
    }
    i = i + 1
  }
  return None
}

pub func updateSessionContainer(sessionId: in String, containerId: in String): Unit {
  val sessions = getSessionsSlice()
  val updated: List[AgentSession] = newList()
  var i = 0
  while i < sessions.length {
    val s = sessions[i]
    if s.sessionId == sessionId {
      updated.add(AgentSession(
        sessionId = s.sessionId,
        repoUrl = s.repoUrl,
        branch = s.branch,
        containerId = containerId,
        harness = s.harness,
        model = s.model,
        nativeSessionId = s.nativeSessionId
      ))
    } else {
      updated.add(s)
    }
    i = i + 1
  }
  saveSessions(updated.toArray())
}

pub func updateSessionModel(sessionId: in String, model: in String): Unit {
  val sessions = getSessionsSlice()
  val updated: List[AgentSession] = newList()
  var i = 0
  while i < sessions.length {
    val s = sessions[i]
    if s.sessionId == sessionId {
      updated.add(AgentSession(
        sessionId = s.sessionId,
        repoUrl = s.repoUrl,
        branch = s.branch,
        containerId = s.containerId,
        harness = s.harness,
        model = model,
        nativeSessionId = s.nativeSessionId
      ))
    } else {
      updated.add(s)
    }
    i = i + 1
  }
  saveSessions(updated.toArray())
}

pub func removeSession(sessionId: in String): Option[AgentSession] {
  val sessions = getSessionsSlice()
  val updated: List[AgentSession] = newList()
  var removed: Option[AgentSession] = None
  var i = 0
  while i < sessions.length {
    val s = sessions[i]
    if s.sessionId == sessionId {
      removed = Some(value = s)
    } else {
      updated.add(s)
    }
    i = i + 1
  }
  saveSessions(updated.toArray())
  return removed
}
