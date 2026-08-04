//! src/v2_tools.l — CloudAgents.Shim.V2Tools: the three phase-6 §7 MCP tool
//! handlers (request_secret, add_followup_task, report_artifact), wrapping
//! CloudAgents.Shim.V2Client's state machines in the wire shapes MCP
//! `tools/call` expects.
//!
//! Every `call` implementation is wrapped in `try { } catch Bug as b { }`
//! (docs/lyric/gotchas.md "FFI" — the extern-boundary exception-conversion
//! idiom CloudAgents.Shim.Tools also uses) so an unexpected internal panic
//! degrades to a safe `isError` result instead of tearing down the whole
//! `serveStdio` loop.
package CloudAgents.Shim.V2Tools

import Std.Core
import JsonRpc.Json
import Mcp
import CloudAgents.Shim.V2Transport
import CloudAgents.Shim.V2Client

// Small local copy of CloudAgents.Shim.Tools' stringSchemaField: that
// function is package-private (no `pub`) so it can't be imported, and
// duplicating ~10 lines here is cheaper than widening tools.l's surface
// for a single helper.
func stringSchemaField(name: in String, description: in String): JsonField {
  JsonField(
    name = name,
    value = JObject(
      fields = [
        JsonField(name = "type", value = JString(value = "string")),
        JsonField(name = "description", value = JString(value = description))
      ]
    )
  )
}

// ── add_todo / update_todo / list_todos (session todo plan) ──────────────────
pub func addSessionTodoSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "note",
              "One step of your working plan for this session, e.g. 'Migrate the auth handler to the new API'."
            )
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "note")]))
    ]
  )
}

pub record AddSessionTodoTool {
  pub transport: V2CallbackTransport
}

func handleAddSessionTodo(tool: in AddSessionTodoTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args {
    case Some(v) -> v
    case None -> return toolErrorResult("missing arguments: 'note' is required")
  }
  val note = match getString(a, "note") {
    case Some(n) -> n
    case None -> return toolErrorResult("missing required argument 'note'")
  }
  return match CloudAgents.Shim.V2Client.addSessionTodo(tool.transport, note) {
    case Ok(id) -> toolTextResult("created todo " + id)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for AddSessionTodoTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleAddSessionTodo(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

pub func updateSessionTodoSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField("id", "The todo's id (returned by add_todo/list_todos)."),
            stringSchemaField("status", "The new status: 'pending', 'in_progress', or 'done'.")
          ]
        )
      ),
      JsonField(
        name = "required",
        value = JArray(items = [JString(value = "id"), JString(value = "status")])
      )
    ]
  )
}

pub record UpdateSessionTodoTool {
  pub transport: V2CallbackTransport
}

func handleUpdateSessionTodo(tool: in UpdateSessionTodoTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args {
    case Some(v) -> v
    case None -> return toolErrorResult("missing arguments: 'id' and 'status' are required")
  }
  val id = match getString(a, "id") {
    case Some(v) -> v
    case None -> return toolErrorResult("missing required argument 'id'")
  }
  val status = match getString(a, "status") {
    case Some(v) -> v
    case None -> return toolErrorResult("missing required argument 'status'")
  }
  return match CloudAgents.Shim.V2Client.setSessionTodoStatus(tool.transport, id, status) {
    case Ok(msg) -> toolTextResult(msg)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for UpdateSessionTodoTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleUpdateSessionTodo(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

pub func listSessionTodosSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(name = "properties", value = JObject(fields = []))
    ]
  )
}

pub record ListSessionTodosTool {
  pub transport: V2CallbackTransport
}

func handleListSessionTodos(tool: in ListSessionTodosTool, args: in Option[JsonValue]): McpToolResult {
  return match CloudAgents.Shim.V2Client.listSessionTodos(tool.transport) {
    case Ok(listing) -> toolTextResult(listing)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for ListSessionTodosTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleListSessionTodos(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── request_secret ──────────────────────────────────────────────────────────
pub func requestSecretSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "name",
              "The name of the stored credential to reveal — must match an existing credential in the user's credential store."
            ),
            stringSchemaField(
              "reason",
              "Why this credential is needed right now — shown to the human when they approve or deny."
            )
          ]
        )
      ),
      JsonField(
        name = "required",
        value = JArray(items = [JString(value = "name"), JString(value = "reason")])
      )
    ]
  )
}

pub record RequestSecretTool {
  pub transport: V2CallbackTransport
  pub pollIntervalMs: Int
  pub timeoutMs: Int
}

