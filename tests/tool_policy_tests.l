@test_module
package CloudAgents.ToolPolicyTests

import Std.Core
import Std.Testing
import CloudAgents.ToolPolicy

test "enabledToolsEnvValue" {
  val empty: slice[String] = []
  assertEqual(enabledToolsEnvValue("all", empty), "", "'all' mode -> no restriction")
  assertEqual(enabledToolsEnvValue("all", ["remember"]), "", "'all' mode ignores any tools list")
  assertEqual(
    enabledToolsEnvValue("selected", empty),
    "",
    "'selected' with no tools chosen collapses to unrestricted (docs/phase7-autonomy.md §7)"
  )
  assertEqual(enabledToolsEnvValue("selected", ["remember"]), "remember", "single tool")
  assertEqual(
    enabledToolsEnvValue("selected", ["remember", "recall"]),
    "remember,recall",
    "multiple tools comma-joined"
  )
  assertEqual(
    enabledToolsEnvValue("selected", ["remember", "recall", "forget"]),
    "remember,recall,forget",
    "three tools comma-joined in order"
  )
}
