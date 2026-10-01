//! CloudAgents.SessionStore — the session store facade. Its functions
//! delegate to the Postgres implementation in `src/pgstore/sessions.l`
//! (`CloudAgents.PgStore.Sessions`).
package CloudAgents.SessionStore

import Std.Core
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.Db
import CloudAgents.Repository
import CloudAgents.Text
import extern System.Environment as Env
import extern System.String as DotNetString
import CloudAgents.PgStore.Sessions

@generate(Json)
pub record AgentSession {
  pub sessionId: String
  pub repoUrl: String
  pub branch: String
  pub containerId: String
  pub harness: String
  pub model: String
  pub nativeSessionId: String
  pub status: String
  pub isArchived: String = "0"
  /// Session-group association (migration 0029); "" = ungrouped.
  pub groupId: String = ""
  /// Epoch-millis TEXT of the user's last view (migration 0029); "0" = never.
  pub lastViewedAt: String = "0"
  /// Parent session ID if branched from another session; "" = root session.
  pub parentSessionId: String = ""
  /// Message ID from which this session branched; "" = root session.
  pub forkedFromMessageId: String = ""
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
  if harness == "gemini" or harness == "antigravity" {
    return "gemini-2.5-pro"
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
  status: in String = "IDLE"
): AgentSession {
  return AgentSession(
    sessionId = sessionId,
    repoUrl = repoUrl,
    branch = branch,
    containerId = containerId,
    harness = harness,
    model = model,
    nativeSessionId = nativeSessionId,
    status = status
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
@externStatic
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

pub func parseJsonField(objStr: in String, fieldName: in String): String {
  val target = "\"" + fieldName + "\""
  val objLen = objStr.length.toInt()
  val pos = CloudAgents.Text.indexOfFrom(objStr, target, 0)
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
  val arrayStart = CloudAgents.Text.indexOfFrom(json, "[", 0)
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
    val rawStatus = parseJsonField(objStr, "status")

    // Default harness to "claude" for legacy sessions
    val harness = if rawHarness.length == 0 { "claude" } else { rawHarness }
    // Default model to the harness's canonical default so legacy sessions don't
    // pass an empty MODEL env var to the container (which would error).
    val model = if rawModel.length == 0 { defaultModelForHarness(harness) } else { rawModel }
    // Default nativeSessionId to sessionId so legacy sessions can resume
    val nativeSessionId = if rawNativeId.length == 0 { sessionId } else { rawNativeId }
    // Default status to IDLE for legacy sessions predating the status field
    val status = if rawStatus.length == 0 { "IDLE" } else { rawStatus }

    val session = AgentSession(
      sessionId = sessionId,
      repoUrl = repoUrl,
      branch = branch,
      containerId = containerId,
      harness = harness,
      model = model,
      nativeSessionId = nativeSessionId,
      status = status
    )
    list = appendSession(list, session)

    idx = objEnd + 1
  }

  return list
}

/// The session-list projection as a complete `{"sessions":[...]}` JSON string,
/// most recently active first. Unlike getSessions()/AgentSession this includes
/// the bookkeeping columns the UI needs to show *when* things happened and
/// what a session is doing right now — status, created_at, last_message_at —
/// while still excluding infrastructure handles (container_id,
/// native_session_id). Built here rather than in CloudAgents.Handlers because
/// this package is where the raw rows (with those extra columns) are visible.
pub func sessionSummariesJson(sc: in CloudAgents.Pg.TenantScope): Result[String, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.sessionSummariesJson(sc)
}

/// One row of the session-list projection, every value as the store's text
/// form. Built by the Postgres store so the JSON shape
/// has a single definition (`sessionSummariesToJson`).
pub record SessionSummaryRow {
  pub sessionId: String
  pub repoUrl: String
  pub branch: String
  pub harness: String
  pub model: String
  pub status: String
  pub createdAt: String
  pub lastMessageAt: String
  pub isArchived: String
  pub groupId: String
  pub lastViewedAt: String
  pub parentSessionId: String
  pub forkedFromMessageId: String
  pub pendingCount: String
  pub ledgerAttention: String
}

/// The `{"sessions":[...]}` document for the session list, in row order.
pub func sessionSummariesToJson(rows: in slice[SessionSummaryRow]): String {
  var json = "{\"sessions\":["
  var i = 0
  for r in rows {
    if i > 0 {
      json = json + ","
    }
    // `attention` is derived, not stored: the pure CloudAgents.Db.attentionFor
    // over status / lastMessageAt / lastViewedAt / pendingCount. New fields
    // are APPENDED to each object so existing consumers of the earlier fields
    // are untouched; every value is a string, matching this projection's
    // TEXT-only convention. attention's four values are fixed lowercase
    // literals, safe to embed unescaped. A session with ledger entries
    // awaiting review needs its owner just as a pending callback does;
    // attentionFor only asks whether the count is non-zero, so pick whichever
    // count is (no Long arithmetic, see docs/lyric/gotchas.md on Int64
    // subtract/compare crashes).
    var waitingText = r.pendingCount
    if waitingText == "0" or waitingText.length == 0 {
      waitingText = r.ledgerAttention
    }
    val attention = CloudAgents.Db.attentionFor(
      r.status,
      CloudAgents.Db.parseEpochMillisText(r.lastMessageAt),
      CloudAgents.Db.parseEpochMillisText(r.lastViewedAt),
      CloudAgents.Db.parseEpochMillisText(waitingText)
    )
    json = json + "{\"sessionId\":\"" + jsonEscapeField(r.sessionId) + "\",\"repoUrl\":\"" +
      jsonEscapeField(r.repoUrl) +
      "\",\"branch\":\"" +
      jsonEscapeField(r.branch) +
      "\",\"harness\":\"" +
      jsonEscapeField(r.harness) +
      "\",\"model\":\"" +
      jsonEscapeField(r.model) +
      "\",\"status\":\"" +
      jsonEscapeField(r.status) +
      "\",\"createdAt\":\"" +
      jsonEscapeField(r.createdAt) +
      "\",\"lastMessageAt\":\"" +
      jsonEscapeField(r.lastMessageAt) +
      "\",\"isArchived\":\"" +
      jsonEscapeField(r.isArchived) +
      "\",\"groupId\":\"" +
      jsonEscapeField(r.groupId) +
      "\",\"lastViewedAt\":\"" +
      jsonEscapeField(r.lastViewedAt) +
      "\",\"parentSessionId\":\"" +
      jsonEscapeField(r.parentSessionId) +
      "\",\"forkedFromMessageId\":\"" +
      jsonEscapeField(r.forkedFromMessageId) +
      "\",\"pendingCount\":\"" +
      jsonEscapeField(r.pendingCount) +
      "\",\"ledgerAttention\":\"" +
      jsonEscapeField(r.ledgerAttention) +
      "\",\"attention\":\"" +
      attention +
      "\"}"
    i = i + 1
  }
  return json + "]}"
}

/// All of the current user's sessions, most recently active first.
pub func getSessions(sc: in CloudAgents.Pg.TenantScope): Result[AgentSessionArray, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.getSessions(sc)
}

// ── Control-character helpers ─────────────────────────────────────────────────
// Same approach as CloudAgents.Streaming / Lyric.Docker: JSON forbids raw
// control characters in string literals, and Lyric literals cannot express
// them, so construction goes through the BCL. The single-char control-character
// test lives in CloudAgents.Text (isControlChar); these char<->code-point
// externs are session-store-specific.
@externTarget("System.Char.ConvertFromUtf32")
func charFromCode(code: in Int): String = ()

/// Inverse of charFromCode: the code point of the char at `index` in `s`. Lets
/// controlEscape resolve a control char in O(1) instead of scanning all 32
/// control codes (#171).
@externTarget("System.Char.ConvertToUtf32")
func codeFromChar(s: in String, index: in Int): Int = ()

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
  // Read the code point directly (O(1)) instead of scanning charFromCode for
  // all 32 control codes to find the one matching `c` (#171).
  val code = codeFromChar(c, 0)
  if code < 16 {
    return "\\u000" + hexDigit(code)
  }
  return "\\u001" + hexDigit(code - 16)
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
    } else if CloudAgents.Text.isControlChar(c) {
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
    "\",\"status\":\"" +
    jsonEscapeField(s.status) + "\"}"
}

/// Persist a new session (status defaults to IDLE unless `session.status`
/// says otherwise, owned by the current user).
pub func addSession(session: in AgentSession, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.addSession(session, sc)
}

/// The status column of a session (the authoritative RUNNING signal, set
/// synchronously by tryBeginRun before the container exists), or None. Shaped
/// like getMessageSessionId — a plain Option[String], deliberately avoiding a
/// custom record on this path.
pub func sessionStatus(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Option[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.sessionStatus(sessionId, sc)
}

/// Associate a session with a profile (empty string clears it). Scoped to the
/// current user. Kept off the AgentSession record — the profile drives
/// container construction, not the client-facing session shape — and read back
/// via sessionProfileId, mirroring sessionStatus.
pub func setSessionProfile(sessionId: in String, sc: in CloudAgents.Pg.TenantScope, profileId: in String): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.setSessionProfile(sessionId, sc, profileId)
}

/// The profile id a session runs under ("" when none), or None if the session
/// does not exist / is not owned by the current user.
pub func sessionProfileId(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Option[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.sessionProfileId(sessionId, sc)
}

/// A single session owned by the current user, or None.
pub func getSession(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Option[AgentSession], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.getSession(sessionId, sc)
}

// The two container-bookkeeping writes below run on Docker's async worker
// threads (see CloudAgents.Docker), where the per-request thread-local
// identity does NOT flow — so they take the owner explicitly, captured on the
// request thread. Deliberately NO parameterless ambient-identity forms: they
// were dead in production and an invitation to reintroduce the
// wrong-tenant-on-a-worker-thread bug (#426).
pub func updateSessionContainerFor(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, containerId: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.updateSessionContainerFor(sessionId, sc, containerId)
}

/// Compare-and-clear the container id: only clears it if it still equals
/// `containerId`, so a late-finishing orphaned run can't wipe the container id a
/// newer run for the same session has since stored (#45).
pub func clearSessionContainerIfMatchesFor(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, containerId: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.clearSessionContainerIfMatchesFor(sessionId, sc, containerId)
}

pub func updateSessionModel(sessionId: in String, sc: in CloudAgents.Pg.TenantScope, model: in String): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.updateSessionModel(sessionId, sc, model)
}

pub func updateSessionArchived(sessionId: in String, sc: in CloudAgents.Pg.TenantScope, isArchived: in String): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.updateSessionArchived(sessionId, sc, isArchived)
}

