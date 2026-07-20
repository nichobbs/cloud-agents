//! tests/repo_artifacts_tests.l — repo-scoped artifacts (docs/phase7-autonomy.md
//! §6): `report_artifact`'s `scope` argument, the corrected user-scoped
//! GET /api/repos/artifacts?repoKey=... listing, and the download path
//! branch. A separate `@test_module` file (not folded into
//! tests/callbacks_v2_tests.l) so the cross-user isolation setup (two
//! distinct owning users on sessions sharing one repoKey) stays readable on
//! its own.
@test_module
package CloudAgents.RepoArtifactsTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Callbacks
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env
import extern System.Text.Encoding as Utf8Encoding

// ── Live-DB plumbing (same pattern as tests/callbacks_v2_tests.l — each
// @test_module file duplicates this small prelude rather than importing
// another test module) ────────────────────────────────────────────────────
val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Utf8Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetBytes")
func utf8Bytes(enc: in Utf8Encoding, s: in String): slice[Byte] = []

@externTarget("System.Convert.ToBase64String")
func toBase64ForTest(b: in slice[Byte]): String = ""

func base64Of(s: in String): String {
  return toBase64ForTest(utf8Bytes(utf8Encoding(), s))
}

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  val artifactsDir = "/tmp/cloud-agents-artifacts-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ARTIFACTS_DIR", artifactsDir)
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
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ARTIFACTS_DIR", "")
  CloudAgents.Auth.setCurrentUserId("default")
}

