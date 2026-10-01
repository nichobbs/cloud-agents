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
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Callbacks
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Tenancy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Db
import extern System.Environment as Env
import extern System.Text.Encoding as Utf8Encoding

// ── Live Postgres ─────────────────────────────────────────────────────────────
//
// The store is Postgres (docs/phase11-postgres-tenancy.md). These tests run iff
// LYRIC_CONFIG_DB_CONNECTION_URL (cloudagents_app) and
// CLOUD_AGENTS_MIGRATE_DATABASE_URL (cloudagents_owner) are set, and fail rather
// than skip when CLOUD_AGENTS_REQUIRE_LIVE_PG=1 (CI). Each test acts as a fresh
// user with its own personal tenant, so tests, suites and repeated runs against
// the same database never see each other's rows.
func live(): Bool {
  val ok = CloudAgents.Pg.serviceConfigured() and
    Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "").length.toInt() > 0
  if ok {
    return true
  }
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: repo artifact tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
  return false
}

func migrate(): Unit {
  val conn = match CloudAgents.Pg.connectDsn(Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "")) {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(_) -> ()
    case Err(e) -> panic("migrate failed: " + CloudAgents.Pg.pgErrorMessage(e))
  }
}

/// A new user with a provisioned personal tenant. Does not change the request
/// identity.
func newUser(tag: in String): String {
  val uid = "t-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  match CloudAgents.PgStore.Tenancy.ensurePersonalTenant(uid) {
    case Ok(_) -> ()
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
  return uid
}

/// Migrate, then make a new user the request identity (what handlers read via
/// CloudAgents.Auth.requestScope()).
func freshUser(tag: in String): String {
  migrate()
  val uid = newUser(tag)
  CloudAgents.Auth.setCurrentUserId(uid)
  return uid
}

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

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

/// Point the artifact store at a fresh on-disk directory and set the
/// encryption key the callback token path needs.
func useFreshArtifactsDir(tag: in String): Unit {
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ARTIFACTS_DIR", "/tmp/cloud-agents-artifacts-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()))
}

func uniq(prefix: in String): String {
  return prefix + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

/// A repo URL / key unique to this test's user, so repo-scoped listings never
/// see other tests' artifacts.
func repoUrlOf(me: in String): String {
  return "https://github.com/t/" + me
}

func repoKeyOf(me: in String): String {
  return "github.com/t/" + me
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
  match addSession(s, CloudAgents.Auth.requestScope()) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Db.dbErrorMessage(e))
  }
}

func mkSession(id: in String, me: in String): Unit {
  mkSessionRepo(id, repoUrlOf(me))
}

