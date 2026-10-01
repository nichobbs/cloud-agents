//! Container callback tests, v2 (request_secret, report_artifact, remember /
//! recall / forget) against the Postgres store.
@test_module
package CloudAgents.CallbacksV2Tests

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
import CloudAgents.Scope
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env
import extern System.Text.Encoding as Utf8Encoding

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

/// A string at least `minLen` characters long, built by doubling
/// (`s = s + s`) rather than single-character concatenation — an
/// O(n) approach used to build an oversize contentBase64 body without a
/// real 8 MiB literal in the source. (Naive one-character-at-a-time
/// concatenation is O(n^2) and is genuinely too slow at this size: it was
/// timed out and replaced with this doubling approach.)
func atLeast(minLen: in Int): String {
  var s = "A"
  while s.length < minLen {
    s = s + s
  }
  return s
}

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
  println("SKIP: callbacks v2 tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
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
    case Err(e) -> panic("provisioning " + uid + " failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
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

/// Session ids are global primary keys that persist across runs.
func uniq(prefix: in String): String {
  return prefix + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

/// freshUser plus the encryption key and artifact directory the secret and
/// artifact handlers need.
func fresh(tag: in String): String {
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ARTIFACTS_DIR", "/tmp/cloud-agents-artifacts-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()))
  return freshUser(tag)
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
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mkSession(id: in String): Unit {
  mkSessionRepo(id, "https://github.com/nic/repo")
}

func mintToken(id: in String, ownerUserId: in String): String {
  return match CloudAgents.SessionStore.mintCallbackToken(id, CloudAgents.Pg.personalScope(ownerUserId)) {
    case Ok(t) -> t
    case Err(e) -> panic("mintCallbackToken failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func bearer(token: in String): String {
  return "Bearer " + token
}

func mustPutCredential(userId: in String, name: in String, value: in String): Unit {
  match CloudAgents.Repository.putCredential(CloudAgents.Scope.userScope(userId), name, value) {
    case Ok(_) -> ()
    case Err(e) -> panic("putCredential failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
}

// ── request_secret ──────────────────────────────────────────────────────────
test "request_secret round trip: create -> poll pending -> approve -> poll delivers value ONCE" {
  if not live() {
    return
  }
  val me = fresh("secret-roundtrip")
  val sid = uniq("sess-secret-1")
  mkSession(sid)
  val token = mintToken(sid, me)
  mustPutCredential(me, "GITHUB_TOKEN", "ghp_super_secret")

  val created = match createSecretRequestHandler(sid, bearer(token), CreateSecretRequestRequest(name = "GITHUB_TOKEN", reason = "push a branch")) {
    case Ok(r) -> r
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  assertEqual(created.status, "pending", "fresh request starts pending")

  match getSecretRequestHandler(sid, created.id, bearer(token)) {
    case Ok(d) -> {
      assertEqual(d.status, "pending", "poll before answer sees pending")
      assertEqual(d.value, "", "no value while pending")
    }
    case Err(e) -> assertTrue(false, "poll failed: " + toString(e.status))
  }

  match answerSecretRequestHandler(sid, created.id, AnswerSecretRequestRequest(decision = "approve")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "answer failed: " + toString(e.status))
  }

  // First poll after approval: the value is delivered exactly once.
  match getSecretRequestHandler(sid, created.id, bearer(token)) {
    case Ok(d) -> {
      assertEqual(d.status, "approved", "poll after answer sees approved")
      assertEqual(d.value, "ghp_super_secret", "the decrypted value is returned on first delivery")
    }
    case Err(e) -> assertTrue(false, "poll after answer failed: " + toString(e.status))
  }

  // A second poll of the SAME request must NOT hand back the value again.
  match getSecretRequestHandler(sid, created.id, bearer(token)) {
    case Ok(d) -> {
      assertEqual(d.status, "approved", "second poll still reports approved")
      assertEqual(d.value, "", "the value is never delivered a second time")
    }
    case Err(e) -> assertTrue(false, "second poll failed: " + toString(e.status))
  }

  // A second answer is a 409 (write-once), mirroring permission requests.
  match answerSecretRequestHandler(sid, created.id, AnswerSecretRequestRequest(decision = "deny")) {
    case Ok(_) -> assertTrue(false, "an already-decided secret request must not be answered twice")
    case Err(e) -> assertEqualInt(e.status, 409, "double-answer returns 409")
  }
}

test "request_secret deny path never carries a value" {
  if not live() {
    return
  }
  val me = fresh("secret-deny")
  val sid = uniq("sess-secret-2")
  mkSession(sid)
  val token = mintToken(sid, me)
  mustPutCredential(me, "AWS_KEY", "aws-secret-value")

  val created = match createSecretRequestHandler(sid, bearer(token), CreateSecretRequestRequest(name = "AWS_KEY", reason = "deploy")) {
    case Ok(r) -> r
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  match answerSecretRequestHandler(sid, created.id, AnswerSecretRequestRequest(decision = "deny")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "deny failed: " + toString(e.status))
  }
  match getSecretRequestHandler(sid, created.id, bearer(token)) {
    case Ok(d) -> {
      assertEqual(d.status, "denied", "poll after deny sees denied")
      assertEqual(d.value, "", "a denied request never carries a value")
    }
    case Err(e) -> assertTrue(false, "poll failed: " + toString(e.status))
  }
}

test "request_secret deny-on-timeout backstop never carries a value" {
  if not live() {
    return
  }
  val me = fresh("secret-timeout")
  val sid = uniq("sess-secret-3")
  mkSession(sid)
  val token = mintToken(sid, me)
  mustPutCredential(me, "TOKEN", "value")

  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS", "0")
  defer {
    Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS", "")
  }
  val created = match createSecretRequestHandler(sid, bearer(token), CreateSecretRequestRequest(name = "TOKEN", reason = "x")) {
    case Ok(r) -> r
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  match getSecretRequestHandler(sid, created.id, bearer(token)) {
    case Ok(d) -> {
      assertEqual(d.status, "timed_out", "an expired-timeout poll fails closed to timed_out")
      assertEqual(d.value, "", "a timed-out request never carries a value")
    }
    case Err(e) -> assertTrue(false, "poll failed: " + toString(e.status))
  }
}

test "request_secret create fails fast when the named credential does not exist" {
  if not live() {
    return
  }
  val me = fresh("secret-missing-cred")
  val sid = uniq("sess-secret-4")
  mkSession(sid)
  val token = mintToken(sid, me)

  // No credential named NOPE has been stored for this user.
  match createSecretRequestHandler(sid, bearer(token), CreateSecretRequestRequest(name = "NOPE", reason = "x")) {
    case Ok(_) -> assertTrue(false, "a request for an unconfigured credential must fail fast")
    case Err(e) -> {
      assertEqualInt(e.status, 400, "missing credential -> 400, not a pending row")
      assertTrue(e.message.contains("NOPE"), "error names the requested credential")
    }
  }
}

test "request_secret answer denies-only when the credential was deleted after creation" {
  if not live() {
    return
  }
  val me = fresh("secret-race")
  val sid = uniq("sess-secret-5")
  mkSession(sid)
  val token = mintToken(sid, me)
  mustPutCredential(me, "ROTATING", "value")

  val created = match createSecretRequestHandler(sid, bearer(token), CreateSecretRequestRequest(name = "ROTATING", reason = "x")) {
    case Ok(r) -> r
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  // Credential deleted between create and answer (a real race in production).
  match CloudAgents.Repository.deleteCredential(CloudAgents.Scope.userScope(me), "ROTATING") {
    case Ok(_) -> ()
    case Err(e) -> panic("deleteCredential failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match answerSecretRequestHandler(sid, created.id, AnswerSecretRequestRequest(decision = "approve")) {
    case Ok(_) -> assertTrue(false, "approving a request for a now-missing credential must fail")
    case Err(e) -> assertEqualInt(e.status, 400, "vanished credential -> 400, human can only deny")
  }
  // Deny still works.
  match answerSecretRequestHandler(sid, created.id, AnswerSecretRequestRequest(decision = "deny")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "deny should still succeed: " + toString(e.status))
  }
}

test "report_artifact upload -> list -> download round trip, and traversal is neutralized" {
  if not live() {
    return
  }
  val me = fresh("artifact-roundtrip")
  val sid = uniq("sess-artifact-1")
  mkSession(sid)
  val token = mintToken(sid, me)

  val uploaded = match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "report.txt", mimeType = "text/plain", description = "a report", contentBase64 = base64Of("hello artifact"), artifactScope = "")) {
    case Ok(r) -> r
    case Err(e) -> panic("upload failed: " + toString(e.status))
  }
  assertTrue(uploaded.id.length > 0, "an artifact id is returned")

  match listArtifactsHandler(sid) {
    case Ok(l) -> {
      assertEqualInt(l.artifacts.length.toInt(), 1, "one artifact listed")
      assertEqual(l.artifacts[0].fileName, "report.txt", "fileName round-trips")
      assertEqual(l.artifacts[0].mimeType, "text/plain", "mimeType round-trips")
      assertEqual(l.artifacts[0].sizeBytes, "14", "sizeBytes is the decoded byte count")
    }
    case Err(e) -> assertTrue(false, "list failed: " + toString(e.status))
  }

  match downloadArtifactHandler(sid, uploaded.id) {
    case Ok(resp) -> assertEqualInt(resp.status, 200, "download succeeds")
    case Err(e) -> assertTrue(false, "download failed: " + toString(e.status))
  }

  // Path traversal in fileName is neutralized (basename only): the stored
  // artifact's fileName must never carry a directory component.
  val traversal = match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "../../etc/passwd", mimeType = "text/plain", description = "", contentBase64 = base64Of("x"), artifactScope = "")) {
    case Ok(r) -> r
    case Err(e) -> panic("traversal-attempt upload should still succeed with a sanitized name: " + toString(e.status))
  }
  match listArtifactsHandler(sid) {
    case Ok(l) -> {
      var found = false
      for a in l.artifacts {
        if a.id == traversal.id {
          found = true
          assertEqual(a.fileName, "passwd", "fileName is reduced to its basename")
          assertTrue(not a.fileName.contains("/"), "no path separator survives sanitization")
        }
      }
      assertTrue(found, "the traversal-attempt artifact was still stored, just renamed")
    }
    case Err(e) -> assertTrue(false, "list failed: " + toString(e.status))
  }
}

test "report_artifact rejects an oversize upload before storing anything" {
  if not live() {
    return
  }
  val me = fresh("artifact-oversize")
  val sid = uniq("sess-artifact-2")
  mkSession(sid)
  val token = mintToken(sid, me)

  // A contentBase64 string longer than the pre-decode cap is rejected
  // without ever reaching the decoder.
  val huge = atLeast(11184813)
  match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "big.bin", mimeType = "application/octet-stream", description = "", contentBase64 = huge, artifactScope = "")) {
    case Ok(_) -> assertTrue(false, "an oversize artifact must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "oversize -> 400")
  }
  match listArtifactsHandler(sid) {
    case Ok(l) -> assertEqualInt(l.artifacts.length.toInt(), 0, "nothing was stored for the rejected upload")
    case Err(e) -> assertTrue(false, "list failed: " + toString(e.status))
  }
}

test "report_artifact rejects a dangerous mimeType before storing anything (#1007)" {
  // Chat attachments (CloudAgents.Handlers.isDangerousAttachmentMimeType,
  // #999/#1000) reject SVG/HTML/XHTML uploads as a stored-XSS defense since
  // mimeType is client-supplied and echoed back verbatim as the download
  // response's Content-Type. report_artifact serves artifacts back the same
  // way (downloadArtifactHandler) but had no equivalent check — this pins
  // the duplicated CloudAgents.Callbacks.isDangerousArtifactMimeType closing
  // that gap.
  if not live() {
    return
  }
  val me = fresh("artifact-dangerous-mime")
  val sid = uniq("sess-artifact-dangerous")
  mkSession(sid)
  val token = mintToken(sid, me)

  match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "evil.svg", mimeType = "image/svg+xml", description = "", contentBase64 = base64Of("<svg onload=alert(1)>"), artifactScope = "")) {
    case Ok(_) -> assertTrue(false, "an SVG upload must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "dangerous mimeType -> 400")
  }
  // Case and a MIME parameter suffix must not bypass the check either,
  // matching isDangerousAttachmentMimeType's own guarantees (#999/#1000).
  match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "evil.html", mimeType = "TEXT/HTML; charset=utf-8", description = "", contentBase64 = base64Of("<script>alert(1)</script>"), artifactScope = "")) {
    case Ok(_) -> assertTrue(false, "an HTML upload must be rejected regardless of case or a parameter suffix")
    case Err(e) -> assertEqualInt(e.status, 400, "dangerous mimeType -> 400")
  }
  match listArtifactsHandler(sid) {
    case Ok(l) -> assertEqualInt(l.artifacts.length.toInt(), 0, "nothing was stored for either rejected upload")
    case Err(e) -> assertTrue(false, "list failed: " + toString(e.status))
  }

  // An ordinary mime type is unaffected by the new check.
  match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "fine.txt", mimeType = "text/plain", description = "", contentBase64 = base64Of("hello"), artifactScope = "")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "an ordinary mimeType must still be accepted: " + toString(e.status))
  }
}

