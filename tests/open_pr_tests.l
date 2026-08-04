@test_module
package CloudAgents.OpenPrTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.OpenPr
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/proxy_tests.l) ────────────────────
//
// NB: no network path is ever exercised here — the no-vaulted-token and
// non-github-repo tests both fail closed before any outbound GitHub request
// could happen (same reasoning proxy_tests.l documents for its own
// no-credential tests), and the compare/dedup/create decision logic is
// covered purely via decidePrAction, with no HTTP round trip involved at
// all. ENCRYPTION_KEY is deliberately NOT set — decryptedCredentialValue
// answers Ok(None) for an absent row before any decryption.

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return path
}

func cleanupTestDb(path: in String): Unit {
  try {
    fileDelete(path)
  } catch Bug as b {
    // locked or already gone — fine for a temp file
  }
  CloudAgents.Auth.setCurrentUserId("default")
}

func mkSession(id: in String, repoUrl: in String, branch: in String): Unit {
  val s = makeAgentSession(
    sessionId = id,
    repoUrl = repoUrl,
    branch = branch,
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = id
  )
  match addSession(s) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── githubOwnerRepoFromUrl: pure URL parsing ──────────────────────────────────
test "githubOwnerRepoFromUrl extracts owner/repo from a plain github.com HTTPS URL" {
  match CloudAgents.OpenPr.githubOwnerRepoFromUrl("https://github.com/nichobbs/cloud-agents") {
    case Some(v) -> {
      assertEqual(v.owner, "nichobbs", "owner extracted")
      assertEqual(v.repo, "cloud-agents", "repo extracted")
    }
    case None -> assertTrue(false, "expected Some for a plain github.com URL")
  }
}

test "githubOwnerRepoFromUrl lowercases and strips a trailing .git" {
  match CloudAgents.OpenPr.githubOwnerRepoFromUrl("https://github.com/NicHobbs/Cloud-Agents.git") {
    case Some(v) -> {
      assertEqual(v.owner, "nichobbs", "owner is lowercased")
      assertEqual(v.repo, "cloud-agents", "repo is lowercased and .git is stripped")
    }
    case None -> assertTrue(false, "expected Some for a .git-suffixed URL")
  }
}

test "githubOwnerRepoFromUrl returns None for a non-github.com host" {
  match CloudAgents.OpenPr.githubOwnerRepoFromUrl("https://gitlab.com/owner/repo") {
    case Some(_) -> assertTrue(false, "a gitlab.com URL must not be treated as a github.com repo")
    case None -> ()
  }
}

test "githubOwnerRepoFromUrl returns None for a URL with no repo segment" {
  match CloudAgents.OpenPr.githubOwnerRepoFromUrl("https://github.com/onlyowner") {
    case Some(_) -> assertTrue(false, "an owner-only URL has no repo to extract")
    case None -> ()
  }
}

test "githubOwnerRepoFromUrl returns None for empty or garbage input" {
  match CloudAgents.OpenPr.githubOwnerRepoFromUrl("") {
    case Some(_) -> assertTrue(false, "empty input must not parse")
    case None -> ()
  }
  match CloudAgents.OpenPr.githubOwnerRepoFromUrl("not a url at all") {
    case Some(_) -> assertTrue(false, "garbage input must not parse")
    case None -> ()
  }
}

// ── decidePrAction: pure compare/dedup/create decision ────────────────────────
test "decidePrAction rejects when the session branch IS the default branch" {
  match CloudAgents.OpenPr.decidePrAction("main", "main", "ahead", "") {
    case Reject(reason) -> assertTrue(reason.length > 0, "a reason is given")
    case Reuse(_) -> assertTrue(false, "must not reuse/create against the default branch itself")
    case Create -> assertTrue(false, "must not reuse/create against the default branch itself")
  }
}

test "decidePrAction rejects when the branch has no commits ahead of default" {
  match CloudAgents.OpenPr.decidePrAction("main", "feature", "identical", "") {
    case Reject(_) -> ()
    case Reuse(_) -> assertTrue(false, "'identical' means nothing to open a PR for")
    case Create -> assertTrue(false, "'identical' means nothing to open a PR for")
  }
  match CloudAgents.OpenPr.decidePrAction("main", "feature", "behind", "") {
    case Reject(_) -> ()
    case Reuse(_) -> assertTrue(false, "'behind' means nothing to open a PR for")
    case Create -> assertTrue(false, "'behind' means nothing to open a PR for")
  }
  match CloudAgents.OpenPr.decidePrAction("main", "feature", "", "") {
    case Reject(_) -> ()
    case Reuse(_) -> assertTrue(false, "an empty/unknown compare status (e.g. branch never pushed) means nothing to open a PR for")
    case Create -> assertTrue(false, "an empty/unknown compare status (e.g. branch never pushed) means nothing to open a PR for")
  }
}

test "decidePrAction creates when the branch is ahead/diverged and no PR is already open" {
  match CloudAgents.OpenPr.decidePrAction("main", "feature", "ahead", "") {
    case Create -> ()
    case Reject(_) -> assertTrue(false, "an ahead branch with no existing PR should create one")
    case Reuse(_) -> assertTrue(false, "there is no existing PR to reuse")
  }
  match CloudAgents.OpenPr.decidePrAction("main", "feature", "diverged", "") {
    case Create -> ()
    case Reject(_) -> assertTrue(false, "a diverged branch with no existing PR should create one")
    case Reuse(_) -> assertTrue(false, "there is no existing PR to reuse")
  }
}

test "decidePrAction reuses an already-open PR instead of creating a duplicate" {
  match CloudAgents.OpenPr.decidePrAction("main", "feature", "ahead", "https://github.com/o/r/pull/5") {
    case Reuse(url) -> assertEqual(url, "https://github.com/o/r/pull/5", "the existing PR's url is returned")
    case Reject(_) -> assertTrue(false, "an ahead branch must not be rejected just because a PR already exists")
    case Create -> assertTrue(false, "must reuse the existing PR, not open a duplicate")
  }
}

// ── openPrHandler: validation paths reachable without a real GitHub call ─────
test "openPrHandler rejects an empty session id" {
  val dbPath = useFreshTestDb("open-pr-empty-id")
  defer {
    cleanupTestDb(dbPath)
  }
  match CloudAgents.OpenPr.openPrHandler("") {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id -> 400")
  }
}

test "openPrHandler 404s for an unknown or foreign session id" {
  val dbPath = useFreshTestDb("open-pr-unknown-session")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("alice")
  mkSession("sess-alice", "https://github.com/nic/repo", "feature")

  CloudAgents.Auth.setCurrentUserId("bob")
  match CloudAgents.OpenPr.openPrHandler("does-not-exist") {
    case Ok(_) -> assertTrue(false, "an unknown session id must 404")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown session -> 404")
  }
  match CloudAgents.OpenPr.openPrHandler("sess-alice") {
    case Ok(_) -> assertTrue(false, "bob must not be able to open a PR for alice's session")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign session -> 404, not a leak")
  }
}

test "openPrHandler rejects a session whose repo is not a github.com repo" {
  val dbPath = useFreshTestDb("open-pr-non-github")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  mkSession("sess-non-github", "https://gitlab.com/nic/repo", "feature")

  match CloudAgents.OpenPr.openPrHandler("sess-non-github") {
    case Ok(_) -> assertTrue(false, "a non-github.com repo must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "non-github.com repo -> 400")
  }
}

test "openPrHandler answers 404 when the vault has no GITHUB_TOKEN, without reaching GitHub" {
  val dbPath = useFreshTestDb("open-pr-no-token")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  mkSession("sess-no-token", "https://github.com/nic/repo", "feature")

  match CloudAgents.OpenPr.openPrHandler("sess-no-token") {
    case Ok(_) -> assertTrue(false, "an empty vault must not reach GitHub")
    case Err(e) -> assertEqualInt(e.status, 404, "no vault token -> 404")
  }
}