func mintToken(id: in String, ownerUserId: in String): String {
  return match CloudAgents.SessionStore.mintCallbackToken(id, CloudAgents.Pg.personalScope(ownerUserId)) {
    case Ok(t) -> t
    case Err(e) -> panic("mintCallbackToken failed: " + CloudAgents.Db.dbErrorMessage(e))
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
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-roundtrip")
  useFreshArtifactsDir("repo-artifact-roundtrip")
  val sid = uniq("sess-repo-artifact-1")
  mkSession(sid, me)
  val token = mintToken(sid, me)

  val uploaded = uploadOk(sid, token, "report.txt", "repo")
  assertTrue(uploaded.id.length > 0, "an artifact id is returned")

  match listRepoArtifactsHandler(repoKeyOf(me)) {
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
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-additive")
  useFreshArtifactsDir("repo-artifact-additive")
  val sid = uniq("sess-repo-artifact-2")
  mkSession(sid, me)
  val token = mintToken(sid, me)

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
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-cross-user")
  useFreshArtifactsDir("repo-artifact-cross-user")
  val alice = newUser("alice")
  val bob = newUser("bob")
  val repoUrl = repoUrlOf(me)
  val repoKey = repoKeyOf(me)

  CloudAgents.Auth.setCurrentUserId(alice)
  val sidAlice = uniq("sess-repo-artifact-alice")
  mkSessionRepo(sidAlice, repoUrl)
  val tokenAlice = mintToken(sidAlice, alice)
  val uploadedAlice = uploadOk(sidAlice, tokenAlice, "alice-only.txt", "repo")

  CloudAgents.Auth.setCurrentUserId(bob)
  val sidBob = uniq("sess-repo-artifact-bob")
  mkSessionRepo(sidBob, repoUrl)
  val tokenBob = mintToken(sidBob, bob)
  val uploadedBob = uploadOk(sidBob, tokenBob, "bob-only.txt", "repo")

  // Alice can see only her own artifact under the shared repoKey.
  CloudAgents.Auth.setCurrentUserId(alice)
  match listRepoArtifactsHandler(repoKey) {
    case Ok(l) -> {
      assertEqualInt(l.artifacts.length.toInt(), 1, "alice sees exactly her own artifact, not bob's")
      assertEqual(l.artifacts[0].id, uploadedAlice.id, "alice's listing contains her own artifact")
      assertEqual(l.artifacts[0].fileName, "alice-only.txt", "alice's artifact, not bob's")
    }
    case Err(e) -> assertTrue(false, "alice's repo list failed: " + toString(e.status))
  }

  // Bob can see only his own artifact under the same repoKey.
  CloudAgents.Auth.setCurrentUserId(bob)
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
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-missing-key")
  useFreshArtifactsDir("repo-artifact-missing-key")
  match listRepoArtifactsHandler("") {
    case Ok(_) -> assertTrue(false, "an empty repoKey must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty repoKey -> 400")
  }
}

/// A string at least `minLen` characters long, built by doubling (O(n))
/// rather than single-character concatenation (O(n^2) — unworkably slow at
/// this size). Mirrors tests/callbacks_v2_tests.l's own helper of the same
/// name/shape (duplicated per this codebase's per-@test_module-file
/// convention rather than imported).
func atLeast(minLen: in Int): String {
  var s = "A"
  while s.length < minLen {
    s = s + s
  }
  return s
}

test "GET repo artifacts rejects an over-length repoKey (#612)" {
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-long-key")
  useFreshArtifactsDir("repo-artifact-long-key")
  match listRepoArtifactsHandler(atLeast(2049)) {
    case Ok(_) -> assertTrue(false, "a repoKey over 2048 characters must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "over-length repoKey -> 400")
  }
}

test "report_artifact rejects an invalid scope value and rejects scope=repo when the session has no repo" {
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-scope-validation")
  useFreshArtifactsDir("repo-artifact-scope-validation")
  val sid = uniq("sess-repo-artifact-scope-val")
  mkSession(sid, me)
  val token = mintToken(sid, me)

  match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "x.txt", mimeType = "text/plain", description = "", contentBase64 = base64Of("x"), artifactScope = "bogus")) {
    case Ok(_) -> assertTrue(false, "an invalid scope value must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "invalid scope -> 400")
  }

  val sidNoRepo = uniq("sess-repo-artifact-norepo")
  mkSessionRepo(sidNoRepo, "")
  val tokenNoRepo = mintToken(sidNoRepo, me)
  match uploadArtifactHandler(sidNoRepo, bearer(tokenNoRepo), UploadArtifactRequest(fileName = "x.txt", mimeType = "text/plain", description = "", contentBase64 = base64Of("x"), artifactScope = "repo")) {
    case Ok(_) -> assertTrue(false, "scope=repo on a session with no repo must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "no repo -> 400")
  }
}

// ── regression guard: legacy scope=""/"session" behavior is unchanged ────────
test "legacy scope='' and scope='session' uploads are byte-identical to today's behavior (regression guard)" {
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-legacy")
  useFreshArtifactsDir("repo-artifact-legacy")
  val sid = uniq("sess-repo-artifact-legacy")
  mkSession(sid, me)
  val token = mintToken(sid, me)

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
  match listRepoArtifactsHandler(repoKeyOf(me)) {
    case Ok(l) -> assertEqualInt(l.artifacts.length.toInt(), 0, "session-scoped artifacts never appear in a repo listing")
    case Err(e) -> assertTrue(false, "repo list failed: " + toString(e.status))
  }
}

// ── path traversal (#610) ─────────────────────────────────────────────────────
test "report_artifact rejects a repo-scoped upload whose repo URL normalizes to a path-traversal repoKey" {
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-traversal")
  useFreshArtifactsDir("repo-artifact-traversal")
  val sid = uniq("sess-repo-artifact-traversal")
  // Passes isHttpsUrl/isSafeRepoUrl (scheme + character-class checks only —
  // neither rejects '..' path segments) but repoKeyOf preserves every path
  // segment (nested-group hosts need this — #597), so this normalizes to a
  // repoKey containing '..' — exactly the input #610 describes.
  mkSessionRepo(sid, "https://github.com/../../../../tmp/pwn")
  val token = mintToken(sid, me)

  match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "x.txt", mimeType = "text/plain", description = "", contentBase64 = base64Of("payload"), artifactScope = "repo")) {
    case Ok(_) -> assertTrue(false, "a repoKey containing '..' must never be used to build a filesystem path")
    case Err(e) -> assertEqualInt(e.status, 400, "path-traversal repoKey -> 400, not a write outside artifactsBaseDir()")
  }
}

// #634: containsPathTraversal checks each '/'-delimited segment for an
// EXACT ".." match rather than whether two dots appear anywhere in the
// string, so a repo name with two literal dots inside a longer segment
// (not itself a traversal segment) is not over-rejected.
test "report_artifact accepts a repo-scoped upload whose repoKey has two dots inside a segment, not as a whole traversal segment (#634)" {
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-dots-not-traversal")
  useFreshArtifactsDir("repo-artifact-dots-not-traversal")
  val sid = uniq("sess-repo-artifact-dots")
  mkSessionRepo(sid, "https://github.com/t/" + me + "/my..repo")
  val token = mintToken(sid, me)

  match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "x.txt", mimeType = "text/plain", description = "", contentBase64 = base64Of("payload"), artifactScope = "repo")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "a repo name with two dots inside a segment is not a traversal segment: " + toString(e.status))
  }
}

