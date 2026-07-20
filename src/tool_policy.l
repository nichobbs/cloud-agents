//! Pure per-profile tool-enablement resolution: given a profile's tool_mode
//! and its granted tool names, produces the CLOUD_AGENTS_ENABLED_TOOLS env
//! value CloudAgents.Docker injects into the runner container
//! (docs/phase7-autonomy.md §7).
//!
//! Lives in its own package rather than CloudAgents.Docker for the same
//! reason CloudAgents.NetworkPolicy / CloudAgents.RepoKey do: a
//! @test_module can't reach anything behind an `async func` package
//! (docs/lyric/gotchas.md), even a pure leaf function, so this stays out of
//! the async CloudAgents.Docker package to remain directly unit-testable.
package CloudAgents.ToolPolicy

import Std.Core

/// The CLOUD_AGENTS_ENABLED_TOOLS value for a profile's tool_mode/tools, or
/// "" for "no restriction" (register every tool). `toolMode != "selected"`
/// (i.e. "all", the default) always returns "" — the fail-safe requirement
/// that an 'all'-mode profile (and, by extension, an empty/unresolved
/// profileId, handled by the caller) is byte-for-byte the pre-phase-7
/// behaviour. A "selected" mode with zero tools chosen also joins to "" and
/// therefore behaves the same as unrestricted — this mirrors the shim's own
/// contract (docs/phase7-autonomy.md §7: "an empty/unset value means
/// 'all'"), so this is a deliberate, spec'd collapse, not an oversight: tool
/// enablement is not a hard security boundary in v1 (host-side enforcement
/// of a disabled tool's callback endpoint is an explicit follow-up), unlike
/// the credential/network-policy grants CloudAgents.Repository fails closed
/// on.
pub func enabledToolsEnvValue(toolMode: in String, tools: in slice[String]): String {
  if toolMode != "selected" {
    return ""
  }
  var result = ""
  var i = 0
  while i < tools.length {
    if i > 0 {
      result = result + ","
    }
    result = result + tools[i]
    i = i + 1
  }
  return result
}
