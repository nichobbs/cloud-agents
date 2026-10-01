//! CloudAgents.Db — the store's error type and the small host-side helpers the
//! store and the container manager share: Docker volume binds, the warm-window
//! length, epoch-millisecond parsing and the session attention digest.
//!
//! The store itself is Postgres (src/pgstore/, docs/phase11-postgres-tenancy.md).
package CloudAgents.Db

import Std.Core

/// Failure modes at the store boundary (the Postgres store's error type).
pub union DbError {
  case OpenFailed(message: String)
  case ExecFailed(sql: String, message: String)
  // A precondition / row-level validation failure at the store boundary that
  // is not itself an open or exec failure (e.g. a requested row is missing or
  // fails an ownership/parentage check). Carries a complete, human-readable
  // message; unlike ExecFailed it has no associated SQL text.
  case ValidationFailed(message: String)
}

pub func dbErrorMessage(e: in DbError): String {
  return match e {
    case OpenFailed(m) -> "failed to open database: " + m
    case ExecFailed(sql, m) -> "query failed (" + sql + "): " + m
    case ValidationFailed(m) -> m
  }
}

// ─── Idle recycling ───────────────────────────────────────────────────────────
//
// A background sweep stops warm containers after a short grace window and
// evicts the container metadata of long-idle sessions (docs/phase2 §2).
/// Grace period a container stays warm after a run before being stopped (5 min).
pub func warmWindowMillis(): Long {
  return 300000.toLong()
}

// (The Phase-3 draft helpers workspaceVolumeName/homeVolumeName were removed
// as dead code (#443): they were never wired into docker_manager.l and used a
// naming shape inconsistent with the *BindFor functions below that actually
// mount volumes — docs/review-2026-07-03*.md reference them historically.)
/// Container-side $HOME mount path for a harness image. Each harness image
/// runs as its own user with its own home directory (#409); unknown or empty
/// harness falls back to the claude image's path, matching
/// `homeVolumeBindForHarness`.
pub func homeMountPathForHarness(harness: in String): String {
  if harness == "codex" {
    return "/home/codex-user"
  }
  if harness == "opencode" {
    return "/home/opencode-user"
  }
  if harness == "gemini" {
    return "/home/gemini-user"
  }
  if harness == "antigravity" {
    return "/home/antigravity-user"
  }
  return "/home/claude-user"
}

/// Home-volume bind (volume:containerPath) for a harness's runner container,
/// shared across all legacy/operator sessions. Each harness image runs as
/// its own user with its own $HOME, so each harness gets its own shared
/// volume mounted at that image's home path — previously every harness
/// shared claude's volume mounted at /home/claude-user, so
/// Codex/OpenCode/Gemini CLI config and history never persisted between runs
/// (#409). Claude keeps its legacy volume name so existing installs keep
/// their authenticated ~/.claude. Kept in this pure package (not
/// CloudAgents.Docker) so tests can invoke it — a @test_module cannot call
/// into an async-bearing package (docs/lyric/gotchas.md). OAuth tenants get
/// per-user volumes instead — see `homeVolumeBindFor`.
pub func homeVolumeBindForHarness(harness: in String): String {
  if harness == "codex" {
    return "codex-home-default:" + homeMountPathForHarness(harness)
  }
  if harness == "opencode" {
    return "opencode-home-default:" + homeMountPathForHarness(harness)
  }
  if harness == "gemini" {
    return "gemini-home-default:" + homeMountPathForHarness(harness)
  }
  if harness == "antigravity" {
    return "antigravity-home-default:" + homeMountPathForHarness(harness)
  }
  return "claude-home-default:" + homeMountPathForHarness(harness)
}

