//! src/config.l — CloudAgents.Shim.Config: timeout parsing/fallback policy
//! for CLOUD_AGENTS_CALLBACK_TIMEOUT_MS, split from the entry package so
//! the policy is testable without importing the executable package or
//! touching process environment (#527). CloudAgents.Docker forwards the
//! host-side value of the same env var into the container (#528), and
//! CloudAgents.Callbacks.tryParseMillis is the host-side parsing twin —
//! keep them behaviorally identical.
package CloudAgents.Shim.Config

import Std.Core

/// Overall client-side deadline for request_permission/ask_user
/// (docs/phase6 §3: "overall timeout from env (default 10 min)").
pub val defaultTimeoutMs: Int = 600000

func digitValue(c: in String): Int {
  if c == "0" {
    return 0
  }
  if c == "1" {
    return 1
  }
  if c == "2" {
    return 2
  }
  if c == "3" {
    return 3
  }
  if c == "4" {
    return 4
  }
  if c == "5" {
    return 5
  }
  if c == "6" {
    return 6
  }
  if c == "7" {
    return 7
  }
  if c == "8" {
    return 8
  }
  if c == "9" {
    return 9
  }
  return -1
}

/// Parse a run of decimal digits (only) into an Int, or -1 for anything
/// else (empty, too long, non-digit) — mirrors
/// CloudAgents.Callbacks.tryParseMillis (cloud-agents' host-side twin) so
/// both ends of CLOUD_AGENTS_CALLBACK_TIMEOUT_MS parse identically. Bounded
/// to 9 digits: realistic timeouts are minutes, not decades of
/// milliseconds, and this only ever reads an operator-set env var.
pub func tryParseMillis(s: in String): Int {
  if s.length == 0 or s.length > 9 {
    return -1
  }
  var n = 0
  var i = 0
  while i < s.length {
    val d = digitValue(s.substring(i, 1))
    if d < 0 {
      return -1
    }
    n = n * 10 + d
    i = i + 1
  }
  return n
}

/// Resolve the effective client-side timeout from the raw env value:
/// empty or unparseable falls back to the default. Split from
/// readTimeoutMs so the fallback policy is testable without touching
/// process environment (#527).
pub func timeoutFromRaw(raw: in String): Int {
  if raw.length == 0 {
    return defaultTimeoutMs
  }
  val n = tryParseMillis(raw)
  if n < 0 {
    return defaultTimeoutMs
  }
  return n
}

// ─── Phase 7 §7: per-profile tool enablement ───────────────────────────────
//
// Split from main.l for the same testability reason as the timeout policy
// above (#527): this decides, given the raw CLOUD_AGENTS_ENABLED_TOOLS env
// value, whether one named tool should be registered — no process
// environment access needed to exercise it.
/// Whether `toolName` should be registered given the raw
/// CLOUD_AGENTS_ENABLED_TOOLS value (docs/phase7-autonomy.md §7): empty
/// means "no restriction" — register every tool, byte-for-byte the
/// pre-phase-7 behaviour (a pre-phase-7 container never sets this var at
/// all, and CloudAgents.Docker never sets it for an 'all'-mode profile
/// either). A non-empty value is a comma-separated allowlist; only a name
/// appearing in it is enabled.
///
/// Hand-rolled index-of-based comma split rather than a stdlib split
/// method: this codebase's established convention (see
/// CloudAgents.RepoKey.firstIndexOf) is to avoid stdlib "convenience"
/// string/collection methods that compile but panic at runtime
/// (docs/lyric/gotchas.md) — a hand-rolled loop over a small,
/// operator/host-controlled CSV is cheap and reliable.
pub func toolIsEnabled(enabledCsv: in String, toolName: in String): Bool {
  if enabledCsv.length == 0 {
    return true
  }
  var start = 0
  var i = 0
  while i <= enabledCsv.length {
    if i == enabledCsv.length or enabledCsv.substring(i, 1) == "," {
      val token = enabledCsv.substring(start, i - start)
      if token == toolName {
        return true
      }
      start = i + 1
    }
    i = i + 1
  }
  return false
}