// ── Validation ───────────────────────────────────────────────────────────────
test "v2 callback endpoints reject an empty session id before touching the database" {
  if not live() {
    return
  }
  val me = fresh("v2-empty-id")
  match createSecretRequestHandler("", "", CreateSecretRequestRequest(name = "X", reason = "")) {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id returns 400")
  }
  match uploadArtifactHandler("", "", UploadArtifactRequest(fileName = "x", mimeType = "text/plain", description = "", contentBase64 = "", artifactScope = "")) {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id returns 400")
  }
}

test "contentDispositionQuoted escapes quotes/backslashes and strips control chars (#547)" {
  // A quote in an (already basename-sanitized) fileName must be escaped so
  // it can't break out of the Content-Disposition quoted-string.
  assertEqual(
    CloudAgents.Callbacks.contentDispositionQuoted("re\"port.txt"),
    "re\\\"port.txt",
    "a double quote is backslash-escaped"
  )
  assertEqual(CloudAgents.Callbacks.contentDispositionQuoted("a\\b"), "a\\\\b", "a backslash is doubled")
  // A CR/LF would split the header — dropped, not passed through.
  assertEqual(
    CloudAgents.Callbacks.contentDispositionQuoted("a\r\nb"),
    "ab",
    "control characters are stripped so the header cannot be split"
  )
  assertEqual(
    CloudAgents.Callbacks.contentDispositionQuoted("normal.txt"),
    "normal.txt",
    "an ordinary name is unchanged"
  )
}