/// Associate a session with a group (empty string clears it). Scoped to the
/// current user; group existence/ownership is validated in the handler
/// (CloudAgents.Groups), mirroring setSessionProfile.
pub func setSessionGroup(sessionId: in String, sc: in CloudAgents.Pg.TenantScope, groupId: in String): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.setSessionGroup(sessionId, sc, groupId)
}

/// Stamp "the user looked at this session just now" (last_viewed_at =
/// nowMillis). Scoped to the current user.
pub func markSessionViewed(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.markSessionViewed(sessionId, sc)
}

/// Remove a session, returning the record that was removed (None when it did
/// not exist or is not owned by the current user).
pub func removeSession(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Option[AgentSession], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.removeSession(sessionId, sc)
}

/// Delete a session row without re-reading it first — for callers that have
/// already fetched and existence-checked the session (e.g. deleteSession, which
/// looks it up to terminate the container), avoiding a redundant second lookup
/// (#172). The DELETE is owner-scoped and a no-op if the row is already gone.
pub func deleteSessionRecord(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.deleteSessionRecord(sessionId, sc)
}

// ─── Run status ───────────────────────────────────────────────────────────────
// Several API instances may serve the same database
// (docs/phase11-postgres-tenancy.md §5.3a). The instance that starts a run
// drives it and renews the session's heartbeat while it does; a RUNNING
// session whose heartbeat has stopped is stranded, and the maintenance sweep
// (CloudAgents.Handlers.reapContainers) takes it over and frees it. Instance
// startup no longer resets RUNNING sessions, which would kill runs another
// instance is driving.

