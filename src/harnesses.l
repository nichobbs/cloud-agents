//! The harnesses this deployment knows: the one backend list every harness
//! check reads (profile pins, session creation, the models proxy, the
//! observer). The frontend's catalog (frontend/src/lib/harnesses.ts) must
//! name the same ids; CI's "harness list is in sync" step checks it.
package CloudAgents.Harnesses

import Std.Core

pub func harnessIds(): slice[String] {
  return ["claude", "codex", "opencode", "gemini", "antigravity"]
}

pub func isSupportedHarness(h: in String): Bool {
  val ids = harnessIds()
  var i = 0
  while i < ids.length {
    if ids[i] == h {
      return true
    }
    i = i + 1
  }
  return false
}

/// "claude, codex, ..." for validation messages.
pub func harnessIdsText(): String {
  val ids = harnessIds()
  var text = ""
  var i = 0
  while i < ids.length {
    if i > 0 {
      text = text + ", "
    }
    text = text + ids[i]
    i = i + 1
  }
  return text
}

/// The runner image for a harness (built by scripts/build-docker.sh). An
/// unknown harness falls back to the claude image, as the home mount path and
/// volume name do (CloudAgents.Db); session creation rejects unknown
/// harnesses before any of these is reached. Pure, so it is testable here
/// rather than inside the async CloudAgents.Docker package.
pub func imageForHarness(harness: in String): String {
  if harness == "codex" {
    return "codex:base"
  }
  if harness == "opencode" {
    return "opencode:base"
  }
  if harness == "gemini" {
    return "gemini:base"
  }
  if harness == "antigravity" {
    return "antigravity:base"
  }
  return "claude-code:base"
}