/// Home-volume bind (volume:containerPath) keyed by tenant. The operator
/// identity ("default" — see CloudAgents.Auth.operatorUserId; empty is
/// treated the same defensively) keeps the legacy per-harness shared volumes
/// from `homeVolumeBindForHarness` so existing installs keep their
/// authenticated ~/.claude etc. OAuth tenants (gh-<digits>) get a per-user
/// volume per harness: `user-<userId>-<harness>-home`. An empty harness is
/// normalised to "claude" in the volume name so it matches the image
/// actually used (imageForHarness falls back to the claude image).
pub func homeVolumeBindFor(userId: in String, harness: in String): String {
  if userId == "" or userId == "default" {
    return homeVolumeBindForHarness(harness)
  }
  // Normalise ANYTHING that isn't a recognised harness to "claude" — not
  // just the empty string — so the volume name always agrees with the mount
  // path and image, which both fall back to claude's for unknown values
  // (homeMountPathForHarness / imageForHarness). Unreachable today
  // (isKnownHarness rejects unknown harnesses upstream), but a divergent
  // name here would silently split a tenant's claude state in two (#437).
  val harnessName = if harness == "codex" or harness == "opencode" or harness == "gemini" or harness == "antigravity" then harness else "claude"
  return "user-" + userId + "-" + harnessName + "-home:" + homeMountPathForHarness(harness)
}

/// Workspace-volume bind (volume:/workspace) keyed by tenant. The operator
/// identity ("default"/empty) keeps the legacy `session-<sessionId>-workspace`
/// name so existing installs keep their workspaces; OAuth tenants get
/// `session-<userId>-<sessionId>-workspace`. Docker volume names allow
/// [a-zA-Z0-9_.-]; user ids are gh-<digits> and session ids are UUIDs, both
/// safe to embed verbatim.
pub func workspaceVolumeBindFor(userId: in String, sessionId: in String): String {
  if userId == "" or userId == "default" {
    return "session-" + sessionId + "-workspace:/workspace"
  }
  return "session-" + userId + "-" + sessionId + "-workspace:/workspace"
}

/// A read-only bind of `sessionId`'s workspace volume at /workspace/observed:
/// how an observer with workspace access reads the session it observes,
/// including uncommitted work, without being able to change it.
pub func observedWorkspaceBindFor(userId: in String, sessionId: in String): String {
  val rw = workspaceVolumeBindFor(userId, sessionId)
  return rw.substring(0, rw.length - ":/workspace".length) + ":/workspace/observed:ro"
}

func attentionDigitValue(c: in String): Int {
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

/// Parse a run of decimal digits from a TEXT column into a Long, ignoring
/// non-digit characters ("" parses to 0). The Long counterpart of
/// CloudAgents.Repository.parseNatString — epoch-millisecond values overflow
/// Int32, so the session-summaries path parses last_message_at /
/// last_viewed_at (and the pending count) through this before feeding
/// attentionFor.
pub func parseEpochMillisText(s: in String): Long {
  var n = 0.toLong()
  var i = 0
  while i < s.length {
    val d = attentionDigitValue(s.substring(i, 1))
    if d >= 0 {
      n = n * 10.toLong() + d.toLong()
    }
    i = i + 1
  }
  return n
}

/// The attention state of a session, derived per the shared frontend/backend
/// attention model: 'pending' (needs the user) when any callback is still
/// pending OR when a non-RUNNING session has activity newer than the user's
/// last view; else 'working' while RUNNING; else 'viewed' when there is
/// history the user has seen; else 'idle' (fresh session, no activity).
/// Pure — the session-summaries builder feeds it parsed TEXT columns, and
/// tests pin every state and the pending-beats-working priority.
pub func attentionFor(
  status: in String, lastMessageAtMs: in Long, lastViewedAtMs: in Long, pendingCount: in Long
): String {
  val zero = 0.toLong()
  if pendingCount > zero {
    return "pending"
  }
  if status != "RUNNING" and lastMessageAtMs > lastViewedAtMs and lastMessageAtMs > zero {
    return "pending"
  }
  if status == "RUNNING" {
    return "working"
  }
  if lastMessageAtMs > zero {
    return "viewed"
  }
  return "idle"
}
