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
  // The loop is now bounded by the expected (second) argument's length, not
  // max(candidate, expected) (#212). A candidate longer than the secret, or
  // shorter, must still fail — with the correct prefix or not.
  assertFalse(constantTimeEquals("abcdef", "abc"), "candidate longer than secret differs")
  assertFalse(constantTimeEquals("ab", "abc"), "candidate shorter than secret differs")
  assertFalse(constantTimeEquals("xyzuvw", "abc"), "longer wrong candidate differs")
  assertFalse(constantTimeEquals("abc", ""), "non-empty candidate vs empty secret differs")
}

test "Static-token authorization" {
  // No token configured -> open (general routes), resolves the operator id.
  assertEqual(outcomeLabel(authorize("", "")), "allow:default", "unconfigured token allows")
  assertEqual(outcomeLabel(authorize("Bearer anything", "")), "allow:default", "unconfigured ignores header")

  // Configured token -> must present a matching bearer. Messages are
  // scheme-neutral (no "GitHub"), since this is the static-token flow.
  assertEqual(outcomeLabel(authorize("Bearer secret", "secret")), "allow:default", "correct token allowed")
  assertEqual(outcomeLabel(authorize("Bearer wrong", "secret")), "deny:invalid or expired token", "wrong token denied")
  assertEqual(outcomeLabel(authorize("", "secret")), "deny:missing Authorization bearer token", "missing header denied")
  assertEqual(outcomeLabel(authorize("Basic secret", "secret")), "deny:missing Authorization bearer token", "wrong scheme denied")
}

test "Secret routes refuse unconfigured auth" {
  // Credential endpoints must never run open, even where general routes would.
  assertEqual(outcomeLabel(authorizeSecret("", "")), "deny:authentication is not configured; access is disabled", "no token -> secret route denied")
  assertEqual(outcomeLabel(authorizeSecret("Bearer secret", "secret")), "allow:default", "configured + correct -> allowed")
  assertEqual(outcomeLabel(authorizeSecret("Bearer wrong", "secret")), "deny:invalid or expired token", "configured + wrong -> denied")
}

test "GitHub /user response parsing" {
  val body = "{\"login\":\"octocat\",\"id\":583231,\"type\":\"User\"}"
  assertEqual(parseJsonString(body, "login"), "octocat", "login")
  assertEqual(parseJsonString(body, "type"), "User", "type")
  assertEqual(parseJsonNumber(body, "id"), "583231", "id number")
  assertEqual(parseJsonString(body, "missing"), "", "missing string field -> empty")
  assertEqual(parseJsonNumber(body, "missing"), "", "missing number field -> empty")
  assertEqual(parseJsonNumber("{\"id\": 42 }", "id"), "42", "number with surrounding spaces")
  // indexOfFrom itself now lives in CloudAgents.Text and is covered directly by
  // CloudAgents.TextTests; parseJsonString/parseJsonNumber above still exercise
  // it transitively here.
}

test "GitHub OAuth authorization derives a user id and applies the whitelist" {
  val body = "{\"login\":\"octocat\",\"id\":583231,\"type\":\"User\"}"
  assertEqual(githubUserIdFromJson(body), "583231", "id parsed from /user response")
  assertEqual(githubLoginFromJson(body), "octocat", "login parsed from /user response")
  assertEqual(userIdForGitHubId("583231"), "gh-583231", "stable prefixed user id")
  // Whitelisted (or open) -> Allowed with the gh- user id.
  assertEqual(outcomeLabel(authorizeGitHub("583231", "")), "allow:gh-583231", "open whitelist allows")
  assertEqual(outcomeLabel(authorizeGitHub("583231", "1,583231,9")), "allow:gh-583231", "listed id allowed")
  assertEqual(outcomeLabel(authorizeGitHub("7", "1,583231")), "deny:user is not on the access whitelist", "unlisted id denied")
  assertEqual(outcomeLabel(authorizeGitHub("", "")), "deny:invalid or expired token", "unparseable identity denied")
}

test "Per-request enforcement classifies secret routes" {
  assertTrue(routeRequiresSecret("/api/credentials"), "credential root is secret")
  assertTrue(routeRequiresSecret("/api/credentials/GITHUB_TOKEN"), "credential sub-path is secret")
  assertFalse(routeRequiresSecret("/api/prompts"), "prompts are not secret")
  assertFalse(routeRequiresSecret("/api/sessions"), "sessions are not secret")
  // enforce() picks the right scheme per route.
  assertEqual(outcomeLabel(enforce("/api/credentials", "", "")), "deny:authentication is not configured; access is disabled", "secret route refuses unconfigured")
  assertEqual(outcomeLabel(enforce("/api/prompts", "", "")), "allow:default", "general route open when unconfigured")
  assertEqual(outcomeLabel(enforce("/api/credentials", "Bearer s", "s")), "allow:default", "secret route allows with a correct token")
}

test "Per-request identity: thread-local set/read/reset roundtrip" {
  // Nothing stamped on this thread yet -> the operator identity.
  assertEqual(currentUserId(), operatorUserId(), "unset defaults to the operator identity")

  // The middleware's stamp is what every downstream query scopes by.
  setCurrentUserId("gh-583231")
  assertEqual(currentUserId(), "gh-583231", "stamped identity is read back")

  // Overwriting (a pooled thread serving the next request) fully replaces it.
  setCurrentUserId("gh-777")
  assertEqual(currentUserId(), "gh-777", "restamp replaces the identity")

  // Reset for any test running later on this thread: an empty stamp reads as
  // unset (IsNullOrEmpty), falling back to the operator identity.
  setCurrentUserId("")
  assertEqual(currentUserId(), operatorUserId(), "empty stamp falls back to operator")
}

test "Cross-package outcome constructors mirror the union cases" {
  assertEqual(outcomeLabel(allowedOutcome("gh-1")), "allow:gh-1", "allowedOutcome constructs Allowed")
  assertEqual(outcomeLabel(deniedOutcome(invalidTokenError())), "deny:invalid or expired token", "deniedOutcome constructs Denied")
}

test "githubIdFromUserId inverts userIdForGitHubId" {
  assertEqual(githubIdFromUserId(userIdForGitHubId("583231")), "583231", "round-trips a numeric id")
  assertEqual(githubIdFromUserId("default"), "", "operator identity is not a GitHub id")
  assertEqual(githubIdFromUserId("gh-"), "", "empty id rejected")
  assertEqual(githubIdFromUserId(""), "", "empty string rejected")
}