// ── remember / recall (phase 7 §4) ────────────────────────────────────────────
test "remember then recall round-trips, overwrites by key, and stays repo-scoped" {
  if not live() {
    return
  }
  val me = fresh("memory-roundtrip")
  val sid = uniq("sess-memory-1")
  mkSession(sid)
  val token = mintToken(sid, me)

  match rememberHandler(sid, bearer(token), RememberRequest(key = "build", value = "make lyric")) {
    case Ok(r) -> assertEqual(r.key, "build", "remember echoes the stored key")
    case Err(e) -> assertTrue(false, "remember failed: " + toString(e.status))
  }
  match rememberHandler(sid, bearer(token), RememberRequest(key = "tests", value = "lyric test")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "second remember failed: " + toString(e.status))
  }

  match recallHandler(sid, bearer(token), None) {
    case Ok(l) -> {
      assertEqualInt(l.entries.length.toInt(), 2, "both entries recalled")
      assertEqual(l.entries[0].key, "build", "entries are key-ordered")
      assertEqual(l.entries[0].value, "make lyric", "value round-trips")
      assertEqual(l.entries[1].key, "tests", "second key present")
    }
    case Err(e) -> assertTrue(false, "recall failed: " + toString(e.status))
  }

  // Re-remembering the same key overwrites the value rather than adding a row.
  match rememberHandler(sid, bearer(token), RememberRequest(key = "build", value = "make lyric && ./scripts/verify.sh")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "overwrite remember failed: " + toString(e.status))
  }
  match recallHandler(sid, bearer(token), None) {
    case Ok(l) -> {
      assertEqualInt(l.entries.length.toInt(), 2, "overwrite does not add a row")
      assertEqual(l.entries[0].value, "make lyric && ./scripts/verify.sh", "the value was overwritten")
    }
    case Err(e) -> assertTrue(false, "recall after overwrite failed: " + toString(e.status))
  }
}

