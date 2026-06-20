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
