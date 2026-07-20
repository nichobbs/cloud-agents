@test_module
package CloudAgents.CallbacksV2Tests

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

// ── Live-DB plumbing (same pattern as tests/callbacks_tests.l) ────────────────
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
  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS", "")
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

func mustPutCredential(userId: in String, name: in String, value: in String): Unit {
  match CloudAgents.Repository.putCredential(userId, name, value) {
    case Ok(_) -> ()
    case Err(e) -> panic("putCredential failed: " + CloudAgents.Repository.credentialErrorMessage(e))
  }
}

// ── request_secret ──────────────────────────────────────────────────────────
test "request_secret round trip: create -> poll pending -> approve -> poll delivers value ONCE" {
  val dbPath = useFreshTestDb("secret-roundtrip")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-secret-1"
  mkSession(sid)
  val token = mintToken(sid, "default")
  mustPutCredential("default", "GITHUB_TOKEN", "ghp_super_secret")

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
  val dbPath = useFreshTestDb("secret-deny")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-secret-2"
  mkSession(sid)
  val token = mintToken(sid, "default")
  mustPutCredential("default", "AWS_KEY", "aws-secret-value")

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
  val dbPath = useFreshTestDb("secret-timeout")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-secret-3"
  mkSession(sid)
  val token = mintToken(sid, "default")
  mustPutCredential("default", "TOKEN", "value")

  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS", "0")
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
  val dbPath = useFreshTestDb("secret-missing-cred")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-secret-4"
  mkSession(sid)
  val token = mintToken(sid, "default")

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
  val dbPath = useFreshTestDb("secret-race")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-secret-5"
  mkSession(sid)
  val token = mintToken(sid, "default")
  mustPutCredential("default", "ROTATING", "value")

  val created = match createSecretRequestHandler(sid, bearer(token), CreateSecretRequestRequest(name = "ROTATING", reason = "x")) {
    case Ok(r) -> r
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  // Credential deleted between create and answer (a real race in production).
  match CloudAgents.Repository.deleteCredential("default", "ROTATING") {
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

// ── add_followup_task ───────────────────────────────────────────────────────
test "add_followup_task creates an unanchored todo and validates the description" {
  val dbPath = useFreshTestDb("followup")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-followup-1"
  mkSession(sid)
  val token = mintToken(sid, "default")

  val created = match createFollowupTaskHandler(sid, bearer(token), CreateFollowupTaskRequest(description = "double-check the migration")) {
    case Ok(r) -> r
    case Err(e) -> panic("create failed: " + toString(e.status))
  }
  assertTrue(created.id.length > 0, "a todo id is returned")

  match CloudAgents.Repository.listTodos(sid) {
    case Ok(todos) -> {
      assertEqualInt(todos.length.toInt(), 1, "the todo was stored")
      assertEqual(todos[0].note, "double-check the migration", "description round-trips as the todo note")
      assertEqual(todos[0].messageId, "", "an add_followup_task todo is unanchored")
    }
    case Err(e) -> assertTrue(false, "listTodos failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  match createFollowupTaskHandler(sid, bearer(token), CreateFollowupTaskRequest(description = "")) {
    case Ok(_) -> assertTrue(false, "an empty description must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty description -> 400")
  }
}

// ── report_artifact ─────────────────────────────────────────────────────────
test "report_artifact upload -> list -> download round trip, and traversal is neutralized" {
  val dbPath = useFreshTestDb("artifact-roundtrip")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-artifact-1"
  mkSession(sid)
  val token = mintToken(sid, "default")

  val uploaded = match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "report.txt", mimeType = "text/plain", description = "a report", contentBase64 = base64Of("hello artifact"))) {
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
  val traversal = match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "../../etc/passwd", mimeType = "text/plain", description = "", contentBase64 = base64Of("x"))) {
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
  val dbPath = useFreshTestDb("artifact-oversize")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-artifact-2"
  mkSession(sid)
  val token = mintToken(sid, "default")

  // A contentBase64 string longer than the pre-decode cap is rejected
  // without ever reaching the decoder.
  val huge = atLeast(11184813)
  match uploadArtifactHandler(sid, bearer(token), UploadArtifactRequest(fileName = "big.bin", mimeType = "application/octet-stream", description = "", contentBase64 = huge)) {
    case Ok(_) -> assertTrue(false, "an oversize artifact must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "oversize -> 400")
  }
  match listArtifactsHandler(sid) {
    case Ok(l) -> assertEqualInt(l.artifacts.length.toInt(), 0, "nothing was stored for the rejected upload")
    case Err(e) -> assertTrue(false, "list failed: " + toString(e.status))
  }
}

// ── Validation ───────────────────────────────────────────────────────────────
test "v2 callback endpoints reject an empty session id before touching the database" {
  val dbPath = useFreshTestDb("v2-empty-id")
  defer {
    cleanupTestDb(dbPath)
  }
  match createSecretRequestHandler("", "", CreateSecretRequestRequest(name = "X", reason = "")) {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id returns 400")
  }
  match createFollowupTaskHandler("", "", CreateFollowupTaskRequest(description = "x")) {
    case Ok(_) -> assertTrue(false, "an empty session id must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty id returns 400")
  }
  match uploadArtifactHandler("", "", UploadArtifactRequest(fileName = "x", mimeType = "text/plain", description = "", contentBase64 = "")) {
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
  val dbPath = useFreshTestDb("memory-roundtrip")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-memory-1"
  mkSession(sid)
  val token = mintToken(sid, "default")

  match rememberHandler(sid, bearer(token), RememberRequest(key = "build", value = "make lyric")) {
    case Ok(r) -> assertEqual(r.key, "build", "remember echoes the stored key")
    case Err(e) -> assertTrue(false, "remember failed: " + toString(e.status))
  }
  match rememberHandler(sid, bearer(token), RememberRequest(key = "tests", value = "lyric test")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "second remember failed: " + toString(e.status))
  }

  match recallHandler(sid, bearer(token)) {
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
  match recallHandler(sid, bearer(token)) {
    case Ok(l) -> {
      assertEqualInt(l.entries.length.toInt(), 2, "overwrite does not add a row")
      assertEqual(l.entries[0].value, "make lyric && ./scripts/verify.sh", "the value was overwritten")
    }
    case Err(e) -> assertTrue(false, "recall after overwrite failed: " + toString(e.status))
  }
}

test "memory carries across sessions on the same repo, isolated from other repos" {
  val dbPath = useFreshTestDb("memory-cross-session")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")

  val sidA = "sess-memory-A"
  mkSession(sidA)
  val tokenA = mintToken(sidA, "default")
  match rememberHandler(sidA, bearer(tokenA), RememberRequest(key = "quirk", value = "sqlite native lib needed")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "remember A failed: " + toString(e.status))
  }

  // A brand-new session on the SAME repo recalls the earlier note — the point.
  val sidB = "sess-memory-B"
  mkSession(sidB)
  val tokenB = mintToken(sidB, "default")
  match recallHandler(sidB, bearer(tokenB)) {
    case Ok(l) -> {
      assertEqualInt(l.entries.length.toInt(), 1, "a new session on the same repo inherits the memory")
      assertEqual(l.entries[0].value, "sqlite native lib needed", "the earlier session's note is readable")
    }
    case Err(e) -> assertTrue(false, "recall B failed: " + toString(e.status))
  }

  // A session on a DIFFERENT repo sees none of it.
  val sidC = "sess-memory-C"
  mkSessionRepo(sidC, "https://github.com/nic/other")
  val tokenC = mintToken(sidC, "default")
  match recallHandler(sidC, bearer(tokenC)) {
    case Ok(l) -> assertEqualInt(l.entries.length.toInt(), 0, "a different repo shares no memory")
    case Err(e) -> assertTrue(false, "recall C failed: " + toString(e.status))
  }
}

test "remember validates key/value and rejects a session with no repo to scope to" {
  val dbPath = useFreshTestDb("memory-validation")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-memory-val"
  mkSession(sid)
  val token = mintToken(sid, "default")

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

  val sidNoRepo = "sess-memory-norepo"
  mkSessionRepo(sidNoRepo, "")
  val tokenNoRepo = mintToken(sidNoRepo, "default")
  match rememberHandler(sidNoRepo, bearer(tokenNoRepo), RememberRequest(key = "k", value = "v")) {
    case Ok(_) -> assertTrue(false, "a session with no repo must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "no repo -> 400")
  }
}

test "recall requires a valid callback token; the owner can list via the user route" {
  val dbPath = useFreshTestDb("memory-auth")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-memory-auth"
  mkSession(sid)
  val token = mintToken(sid, "default")

  match recallHandler(sid, bearer("wrong-token")) {
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
  val dbPath = useFreshTestDb("memory-forget")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-memory-forget"
  mkSession(sid)
  val token = mintToken(sid, "default")

  match rememberHandler(sid, bearer(token), RememberRequest(key = "build", value = "make lyric")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "remember failed: " + toString(e.status))
  }
  // Forgetting a present key deletes it.
  match forgetHandler(sid, bearer(token), ForgetRequest(key = "build")) {
    case Ok(r) -> assertEqual(r.status, "deleted", "an existing key reports deleted")
    case Err(e) -> assertTrue(false, "forget failed: " + toString(e.status))
  }
  match recallHandler(sid, bearer(token)) {
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
  val dbPath = useFreshTestDb("memory-cap")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-memory-cap"
  mkSession(sid)
  val token = mintToken(sid, "default")

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
