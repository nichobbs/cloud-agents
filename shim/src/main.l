//! src/main.l — CloudAgents.Shim: cloud-agents-shim, the in-container MCP
//! callback server (docs/phase6-mcp-callbacks.md). Registers three tools
//! (request_permission, ask_user, report_progress) against Mcp.Server and
//! serves them over stdio.
//!
//! Environment contract (docs/phase6-mcp-callbacks.md §2, rendered into
//! mcp.json by docker/entrypoint.sh from docker/mcp-callbacks.json.template
//! — all three are required, minted per-session by CloudAgents.Docker):
//!   CLOUD_AGENTS_API_URL          host API base URL reachable from this container
//!   CLOUD_AGENTS_CALLBACK_TOKEN   per-session callback bearer token
//!   CLOUD_AGENTS_SESSION_ID       the session this container belongs to
//! Optional:
//!   CLOUD_AGENTS_CALLBACK_TIMEOUT_MS   client-side long-poll deadline in ms
//!     (default 600000 = 10 min); shares its name with
//!     CloudAgents.Callbacks.callbackTimeoutMillis's host-side backstop of
//!     the same default, so one env var conceptually tunes both ends.
package CloudAgents.Shim

import Std.Core
import Mcp
import Mcp.Server
import CloudAgents.Shim.Transport
import CloudAgents.Shim.Callbacks
import CloudAgents.Shim.Tools
import extern System.Environment as Env
import extern System.String as DotNetString

// Owned here rather than as a `pub val` on CloudAgents.Shim.Tools that
// main.l would read cross-package: a confirmed self-hosted MSIL codegen bug
// (see CloudAgents.Shim.Tools' module doc) panics
// `System.InvalidProgramException` when a cross-package-qualified `pub val`
// is read and used to construct three different record types in one
// function — exactly this function's shape. Hardcoding the literals here
// instead sidesteps it entirely.
/// Poll cadence between long-poll GETs (docs/phase6 §3: "25s poll").
val defaultPollIntervalMs: Int = 25000

/// Overall client-side deadline for request_permission/ask_user
/// (docs/phase6 §3: "overall timeout from env (default 10 min)").
val defaultTimeoutMs: Int = 600000

func readEnv(name: in String): String {
  val raw = Env.GetEnvironmentVariable(name)
  if DotNetString.IsNullOrEmpty(raw) {
    return ""
  }
  return raw
}

/// A missing required env var is a deployment/configuration bug, not a
/// runtime condition to recover from — panic (fail loud) rather than start
/// a shim that can only ever fail-closed-deny every permission request.
func requireEnv(name: in String): String {
  val v = readEnv(name)
  if v.length == 0 {
    panic("cloud-agents-shim: missing required environment variable " + name)
  }
  return v
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

/// Parse a run of decimal digits (only) into an Int, or -1 for anything
/// else (empty, too long, non-digit) — mirrors
/// CloudAgents.Callbacks.tryParseMillis (cloud-agents' host-side twin) so
/// both ends of CLOUD_AGENTS_CALLBACK_TIMEOUT_MS parse identically. Bounded
/// to 9 digits: realistic timeouts are minutes, not decades of
/// milliseconds, and this only ever reads an operator-set env var.
func tryParseMillis(s: in String): Int {
  if s.length == 0 or s.length > 9 {
    return -1
  }
  var n = 0
  var i = 0
  while i < s.length {
    val d = digitValue(s.substring(i, 1))
    if d < 0 {
      return -1
    }
    n = n * 10 + d
    i = i + 1
  }
  return n
}

func readTimeoutMs(): Int {
  val raw = readEnv("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS")
  if raw.length == 0 {
    return defaultTimeoutMs
  }
  val n = tryParseMillis(raw)
  if n < 0 {
    return defaultTimeoutMs
  }
  return n
}

func main(): Unit {
  val apiUrl = requireEnv("CLOUD_AGENTS_API_URL")
  val token = requireEnv("CLOUD_AGENTS_CALLBACK_TOKEN")
  val sessionId = requireEnv("CLOUD_AGENTS_SESSION_ID")
  val timeoutMs = readTimeoutMs()
  val pollIntervalMs = defaultPollIntervalMs

  val transport = HttpCallbackTransport(baseUrl = apiUrl, sessionId = sessionId, token = token)

  val server = newServer(McpImplementation(name = "cloud-agents", version = "0.1.0"))
  addTool(
    server,
    McpToolDef(
      name = "request_permission",
      description = "Ask the human operator to allow or deny a pending tool call. Returns the JSON payload Claude Code's --permission-prompt-tool contract expects.",
      inputSchema = CloudAgents.Shim.Tools.requestPermissionSchema(),
      handler = RequestPermissionTool(transport = transport, pollIntervalMs = pollIntervalMs, timeoutMs = timeoutMs)
    )
  )
  addTool(
    server,
    McpToolDef(
      name = "ask_user",
      description = "Ask the human a free-text or multiple-choice question mid-run and wait for their answer.",
      inputSchema = CloudAgents.Shim.Tools.askUserSchema(),
      handler = AskUserTool(transport = transport, pollIntervalMs = pollIntervalMs, timeoutMs = timeoutMs)
    )
  )
  addTool(
    server,
    McpToolDef(
      name = "report_progress",
      description = "Report a short status update on the current run, shown live in the session UI.",
      inputSchema = CloudAgents.Shim.Tools.reportProgressSchema(),
      handler = ReportProgressTool(transport = transport)
    )
  )

  match serveStdio(server) {
    case Ok(_) -> ()
    case Err(e) -> {
      CloudAgents.Shim.Transport.eprintln("cloud-agents-shim: serveStdio ended: " + e)
      panic("cloud-agents-shim: serveStdio ended: " + e)
    }
  }
}
