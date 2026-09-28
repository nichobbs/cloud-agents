//! src/ledger_tools.l — CloudAgents.Shim.LedgerTools: the session ledger's
//! ledger_* MCP tools (cloud-agents docs/session-ledger.md).
//!
//! Deliberately logic-free: each tool forwards its raw MCP `arguments`
//! object to the host's `POST /api/sessions/{id}/callbacks/ledger/{op}`,
//! where CloudAgents.Ledger.ToolArgs decodes it and the ledger core
//! validates it, so the argument contract lives in exactly one place. The
//! host answers every authenticated call with 200 and an envelope
//! `{ok, error, reply}` (HttpWebRequest drops non-2xx bodies, and the agent
//! needs the host's message — "cannot move #3 from queued to done" — to
//! correct itself): `ok` "true" returns `reply` as the tool's text, anything
//! else becomes an `isError` result carrying `error`.
//!
//! The descriptions and schemas below are what the agent reads to decide
//! WHEN to call each tool, so they matter as much as the host code.
package CloudAgents.Shim.LedgerTools

import Std.Core
import Std.Collections
import JsonRpc.Json
import Mcp
import CloudAgents.Shim.Transport

// ── Transport ─────────────────────────────────────────────────────────────────
/// The shim's one outbound call for every ledger tool, as an interface so
/// the tools can be tested against an in-memory fake.
pub interface LedgerTransport {
  func call(op: in String, argumentsJson: in String): Result[String, String]
}

pub record HttpLedgerTransport {
  pub baseUrl: String
  pub sessionId: String
  pub token: String
}

impl LedgerTransport for HttpLedgerTransport {
  func call(op: in String, argumentsJson: in String): Result[String, String] {
    CloudAgents.Shim.Transport.postJsonWithBearer(
      self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/ledger/" + op,
      self.token,
      argumentsJson
    )
  }
}

/// Mirrors CloudAgents.LedgerHandlers.LedgerToolEnvelope field-for-field.
@generate(Json)
pub record LedgerToolEnvelope {
  pub ok: String
  pub error: String
  pub reply: String
}