/// How often a driving instance renews a running session's heartbeat.
pub val runHeartbeatIntervalMs: Int = 30000

/// A RUNNING session whose heartbeat is this old is stranded.
pub val strandedRunAfterMs: Int = 120000

/// This instance's name, recorded on the runs it drives:
/// `CLOUDAGENTS_INSTANCE_ID`, else the host name (a container's id under
/// Docker), else the machine name and process id. Each is fixed for the
/// process's life, so every call returns the same name without shared state
/// (#1200), and two instances never share one (#1196).
pub func instanceId(): String {
  val configured = Env.GetEnvironmentVariable("CLOUDAGENTS_INSTANCE_ID")
  if not DotNetString.IsNullOrEmpty(configured) {
    return configured
  }
  val host = Env.GetEnvironmentVariable("HOSTNAME")
  if not DotNetString.IsNullOrEmpty(host) {
    return host
  }
  return Env.MachineName + "-" + toString(Env.ProcessId)
}

/// The name a sweep on this instance takes stranded runs over under.
pub func sweeperId(): String {
  return "sweep:" + instanceId()
}

/// Atomically claim a session for a run. Ok(false) means another run is
/// already in progress (the caller should respond 409); the single UPDATE
/// with a status guard makes two concurrent sends unable to both win. The
/// claim records this instance and the run's first heartbeat.
pub func tryBeginRun(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.tryBeginRun(sessionId, sc)
}

