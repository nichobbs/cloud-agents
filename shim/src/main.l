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
//!     the same default, and CloudAgents.Docker forwards the host's value
//!     into the container at session creation, so setting it once on the
//!     host genuinely tunes both ends (#528).
//!   CLOUD_AGENTS_ENABLED_TOOLS   per-profile tool enablement
//!     (docs/phase7-autonomy.md §7): a comma-separated allowlist of tool
//!     names to register; empty/unset registers every tool (unchanged
//!     behaviour). Injected only for a 'selected'-mode profile by
//!     CloudAgents.Docker — see CloudAgents.Shim.Config.toolIsEnabled.
package CloudAgents.Shim

import Std.Core
import Mcp
import Mcp.Server
import CloudAgents.Shim.Config
import CloudAgents.Shim.Transport
import CloudAgents.Shim.Callbacks
import CloudAgents.Shim.Tools
import CloudAgents.Shim.V2Transport
import CloudAgents.Shim.V2Tools
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

func readTimeoutMs(): Int {
  CloudAgents.Shim.Config.timeoutFromRaw(readEnv("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS"))
}

func main(): Unit {
  val apiUrl = requireEnv("CLOUD_AGENTS_API_URL")
  val token = requireEnv("CLOUD_AGENTS_CALLBACK_TOKEN")
  val sessionId = requireEnv("CLOUD_AGENTS_SESSION_ID")
  val timeoutMs = readTimeoutMs()
  val pollIntervalMs = defaultPollIntervalMs
  // Phase 7 §7 per-profile tool enablement (docs/phase7-autonomy.md): an
  // empty/unset value means "no restriction" — every addTool call below
  // fires exactly as it did before this env var existed. A non-empty value
  // is a comma-separated allowlist (CloudAgents.Docker injects it only for
  // a 'selected'-mode profile) and only a listed tool is registered.
  val enabledToolsCsv = readEnv("CLOUD_AGENTS_ENABLED_TOOLS")

  val transport = HttpCallbackTransport(baseUrl = apiUrl, sessionId = sessionId, token = token)
  val v2Transport = HttpV2CallbackTransport(baseUrl = apiUrl, sessionId = sessionId, token = token)

  val server = newServer(McpImplementation(name = "cloud-agents", version = "0.1.0"))
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "request_permission") {
    addTool(
      server,
      McpToolDef(
        name = "request_permission",
        description = "Ask the human operator to allow or deny a pending tool call. Returns the JSON payload Claude Code's --permission-prompt-tool contract expects.",
        inputSchema = CloudAgents.Shim.Tools.requestPermissionSchema(),
        handler = RequestPermissionTool(transport = transport, pollIntervalMs = pollIntervalMs, timeoutMs = timeoutMs)
      )
    )
  }
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "ask_user") {
    addTool(
      server,
      McpToolDef(
        name = "ask_user",
        description = "Ask the human a free-text or multiple-choice question mid-run and wait for their answer.",
        inputSchema = CloudAgents.Shim.Tools.askUserSchema(),
        handler = AskUserTool(transport = transport, pollIntervalMs = pollIntervalMs, timeoutMs = timeoutMs)
      )
    )
  }
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "report_progress") {
    addTool(
      server,
      McpToolDef(
        name = "report_progress",
        description = "Report a short status update on the current run, shown live in the session UI.",
        inputSchema = CloudAgents.Shim.Tools.reportProgressSchema(),
        handler = ReportProgressTool(transport = transport)
      )
    )
  }
  // Phase 6 §7 v2 tools (docs/phase6-mcp-callbacks.md).
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "request_secret") {
    addTool(
      server,
      McpToolDef(
        name = "request_secret",
        description = "Ask the human to reveal a stored credential by name. Returns a local file path containing the value on approval — the value itself never appears in the tool result.",
        inputSchema = CloudAgents.Shim.V2Tools.requestSecretSchema(),
        handler = RequestSecretTool(transport = v2Transport, pollIntervalMs = pollIntervalMs, timeoutMs = timeoutMs)
      )
    )
  }
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "add_followup_task") {
    addTool(
      server,
      McpToolDef(
        name = "add_followup_task",
        description = "Leave a note for the human to follow up on later, without blocking the current run.",
        inputSchema = CloudAgents.Shim.V2Tools.addFollowupTaskSchema(),
        handler = AddFollowupTaskTool(transport = v2Transport)
      )
    )
  }
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "report_artifact") {
    addTool(
      server,
      McpToolDef(
        name = "report_artifact",
        description = "Upload a file from inside the container as a downloadable artifact on the session (max 8 MiB).",
        inputSchema = CloudAgents.Shim.V2Tools.reportArtifactSchema(),
        handler = ReportArtifactTool(transport = v2Transport)
      )
    )
  }
  // Phase 7 §4 repo-scoped memory (docs/phase7-autonomy.md).
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "remember") {
    addTool(
      server,
      McpToolDef(
        name = "remember",
        description = "Save a note keyed to this repository so future sessions on the same repo can read it back — avoids re-learning the repo each time. Do NOT store secrets, tokens, or credentials here: memory is kept in plaintext and readable by any future session on this repo. Use request_secret for credentials.",
        inputSchema = CloudAgents.Shim.V2Tools.rememberSchema(),
        handler = RememberTool(transport = v2Transport)
      )
    )
  }
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "recall") {
    addTool(
      server,
      McpToolDef(
        name = "recall",
        description = "Read back what earlier sessions remembered about this repository. Omit 'key' to load everything; pass a key for one entry.",
        inputSchema = CloudAgents.Shim.V2Tools.recallSchema(),
        handler = RecallTool(transport = v2Transport)
      )
    )
  }
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "forget") {
    addTool(
      server,
      McpToolDef(
        name = "forget",
        description = "Delete one remembered entry for this repository by key — use it to prune stale notes or free a slot when the memory limit is reached.",
        inputSchema = CloudAgents.Shim.V2Tools.forgetSchema(),
        handler = ForgetTool(transport = v2Transport)
      )
    )
  }
  // Phase 7 §8 repo-scoped task list (docs/phase7-autonomy.md). Distinct
  // from add_followup_task: this is a repo-scoped, agent-completable shared
  // backlog with an open->done lifecycle, not a session-scoped note for the
  // human.
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "add_task") {
    addTool(
      server,
      McpToolDef(
        name = "add_task",
        description = "Add a task to this repository's shared backlog for a future session (possibly a different agent) to pick up and complete. Distinct from add_followup_task, which leaves a session-scoped note for a HUMAN — this is repo-scoped and agent-completable via complete_task.",
        inputSchema = CloudAgents.Shim.V2Tools.addTaskSchema(),
        handler = AddTaskTool(transport = v2Transport)
      )
    )
  }
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "list_tasks") {
    addTool(
      server,
      McpToolDef(
        name = "list_tasks",
        description = "List this repository's shared backlog of tasks, optionally filtered by status ('open' or 'done').",
        inputSchema = CloudAgents.Shim.V2Tools.listTasksSchema(),
        handler = ListTasksTool(transport = v2Transport)
      )
    )
  }
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "complete_task") {
    addTool(
      server,
      McpToolDef(
        name = "complete_task",
        description = "Mark a task in this repository's shared backlog as done. Idempotent — completing an already-done task succeeds without error.",
        inputSchema = CloudAgents.Shim.V2Tools.completeTaskSchema(),
        handler = CompleteTaskTool(transport = v2Transport)
      )
    )
  }

  // Phase 7 §5 notify (docs/phase7-autonomy.md).
  if CloudAgents.Shim.Config.toolIsEnabled(enabledToolsCsv, "notify") {
    addTool(
      server,
      McpToolDef(
        name = "notify",
        description = "Push a short status update to the human right now (e.g. 'done', 'blocked', or a plain info update) — reaches them even if they've closed the session tab.",
        inputSchema = CloudAgents.Shim.V2Tools.notifySchema(),
        handler = NotifyTool(transport = v2Transport)
      )
    )
  }

  match serveStdio(server) {
    case Ok(_) -> ()
    case Err(e) -> {
      CloudAgents.Shim.Transport.eprintln("cloud-agents-shim: serveStdio ended: " + e)
      panic("cloud-agents-shim: serveStdio ended: " + e)
    }
  }
}