// ── downloadable from a different session (#611) ─────────────────────────────
test "a repo-scoped artifact discovered from a LATER session on the same repo is actually downloadable" {
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-cross-session-download")
  useFreshArtifactsDir("repo-artifact-cross-session-download")

  // Session A uploads a repo-scoped artifact.
  val sidA = uniq("sess-repo-artifact-download-A")
  mkSession(sidA, me)
  val tokenA = mintToken(sidA, me)
  val uploaded = uploadOk(sidA, tokenA, "handoff.txt", "repo")

  // Session B (a later session on the same repo) discovers it via the repo
  // listing — NOT via its own GET /api/sessions/{sidB}/artifacts, which
  // would never show sidA's row.
  val sidB = uniq("sess-repo-artifact-download-B")
  mkSession(sidB, me)
  val discovered = match listRepoArtifactsHandler(repoKeyOf(me)) {
    case Ok(l) -> {
      assertEqualInt(l.artifacts.length.toInt(), 1, "session B sees the artifact session A reported")
      l.artifacts[0]
    }
    case Err(e) -> panic("repo list failed: " + toString(e.status))
  }
  assertEqual(discovered.sessionId, sidA, "the summary names the artifact's ORIGINATING session, not session B's")

  // The only download route needs the originating session's id — exactly
  // what `discovered.sessionId` now provides. Without it (#611) this artifact
  // would be listable but never downloadable outside session A.
  match downloadArtifactHandler(discovered.sessionId, discovered.id) {
    case Ok(resp) -> assertEqualInt(resp.status, 200, "downloadable using the sessionId from the repo listing")
    case Err(e) -> assertTrue(false, "download via the discovered sessionId failed: " + toString(e.status))
  }
}

