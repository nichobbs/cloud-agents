//! src/repo_key.l — CloudAgents.RepoKey: pure normalization of a git remote
//! URL to a stable `host/owner/repo` identity, used to scope repo-level
//! memory across sessions (docs/phase7-autonomy.md §3).
//!
//! Pure and standalone for the same reason CloudAgents.NetworkPolicy is: a
//! @test_module cannot reach anything behind an `async func` package
//! (docs/lyric/gotchas.md), so keeping this logic out of the async
//! CloudAgents.Docker / CloudAgents.Repository packages lets a test import
//! and exercise it directly.
package CloudAgents.RepoKey

import Std.Core
import extern System.String as DotNetString

// Instance-method extern, declared receiver-as-first-arg exactly like
// CloudAgents.Webhooks' strToLower (src/handlers/webhooks.l) — that shape is
// confirmed to resolve for System.String instance methods.
@externTarget("System.String.ToLowerInvariant")
func strToLower(s: in String): String = ()

/// Index of the first occurrence of the single-character `ch` in `s`, or -1.
func firstIndexOf(s: in String, ch: in String): Int {
  var i = 0
  while i < s.length {
    if s.substring(i, 1) == ch {
      return i
    }
    i = i + 1
  }
  return -1
}

func stripPrefix(s: in String, prefix: in String): String {
  if s.startsWith(prefix) {
    return s.substring(prefix.length, s.length - prefix.length)
  }
  return s
}

func dropLast(s: in String, n: in Int): String {
  if s.length < n {
    return ""
  }
  return s.substring(0, s.length - n)
}

/// Normalize a git remote URL to `host/owner/repo`, lowercased. Returns ""
/// when the input has no usable path (empty, or host-only). See
/// docs/phase7-autonomy.md §3 for the exact rules and examples.
pub func repoKeyOf(url: in String): String {
  if DotNetString.IsNullOrEmpty(url) {
    return ""
  }
  var s = strToLower(url)
  // Strip a scheme prefix.
  s = stripPrefix(s, "https://")
  s = stripPrefix(s, "http://")
  s = stripPrefix(s, "ssh://")
  s = stripPrefix(s, "git://")
  // Strip `user[:password]@` credentials that appear before the first path
  // separator (this also covers the scp-style `git@host:owner/repo` login).
  val at = firstIndexOf(s, "@")
  val slash = firstIndexOf(s, "/")
  if at >= 0 and (slash < 0 or at < slash) {
    s = s.substring(at + 1, s.length - at - 1)
  }
  // scp-style `host:owner/repo` -> `host/owner/repo`: turn the first ':' that
  // precedes the first '/' into '/'.
  val colon = firstIndexOf(s, ":")
  val slash2 = firstIndexOf(s, "/")
  if colon >= 0 and (slash2 < 0 or colon < slash2) {
    val before = s.substring(0, colon)
    val after = s.substring(colon + 1, s.length - colon - 1)
    s = before + "/" + after
  }
  // Strip a trailing '/', then a trailing '.git', then any resulting '/'.
  if s.endsWith("/") {
    s = dropLast(s, 1)
  }
  if s.endsWith(".git") {
    s = dropLast(s, 4)
  }
  if s.endsWith("/") {
    s = dropLast(s, 1)
  }
  // Must be at least `host/segment`.
  if s.length == 0 or firstIndexOf(s, "/") < 0 {
    return ""
  }
  return s
}