func mkSessionRepo(id: in String, repoUrl: in String): Unit {
  val s = makeAgentSession(
    sessionId = id,
    repoUrl = repoUrl,
    branch = "main",
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

func mkSession(id: in String): Unit {
  mkSessionRepo(id, "https://github.com/nic/repo")
}

func mintToken(id: in String, ownerUserId: in String): String {
  return match CloudAgents.SessionStore.mintCallbackToken(id, ownerUserId) {
    case Ok(t) -> t
    case Err(e) -> panic("mintCallbackToken failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func bearer(token: in String): String {
  return "Bearer " + token
}

func uploadOk(sid: in String, token: in String, fileName: in String, contentScope: in String): UploadArtifactResponse {
  return match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = fileName, mimeType = "text/plain", description = "d", contentBase64 = base64Of("payload for " + fileName), artifactScope = contentScope)) {
    case Ok(r) -> r
    case Err(e) -> panic("upload failed: " + toString(e.status))
  }
}

// ── scope=repo round trip: upload -> repo list -> download ───────────────────
test "report_artifact with scope=repo appears in the repo listing for the same user and downloads via the repo path" {
  val dbPath = useFreshTestDb("repo-artifact-roundtrip")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-repo-artifact-1"
  mkSession(sid)
  val token = mintToken(sid, "default")

  val uploaded = uploadOk(sid, token, "report.txt", "repo")
  assertTrue(uploaded.id.length > 0, "an artifact id is returned")

  match listRepoArtifactsHandler("github.com/nic/repo") {
    case Ok(l) -> {
      assertEqualInt(l.artifacts.length.toInt(), 1, "one repo-scoped artifact listed")
      assertEqual(l.artifacts[0].fileName, "report.txt", "fileName round-trips")
      assertEqual(l.artifacts[0].id, uploaded.id, "the listed artifact is the one just uploaded")
    }
    case Err(e) -> assertTrue(false, "repo list failed: " + toString(e.status))
  }

  match downloadArtifactHandler(sid, uploaded.id) {
    case Ok(resp) -> assertEqualInt(resp.status, 200, "download succeeds via the repo-keyed on-disk path")
    case Err(e) -> assertTrue(false, "download failed: " + toString(e.status))
  }
}

// ── additive, not exclusive: still shows up in the reporting session's own list ──
test "a repo-scoped artifact still lists under its own session's GET /artifacts (additive, not exclusive)" {
  val dbPath = useFreshTestDb("repo-artifact-additive")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-repo-artifact-2"
  mkSession(sid)
  val token = mintToken(sid, "default")

  val uploaded = uploadOk(sid, token, "additive.txt", "repo")

  match listArtifactsHandler(sid) {
    case Ok(l) -> {
      assertEqualInt(l.artifacts.length.toInt(), 1, "the repo-scoped artifact still appears in its own session's listing")
      assertEqual(l.artifacts[0].id, uploaded.id, "it is the same artifact")
    }
    case Err(e) -> assertTrue(false, "session list failed: " + toString(e.status))
  }
}

// ── cross-user isolation: same repoKey, different owning users ───────────────
test "repo artifact listing never leaks another user's artifacts under the same repoKey (#security)" {
  val dbPath = useFreshTestDb("repo-artifact-cross-user")
  defer {
    cleanupTestDb(dbPath)
  }
  val repoUrl = "https://github.com/shared/repo"
  val repoKey = "github.com/shared/repo"

  CloudAgents.Auth.setCurrentUserId("alice")
  val sidAlice = "sess-repo-artifact-alice"
  mkSessionRepo(sidAlice, repoUrl)
  val tokenAlice = mintToken(sidAlice, "alice")
  val uploadedAlice = uploadOk(sidAlice, tokenAlice, "alice-only.txt", "repo")

  CloudAgents.Auth.setCurrentUserId("bob")
  val sidBob = "sess-repo-artifact-bob"
  mkSessionRepo(sidBob, repoUrl)
  val tokenBob = mintToken(sidBob, "bob")
  val uploadedBob = uploadOk(sidBob, tokenBob, "bob-only.txt", "repo")

  // Alice can see only her own artifact under the shared repoKey.
  CloudAgents.Auth.setCurrentUserId("alice")
  match listRepoArtifactsHandler(repoKey) {
    case Ok(l) -> {
      assertEqualInt(l.artifacts.length.toInt(), 1, "alice sees exactly her own artifact, not bob's")
      assertEqual(l.artifacts[0].id, uploadedAlice.id, "alice's listing contains her own artifact")
      assertEqual(l.artifacts[0].fileName, "alice-only.txt", "alice's artifact, not bob's")
    }
    case Err(e) -> assertTrue(false, "alice's repo list failed: " + toString(e.status))
  }

  // Bob can see only his own artifact under the same repoKey.
  CloudAgents.Auth.setCurrentUserId("bob")
  match listRepoArtifactsHandler(repoKey) {
    case Ok(l) -> {
      assertEqualInt(l.artifacts.length.toInt(), 1, "bob sees exactly his own artifact, not alice's")
      assertEqual(l.artifacts[0].id, uploadedBob.id, "bob's listing contains his own artifact")
    }
    case Err(e) -> assertTrue(false, "bob's repo list failed: " + toString(e.status))
  }
}

// ── validation ────────────────────────────────────────────────────────────────
test "GET repo artifacts requires a repoKey" {
  val dbPath = useFreshTestDb("repo-artifact-missing-key")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  match listRepoArtifactsHandler("") {
    case Ok(_) -> assertTrue(false, "an empty repoKey must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty repoKey -> 400")
  }
}

test "report_artifact rejects an invalid scope value and rejects scope=repo when the session has no repo" {
  val dbPath = useFreshTestDb("repo-artifact-scope-validation")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-repo-artifact-scope-val"
  mkSession(sid)
  val token = mintToken(sid, "default")

  match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "x.txt", mimeType = "text/plain", description = "", contentBase64 = base64Of("x"), artifactScope = "bogus")) {
    case Ok(_) -> assertTrue(false, "an invalid scope value must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "invalid scope -> 400")
  }

  val sidNoRepo = "sess-repo-artifact-norepo"
  mkSessionRepo(sidNoRepo, "")
  val tokenNoRepo = mintToken(sidNoRepo, "default")
  match uploadArtifactHandler(sidNoRepo, bearer(tokenNoRepo), UploadArtifactRequest(fileName = "x.txt", mimeType = "text/plain", description = "", contentBase64 = base64Of("x"), artifactScope = "repo")) {
    case Ok(_) -> assertTrue(false, "scope=repo on a session with no repo must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "no repo -> 400")
  }
}

// ── regression guard: legacy scope=""/"session" behavior is unchanged ────────
test "legacy scope='' and scope='session' uploads are byte-identical to today's behavior (regression guard)" {
  val dbPath = useFreshTestDb("repo-artifact-legacy")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-repo-artifact-legacy"
  mkSession(sid)
  val token = mintToken(sid, "default")

  val emptyScope = uploadOk(sid, token, "empty-scope.txt", "")
  val sessionScope = uploadOk(sid, token, "session-scope.txt", "session")

  match listArtifactsHandler(sid) {
    case Ok(l) -> {
      assertEqualInt(l.artifacts.length.toInt(), 2, "both session-scoped uploads are listed")
      assertEqual(l.artifacts[0].fileName, "empty-scope.txt", "first upload (empty scope) round-trips")
      assertEqual(l.artifacts[1].fileName, "session-scope.txt", "second upload (explicit 'session' scope) round-trips")
    }
    case Err(e) -> assertTrue(false, "list failed: " + toString(e.status))
  }

  match downloadArtifactHandler(sid, emptyScope.id) {
    case Ok(resp) -> assertEqualInt(resp.status, 200, "empty-scope download succeeds via the unchanged session path")
    case Err(e) -> assertTrue(false, "empty-scope download failed: " + toString(e.status))
  }
  match downloadArtifactHandler(sid, sessionScope.id) {
    case Ok(resp) -> assertEqualInt(resp.status, 200, "explicit session-scope download succeeds via the unchanged session path")
    case Err(e) -> assertTrue(false, "session-scope download failed: " + toString(e.status))
  }

  // Neither legacy-scoped upload is visible in ANY repo listing — repo_key
  // stays '' for both, exactly as before this change.
  match listRepoArtifactsHandler("github.com/nic/repo") {
    case Ok(l) -> assertEqualInt(l.artifacts.length.toInt(), 0, "session-scoped artifacts never appear in a repo listing")
    case Err(e) -> assertTrue(false, "repo list failed: " + toString(e.status))
  }
}
