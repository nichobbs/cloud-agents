//! src/tools.l — CloudAgents.Shim.Tools: the three MCP tool handlers
//! (docs/phase6-mcp-callbacks.md §3-4), wrapping CloudAgents.Shim.Callbacks'
//! state machine in the exact wire shapes each tool's caller expects.
//!
//! `request_permission` is Claude Code's `--permission-prompt-tool`
//! contract: the tool's argument shape (`tool_use_id`, `tool_name`,
//! `input`) and its required text-content response shape
//! (`{"behavior":"allow","updatedInput":{...}}` /
//! `{"behavior":"deny","message":"..."}`) are an external contract this
//! file must match exactly, not an internal design choice — see
//! `handleRequestPermission` below.
//!
//! Every `call` implementation is wrapped in `try { } catch Bug as b { }`
//! (the extern-boundary exception-conversion idiom, docs/lyric/gotchas.md
//! "FFI") so an unexpected internal panic degrades to a safe result
//! (fail-closed deny for `request_permission`, an `isError` result for the
//! other two) instead of tearing down the whole `serveStdio` loop.
package CloudAgents.Shim.Tools

import Std.Core
import JsonRpc.Json
import Mcp
import CloudAgents.Shim.Transport
import CloudAgents.Shim.Callbacks

// defaultPollIntervalMs/defaultTimeoutMs (docs/phase6 §3: 25s poll, 10 min
// default deadline) deliberately do NOT live here as `pub val`s for
// src/main.l to read cross-package: a confirmed self-hosted MSIL codegen
// bug (bisected directly — reading a cross-package `pub val` and using it
// to construct three different record types in one function panics
// `System.InvalidProgramException` at JIT time, even though the exact same
// value hardcoded as a literal compiles and runs fine) makes that break.
// Same root-cause family as lyric-mcp's own documented workaround
// (README.md "Upstream compiler bugs" #2: a package-qualified constant read
// inside a function silently misbehaves) — the fix there and here is the
// same: no cross-package qualified constant reads at a call site that
// matters. main.l owns these two literals directly instead.
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

// ── request_permission ──────────────────────────────────────────────────────
pub func requestPermissionSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField(
              "tool_use_id",
              "Identifier for this permission request, echoed by Claude Code."
            ),
            stringSchemaField(
              "tool_name",
              "The name of the tool Claude wants to use, e.g. Bash, Write, Edit."
            ),
            JsonField(
              name = "input",
              value = JObject(
                fields = [
                  JsonField(name = "type", value = JString(value = "object")),
                  JsonField(
                    name = "description",
                    value = JString(
                      value = "The tool's proposed input parameters."
                    )
                  )
                ]
              )
            )
          ]
        )
      ),
      JsonField(
        name = "required",
        value = JArray(items = [JString(value = "tool_name"), JString(value = "input")])
      )
    ]
  )
}

func allowPayload(updatedInput: in JsonValue): String {
  writeValue(
    JObject(
      fields = [
        JsonField(name = "behavior", value = JString(value = "allow")),
        JsonField(name = "updatedInput", value = updatedInput)
      ]
    )
  )
}

func denyPayload(message: in String): String {
  writeValue(
    JObject(
      fields = [
        JsonField(name = "behavior", value = JString(value = "deny")),
        JsonField(name = "message", value = JString(value = message))
      ]
    )
  )
}

/// `Deny`'s corresponding `McpToolResult` — always `isError: false`
/// (`toolTextResult`, not `toolErrorResult`): a deny decision is a
/// successfully-computed protocol response, not a tool execution failure,
/// per docs/phase6 §3 and the MCP spec's isError convention.
func deny(message: in String): McpToolResult {
  toolTextResult(denyPayload(message))
}

/// Resolve the host's `updatedInputJson` against the tool's original
/// `input`: empty means "unchanged" (use `originalInput`); non-empty must
/// parse as JSON or the whole decision is treated as malformed and denied
/// (fail-closed — a human answered "allow" but the host handed back
/// unparseable JSON is a protocol violation this shim must not paper over
/// by silently falling back to the original, potentially-more-permissive
/// input).
func resolveUpdatedInput(updatedInputJson: in String, originalInput: in JsonValue): Option[JsonValue] {
  if updatedInputJson.length == 0 {
    return Some(value = originalInput)
  }
  match parseValue(updatedInputJson) {
    case Ok(v) -> Some(value = v)
    case Err(_) -> None
  }
}

