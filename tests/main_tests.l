@test_module
package CloudAgents.MainTests

import Std.Core
import Std.Testing
import CloudAgents

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