test "recall with a key does a single-entry lookup instead of the whole list (#590)" {
  if not live() {
    return
  }
  val me = fresh("memory-recall-key")
  val sid = uniq("sess-memory-key")
  mkSession(sid)
  val token = mintToken(sid, me)

  match rememberHandler(sid, bearer(token), RememberRequest(key = "build", value = "make lyric")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "remember build failed: " + toString(e.status))
  }
  match rememberHandler(sid, bearer(token), RememberRequest(key = "tests", value = "lyric test")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "remember tests failed: " + toString(e.status))
  }

  // A known key returns exactly that one entry, not the whole store.
  match recallHandler(sid, bearer(token), Some(value = "tests")) {
    case Ok(l) -> {
      assertEqualInt(l.entries.length.toInt(), 1, "a keyed recall returns exactly one entry")
      assertEqual(l.entries[0].key, "tests", "the requested key is returned")
      assertEqual(l.entries[0].value, "lyric test", "the requested key's value round-trips")
    }
    case Err(e) -> assertTrue(false, "keyed recall failed: " + toString(e.status))
  }

  // An unknown key returns an empty list, not an error.
  match recallHandler(sid, bearer(token), Some(value = "nope")) {
    case Ok(l) -> assertEqualInt(l.entries.length.toInt(), 0, "an unknown key returns no entries")
    case Err(e) -> assertTrue(false, "keyed recall of an unknown key must not error: " + toString(e.status))
  }

  // An empty key string behaves the same as no key at all (returns everything).
  match recallHandler(sid, bearer(token), Some(value = "")) {
    case Ok(l) -> assertEqualInt(l.entries.length.toInt(), 2, "an empty key falls back to the full list")
    case Err(e) -> assertTrue(false, "empty-key recall failed: " + toString(e.status))
  }

  // An over-length key is a 400, same validation as remember/forget (#594).
  match recallHandler(sid, bearer(token), Some(value = atLeast(257))) {
    case Ok(_) -> assertTrue(false, "an over-length key must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "over-length key -> 400")
  }

  // A wrong callback token is rejected before the key is even looked at.
  match recallHandler(sid, bearer("wrong-token"), Some(value = "build")) {
    case Ok(_) -> assertTrue(false, "a wrong callback token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 401, "bad token -> 401")
  }
}

test "memory carries across sessions on the same repo, isolated from other repos" {
  if not live() {
    return
  }
  val me = fresh("memory-cross-session")

  val sidA = uniq("sess-memory-A")
  mkSession(sidA)
  val tokenA = mintToken(sidA, me)
  match rememberHandler(sidA, bearer(tokenA), RememberRequest(key = "quirk", value = "native lib needed")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "remember A failed: " + toString(e.status))
  }

  // A brand-new session on the SAME repo recalls the earlier note — the point.
  val sidB = uniq("sess-memory-B")
  mkSession(sidB)
  val tokenB = mintToken(sidB, me)
  match recallHandler(sidB, bearer(tokenB), None) {
    case Ok(l) -> {
      assertEqualInt(l.entries.length.toInt(), 1, "a new session on the same repo inherits the memory")
      assertEqual(l.entries[0].value, "native lib needed", "the earlier session's note is readable")
    }
    case Err(e) -> assertTrue(false, "recall B failed: " + toString(e.status))
  }

  // A session on a DIFFERENT repo sees none of it.
  val sidC = uniq("sess-memory-C")
  mkSessionRepo(sidC, "https://github.com/nic/other")
  val tokenC = mintToken(sidC, me)
  match recallHandler(sidC, bearer(tokenC), None) {
    case Ok(l) -> assertEqualInt(l.entries.length.toInt(), 0, "a different repo shares no memory")
    case Err(e) -> assertTrue(false, "recall C failed: " + toString(e.status))
  }
}

