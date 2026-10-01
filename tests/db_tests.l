//! Tests for CloudAgents.Db's host-side helpers: Docker volume binds,
//! epoch-millisecond parsing and the session attention digest.
@test_module
package CloudAgents.DbTests

import Std.Core
import Std.Testing
import CloudAgents.Db

test "Volume names key by user and session" {
  assertEqual(
    homeVolumeBindForHarness("claude"),
    "claude-home-default:/home/claude-user",
    "claude keeps its legacy home volume"
  )
  assertEqual(homeVolumeBindForHarness("codex"), "codex-home-default:/home/codex-user", "codex home volume bind")
  assertEqual(
    homeVolumeBindForHarness("opencode"),
    "opencode-home-default:/home/opencode-user",
    "opencode home volume bind"
  )
  assertEqual(homeVolumeBindForHarness("gemini"), "gemini-home-default:/home/gemini-user", "gemini home volume bind")
  assertEqual(
    homeVolumeBindForHarness("antigravity"),
    "antigravity-home-default:/home/antigravity-user",
    "antigravity home volume bind"
  )
  assertEqual(
    homeVolumeBindForHarness(""),
    "claude-home-default:/home/claude-user",
    "empty harness falls back to claude"
  )
}

test "Harness home mount paths cover every image" {
  assertEqual(homeMountPathForHarness("claude"), "/home/claude-user", "claude mount path")
  assertEqual(homeMountPathForHarness("codex"), "/home/codex-user", "codex mount path")
  assertEqual(homeMountPathForHarness("opencode"), "/home/opencode-user", "opencode mount path")
  assertEqual(homeMountPathForHarness("gemini"), "/home/gemini-user", "gemini mount path")
  assertEqual(homeMountPathForHarness("antigravity"), "/home/antigravity-user", "antigravity mount path")
  assertEqual(homeMountPathForHarness(""), "/home/claude-user", "empty harness falls back to claude's path")
  assertEqual(homeMountPathForHarness("bogus"), "/home/claude-user", "unknown harness falls back to claude's path")
}

test "Per-user volume binds isolate tenants; operator keeps legacy names" {
  // Operator identity ("default", and "" defensively) keeps the exact legacy
  // shared shapes so existing installs keep their authenticated ~/.claude
  // and workspaces.
  assertEqual(
    workspaceVolumeBindFor("default", "abc"),
    "session-abc-workspace:/workspace",
    "operator workspace bind keeps legacy name"
  )
  assertEqual(
    workspaceVolumeBindFor("", "abc"),
    "session-abc-workspace:/workspace",
    "empty user treated as operator for workspace"
  )
  assertEqual(
    homeVolumeBindFor("default", "claude"),
    "claude-home-default:/home/claude-user",
    "operator claude home bind keeps legacy name"
  )
  assertEqual(
    homeVolumeBindFor("default", "codex"),
    "codex-home-default:/home/codex-user",
    "operator codex home bind keeps legacy name"
  )
  assertEqual(
    homeVolumeBindFor("default", "opencode"),
    "opencode-home-default:/home/opencode-user",
    "operator opencode home bind keeps legacy name"
  )
  assertEqual(
    homeVolumeBindFor("default", "gemini"),
    "gemini-home-default:/home/gemini-user",
    "operator gemini home bind keeps legacy name"
  )
  assertEqual(
    homeVolumeBindFor("default", "antigravity"),
    "antigravity-home-default:/home/antigravity-user",
    "operator antigravity home bind keeps legacy name"
  )
  assertEqual(
    homeVolumeBindFor("default", ""),
    "claude-home-default:/home/claude-user",
    "operator empty harness keeps legacy claude bind"
  )
  assertEqual(
    homeVolumeBindFor("", "claude"),
    "claude-home-default:/home/claude-user",
    "empty user treated as operator for home"
  )

  // OAuth tenants (gh-<digits>) get per-user volumes for every harness.
  assertEqual(
    workspaceVolumeBindFor("gh-42", "abc"),
    "session-gh-42-abc-workspace:/workspace",
    "tenant workspace bind keys by user"
  )
  assertEqual(
    homeVolumeBindFor("gh-42", "claude"),
    "user-gh-42-claude-home:/home/claude-user",
    "tenant claude home bind"
  )
  assertEqual(homeVolumeBindFor("gh-42", "codex"), "user-gh-42-codex-home:/home/codex-user", "tenant codex home bind")
  assertEqual(
    homeVolumeBindFor("gh-42", "opencode"),
    "user-gh-42-opencode-home:/home/opencode-user",
    "tenant opencode home bind"
  )
  assertEqual(
    homeVolumeBindFor("gh-42", "gemini"),
    "user-gh-42-gemini-home:/home/gemini-user",
    "tenant gemini home bind"
  )
  assertEqual(
    homeVolumeBindFor("gh-42", "antigravity"),
    "user-gh-42-antigravity-home:/home/antigravity-user",
    "tenant antigravity home bind"
  )
  // Any unrecognised harness — not just empty — normalises to "claude" in the
  // volume name, agreeing with the mount path and image fallbacks (#437).
  assertEqual(
    homeVolumeBindFor("gh-42", ""),
    "user-gh-42-claude-home:/home/claude-user",
    "tenant empty harness normalised to claude"
  )
  assertEqual(
    homeVolumeBindFor("gh-42", "bogus"),
    "user-gh-42-claude-home:/home/claude-user",
    "tenant unknown harness normalised to claude (#437)"
  )
}

test "parseEpochMillisText parses epoch-scale values into a Long" {
  assertEqual(toString(parseEpochMillisText("0")), "0", "zero")
  assertEqual(toString(parseEpochMillisText("")), "0", "empty is zero")
  assertEqual(toString(parseEpochMillisText("1721470000123")), "1721470000123", "13-digit epoch millis exceed Int32")
  assertEqual(toString(parseEpochMillisText("42")), "42", "small count")
}

test "attentionFor derives all four states with the right priority" {
  val zero = 0.toLong()
  val t1 = 1000.toLong()
  val t2 = 2000.toLong()
  // pending: a callback is waiting.
  assertEqual(attentionFor("IDLE", t1, t2, 1.toLong()), "pending", "pending callback -> pending")
  // pending: finished run the user hasn't looked at since.
  assertEqual(attentionFor("IDLE", t2, t1, zero), "pending", "unseen activity -> pending")
  assertEqual(attentionFor("WARM", t2, t1, zero), "pending", "unseen activity on WARM -> pending")
  // working: RUNNING with nothing pending.
  assertEqual(attentionFor("RUNNING", t1, t2, zero), "working", "running, all seen -> working")
  // The unseen-activity branch only fires when NOT running — a live run's own
  // activity is 'working', not 'pending'...
  assertEqual(attentionFor("RUNNING", t2, t1, zero), "working", "running, unseen -> still working")
  // ...but a pending callback DURING a run beats working.
  assertEqual(attentionFor("RUNNING", t1, t2, 2.toLong()), "pending", "pending callback during RUNNING -> pending")
  // viewed: history exists and the user has seen everything.
  assertEqual(attentionFor("IDLE", t1, t1, zero), "viewed", "all seen -> viewed")
  assertEqual(attentionFor("IDLE", t1, t2, zero), "viewed", "viewed after activity -> viewed")
  // idle: no activity at all.
  assertEqual(attentionFor("IDLE", zero, zero, zero), "idle", "fresh -> idle")
  assertEqual(attentionFor("CREATED", zero, zero, zero), "idle", "fresh CREATED -> idle")
}