test "a repo-scoped artifact stays listable and downloadable after its reporting session is deleted (#619)" {
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-survives-session-delete")
  useFreshArtifactsDir("repo-artifact-survives-session-delete")

  val sid = uniq("sess-repo-artifact-deleted")
  mkSession(sid, me)
  val token = mintToken(sid, me)
  val uploaded = uploadOk(sid, token, "durable.txt", "repo")

  // Delete the reporting session's row directly (mirrors the effect of
  // DELETE /api/sessions/{id}: deleteSessionRecord is the exact call that
  // handler makes once container teardown is done — skipped here since
  // mkSession's containerId is always "").
  match CloudAgents.SessionStore.deleteSessionRecord(sid, CloudAgents.Auth.requestScope()) {
    case Ok(_) -> ()
    case Err(e) -> panic("deleteSessionRecord failed: " + CloudAgents.Db.dbErrorMessage(e))
  }

  // The repo listing must still surface it — selectRepoArtifactsSql no
  // longer joins against `sessions`, so a deleted reporting session can't
  // silently drop the row out of the listing.
  val discovered = match listRepoArtifactsHandler(repoKeyOf(me)) {
    case Ok(l) -> {
      assertEqualInt(l.artifacts.length.toInt(), 1, "the artifact is still listed after its session is gone")
      l.artifacts[0]
    }
    case Err(e) -> panic("repo list failed after session delete: " + toString(e.status))
  }
  assertEqual(discovered.id, uploaded.id, "the surviving row is the one that was uploaded")

  // The session-keyed download route is now unreachable (the session no
  // longer exists to own it) — but the session-independent repo route must
  // still serve the bytes.
  match downloadArtifactHandler(sid, discovered.id) {
    case Ok(_) -> assertTrue(false, "the session-keyed route should 404 once the session is gone")
    case Err(e) -> assertEqualInt(e.status, 404, "session-keyed download 404s once the session is deleted")
  }
  match downloadRepoArtifactHandler(discovered.id) {
    case Ok(resp) -> assertEqualInt(resp.status, 200, "the repo-scoped route downloads it with no session involved")
    case Err(e) -> assertTrue(false, "session-independent download failed: " + toString(e.status))
  }
}

test "downloadRepoArtifactHandler never serves a session-scoped (non-repo) artifact" {
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-download-rejects-session-scoped")
  useFreshArtifactsDir("repo-artifact-download-rejects-session-scoped")

  val sid = uniq("sess-repo-artifact-not-repo-scoped")
  mkSession(sid, me)
  val token = mintToken(sid, me)
  val uploaded = uploadOk(sid, token, "session-only.txt", "session")

  match downloadRepoArtifactHandler(uploaded.id) {
    case Ok(_) -> assertTrue(false, "a session-only artifact must never be reachable via the repo-scoped route")
    case Err(e) -> assertEqualInt(e.status, 404, "session-only artifact -> 404 via the repo-scoped route")
  }
}

test "downloadRepoArtifactHandler never serves another user's repo-scoped artifact" {
  if not live() {
    return
  }
  val me = freshUser("repo-artifact-download-cross-user")
  useFreshArtifactsDir("repo-artifact-download-cross-user")
  val alice = newUser("alice")
  val bob = newUser("bob")

  CloudAgents.Auth.setCurrentUserId(alice)
  val sidAlice = uniq("sess-repo-artifact-alice")
  mkSession(sidAlice, alice)
  val tokenAlice = mintToken(sidAlice, alice)
  val uploaded = uploadOk(sidAlice, tokenAlice, "alice-only.txt", "repo")

  CloudAgents.Auth.setCurrentUserId(bob)
  match downloadRepoArtifactHandler(uploaded.id) {
    case Ok(_) -> assertTrue(false, "bob must never download alice's repo-scoped artifact")
    case Err(e) -> assertEqualInt(e.status, 404, "cross-user download -> 404, not leaking existence")
  }
}
