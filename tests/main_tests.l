@test_module
package CloudAgents.MainTests

import Std.Core
import Std.Testing
import CloudAgents
import Web
import extern System.Environment as Env

// A stub next-in-chain Handler for driving AuthMiddleware.wrap() directly —
// returns a response distinguishable from AuthMiddleware's own 401 denial.
record NextOkHandler {}
impl Web.Handler for NextOkHandler {
  func handle(req: in Web.Request): Web.Response {
    return Web.noContent()
  }
}

// Package-qualified record construction fails at runtime (docs/lyric/gotchas.md)
// — construct Request unqualified (Web is imported above) rather than as
// Web.Request(...).
func makeRequest(path: in String, authHeader: in String): Web.Request {
  var headers = Map.empty[String, String]()
  if authHeader.length > 0 {
    headers = headers.put("Authorization", authHeader)
  }
  return Request(
    method = "GET",
    path = path,
    pathParams = Map.empty[String, String](),
    queryParams = Map.empty[String, String](),
    headers = headers,
    body = "",
  )
}

test "unitResp maps Ok to 204 and Err to the error's own status (#351)" {
  assertEqualInt(unitResp(Ok(value = ())).status, 204, "Ok(Unit) -> 204 No Content")
  assertEqualInt(unitResp(Err(error = Web.badRequest("bad"))).status, 400, "Err(badRequest) -> 400")
  assertEqualInt(unitResp(Err(error = Web.notFound("missing"))).status, 404, "Err(notFound) -> 404")
}

test "jsonStringResp passes a pre-built JSON string through with a 200, maps Err to its status (#351)" {
  assertEqualInt(jsonStringResp(Ok(value = "{\"sessions\":[]}")).status, 200, "Ok(json) -> 200")
  assertEqualInt(jsonStringResp(Err(error = Web.internalError("db down"))).status, 500, "Err(internalError) -> 500")
}

test "HealthHandler.handle returns a real HTTP status (#351)" {
  // checkHealth() pings the DB; this suite's default env may or may not have
  // one configured. Either way the adapter must route through
  // Web.json/Web.errorResponse without crashing.
  val resp = HealthHandler().handle(makeRequest("/api/health", ""))
  assertTrue(resp.status == 200 or resp.status == 500, "health check completes with a real HTTP status")
}

test "AuthMiddleware allows /api/health through with no token configured (#351)" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_API_TOKEN", "")
  val resp = AuthMiddleware().wrap(makeRequest("/api/health", ""), NextOkHandler())
  assertEqualInt(resp.status, 204, "health bypasses auth entirely")
}

test "AuthMiddleware lets requests through when no API token is configured (#351)" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_API_TOKEN", "")
  val resp = AuthMiddleware().wrap(makeRequest("/api/sessions", ""), NextOkHandler())
  assertEqualInt(resp.status, 204, "unconfigured token means auth is open (matches authorize()'s documented contract)")
}

test "AuthMiddleware denies a missing or wrong bearer token once CLOUD_AGENTS_API_TOKEN is configured (#78/#211/#351)" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_API_TOKEN", "secret-token")
  val noAuth = AuthMiddleware().wrap(makeRequest("/api/sessions", ""), NextOkHandler())
  assertEqualInt(noAuth.status, 401, "missing Authorization header is denied")
  val wrongAuth = AuthMiddleware().wrap(makeRequest("/api/sessions", "Bearer nope"), NextOkHandler())
  assertEqualInt(wrongAuth.status, 401, "wrong token is denied")
  val rightAuth = AuthMiddleware().wrap(makeRequest("/api/sessions", "Bearer secret-token"), NextOkHandler())
  assertEqualInt(rightAuth.status, 204, "correct token is let through")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_API_TOKEN", "")
}

test "AuthMiddleware's default-deny on credential routes holds even with no token configured (#78/#211/#351)" {
  // routeRequiresSecret gates /api/credentials specifically: with no token
  // configured at all, the general authorize() path is wide open, but
  // authorizeSecret's default-deny still refuses credential routes.
  Env.SetEnvironmentVariable("CLOUD_AGENTS_API_TOKEN", "")
  val resp = AuthMiddleware().wrap(makeRequest("/api/credentials", ""), NextOkHandler())
  assertEqualInt(resp.status, 401, "credential routes refuse even when no token is configured")
}

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