func handleRequestSecret(tool: in RequestSecretTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args {
    case Some(v) -> v
    case None -> return toolErrorResult("missing arguments: 'name' and 'reason' are required")
  }
  val name = match getString(a, "name") {
    case Some(n) -> n
    case None -> return toolErrorResult("missing required argument 'name'")
  }
  val reason = match getString(a, "reason") {
    case Some(r) -> r
    case None -> return toolErrorResult("missing required argument 'reason'")
  }
  return match CloudAgents.Shim.V2Client.requestSecret(tool.transport, name, reason, tool.pollIntervalMs, tool.timeoutMs) {
    // Only the file PATH ever reaches the tool result — never the value
    // (docs/phase6 §7.1's threat model: the value must never enter the
    // agent-visible transcript).
    case Approved(path) -> toolTextResult(path)
    case Refused(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for RequestSecretTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleRequestSecret(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── add_followup_task ─────────────────────────────────────────────────────────
pub func addFollowupTaskSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "description",
              "A short note describing the follow-up work for the human to pick up later."
            )
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "description")]))
    ]
  )
}

pub record AddFollowupTaskTool {
  pub transport: V2CallbackTransport
}

func handleAddFollowupTask(tool: in AddFollowupTaskTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args {
    case Some(v) -> v
    case None -> return toolErrorResult("missing arguments: 'description' is required")
  }
  val description = match getString(a, "description") {
    case Some(d) -> d
    case None -> return toolErrorResult("missing required argument 'description'")
  }
  return match CloudAgents.Shim.V2Client.addFollowupTask(tool.transport, description) {
    case Ok(id) -> toolTextResult("created follow-up task " + id)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for AddFollowupTaskTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleAddFollowupTask(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── report_artifact ───────────────────────────────────────────────────────────
pub func reportArtifactSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "path",
              "Absolute path inside the container of the file to upload (max 8 MiB)."
            ),
            stringSchemaField(
              "mimeType",
              "The artifact's MIME type, e.g. text/plain or application/pdf."
            ),
            stringSchemaField("description", "Optional description of the artifact."),
            stringSchemaField(
              "scope",
              "Optional. 'session' (default) keeps the artifact attached to this session only. 'repo' additionally scopes it to this session's repository so it is still listable in later sessions on the same repo."
            )
          ]
        )
      ),
      JsonField(
        name = "required",
        value = JArray(items = [JString(value = "path"), JString(value = "mimeType")])
      )
    ]
  )
}

pub record ReportArtifactTool {
  pub transport: V2CallbackTransport
}

func handleReportArtifact(tool: in ReportArtifactTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args {
    case Some(v) -> v
    case None -> return toolErrorResult("missing arguments: 'path' and 'mimeType' are required")
  }
  val path = match getString(a, "path") {
    case Some(p) -> p
    case None -> return toolErrorResult("missing required argument 'path'")
  }
  val mimeType = match getString(a, "mimeType") {
    case Some(m) -> m
    case None -> return toolErrorResult("missing required argument 'mimeType'")
  }
  val description = match getString(a, "description") { case Some(d) -> d; case None -> "" }
  val artifactScope = match getString(a, "scope") { case Some(s) -> s; case None -> "" }
  return match CloudAgents.Shim.V2Client.reportArtifact(tool.transport, path, mimeType, description, artifactScope) {
    case Ok(id) -> toolTextResult("uploaded artifact " + id)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for ReportArtifactTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleReportArtifact(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── remember (phase 7 §4) ─────────────────────────────────────────────────────
pub func rememberSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "key",
              "A short stable label for this memory (e.g. 'build-steps', 'test-layout'). Re-using a key overwrites its value."
            ),
            stringSchemaField(
              "value",
              "The information to remember for future sessions on this repository. Never a secret, token, or credential — memory is stored in plaintext; use request_secret for those. The host will reject values that look like a common credential format (API keys, GitHub/AWS tokens, JWTs, or other obviously randomly-generated tokens)."
            )
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "key"), JString(value = "value")]))
    ]
  )
}

pub record RememberTool {
  pub transport: V2CallbackTransport
}

func handleRemember(tool: in RememberTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args {
    case Some(v) -> v
    case None -> return toolErrorResult("missing arguments: 'key' and 'value' are required")
  }
  val key = match getString(a, "key") {
    case Some(k) -> k
    case None -> return toolErrorResult("missing required argument 'key'")
  }
  val value = match getString(a, "value") {
    case Some(v) -> v
    case None -> return toolErrorResult("missing required argument 'value'")
  }
  return match CloudAgents.Shim.V2Client.remember(tool.transport, key, value) {
    case Ok(msg) -> toolTextResult(msg)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for RememberTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleRemember(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── recall (phase 7 §4) ───────────────────────────────────────────────────────
pub func recallSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "key",
              "Optional. The specific memory key to recall. Omit to return everything remembered for this repository."
            )
          ]
        )
      )
    ]
  )
}