/// Renew the heartbeat of a run this instance drives. Ok(false) when the
/// session is no longer running here (it ended, or a sweep took it over).
pub func heartbeatRun(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.heartbeatRun(sessionId, sc)
}

/// Return a session to IDLE after a run (success or failure) and record the
/// activity time.
pub func endRun(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.endRun(sessionId, sc)
}

/// A stranded run the sweep has taken over. `containerId` is the container
/// the run was using ("" if it had none yet), and `previousInstance` the
/// instance that stopped heartbeating.
pub record StrandedRun {
  pub tenantScope: CloudAgents.Pg.TenantScope
  pub sessionId: String
  pub containerId: String
  pub previousInstance: String
  pub sweeper: String
}

/// Take over up to `limit` stranded runs, across every user: RUNNING
/// sessions with no heartbeat for `strandedRunAfterMs`. Taking one over
/// renews its heartbeat under this instance's sweeper name, so an
/// overlapping sweep on any instance does not take it too. The caller
/// terminates the container, records the outcome and calls
/// `releaseStrandedRun` (SessionStore cannot reach CloudAgents.Docker).
pub func claimStrandedRuns(limit: in Int): Result[slice[StrandedRun], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.claimStrandedRuns(limit)
}

/// Return a stranded session to IDLE once its container is gone. Ok(false)
/// when the sweep no longer holds it.
pub func releaseStrandedRun(r: in StrandedRun): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.releaseStrandedRun(r)
}

// ─── Idle container reaping ─────────────────────────────────────────────────────
/// A WARM session whose container is past the warm window and should be stopped.
pub record ReapTarget {
  pub tenantScope: CloudAgents.Pg.TenantScope
  pub sessionId: String
  pub containerId: String
}

