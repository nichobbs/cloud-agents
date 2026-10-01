//! Tests for CloudAgents.ClaudeLogin: the newer-login rule that guards the
//! vault write-back (docs/credentials.md "Refreshable Claude login").
@test_module
package CloudAgents.ClaudeLoginTests

import Std.Core
import Std.Testing
import CloudAgents.ClaudeLogin

func login(access: in String, refresh: in String, expiresAt: in String): String {
  return "{\"claudeAiOauth\":{\"accessToken\":\"" + access + "\",\"refreshToken\":\"" + refresh +
    "\",\"expiresAt\":" +
    expiresAt +
    "}}"
}

func isUnusable(json: in String): Bool {
  match parseLogin(json) {
    case Some(_) -> return false
    case None -> return true
  }
}

test "parseLogin reads a real-shaped file with extra fields" {
  val real = "{\"claudeAiOauth\":{\"accessToken\":\"sk-ant-oat01-a\",\"refreshToken\":\"sk-ant-ort01-r\",\"expiresAt\":1790000000000,\"scopes\":[\"user:inference\",\"user:profile\"],\"subscriptionType\":\"max\",\"rateLimitTier\":\"default_claude_max_5x\"}}"
  match parseLogin(real) {
    case Some(l) -> {
      assertEqual(l.claudeAiOauth.accessToken, "sk-ant-oat01-a", "access token")
      assertEqual(l.claudeAiOauth.refreshToken, "sk-ant-ort01-r", "refresh token")
      assertTrue(l.claudeAiOauth.expiresAt == 1790000000000, "expiry")
    }
    case None -> assertTrue(false, "a real-shaped login parses")
  }
}

test "parseLogin rejects malformed input and an empty access token" {
  assertTrue(isUnusable("not json"), "garbage")
  assertTrue(isUnusable("{}"), "no claudeAiOauth")
  assertTrue(isUnusable(login("", "r", "1")), "empty access token")
}

test "a later-expiring login replaces an earlier one" {
  assertTrue(isNewerLogin(login("n", "r", "1791000000000"), login("o", "r", "1790000000000")), "later wins")
}

test "an earlier or equal login never replaces the current one" {
  assertFalse(isNewerLogin(login("o", "r", "1790000000000"), login("n", "r", "1791000000000")), "earlier loses")
  assertFalse(isNewerLogin(login("a", "r", "1790000000000"), login("b", "r", "1790000000000")), "equal keeps current")
}

test "an unusable candidate never replaces anything, an unusable current always yields" {
  assertFalse(isNewerLogin("not json", login("o", "r", "1")), "garbage candidate")
  assertFalse(isNewerLogin(login("", "r", "9"), login("o", "r", "1")), "no-access-token candidate")
  assertTrue(isNewerLogin(login("n", "r", "1"), "not json"), "usable beats unusable")
  assertFalse(isNewerLogin("not json", "also not json"), "nothing usable on either side")
}