test "remember validates key/value and rejects a session with no repo to scope to" {
  if not live() {
    return
  }
  val me = fresh("memory-validation")
  val sid = uniq("sess-memory-val")
  mkSession(sid)
  val token = mintToken(sid, me)

  match rememberHandler(sid, bearer(token), RememberRequest(key = "", value = "v")) {
    case Ok(_) -> assertTrue(false, "empty key must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty key -> 400")
  }
  match rememberHandler(sid, bearer(token), RememberRequest(key = "k", value = "")) {
    case Ok(_) -> assertTrue(false, "empty value must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty value -> 400")
  }
  // An over-length key (> 256) and an over-length value (> 64 KiB) are both
  // rejected before any write (#589).
  match rememberHandler(sid, bearer(token), RememberRequest(key = atLeast(257), value = "v")) {
    case Ok(_) -> assertTrue(false, "an over-length key must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "over-length key -> 400")
  }
  match rememberHandler(sid, bearer(token), RememberRequest(key = "k", value = atLeast(65537))) {
    case Ok(_) -> assertTrue(false, "an over-length value must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "over-length value -> 400")
  }

  val sidNoRepo = uniq("sess-memory-norepo")
  mkSessionRepo(sidNoRepo, "")
  val tokenNoRepo = mintToken(sidNoRepo, me)
  match rememberHandler(sidNoRepo, bearer(tokenNoRepo), RememberRequest(key = "k", value = "v")) {
    case Ok(_) -> assertTrue(false, "a session with no repo must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "no repo -> 400")
  }
}

test "remember rejects values shaped like common credential formats (#593)" {
  if not live() {
    return
  }
  val me = fresh("memory-secret-heuristic")
  val sid = uniq("sess-memory-secret")
  mkSession(sid)
  val token = mintToken(sid, me)

  // Known provider prefixes (#593).
  match rememberHandler(sid, bearer(token), RememberRequest(key = "k", value = "sk-abcdefghijklmnopqrstuvwxyz012345")) {
    case Ok(_) -> assertTrue(false, "an OpenAI-style sk- value must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "sk- prefix -> 400")
  }
  match rememberHandler(sid, bearer(token), RememberRequest(key = "k", value = "ghp_abcdefghijklmnopqrstuvwxyz0123456789")) {
    case Ok(_) -> assertTrue(false, "a GitHub ghp_ token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "ghp_ prefix -> 400")
  }
  match rememberHandler(sid, bearer(token), RememberRequest(key = "k", value = "gho_abcdefghijklmnopqrstuvwxyz0123456789")) {
    case Ok(_) -> assertTrue(false, "a GitHub gho_ token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "gho_ prefix -> 400")
  }
  match rememberHandler(sid, bearer(token), RememberRequest(key = "k", value = "ghs_abcdefghijklmnopqrstuvwxyz0123456789")) {
    case Ok(_) -> assertTrue(false, "a GitHub ghs_ token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "ghs_ prefix -> 400")
  }
  match rememberHandler(sid, bearer(token), RememberRequest(key = "k", value = "AKIAABCDEFGHIJKLMNOP")) {
    case Ok(_) -> assertTrue(false, "an AWS AKIA access key must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "AKIA prefix -> 400")
  }

  // JWT shape: header.payload.signature, with the header segment starting
  // "eyJ" (a JSON object literal's base64url encoding always starts this way).
  val jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dGhpc2lzYXNpZ25hdHVyZQ"
  match rememberHandler(sid, bearer(token), RememberRequest(key = "k", value = jwt)) {
    case Ok(_) -> assertTrue(false, "a JWT-shaped value must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "JWT shape -> 400")
  }

  // Generic high-entropy single token: long, no whitespace, mixed
  // upper/lower/digit, no recognizable provider prefix.
  val highEntropy = "aB3dE6fG9hJ2kL5mN8pQ1rS4tU7vW0xY3zA6bC9dE2fG5"
  match rememberHandler(sid, bearer(token), RememberRequest(key = "k", value = highEntropy)) {
    case Ok(_) -> assertTrue(false, "a long high-entropy-looking token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "high-entropy token -> 400")
  }

  // Normal, non-secret-looking values are unaffected.
  match rememberHandler(sid, bearer(token), RememberRequest(key = "build", value = "make lyric && ./scripts/verify.sh")) {
    case Ok(r) -> assertEqual(r.key, "build", "an ordinary sentence-shaped value is accepted")
    case Err(e) -> assertTrue(false, "an ordinary value must not be rejected: " + toString(e.status))
  }
  match rememberHandler(sid, bearer(token), RememberRequest(key = "tests", value = "lyric test")) {
    case Ok(r) -> assertEqual(r.key, "tests", "a short normal value is accepted")
    case Err(e) -> assertTrue(false, "an ordinary value must not be rejected: " + toString(e.status))
  }
  // A short token-shaped value under the high-entropy length floor is fine
  // (e.g. a short commit hash prefix or id).
  match rememberHandler(sid, bearer(token), RememberRequest(key = "commit", value = "abc123")) {
    case Ok(r) -> assertEqual(r.key, "commit", "a short token-shaped value under the length floor is accepted")
    case Err(e) -> assertTrue(false, "a short value must not be rejected: " + toString(e.status))
  }

  // #636: a full-length git SHA-1 (40 lowercase hex chars) and a UUID are
  // both plausible, entirely non-secret things to remember (e.g. "last
  // verified commit") — neither should trip the generic high-entropy check,
  // even though both are >= the length floor and mix lowercase letters with
  // digits, exactly the shape that check otherwise flags.
  match rememberHandler(
    sid, bearer(token), RememberRequest(key = "lastGoodCommit", value = "a1b2c3d4e5f6789012345678901234567890abcd")
  ) {
    case Ok(r) -> assertEqual(r.key, "lastGoodCommit", "a 40-char git SHA-1 is not treated as a secret")
    case Err(e) -> assertTrue(false, "a git SHA must not be rejected: " + toString(e.status))
  }
  match rememberHandler(
    sid, bearer(token), RememberRequest(key = "deploymentId", value = "123e4567-e89b-12d3-a456-426614174000")
  ) {
    case Ok(r) -> assertEqual(r.key, "deploymentId", "a UUID is not treated as a secret")
    case Err(e) -> assertTrue(false, "a UUID must not be rejected: " + toString(e.status))
  }
}

test "recall requires a valid callback token; the owner can list via the user route" {
  if not live() {
    return
  }
  val me = fresh("memory-auth")
  val sid = uniq("sess-memory-auth")
  mkSession(sid)
  val token = mintToken(sid, me)

  match recallHandler(sid, bearer("wrong-token"), None) {
    case Ok(_) -> assertTrue(false, "a wrong callback token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 401, "bad token -> 401")
  }
  match rememberHandler(sid, bearer(token), RememberRequest(key = "k", value = "v")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "remember failed: " + toString(e.status))
  }
  match listMemoryHandler(sid) {
    case Ok(l) -> assertEqualInt(l.entries.length.toInt(), 1, "the owner can list repo memory")
    case Err(e) -> assertTrue(false, "listMemory failed: " + toString(e.status))
  }
}

test "forget deletes an entry, frees a slot under the cap, and is idempotent (#592)" {
  if not live() {
    return
  }
  val me = fresh("memory-forget")
  val sid = uniq("sess-memory-forget")
  mkSession(sid)
  val token = mintToken(sid, me)

  match rememberHandler(sid, bearer(token), RememberRequest(key = "build", value = "make lyric")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "remember failed: " + toString(e.status))
  }
  // Forgetting a present key deletes it.
  match forgetHandler(sid, bearer(token), ForgetRequest(key = "build")) {
    case Ok(r) -> assertEqual(r.status, "deleted", "an existing key reports deleted")
    case Err(e) -> assertTrue(false, "forget failed: " + toString(e.status))
  }
  match recallHandler(sid, bearer(token), None) {
    case Ok(l) -> assertEqualInt(l.entries.length.toInt(), 0, "the entry is gone after forget")
    case Err(e) -> assertTrue(false, "recall failed: " + toString(e.status))
  }
  // Forgetting an absent key is a success, not an error (idempotent).
  match forgetHandler(sid, bearer(token), ForgetRequest(key = "build")) {
    case Ok(r) -> assertEqual(r.status, "absent", "a missing key reports absent, not an error")
    case Err(e) -> assertTrue(false, "idempotent forget must not error: " + toString(e.status))
  }
  // A wrong callback token is rejected.
  match forgetHandler(sid, bearer("wrong-token"), ForgetRequest(key = "build")) {
    case Ok(_) -> assertTrue(false, "a wrong callback token must be rejected")
    case Err(e) -> assertEqualInt(e.status, 401, "bad token -> 401")
  }
  // Key validation matches remember: empty and over-length keys are 400 (#594).
  match forgetHandler(sid, bearer(token), ForgetRequest(key = "")) {
    case Ok(_) -> assertTrue(false, "an empty key must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty key -> 400")
  }
  match forgetHandler(sid, bearer(token), ForgetRequest(key = atLeast(257))) {
    case Ok(_) -> assertTrue(false, "an over-length key must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "over-length key -> 400")
  }
}

test "remember caps the number of distinct keys per repo but always allows overwrites (#575)" {
  if not live() {
    return
  }
  val me = fresh("memory-cap")
  val sid = uniq("sess-memory-cap")
  mkSession(sid)
  val token = mintToken(sid, me)

  // Fill the repo to exactly the cap (256 distinct keys).
  var i = 0
  while i < 256 {
    match rememberHandler(sid, bearer(token), RememberRequest(key = "k" + toString(i), value = "v")) {
      case Ok(_) -> ()
      case Err(e) -> assertTrue(false, "remember " + toString(i) + " failed: " + toString(e.status))
    }
    i = i + 1
  }

  // A 257th distinct key is rejected.
  match rememberHandler(sid, bearer(token), RememberRequest(key = "one-too-many", value = "v")) {
    case Ok(_) -> assertTrue(false, "a new key past the cap must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "over-cap new key -> 400")
  }

  // Overwriting an EXISTING key is still allowed even at the cap.
  match rememberHandler(sid, bearer(token), RememberRequest(key = "k0", value = "updated")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "overwriting an existing key at the cap must still work: " + toString(e.status))
  }
}