/// Sessions whose WARM container has been idle past the warm window — ready for
/// the reaper to stop. System-wide (reaping is maintenance, not per-request).
/// The age filter runs in SQL; the caller (which can reach CloudAgents.Docker)
/// calls reapWarmSession and terminates the container only if that wins.
pub func reapableWarmContainers(): Result[slice[ReapTarget], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.reapableWarmContainers()
}

/// The warm window in seconds, for the Postgres reaper's claim.
pub func warmWindowSeconds(): String {
  return toString(CloudAgents.Db.warmWindowMillis() / 1000.toLong())
}

/// Free a reap target's session row: Ok(true) when it was still WARM on the
/// same container, in which case the caller terminates the container. Ok(false)
/// when a run has started on it since, or another reaper got there first.
pub func reapWarmSession(t: in ReapTarget): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.reapWarmSession(t)
}

/// Return one of the caller's sessions to IDLE and drop its container
/// reference, after the caller has terminated the container. A no-op while a
/// run is in progress.
pub func resetSessionContainer(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.resetSessionContainer(sessionId, sc)
}

// ─── Phase 6: MCP-callback bearer token ──────────────────────────────────────
//
// Minted at container creation (see CloudAgents.Docker.createRunnerContainer,
// gated by the CLOUD_AGENTS_MCP_CALLBACKS feature flag, on by default as of
// stage 4 — docs/phase6 §8) and injected into the
// container as CLOUD_AGENTS_CALLBACK_TOKEN. The token authenticates the
// container's own calls into CloudAgents.Callbacks — it is never the user's
// OAuth/static token. Runs on Docker's worker thread (see the container-
// bookkeeping writes above), so `userId` is explicit, captured on the request
// thread.
/// Mint a fresh callback token for a session, persist ONLY its SHA-256 hash
/// (CloudAgents.Auth.hashCallbackToken), and return the raw token for the
/// caller to inject into the container's environment — the one place it ever
/// lives. Two UUIDs concatenated gives the caller ~244 bits of randomness —
/// generous for a bearer secret that expires with the session (docs/phase6
/// §2) — without introducing a new CSPRNG binding beyond the one Std.Uuid
/// already provides. A fresh token is minted on every container start, which
/// replaces the stored hash.
pub func mintCallbackToken(sessionId: in String, sc: in CloudAgents.Pg.TenantScope): Result[String, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.mintCallbackToken(sessionId, sc)
}

/// A session's stored callback-token hash by id ONLY ("" / None handling
/// lives in the caller) — deliberately unscoped by user_id, since the
/// container presenting a candidate token has no user identity of its own;
/// hashing the presented token and comparing it in constant time against this
/// value (CloudAgents.Auth.authorizeCallback) is the authentication. Returns
/// None only when the session id does not exist at all; an existing session
/// that never minted a token (callbacks disabled, or a pre-migration-0036
/// token that was cleared) reads back "".
pub func callbackTokenHashForSession(sessionId: in String): Result[Option[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.callbackTokenHashForSession(sessionId)
}

/// A session's owning user id by id ONLY — deliberately unscoped by the
/// current identity, mirroring callbackTokenHashForSession. Used by
/// request_secret's create path (docs/phase6-mcp-callbacks.md §7.1): the
/// container-originated caller is stamped as the operator, not the session
/// owner, so resolving whose credential store to check needs this unscoped
/// lookup rather than the owner-scoped getSession above.
pub func sessionOwnerUserId(sessionId: in String): Result[Option[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.sessionOwnerUserId(sessionId)
}

/// The scope a session's container callbacks run under (spec §5.2's
/// callback-token resolver): its owner's personal tenant, or None for an
/// unknown session. Deliberately unscoped by the current identity, like
/// sessionOwnerUserId; callers authenticate the presented token against
/// callbackTokenHashForSession before acting in this scope. The Postgres
/// store reads the same answer from `session_routes`.
pub func sessionRouteScope(sessionId: in String): Result[Option[CloudAgents.Pg.TenantScope], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Sessions.sessionRouteScope(sessionId)
}

