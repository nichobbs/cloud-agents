@test_module
package CloudAgents.AuthTests

import Std.Core
import Std.Testing
import CloudAgents.Auth

test "Bearer token extraction" {
  match extractBearerToken("Bearer xyz123") {
    case Some(t) -> assertEqual(t, "xyz123", "extracts token")
    case None -> assertTrue(false, "should extract a valid bearer token")
  }
  match extractBearerToken("Basic abc") {
    case Some(_) -> assertTrue(false, "wrong scheme must not parse")
    case None -> assertTrue(true, "non-bearer -> None")
  }
  match extractBearerToken("Bearer ") {
    case Some(_) -> assertTrue(false, "empty token must not parse")
    case None -> assertTrue(true, "empty token -> None")
  }
}

test "Whitelist access control" {
  assertTrue(isWhitelisted("42", ""), "empty whitelist = open access")
  assertTrue(isWhitelisted("42", "1, 42 ,99"), "present (with spaces) is allowed")
  assertFalse(isWhitelisted("7", "1,42,99"), "absent id is denied")
}

test "Validation cache expiry" {
  val entry = CachedToken(userId = "42", login = "octocat", expiresAtMillis = 1000.toLong())
  assertTrue(isCacheValid(entry, 999.toLong()), "valid before expiry")
  assertFalse(isCacheValid(entry, 1000.toLong()), "invalid at expiry")
  assertFalse(isCacheValid(entry, 2000.toLong()), "invalid after expiry")
  assertEqual(toString(cacheExpiry(1000.toLong(), 3600.toLong())), "3601000", "now + ttl seconds")
}

test "Resource ownership" {
  assertTrue(ownsResource("42", "42"), "owner matches")
  assertFalse(ownsResource("42", "7"), "non-owner rejected")
}

func outcomeLabel(o: in AuthOutcome): String {
  return match o {
    case Allowed(uid) -> "allow:" + uid
    case Denied(e) -> "deny:" + authErrorMessage(e)
  }
}

test "Constant-time equality" {
  assertTrue(constantTimeEquals("abc", "abc"), "equal strings match")
  assertFalse(constantTimeEquals("abc", "abd"), "differing strings differ")
  assertFalse(constantTimeEquals("abc", "abcd"), "different lengths differ")
  assertFalse(constantTimeEquals("", "x"), "empty vs non-empty differ")
  assertTrue(constantTimeEquals("", ""), "empty equals empty")
}

test "Static-token authorization" {
  // No token configured -> open (general routes), resolves the operator id.
  assertEqual(outcomeLabel(authorize("", "")), "allow:default", "unconfigured token allows")
  assertEqual(outcomeLabel(authorize("Bearer anything", "")), "allow:default", "unconfigured ignores header")

  // Configured token -> must present a matching bearer.
  assertEqual(outcomeLabel(authorize("Bearer secret", "secret")), "allow:default", "correct token allowed")
  assertEqual(outcomeLabel(authorize("Bearer wrong", "secret")), "deny:invalid or expired GitHub token", "wrong token denied")
  assertEqual(outcomeLabel(authorize("", "secret")), "deny:missing Authorization bearer token", "missing header denied")
  assertEqual(outcomeLabel(authorize("Basic secret", "secret")), "deny:missing Authorization bearer token", "wrong scheme denied")
}

test "Secret routes refuse unconfigured auth" {
  // Credential endpoints must never run open, even where general routes would.
  assertEqual(outcomeLabel(authorizeSecret("", "")), "deny:user is not on the access whitelist", "no token -> secret route denied")
  assertEqual(outcomeLabel(authorizeSecret("Bearer secret", "secret")), "allow:default", "configured + correct -> allowed")
  assertEqual(outcomeLabel(authorizeSecret("Bearer wrong", "secret")), "deny:invalid or expired GitHub token", "configured + wrong -> denied")
}

test "GitHub /user response parsing" {
  val body = "{\"login\":\"octocat\",\"id\":583231,\"type\":\"User\"}"
  assertEqual(parseJsonString(body, "login"), "octocat", "login")
  assertEqual(parseJsonString(body, "type"), "User", "type")
  assertEqual(parseJsonNumber(body, "id"), "583231", "id number")
  assertEqual(parseJsonString(body, "missing"), "", "missing string field -> empty")
  assertEqual(parseJsonNumber(body, "missing"), "", "missing number field -> empty")
  assertEqual(parseJsonNumber("{\"id\": 42 }", "id"), "42", "number with surrounding spaces")
  assertEqual(toString(indexOfFrom("hello world", "world", 0)), "6", "indexOfFrom found")
  assertEqual(toString(indexOfFrom("hello", "zzz", 0)), "-1", "indexOfFrom not found")
}
