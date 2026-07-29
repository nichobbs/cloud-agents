@test_module
package CloudAgents.DockerClientTests

import Std.Core
import Std.Testing
import Lyric.Docker

test "createContainerBodyWithNetwork sets NetworkMode only when provided" {
  val env = ["A=1"]
  val binds = ["v:/w"]
  val dflt = Lyric.Docker.createContainerBodyWithNetwork("img", env, binds, "")
  assertTrue(dflt.contains("\"Binds\":"), "binds always present")
  assertTrue(not dflt.contains("NetworkMode"), "no NetworkMode field for the default network")
  val isolated = Lyric.Docker.createContainerBodyWithNetwork("img", env, binds, "none")
  assertTrue(isolated.contains("\"NetworkMode\":\"none\""), "NetworkMode set when a policy pins it")
  assertTrue(isolated.contains("\"Binds\":"), "binds preserved alongside NetworkMode")
}

test "createContainerBody keeps the Docker default network" {
  val body = Lyric.Docker.createContainerBody("img", [], [])
  assertTrue(not body.contains("NetworkMode"), "createContainer omits NetworkMode entirely")
}

// The Docker daemon's JSON decoder rejects raw control bytes in string
// literals, and env values routinely contain them: a multi-line PROMPT
// (newlines) or pasted terminal output (ESC and friends). Round-trip
// through the real escape (createContainerBodyWithNetwork) and decode
// (extractJsonField) paths together so this doesn't depend on guessing the
// library's exact intermediate escaping.
test "createContainerBodyWithNetwork round-trips control characters through extractJsonField" {
  val image = "abc\u{0001}def\u{001f}ghi"
  val body = Lyric.Docker.createContainerBodyWithNetwork(image, [], [], "none")
  val extracted = Lyric.Docker.extractJsonField(body, "Image")
  assertEqual(extracted, image, "Control characters round-trip through escape + decode unchanged")
}

test "createContainerBodyWithNetwork escapes a multi-line PROMPT env value" {
  val prompt = "line one\nline two\ttabbed"
  val body = Lyric.Docker.createContainerBodyWithNetwork("img", ["PROMPT=" + prompt], [], "")
  assertTrue(body.contains("\\n"), "newline in PROMPT is escaped, not emitted raw")
  assertTrue(body.contains("\\t"), "tab in PROMPT is escaped, not emitted raw")
}
