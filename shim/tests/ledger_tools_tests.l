//! Tests for CloudAgents.Shim.LedgerTools: the ledger_* tools forward their
//! raw arguments to the host's ledger route and map its {ok, error, reply}
//! envelope to an MCP tool result.
@test_module
package CloudAgents.Shim.LedgerToolsTests

import Std.Core
import Std.Testing
import JsonRpc.Json
import Mcp
import CloudAgents.Shim.LedgerTools

record FakeLedgerTransport {
  pub var ok: Bool
  pub var body: String
  pub var error: String
  pub var lastOp: String
  pub var lastArguments: String
  pub var calls: Int
}

impl LedgerTransport for FakeLedgerTransport {
  func call(op: in String, argumentsJson: in String): Result[String, String] {
    self.lastOp = op
    self.lastArguments = argumentsJson
    self.calls = self.calls + 1
    if self.ok {
      Ok(value = self.body)
    } else {
      Err(error = self.error)
    }
  }
}

func fakeReplying(body: in String): FakeLedgerTransport {
  return FakeLedgerTransport(ok = true, body = body, error = "", lastOp = "", lastArguments = "", calls = 0)
}

func onlyText(r: in McpToolResult): String {
  match r.content[0] {
    case TextContent(t) -> t
    case _ -> ""
  }
}

test "an ok envelope returns the host's reply as the tool text" {
  val fake = fakeReplying("{\"ok\":\"true\",\"error\":\"\",\"reply\":\"{\\\"id\\\":\\\"e1\\\"}\"}")
  val args = JObject(fields = [JsonField(name = "summary", value = JString(value = "Chose SQLite"))])
  val r = invokeLedger(fake, "decision", Some(value = args))
  assertTrue(not r.isError, "success")
  assertEqual(onlyText(r), "{\"id\":\"e1\"}", "reply passed through verbatim")
  assertEqual(fake.lastOp, "decision", "op forwarded")
  assertTrue(fake.lastArguments.contains("Chose SQLite"), "arguments forwarded: " + fake.lastArguments)
}

test "an error envelope becomes an isError result carrying the host's message" {
  val fake = fakeReplying("{\"ok\":\"false\",\"error\":\"cannot move gh:a/b#3 from queued to done\",\"reply\":\"\"}")
  val r = invokeLedger(fake, "item-status", None)
  assertTrue(r.isError, "error")
  assertEqual(onlyText(r), "cannot move gh:a/b#3 from queued to done", "host message verbatim")
  assertEqual(fake.lastArguments, "{}", "absent arguments forward as {}")
}

func failingWith(error: in String): FakeLedgerTransport {
  return FakeLedgerTransport(ok = false, body = "", error = error, lastOp = "", lastArguments = "", calls = 0)
}

record ThrowingLedgerTransport {
  pub message: String
}

impl LedgerTransport for ThrowingLedgerTransport {
  func call(op: in String, argumentsJson: in String): Result[String, String] {
    panic(self.message)
  }
}

test "an unreachable host tells the agent to carry on" {
  val fake = FakeLedgerTransport(
    ok = false,
    body = "",
    error = "connection refused",
    lastOp = "",
    lastArguments = "",
    calls = 0
  )
  val r = invokeLedger(fake, "state", None)
  assertTrue(r.isError, "error")
  assertTrue(onlyText(r).contains("unreachable"), onlyText(r))
  assertTrue(onlyText(r).contains("connection refused"), onlyText(r))
}

test "a malformed host response is an error, not a crash" {
  val r = invokeLedger(fakeReplying("<html>502</html>"), "state", None)
  assertTrue(r.isError, "error")
  assertTrue(onlyText(r).contains("malformed"), onlyText(r))
}

