//! CloudAgents.Ledger.ObserverPolicy — the observer's settings and the pure
//! rules for when a pass runs (docs/session-ledger.md §10). A profile either
//! carries observer settings or it doesn't; a session is observed iff its
//! profile's observer is enabled. No I/O.
package CloudAgents.Ledger.ObserverPolicy

import Std.Core

/// A profile's observer settings. Strings on the wire like the rest of the
/// API: `enabled` "true"/"false"; `harness`/`model` run the observer (model ""
/// = the harness default); `repoAccess` is "none" (transcript only), "diff"
/// (plus the observed workspace's diff) or "workspace" (plus a read-only mount
/// of the observed workspace); `midRunMinutes` is "0" (end of run only), "15",
/// "30" or "60"; `maxPassesPerDay` caps passes per observed session per UTC
/// day.
@generate(Json)
pub record ObserverSettings {
  pub enabled: String
  pub harness: String
  pub model: String
  pub repoAccess: String
  pub midRunMinutes: String
  pub maxPassesPerDay: String
}

pub func disabledObserverSettings(): ObserverSettings {
  return ObserverSettings(
    enabled = "false",
    harness = "claude",
    model = "",
    repoAccess = "diff",
    midRunMinutes = "15",
    maxPassesPerDay = "48"
  )
}

pub func isObserverHarness(h: in String): Bool {
  return h == "claude" or h == "codex" or h == "opencode" or h == "gemini" or h == "antigravity"
}

pub func isRepoAccess(r: in String): Bool {
  return r == "none" or r == "diff" or r == "workspace"
}

pub func isMidRunMinutes(m: in String): Bool {
  return m == "0" or m == "15" or m == "30" or m == "60"
}

func isModelChar(c: in String): Bool {
  return "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-[]@".contains(c)
}

func digitOf(c: in String): Int {
  val digits = "0123456789"
  var d = 0
  while d < 10 {
    if digits.substring(d, 1) == c {
      return d
    }
    d = d + 1
  }
  return -1
}

func smallInt(s: in String): Int {
  if s.length.toInt() == 0 or s.length.toInt() > 4 {
    return -1
  }
  var acc = 0
  var i = 0
  while i < s.length.toInt() {
    val d = digitOf(s.substring(i, 1))
    if d < 0 {
      return -1
    }
    acc = acc * 10 + d
    i = i + 1
  }
  return acc
}

pub val maxObserverPassesPerDay: Int = 500

/// The problem with a settings body, or "" when it is valid.
pub func validateObserverSettings(s: in ObserverSettings): String {
  if s.enabled != "true" and s.enabled != "false" {
    return "enabled must be \"true\" or \"false\""
  }
  if not isObserverHarness(s.harness) {
    return "harness must be one of: claude, codex, opencode, gemini, antigravity"
  }
  if s.model.length.toInt() > 100 {
    return "model is too long (max 100 characters)"
  }
  var i = 0
  while i < s.model.length.toInt() {
    if not isModelChar(s.model.substring(i, 1)) {
      return "model may only contain letters, digits and . _ : / - [ ] @"
    }
    i = i + 1
  }
  if not isRepoAccess(s.repoAccess) {
    return "repoAccess must be one of: none, diff, workspace"
  }
  if not isMidRunMinutes(s.midRunMinutes) {
    return "midRunMinutes must be one of: 0, 15, 30, 60"
  }
  val cap = smallInt(s.maxPassesPerDay)
  if cap < 1 or cap > maxObserverPassesPerDay {
    return "maxPassesPerDay must be a whole number from 1 to " + toString(maxObserverPassesPerDay)
  }
  return ""
}

/// A fingerprint of the settings that shape an observer session: a change
/// starts a fresh observer (the cursor is kept, so nothing is re-reported).
pub func observerConfigKey(s: in ObserverSettings): String {
  return s.harness + "|" + s.model + "|" + s.repoAccess
}

/// The UTC day number of an epoch-millis instant, as text.
pub func utcDay(nowMillis: in Long): String {
  return toString(nowMillis / 86400000.toLong())
}

/// Passes already run today, given the stored day and count.
pub func passesToday(storedDay: in String, storedCount: in String, nowMillis: in Long): Int {
  if storedDay != utcDay(nowMillis) {
    return 0
  }
  val n = smallInt(storedCount)
  if n < 0 {
    return 0
  }
  return n
}

pub func underDailyCap(s: in ObserverSettings, storedDay: in String, storedCount: in String, nowMillis: in Long): Bool {
  return passesToday(storedDay, storedCount, nowMillis) < smallInt(s.maxPassesPerDay)
}

/// Whether a running session is due a mid-run pass: mid-run passes are on and
/// at least that many minutes passed since the last pass (or since the run
/// started, when none has run since).
pub func midRunDue(s: in ObserverSettings, sinceMillis: in Long, nowMillis: in Long): Bool {
  val minutes = smallInt(s.midRunMinutes)
  if minutes <= 0 {
    return false
  }
  return nowMillis - sinceMillis >= minutes.toLong() * 60000.toLong()
}

/// Events a window must carry before a pass is worth running: at least one
/// line that can show undeclared work.
pub func windowWorthAPass(signal: in Int): Bool {
  return signal > 0
}

/// The only tools an observer container gets: read the window, report on it.
pub func observerToolNames(): slice[String] {
  return ["observer_get_window", "observer_report"]
}

/// Credentials an observer never receives: anything that could push to or
/// change a repository. It reads what the host hands it and nothing else.
pub func isRepoCredential(name: in String): Bool {
  return name.contains("GITHUB") or name.contains("GH_TOKEN") or name.contains("GITLAB") or name.contains("BITBUCKET")
}