pub record RecallTool {
  pub transport: V2CallbackTransport
}

func handleRecall(tool: in RecallTool, args: in Option[JsonValue]): McpToolResult {
  val key = match args {
    case Some(v) -> match getString(v, "key") { case Some(k) -> k; case None -> "" }
    case None -> ""
  }
  return match CloudAgents.Shim.V2Client.recall(tool.transport, key) {
    case Ok(text) -> toolTextResult(text)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for RecallTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleRecall(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── forget (phase 7 §4, #592) ─────────────────────────────────────────────────
pub func forgetSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "key",
              "The memory key to delete for this repository — frees a slot under the entry limit."
            )
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "key")]))
    ]
  )
}

pub record ForgetTool {
  pub transport: V2CallbackTransport
}

func handleForget(tool: in ForgetTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args { case Some(v) -> v; case None -> return toolErrorResult("missing arguments: 'key' is required") }
  val key = match getString(a, "key") {
    case Some(k) -> k
    case None -> return toolErrorResult("missing required argument 'key'")
  }
  return match CloudAgents.Shim.V2Client.forget(tool.transport, key) {
    case Ok(text) -> toolTextResult(text)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for ForgetTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleForget(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── notify (phase 7 §5) ───────────────────────────────────────────────────────
pub func notifySchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "summary",
              "A short status update to push to the human right now (e.g. what finished, or what you're blocked on)."
            ),
            stringSchemaField(
              "level",
              "Optional. One of 'info', 'done', or 'blocked'. Defaults to 'info' when omitted."
            )
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "summary")]))
    ]
  )
}

pub record NotifyTool {
  pub transport: V2CallbackTransport
}

func handleNotify(tool: in NotifyTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args { case Some(v) -> v; case None -> return toolErrorResult("missing required argument 'summary'") }
  val summary = match getString(a, "summary") {
    case Some(s) -> s
    case None -> return toolErrorResult("missing required argument 'summary'")
  }
  val level = match getString(a, "level") { case Some(l) -> l; case None -> "" }
  return match CloudAgents.Shim.V2Client.notify(tool.transport, summary, level) {
    case Ok(id) -> toolTextResult("sent notification " + id)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for NotifyTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleNotify(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── add_task (phase 7 §8) ─────────────────────────────────────────────────────
pub func addTaskSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "description",
              "A short description of work to track for future sessions on this repository (e.g. 'migrate the auth module'). Distinct from add_followup_task: this is a repo-scoped backlog item a future AGENT can complete, not a session-scoped note for the human."
            )
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "description")]))
    ]
  )
}

pub record AddTaskTool {
  pub transport: V2CallbackTransport
}

func handleAddTask(tool: in AddTaskTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args {
    case Some(v) -> v
    case None -> return toolErrorResult("missing arguments: 'description' is required")
  }
  val description = match getString(a, "description") {
    case Some(d) -> d
    case None -> return toolErrorResult("missing required argument 'description'")
  }
  return match CloudAgents.Shim.V2Client.addTask(tool.transport, description) {
    case Ok(id) -> toolTextResult("created task " + id)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for AddTaskTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleAddTask(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── list_tasks (phase 7 §8) ───────────────────────────────────────────────────
pub func listTasksSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "status",
              "Optional. Filter to 'open' or 'done'. Omit to list every task regardless of status."
            )
          ]
        )
      )
    ]
  )
}

pub record ListTasksTool {
  pub transport: V2CallbackTransport
}

func handleListTasks(tool: in ListTasksTool, args: in Option[JsonValue]): McpToolResult {
  val statusFilter = match args {
    case Some(v) -> match getString(v, "status") { case Some(s) -> s; case None -> "" }
    case None -> ""
  }
  return match CloudAgents.Shim.V2Client.listTasks(tool.transport, statusFilter) {
    case Ok(text) -> toolTextResult(text)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for ListTasksTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleListTasks(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── complete_task (phase 7 §8) ────────────────────────────────────────────────
pub func completeTaskSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "id",
              "The id of the task to mark done (returned by add_task/list_tasks)."
            )
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "id")]))
    ]
  )
}

pub record CompleteTaskTool {
  pub transport: V2CallbackTransport
}