test "the tool table covers exactly the eight ledger tools, each with a distinct op" {
  val specs = ledgerToolSpecs()
  assertEqualInt(specs.length, 8, "eight tools")
  val expected: slice[String] = [
    "ledger_get_state",
    "ledger_register_items",
    "ledger_set_item_status",
    "ledger_record_decision",
    "ledger_record_deviation",
    "ledger_ask",
    "ledger_note",
    "ledger_check_feedback"
  ]
  var i = 0
  while i < specs.length {
    assertEqual(specs[i].name, expected[i], "tool " + toString(i))
    assertTrue(specs[i].description.startsWith("Session ledger:"), "description says when to call it")
    var j = i + 1
    while j < specs.length {
      assertTrue(specs[i].op != specs[j].op, "ops are distinct")
      j = j + 1
    }
    i = i + 1
  }
}

test "schemas declare their required fields" {
  assertTrue(
    writeValue(schemaForOp("item-status")).contains("\"required\":[\"item\",\"state\"]"),
    writeValue(schemaForOp("item-status"))
  )
  assertTrue(writeValue(schemaForOp("ask")).contains("\"proceedingWith\""), "ask requires a default")
  assertTrue(writeValue(schemaForOp("state")).contains("\"required\":[]"), "state takes no arguments")
}

test "a rejected credential tells the agent to surface it, not carry on" {
  val r = invokeLedger(
    failingWith("POST http://h/x failed: The remote server returned an error: (401) Unauthorized."),
    "decision",
    None
  )
  assertTrue(r.isError, "error")
  assertTrue(onlyText(r).contains("HTTP 401"), onlyText(r))
  assertTrue(onlyText(r).contains("Tell the user"), onlyText(r))
  assertTrue(not onlyText(r).contains("carry on"), onlyText(r))
  val forbidden = invokeLedger(failingWith("failed: (403) Forbidden."), "note", None)
  assertTrue(onlyText(forbidden).contains("HTTP 403"), onlyText(forbidden))
}

test "a missing ledger route is reported as unsupported" {
  val r = invokeLedger(failingWith("failed: (404) Not Found."), "state", None)
  assertTrue(onlyText(r).contains("HTTP 404"), onlyText(r))
  assertTrue(not onlyText(r).contains("carry on"), onlyText(r))
}

test "an error envelope without a message still says what failed" {
  val r = invokeLedger(fakeReplying("{\"ok\":\"false\",\"error\":\"\",\"reply\":\"\"}"), "deviation", None)
  assertTrue(r.isError, "error")
  assertTrue(onlyText(r).contains("deviation"), onlyText(r))
}

test "a tool called through its handler with no arguments forwards {}" {
  val fake = fakeReplying("{\"ok\":\"true\",\"error\":\"\",\"reply\":\"{}\"}")
  val tool = LedgerTool(transport = fake, op = "check-feedback")
  match tool.call(None) {
    case Ok(r) -> assertTrue(not r.isError, onlyText(r))
    case Err(e) -> assertTrue(false, e)
  }
  assertEqual(fake.lastArguments, "{}", "no arguments forward as {}")
}

test "a crash inside a tool becomes an error result" {
  val tool = LedgerTool(transport = ThrowingLedgerTransport(message = "boom"), op = "state")
  match tool.call(Some(value = JObject(fields = []))) {
    case Ok(r) -> {
      assertTrue(r.isError, "error result, not a crash")
      assertTrue(onlyText(r).contains("boom"), onlyText(r))
    }
    case Err(e) -> assertTrue(false, "handler returned Err: " + e)
  }
}

test "every op maps to its own schema" {
  assertTrue(writeValue(schemaForOp("register-items")).contains("\"required\":[\"items\"]"), "register-items")
  assertTrue(
    writeValue(schemaForOp("decision")).contains("\"required\":[\"summary\",\"chosen\",\"rationale\"]"),
    "decision"
  )
  assertTrue(writeValue(schemaForOp("deviation")).contains("\"required\":[\"kind\",\"summary\"]"), "deviation")
  assertTrue(writeValue(schemaForOp("note")).contains("\"required\":[\"summary\"]"), "note")
  assertTrue(writeValue(schemaForOp("check-feedback")).contains("\"required\":[]"), "check-feedback takes none")
}
