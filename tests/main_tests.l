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

// NOT covered here: HealthHandler.handle() / AuthMiddleware.wrap() end-to-end,
// i.e. actually driving the Handler/Middleware interfaces with a constructed
// Web.Request. Attempted and reverted (#351 follow-up, see PR #342 history):
// constructing a Web.Request record — even unqualified, per the
// package-qualified-record-construction gotcha in docs/lyric/gotchas.md —
// crashes every test that reaches it with "Common Language Runtime detected
// an invalid program" (a bare System.InvalidProgramException, no further
// detail). Isolated by removing everything from the failing tests except the
// Request construction itself: HealthHandler.handle(req) fails even though it
// never reads any field of req, which places the crash in constructing the
// Request value (record literal and/or its Map[String,String] fields), not in
// the Handler/Middleware method bodies. Web's public API has no alternative
// Request-constructing function to route around this with. This is the same
// class of "compiles fine, crashes only when actually exercised" defect this
// project has hit before in Lyric.Web/the compiler (see docs/BUILD.md
// "Compiler notes"), but is not yet confirmed against a live HTTP request —
// only against a hand-constructed Request in this test process. Until it's
// resolved (or Web ships a `Request`-constructing helper), Handler/Middleware
// runtime behavior is exercised only implicitly, via the real HTTP server
// (scripts/run-api.sh) — not by an automated test.

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
