@test_module
package CloudAgents.DockerClientTests

import Std.Core
import Std.Testing
import Lyric.Docker

test "jsonEscapeValue escapes quotes, backslashes and whitespace escapes" {
  assertEqual(jsonEscapeValue("plain"), "plain", "plain text unchanged")
  assertEqual(jsonEscapeValue("a\"b"), "a\\\"b", "quote escaped")
  assertEqual(jsonEscapeValue("a\\b"), "a\\\\b", "backslash escaped")
  assertEqual(jsonEscapeValue("line1\nline2"), "line1\\nline2", "newline escaped (multi-line PROMPT)")
  assertEqual(jsonEscapeValue("a\r\tb"), "a\\r\\tb", "carriage return and tab escaped")
}

test "jsonEscapeValue escapes raw control characters as unicode escapes" {
  // The Docker daemon's JSON decoder rejects raw control bytes in string
  // literals; pasted terminal output (ESC and friends) must not make the
  // create-container body unparseable.
  assertEqual(jsonEscapeValue(charFromCode(27) + "[1m"), "\\u001b[1m", "ESC escaped")
  assertEqual(jsonEscapeValue(charFromCode(7)), "\\u0007", "BEL escaped")
  assertEqual(jsonEscapeValue("a" + charFromCode(1) + "b"), "a\\u0001b", "SOH mid-string escaped")
}

test "containerBodyWithNetwork sets NetworkMode only when provided" {
  val env = ["A=1"]
  val binds = ["v:/w"]
  val dflt = containerBodyWithNetwork("img", env, binds, "")
  assertTrue(dflt.contains("\"Binds\":"), "binds always present")
  assertTrue(not dflt.contains("NetworkMode"), "no NetworkMode field for the default network")
  val isolated = containerBodyWithNetwork("img", env, binds, "none")
  assertTrue(isolated.contains("\"NetworkMode\":\"none\""), "NetworkMode set when a policy pins it")
  assertTrue(isolated.contains("\"Binds\":"), "binds preserved alongside NetworkMode")
}
