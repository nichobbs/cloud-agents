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

/// Whether `s` is a non-empty run of ASCII digits — used to tell an explicit
/// port (`host:22/owner/repo`) from the scp-style separator
/// (`host:owner/repo`).
func isAllDigits(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    if c < "0" or c > "9" {
      return false
    }
    i = i + 1
  }
  return true
}

/// Normalize a git remote URL to `host/owner/repo`, lowercased. Returns ""
/// when the input has no usable path (empty, or host-only). See
/// docs/phase7-autonomy.md §3 for the exact rules and examples.
///
/// Deliberately general (#595): it accepts every common git remote form —
/// https/http/ssh/git schemes, scp-style `git@host:owner/repo`, embedded
/// credentials, explicit ports. Today the only caller feeds it a
/// `sessions.repo_url`, which `CloudAgents.Handlers` gates to `https://`
/// (`isHttpsUrl` in src/handlers/sessions.l), so the ssh/scp/port branches
/// are unreachable against *current* persisted data. They are kept — as a
/// pure, self-contained, fully-tested (#574/#585) function with a contract
/// independent of any caller — precisely so this stays correct if repo-URL
/// validation ever broadens to SSH remotes: trimming them would make an
/// `git@host:owner/repo` input silently mis-normalize and collide two
/// distinct repos onto one memory key. This is forward-compatibility, not
/// accidental complexity.
pub func repoKeyOf(url: in String): String {
  if DotNetString.IsNullOrEmpty(url) {
    return ""
  }
  var s = strToLower(url)
  // Strip a scheme prefix, remembering whether one was present. Only the
  // URL forms carry an explicit `host:port`; scp-style `git@host:path` never
  // does — its ':' is always the path separator, even when the path segment
  // happens to be numeric (#585).
  val hadScheme = s.startsWith("https://") or s.startsWith("http://") or s.startsWith("ssh://") or
    s.startsWith("git://")
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
  // Resolve a ':' that precedes the first '/'. Two distinct cases share this
  // syntax (#574):
  //   - an explicit port (`ssh://…:2222/…`, `https://host:443/…`) — ONLY in a
  //     scheme-bearing URL, token all digits; drop `:port`.
  //   - the scp-style separator (`git@host:owner/repo`, no scheme) — turn the
  //     ':' into '/', even when the segment is numeric (#585).
  val colon = firstIndexOf(s, ":")
  val slash2 = firstIndexOf(s, "/")
  if colon >= 0 and (slash2 < 0 or colon < slash2) {
    val tokEnd = if slash2 < 0 { s.length } else { slash2 }
    val token = s.substring(colon + 1, tokEnd - colon - 1)
    val before = s.substring(0, colon)
    if hadScheme and isAllDigits(token) {
      // host:port[/path] -> host[/path] (drop the ":port").
      val after = s.substring(tokEnd, s.length - tokEnd)
      s = before + after
    } else {
      val after = s.substring(colon + 1, s.length - colon - 1)
      s = before + "/" + after
    }
  }
  // Drop any query string or fragment — never part of repo identity, so
  // `…/repo?ref=x` and `…/repo#readme` scope to the same memory as the bare
  // `…/repo` (#597). Extra path segments are deliberately NOT trimmed:
  // nested-group hosts (GitLab `group/subgroup/repo`) make them part of the
  // identity, so truncating to owner/repo would merge distinct repos.
  val q = firstIndexOf(s, "?")
  if q >= 0 {
    s = s.substring(0, q)
  }
  val frag = firstIndexOf(s, "#")
  if frag >= 0 {
    s = s.substring(0, frag)
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