func handleCompleteTask(tool: in CompleteTaskTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args { case Some(v) -> v; case None -> return toolErrorResult("missing arguments: 'id' is required") }
  val id = match getString(a, "id") {
    case Some(i) -> i
    case None -> return toolErrorResult("missing required argument 'id'")
  }
  return match CloudAgents.Shim.V2Client.completeTask(tool.transport, id) {
    case Ok(text) -> toolTextResult(text)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for CompleteTaskTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleCompleteTask(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── schedule_job / list_jobs / update_job / cancel_job (phase 8) ────────────
// docs/phase8-scheduling.md. schedule_job always attaches THIS session, so
// every future firing continues it.
pub func scheduleJobSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField("name", "Optional short label for this job."),
            stringSchemaField(
              "prompt",
              "The message to send to THIS session each time the job fires."
            ),
            stringSchemaField(
              "runAtEpochMillis",
              "Optional. A one-shot run time as epoch milliseconds (a decimal number, as a string). Omit for a purely recurring job that starts now."
            ),
            stringSchemaField(
              "intervalSeconds",
              "Optional. Recur every this many seconds (60 to 2592000 / 30 days). Omit for a one-shot job that fires once at runAtEpochMillis and never again."
            )
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "prompt")]))
    ]
  )
}

pub record ScheduleJobTool {
  pub transport: V2CallbackTransport
}

func handleScheduleJob(tool: in ScheduleJobTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args {
    case Some(v) -> v
    case None -> return toolErrorResult("missing required argument 'prompt'")
  }
  val prompt = match getString(a, "prompt") {
    case Some(p) -> p
    case None -> return toolErrorResult("missing required argument 'prompt'")
  }
  val name = match getString(a, "name") { case Some(n) -> n; case None -> "" }
  val runAtEpochMillis = match getString(a, "runAtEpochMillis") { case Some(r) -> r; case None -> "" }
  val intervalSeconds = match getString(a, "intervalSeconds") { case Some(i) -> i; case None -> "" }
  return match CloudAgents.Shim.V2Client.scheduleJob(tool.transport, name, prompt, runAtEpochMillis, intervalSeconds) {
    case Ok(id) -> toolTextResult("scheduled job " + id)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for ScheduleJobTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleScheduleJob(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

pub func listJobsSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(name = "properties", value = JObject(fields = []))
    ]
  )
}

pub record ListJobsTool {
  pub transport: V2CallbackTransport
}

func handleListJobs(tool: in ListJobsTool, args: in Option[JsonValue]): McpToolResult {
  return match CloudAgents.Shim.V2Client.listJobs(tool.transport) {
    case Ok(listing) -> toolTextResult(listing)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for ListJobsTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleListJobs(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

pub func updateJobSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField("id", "The job's id (returned by schedule_job/list_jobs)."),
            stringSchemaField("prompt", "Optional. Replace the prompt sent on each firing."),
            stringSchemaField(
              "runAtEpochMillis",
              "Optional. Replace the schedule with a one-shot run at this epoch-millisecond time. Providing either this or intervalSeconds replaces the whole schedule."
            ),
            stringSchemaField(
              "intervalSeconds",
              "Optional. Replace the schedule with this recurring cadence in seconds (60 to 2592000)."
            ),
            stringSchemaField(
              "status",
              "Optional. One of 'active', 'paused', or 'cancelled'."
            )
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "id")]))
    ]
  )
}

pub record UpdateJobTool {
  pub transport: V2CallbackTransport
}

func handleUpdateJob(tool: in UpdateJobTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args { case Some(v) -> v; case None -> return toolErrorResult("missing required argument 'id'") }
  val id = match getString(a, "id") {
    case Some(i) -> i
    case None -> return toolErrorResult("missing required argument 'id'")
  }
  val prompt = match getString(a, "prompt") { case Some(p) -> p; case None -> "" }
  val runAtEpochMillis = match getString(a, "runAtEpochMillis") { case Some(r) -> r; case None -> "" }
  val intervalSeconds = match getString(a, "intervalSeconds") { case Some(i) -> i; case None -> "" }
  val status = match getString(a, "status") { case Some(s) -> s; case None -> "" }
  return match CloudAgents.Shim.V2Client.updateJob(tool.transport, id, prompt, "", runAtEpochMillis, intervalSeconds, status) {
    case Ok(msg) -> toolTextResult(msg)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for UpdateJobTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleUpdateJob(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

pub func cancelJobSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField("id", "The id of the job to cancel (returned by schedule_job/list_jobs). It will not fire again.")
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "id")]))
    ]
  )
}

pub record CancelJobTool {
  pub transport: V2CallbackTransport
}

func handleCancelJob(tool: in CancelJobTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args { case Some(v) -> v; case None -> return toolErrorResult("missing required argument 'id'") }
  val id = match getString(a, "id") {
    case Some(i) -> i
    case None -> return toolErrorResult("missing required argument 'id'")
  }
  return match CloudAgents.Shim.V2Client.cancelJob(tool.transport, id) {
    case Ok(msg) -> toolTextResult(msg)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for CancelJobTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleCancelJob(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}
