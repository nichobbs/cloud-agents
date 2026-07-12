@test_module
package CloudAgents.MainTests

import Std.Core
import Std.Testing
import CloudAgents
import Web

test "unitResp maps Ok to 204 and Err to the error's own status (#351)" {
  assertEqualInt(unitResp(Ok(value = ())).status, 204, "Ok(Unit) -> 204 No Content")
  assertEqualInt(unitResp(Err(error = Web.badRequest("bad"))).status, 400, "Err(badRequest) -> 400")
  assertEqualInt(unitResp(Err(error = Web.notFound("missing"))).status, 404, "Err(notFound) -> 404")
}

test "jsonStringResp passes a pre-built JSON string through with a 200, maps Err to its status (#351)" {
  assertEqualInt(jsonStringResp(Ok(value = "{\"sessions\":[]}")).status, 200, "Ok(json) -> 200")
  assertEqualInt(jsonStringResp(Err(error = Web.internalError("db down"))).status, 500, "Err(internalError) -> 500")
}

// NOT covered here: HealthHandler.handle() / AuthMiddleware.wrap() end-to-end
// against a hand-constructed Web.Request. Filed as a tracked upstream defect
// (nichobbs/cloud-agents#355) rather than left only as this comment — see that
// issue for the full reproduction. Summary: constructing a Web.Request record
// (unqualified, per docs/lyric/gotchas.md's package-qualified-record-
// construction rule; with `import Std.Collections` for Map, ruled out as the
// cause by direct test) crashes at runtime with a bare "Common Language
// Runtime detected an invalid program" — reproduced twice, isolated to
// construction itself (HealthHandler.handle(req) fails even though it never
// reads a field of req). Web's public API has no alternative
// Request-constructing function to route around this. Does not prove the live
// server is broken: main.l's adapters only ever RECEIVE a Request as a
// parameter (from the framework) and read/query it — they never construct
// one, unlike this reverted test harness — so Handler/Middleware runtime
// behavior is exercised only implicitly via the real server
// (scripts/run-api.sh), not by an automated test, until this is resolved.

test "isValidPort accepts valid TCP ports" {
  assertTrue(isValidPort("1"), "minimum port")
  assertTrue(isValidPort("8080"), "common port")
  assertTrue(isValidPort("65535"), "maximum port")
}

test "isValidPort rejects invalid values" {
  assertFalse(isValidPort(""), "empty string")
  assertFalse(isValidPort("0"), "port zero")
  assertFalse(isValidPort("65536"), "just above maximum")
  assertFalse(isValidPort("123456"), "six digits")
  assertFalse(isValidPort("80a"), "trailing non-digit")
  assertFalse(isValidPort("-1"), "negative")
  assertFalse(isValidPort(" 80"), "leading space")
}
