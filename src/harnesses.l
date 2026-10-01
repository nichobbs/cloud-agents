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