func decodeEnvelope(body: in String): Option[LedgerToolEnvelope] {
  return try {
    match LedgerToolEnvelope.fromJson(body) {
      case Ok(e) -> Some(value = e)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

/// Forward one tool call and map the host's envelope to a tool result.
pub func invokeLedger(transport: in LedgerTransport, op: in String, args: in Option[JsonValue]): McpToolResult {
  // A wildcard, not `case None`: a None that arrives through the
  // McpToolHandler interface call fails a `case None` arm at runtime
  // ("match not exhaustive"); anything but Some means no arguments.
  val body = match args { case Some(v) -> writeValue(v); case _ -> "{}" }
  val raw = match transport.call(op, body) {
    case Ok(b) -> b
    case Err(e) -> return toolErrorResult(transportFailureMessage(op, e))
  }
  return match decodeEnvelope(raw) {
    case None -> toolErrorResult("malformed response from the cloud-agents host")
    case Some(env) -> if env.ok == "true" {
      toolTextResult(env.reply)
    } else {
      toolErrorResult(nonEmptyError(op, env.error))
    }
  }
}

/// What the agent is told when the host call itself failed. A rejected
/// credential or a missing route will fail the same way on every call, so
/// the agent is told to surface it rather than to carry on and retry.
pub func transportFailureMessage(op: in String, transportError: in String): String {
  if transportError.contains("(401)") or transportError.contains("(403)") {
    return "the session ledger rejected this container's credentials (" + httpStatusOf(transportError) +
      "), so every ledger call this run will fail. Tell the user the session ledger is unavailable, and put the decisions, blockers and questions you would have recorded in your reply instead."
  }
  if transportError.contains("(404)") {
    return "the cloud-agents host has no session ledger for this session (HTTP 404), so ledger calls will not work this run. Tell the user, and put what you would have recorded in your reply instead."
  }
  return "the session ledger is unreachable (" + transportError + "); carry on and retry " + op + " later."
}

func httpStatusOf(transportError: in String): String {
  if transportError.contains("(401)") {
    return "HTTP 401"
  }
  return "HTTP 403"
}

/// The host's error text, or a message naming the operation when the host
/// sent none: the agent always gets something to act on.
pub func nonEmptyError(op: in String, hostError: in String): String {
  if hostError.trim().length.toInt() > 0 {
    return hostError
  }
  return "the session ledger refused " + op +
    " without saying why; check the arguments against the tool's schema and retry once."
}

/// One ledger_* tool: which host operation it forwards to.
pub record LedgerTool {
  pub transport: LedgerTransport
  pub op: String
}

impl McpToolHandler for LedgerTool {
  func call(args: in Option[JsonValue]): Result[McpToolResult, String] {
    try {
      Ok(value = invokeLedger(self.transport, self.op, args))
    } catch Bug as b {
      Ok(value = toolErrorResult("internal error in cloud-agents-shim: " + b.message))
    }
  }
}

// ── Schemas ───────────────────────────────────────────────────────────────────
func prop(name: in String, typ: in String, description: in String): JsonField {
  JsonField(
    name = name,
    value = JObject(
      fields = [
        JsonField(name = "type", value = JString(value = typ)),
        JsonField(name = "description", value = JString(value = description))
      ]
    )
  )
}

// JObject/JArray hold List[...]; a slice variable passed to them is not
// converted (only a literal written at the construction site is), so the
// dynamic ones below build real Lists.
func stringValues(values: in slice[String]): List[JsonValue] {
  val items: List[JsonValue] = newList()
  var i = 0
  while i < values.length {
    items.add(JString(value = values[i]))
    i = i + 1
  }
  return items
}

func fieldList(props: in slice[JsonField]): List[JsonField] {
  val fields: List[JsonField] = newList()
  var i = 0
  while i < props.length {
    fields.add(props[i])
    i = i + 1
  }
  return fields
}

func enumProp(name: in String, values: in slice[String], description: in String): JsonField {
  val items = stringValues(values)
  JsonField(
    name = name,
    value = JObject(
      fields = [
        JsonField(name = "type", value = JString(value = "string")),
        JsonField(name = "enum", value = JArray(items = items)),
        JsonField(name = "description", value = JString(value = description))
      ]
    )
  )
}

func listProp(name: in String, description: in String): JsonField {
  JsonField(
    name = name,
    value = JObject(
      fields = [
        JsonField(name = "type", value = JString(value = "array")),
        JsonField(
          name = "items",
          value = JObject(fields = [JsonField(name = "type", value = JString(value = "string"))])
        ),
        JsonField(name = "description", value = JString(value = description))
      ]
    )
  )
}

func schema(props: in slice[JsonField], required: in slice[String]): JsonValue {
  JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(name = "properties", value = JObject(fields = fieldList(props))),
      JsonField(name = "required", value = JArray(items = stringValues(required)))
    ]
  )
}

func itemProp(): JsonField {
  prop(
    "item",
    "string",
    "The work item this concerns: #12 (this repo), owner/repo#12, a GitHub issue URL, or local:<slug>. Omit for session-level entries."
  )
}

func tagsProp(): JsonField {
  listProp(
    "tags",
    "Optional labels such as tests, deps, schema, security, api-change, migration. Some raise the review level."
  )
}

func filesProp(): JsonField {
  listProp("files", "Optional repo-relative paths affected.")
}

func severityProp(): JsonField {
  enumProp(
    "severity",
    ["info", "review", "blocking"],
    "Optional. Your proposed severity; policy may raise it but never lowers it. blocking means the related item cannot proceed without a human."
  )
}

func recommendationProp(): JsonField {
  prop(
    "recommendation",
    "string",
    "What you recommend the human do or accept. Always include this when something needs review."
  )
}

func reversibleProp(): JsonField {
  prop("reversible", "boolean", "Whether this is easy to undo later. false raises it for review.")
}

func supersedesProp(): JsonField {
  prop(
    "supersedes",
    "string",
    "Optional: the id of an earlier ledger entry this one revises (e.g. after feedback rejected it)."
  )
}

pub func registerItemsSchema(): JsonValue {
  val itemSchema = JObject(
    fields = [
      JsonField(name = "type", value = JString(value = "object")),
      JsonField(
        name = "properties",
        value = JObject(
          fields = [
            prop(
              "id",
              "string",
              "#12, owner/repo#12, a GitHub issue URL, or local:<slug> for untracked work."
            ),
            prop("title", "string", "Optional short title."),
            prop("url", "string", "Optional link.")
          ]
        )
      ),
      JsonField(name = "required", value = JArray(items = [JString(value = "id")]))
    ]
  )
  schema(
    [
      JsonField(
        name = "items",
        value = JObject(
          fields = [
            JsonField(name = "type", value = JString(value = "array")),
            JsonField(name = "items", value = itemSchema),
            JsonField(
              name = "description",
              value = JString(
                value = "The work items in this batch, in the order you plan to do them."
              )
            )
          ]
        )
      )
    ],
    ["items"]
  )
}

pub func setItemStatusSchema(): JsonValue {
  schema(
    [
      itemProp(),
      enumProp(
        "state",
        ["queued", "in_progress", "pr_open", "done", "blocked", "needs_human", "skipped"],
        "The item's new state."
      ),
      prop("reason", "string", "Why. Required for blocked, needs_human and skipped."),
      listProp("blockedBy", "For blocked: the issue refs this item waits on (#3, owner/repo#3)."),
      prop(
        "prerequisiteProposal",
        "string",
        "For blocked: the work that must happen first, if it is not an existing issue."
      ),
      recommendationProp(),
      prop("prUrl", "string", "For pr_open / done: the pull request URL.")
    ],
    ["item", "state"]
  )
}

pub func recordDecisionSchema(): JsonValue {
  schema(
    [
      prop("summary", "string", "One line, at most 140 characters."),
      prop("detail", "string", "Optional markdown detail."),
      listProp("optionsConsidered", "The alternatives you weighed."),
      prop("chosen", "string", "The option you went with."),
      prop("rationale", "string", "Why a reviewer should accept this choice."),
      recommendationProp(),
      reversibleProp(),
      itemProp(),
      tagsProp(),
      filesProp(),
      severityProp(),
      supersedesProp()
    ],
    ["summary", "chosen", "rationale"]
  )
}

pub func recordDeviationSchema(): JsonValue {
  schema(
    [
      enumProp(
        "kind",
        ["deviation", "shortcut"],
        "deviation: you departed from the issue, spec or plan, or changed approach. shortcut: you did less than ideal (skipped or weakened tests, stubs, TODOs, suppressed warnings, broad catch blocks)."
      ),
      prop("summary", "string", "One line, at most 140 characters."),
      prop("detail", "string", "Optional markdown detail: what, where, and why."),
      recommendationProp(),
      reversibleProp(),
      itemProp(),
      tagsProp(),
      filesProp(),
      severityProp(),
      supersedesProp()
    ],
    ["kind", "summary"]
  )
}

pub func askSchema(): JsonValue {
  schema(
    [
      prop("question", "string", "The question, one line, at most 140 characters."),
      prop("detail", "string", "Optional context."),
      listProp("options", "Optional choices."),
      prop("proceedingWith", "string", "The default you are carrying on with while you wait. Required."),
      itemProp(),
      severityProp()
    ],
    ["question", "proceedingWith"]
  )
}

pub func noteSchema(): JsonValue {
  schema(
    [
      prop("summary", "string", "One line, at most 140 characters."),
      prop("detail", "string", "Optional markdown detail."),
      recommendationProp(),
      prop("needsReview", "boolean", "true if the human should look at this (puts it in their review queue)."),
      itemProp(),
      tagsProp(),
      filesProp()
    ],
    ["summary"]
  )
}

pub func noArgsSchema(): JsonValue {
  // Typed empties: an untyped `[]` argument materialises as List<object>
  // and fails the JsonField cast at runtime.
  val noProps: slice[JsonField] = []
  val noRequired: slice[String] = []
  schema(noProps, noRequired)
}

// ── Tool table ────────────────────────────────────────────────────────────────
/// One tool's registration data. `op` is the host route segment.
pub record LedgerToolSpec {
  pub name: String
  pub op: String
  pub description: String
}

/// Every ledger tool, in registration order. Names are kept in sync by hand
/// with cloud-agents' CloudAgents.Profiles.validShimToolNames and
/// CloudAgents.Ledger.Schema.ledgerToolNames.
pub func ledgerToolSpecs(): slice[LedgerToolSpec] {
  [
    LedgerToolSpec(
      name = "ledger_get_state",
      op = "state",
      description = "Session ledger: re-orient. Call at the start of every run and after any context compaction. Returns your work items and their states, entries still waiting for human review, recent decisions, entries the human has reviewed, and how much feedback is waiting. The human reads the ledger, not your transcript."
    ),
    LedgerToolSpec(
      name = "ledger_register_items",
      op = "register-items",
      description = "Session ledger: call once you know the list of work items for this session (e.g. the GitHub issues in a batch, or one local:<slug> item for a single task). Re-registering an item only updates its title/url."
    ),
    LedgerToolSpec(
      name = "ledger_set_item_status",
      op = "item-status",
      description = "Session ledger: call on EVERY work item state change: in_progress when you start it, pr_open/done when finished, skipped with a reason. If other work must happen first, set blocked with blockedBy and/or prerequisiteProposal plus a recommendation, then move on to the next item instead of stopping. needs_human only when a person must decide or act. An invalid move returns an error naming the allowed states."
    ),
    LedgerToolSpec(
      name = "ledger_record_decision",
      op = "decision",
      description = "Session ledger: call when you choose between viable alternatives that a reasonable reviewer might have chosen differently (libraries, data shapes, API design, scope). Include the options, what you chose, why, and a recommendation."
    ),
    LedgerToolSpec(
      name = "ledger_record_deviation",
      op = "deviation",
      description = "Session ledger: call when you depart from the issue, spec or plan, change approach mid-task (kind=deviation), or take a shortcut such as skipping or weakening tests, stubbing code, leaving TODOs, suppressing warnings or adding broad catch blocks (kind=shortcut). Be candid: unreported shortcuts are treated as more serious than reported ones."
    ),
    LedgerToolSpec(
      name = "ledger_ask",
      op = "ask",
      description = "Session ledger: call when human input would help but you can continue with a default. Name the default in proceedingWith and carry on; the answer arrives via ledger_check_feedback. Use ask_user instead only if you truly cannot continue."
    ),
    LedgerToolSpec(
      name = "ledger_note",
      op = "note",
      description = "Session ledger: leave a note for the human, such as follow-up work you recommend after this session or a discovery they should know about. Set needsReview to put it in their review queue."
    ),
    LedgerToolSpec(
      name = "ledger_check_feedback",
      op = "check-feedback",
      description = "Session ledger: call before starting each new work item, before opening a PR, and whenever a ledger reply says feedback is waiting. Returns the human's reviews and directives (each delivered once) — apply them before continuing."
    )
  ]
}

/// The input schema for a ledger tool, by op.
pub func schemaForOp(op: in String): JsonValue {
  if op == "register-items" {
    return registerItemsSchema()
  }
  if op == "item-status" {
    return setItemStatusSchema()
  }
  if op == "decision" {
    return recordDecisionSchema()
  }
  if op == "deviation" {
    return recordDeviationSchema()
  }
  if op == "ask" {
    return askSchema()
  }
  if op == "note" {
    return noteSchema()
  }
  return noArgsSchema()
}