pub record RequestPermissionTool {
  pub transport: CallbackTransport
  pub pollIntervalMs: Int
  pub timeoutMs: Int
}

func handleRequestPermission(tool: in RequestPermissionTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args {
    case Some(v) -> v
    case None -> return deny("missing arguments: 'tool_name' and 'input' are required")
  }
  val toolName = match getString(a, "tool_name") {
    case Some(t) -> t
    case None -> return deny("missing required argument 'tool_name'")
  }
  val inputValue = match getField(a, "input") { case Some(v) -> v; case None -> JObject(fields = newList()) }
  val inputJson = writeValue(inputValue)
  val outcome = CloudAgents.Shim.Callbacks.requestPermission(
    tool.transport,
    toolName,
    inputJson,
    tool.pollIntervalMs,
    tool.timeoutMs
  )
  return match outcome {
    case Allow(updatedInputJson) -> match resolveUpdatedInput(updatedInputJson, inputValue) { case Some(v) -> toolTextResult(allowPayload(v)); case None -> deny("the cloud-agents host returned a malformed updatedInput; denying for safety") }
    case Deny(message) -> deny(message)
  }
}

impl McpToolHandler for RequestPermissionTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleRequestPermission(self, args))
    } catch Bug as b {
      Ok(value = deny("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── ask_user ─────────────────────────────────────────────────────────────────
pub func askUserSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField("question", "The question to ask the human."),
            JsonField(
              name = "options",
              value = JObject(
                fields = [
                  JsonField(name = "type", value = JString(value = "array")),
                  JsonField(
                    name = "items",
                    value = JObject(
                      fields = [
                        JsonField(
                          name = "type",
                          value = JString(value = "string")
                        )
                      ]
                    )
                  ),
                  JsonField(
                    name = "description",
                    value = JString(
                      value = "Optional multiple-choice options."
                    )
                  )
                ]
              )
            )
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "question")]))
    ]
  )
}

pub record AskUserTool {
  pub transport: CallbackTransport
  pub pollIntervalMs: Int
  pub timeoutMs: Int
}

func handleAskUser(tool: in AskUserTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args {
    case Some(v) -> v
    case None -> return toolErrorResult("missing arguments: 'question' is required")
  }
  val question = match getString(a, "question") {
    case Some(q) -> q
    case None -> return toolErrorResult("missing required argument 'question'")
  }
  val optionsJson = match getField(a, "options") { case Some(v) -> writeValue(v); case None -> "" }
  return match CloudAgents.Shim.Callbacks.askUser(tool.transport, question, optionsJson, tool.pollIntervalMs, tool.timeoutMs) {
    case Ok(answer) -> toolTextResult(answer)
    case Err(message) -> toolErrorResult(message)
  }
}

impl McpToolHandler for AskUserTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleAskUser(self, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── report_progress ──────────────────────────────────────────────────────────
pub func reportProgressSchema(): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            stringSchemaField("summary", "A short status line describing current progress."),
            JsonField(
              name = "percentComplete",
              value = JObject(
                fields = [
                  JsonField(name = "type", value = JString(value = "number")),
                  JsonField(
                    name = "description",
                    value = JString(
                      value = "Optional 0-100 completion estimate."
                    )
                  )
                ]
              )
            )
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "summary")]))
    ]
  )
}

pub record ReportProgressTool {
  pub transport: CallbackTransport
}

func handleReportProgress(tool: in ReportProgressTool, args: in Option[JsonValue]): McpToolResult {
  val a = match args {
    case Some(v) -> v
    case None -> return toolErrorResult("missing arguments: 'summary' is required")
  }
  val summary = match getString(a, "summary") {
    case Some(s) -> s
    case None -> return toolErrorResult("missing required argument 'summary'")
  }
  val percent = match getInt(a, "percentComplete") {
    case Some(n) -> toString(n)
    case None -> match getString(a, "percentComplete") { case Some(s) -> s; case None -> "" }
  }
  CloudAgents.Shim.Callbacks.reportProgress(tool.transport, summary, percent)
  return toolTextResult("progress reported")
}

impl McpToolHandler for ReportProgressTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = handleReportProgress(self, args))
    } catch Bug as b {
      // Fire-and-forget even on an internal error — never fail the
      // agent's turn over a progress report (see CloudAgents.Shim.Callbacks
      // .reportProgress's own module doc).
      CloudAgents.Shim.Transport.eprintln("cloud-agents-shim: report_progress handler error: " + b.message)
      Ok(value = toolTextResult("progress reported"))
    }
  }
}
