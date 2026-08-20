@test_module
package CloudAgents.AttachmentTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Handlers
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env
import extern System.Text.Encoding as Utf8Encoding

// ── Live-DB plumbing (same pattern as tests/callbacks_v2_tests.l) ─────────────
func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  val attachmentsDir = "/tmp/cloud-agents-attachments-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid())
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ATTACHMENTS_DIR", attachmentsDir)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return path
}

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func cleanupTestDb(path: in String): Unit {
  try {
    fileDelete(path)
  } catch Bug as b {
    // locked or already gone — fine for a temp file
  }
  Env.SetEnvironmentVariable("CLOUD_AGENTS_ATTACHMENTS_DIR", "")
  CloudAgents.Auth.setCurrentUserId("default")
}

func mkSession(id: in String): Unit {
  val s = makeAgentSession(
    sessionId = id,
    repoUrl = "https://github.com/nic/repo",
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

/// A string of EXACTLY `n` characters, built in O(n) via doubling (same
/// reasoning as atLeast below) but topping the final doubling step off with
/// a prefix slice instead of a full double whenever that would overshoot —
/// needed where atLeast's up-to-2x overshoot isn't precise enough (e.g.
/// landing a decoded size just on one side of a byte-count boundary).
func stringOfLength(n: in Int): String {
  var s = "A"
  while s.length < n {
    val remaining = n - s.length
    if remaining >= s.length {
      s = s + s
    } else {
      s = s + s.substring(0, remaining)
    }
  }
  return s
}

/// A string at least `minLen` characters long, built by doubling — see
/// callbacks_v2_tests.l's identical helper for why (an O(n^2) one-char-at-a-
/// time build is genuinely too slow at these sizes).
func atLeast(minLen: in Int): String {
  var s = "A"
  while s.length < minLen {
    s = s + s
  }
  return s
}

// ── basenameOfAttachment ───────────────────────────────────────────────────
test "basenameOfAttachment strips directory components and rejects degenerate names" {
  match basenameOfAttachment("photo.png") {
    case Some(b) -> assertEqual(b, "photo.png", "a plain name passes through")
    case None -> assertTrue(false, "a plain name must resolve")
  }
  match basenameOfAttachment("../../etc/passwd") {
    case Some(b) -> assertEqual(b, "passwd", "traversal is reduced to the basename")
    case None -> assertTrue(false, "a traversal attempt must still resolve to a name")
  }
  match basenameOfAttachment("a/b\\c.txt") {
    case Some(b) -> assertEqual(b, "c.txt", "both / and \\ are treated as separators")
    case None -> assertTrue(false, "must resolve")
  }
  // .isNone()/.isSome() don't resolve at runtime (docs/lyric/gotchas.md) —
  // match instead, same as everywhere else in this codebase.
  match basenameOfAttachment("") {
    case None -> ()
    case Some(_) -> assertTrue(false, "empty is rejected")
  }
  match basenameOfAttachment(".") {
    case None -> ()
    case Some(_) -> assertTrue(false, "'.' is rejected")
  }
  match basenameOfAttachment("..") {
    case None -> ()
    case Some(_) -> assertTrue(false, "'..' is rejected")
  }
  match basenameOfAttachment("a/") {
    case None -> ()
    case Some(_) -> assertTrue(false, "a trailing separator with nothing after it is rejected")
  }
}

// ── attachmentKindOf ────────────────────────────────────────────────────────
test "attachmentKindOf classifies image/* as image and everything else as document" {
  assertEqual(attachmentKindOf("image/png"), "image", "image/png is an image")
  assertEqual(attachmentKindOf("image/jpeg"), "image", "image/jpeg is an image")
  assertEqual(attachmentKindOf("application/pdf"), "document", "a PDF is a document")
  assertEqual(attachmentKindOf("text/plain"), "document", "plain text is a document")
  assertEqual(attachmentKindOf(""), "document", "an empty mime type defaults to document")
}

// ── contentDispositionQuoted ────────────────────────────────────────────────
test "contentDispositionQuoted escapes quotes/backslashes and strips control chars" {
  assertEqual(
    CloudAgents.Handlers.contentDispositionQuoted("re\"port.txt"),
    "re\\\"port.txt",
    "a double quote is backslash-escaped"
  )
  assertEqual(CloudAgents.Handlers.contentDispositionQuoted("a\\b"), "a\\\\b", "a backslash is doubled")
  assertEqual(
    CloudAgents.Handlers.contentDispositionQuoted("a\r\nb"),
    "ab",
    "control characters are stripped so the header cannot be split"
  )
}

// ── promptWithAttachments ───────────────────────────────────────────────────
test "promptWithAttachments appends a Read-tool manifest naming each container path" {
  val noAttachments: slice[CloudAgents.Repository.Attachment] = []
  assertEqual(
    promptWithAttachments("hello", noAttachments),
    "hello",
    "text is returned unchanged when there are no attachments"
  )

  // Unqualified construction — a package-qualified record constructor
  // compiles but crashes at runtime (docs/lyric/gotchas.md); CloudAgents.
  // Repository is already imported above, so `Attachment(...)` resolves.
  val a = Attachment(
    id = "att-1",
    sessionId = "sess-1",
    messageId = "",
    fileName = "photo.png",
    storedName = "att-1_photo.png",
    mimeType = "image/png",
    kind = "image",
    sizeBytes = "10",
    createdAt = "0"
  )
  val withOne: slice[CloudAgents.Repository.Attachment] = [a]
  val prompt = promptWithAttachments("look at this", withOne)
  assertTrue(prompt.startsWith("look at this"), "the original text leads the prompt")
  assertTrue(prompt.contains("/workspace/.attachments/att-1_photo.png"), "the container-visible path is named")
  assertTrue(prompt.contains("image/png"), "the mime type is included")

  val emptyText = promptWithAttachments("", withOne)
  assertTrue(
    emptyText.startsWith("Please review the attached file(s)."),
    "an empty text send with attachments gets a default lead-in"
  )
}

// ── isDangerousAttachmentMimeType ───────────────────────────────────────────
test "isDangerousAttachmentMimeType rejects SVG/HTML case-insensitively, allows ordinary types" {
  assertTrue(isDangerousAttachmentMimeType("image/svg+xml"), "SVG is dangerous")
  assertTrue(isDangerousAttachmentMimeType("IMAGE/SVG+XML"), "case must not bypass the check")
  assertTrue(isDangerousAttachmentMimeType("Text/Html"), "mixed-case HTML is still caught")
  assertTrue(isDangerousAttachmentMimeType("application/xhtml+xml"), "XHTML is dangerous")
  assertFalse(isDangerousAttachmentMimeType("image/png"), "an ordinary raster image is fine")
  assertFalse(isDangerousAttachmentMimeType("application/pdf"), "a PDF is fine")
  assertFalse(isDangerousAttachmentMimeType("text/plain"), "plain text is fine")
}

// ── storeAttachments ────────────────────────────────────────────────────────
test "storeAttachments rejects a dangerous mimeType before storing anything (#989)" {
  val dbPath = useFreshTestDb("attach-dangerous-mime")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-attach-6"
  mkSession(sid)

  val inputs: slice[AttachmentInput] = [
    AttachmentInput(fileName = "evil.svg", mimeType = "image/svg+xml", contentBase64 = base64Of("<svg onload=alert(1)>"))
  ]
  match storeAttachments(sid, inputs) {
    case Ok(_) -> assertTrue(false, "an SVG upload must be rejected")
    case Err(e) -> assertEqualInt(e.code, 400, "dangerous mimeType -> 400")
  }
  match CloudAgents.Repository.listAttachments(sid) {
    case Ok(l) -> assertEqualInt(l.length.toInt(), 0, "nothing was stored for the rejected upload")
    case Err(e) -> assertTrue(false, "list failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "storeAttachments validates, writes to disk, and records metadata" {
  val dbPath = useFreshTestDb("attach-roundtrip")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-attach-1"
  mkSession(sid)

  val noInputs: slice[AttachmentInput] = []
  match storeAttachments(sid, noInputs) {
    case Ok(s) -> {
      assertEqualInt(s.attachments.length.toInt(), 0, "no inputs stores nothing")
      assertEqual(s.hostDir, "", "no inputs means no host dir to bind-mount")
    }
    case Err(e) -> assertTrue(false, "empty input must succeed as a no-op: " + e.message)
  }

  val inputs: slice[AttachmentInput] = [
    AttachmentInput(fileName = "notes.txt", mimeType = "text/plain", contentBase64 = base64Of("hello attachment")),
    AttachmentInput(fileName = "../../etc/passwd", mimeType = "text/plain", contentBase64 = base64Of("x"))
  ]
  val stored = match storeAttachments(sid, inputs) {
    case Ok(s) -> s
    case Err(e) -> panic("store failed: " + e.message)
  }
  assertEqualInt(stored.attachments.length.toInt(), 2, "both files are stored")
  assertTrue(stored.hostDir.length > 0, "a host dir is returned to bind-mount")
  assertEqual(stored.attachments[0].fileName, "notes.txt", "fileName round-trips")
  assertEqual(stored.attachments[0].mimeType, "text/plain", "mimeType round-trips")
  assertEqual(stored.attachments[0].kind, "document", "text/plain classifies as a document")
  assertEqual(stored.attachments[0].sizeBytes, "17", "sizeBytes is the decoded byte count")
  assertEqual(stored.attachments[0].messageId, "", "messageId starts empty — linked later by streamSendMessage")
  // Path traversal in fileName is neutralized (basename only), matching the
  // artifact upload path's identical guarantee.
  assertEqual(stored.attachments[1].fileName, "passwd", "fileName is reduced to its basename")
  assertTrue(not stored.attachments[1].fileName.contains("/"), "no path separator survives sanitization")

  // The bytes are genuinely on disk at attachmentsBaseDir()/<sessionId>/<storedName>.
  match CloudAgents.Repository.listAttachments(sid) {
    case Ok(l) -> assertEqualInt(l.length.toInt(), 2, "both rows are persisted")
    case Err(e) -> assertTrue(false, "list failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "storeAttachments rejects an oversize file before storing anything" {
  val dbPath = useFreshTestDb("attach-oversize")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-attach-2"
  mkSession(sid)

  // A contentBase64 string longer than the pre-decode cap is rejected
  // without ever reaching the decoder or touching disk/DB.
  val huge = atLeast(27962029)
  val inputs: slice[AttachmentInput] = [
    AttachmentInput(fileName = "big.bin", mimeType = "application/octet-stream", contentBase64 = huge)
  ]
  match storeAttachments(sid, inputs) {
    case Ok(_) -> assertTrue(false, "an oversize attachment must be rejected")
    case Err(e) -> assertEqualInt(e.code, 400, "oversize -> 400")
  }
  match CloudAgents.Repository.listAttachments(sid) {
    case Ok(l) -> assertEqualInt(l.length.toInt(), 0, "nothing was stored for the rejected upload")
    case Err(e) -> assertTrue(false, "list failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "storeAttachments rejects more than the per-message file cap" {
  val dbPath = useFreshTestDb("attach-toomany")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-attach-3"
  mkSession(sid)

  var inputs: slice[AttachmentInput] = []
  var i = 0
  while i < 11 {
    inputs = inputs.append(AttachmentInput(fileName = "f" + toString(i) + ".txt", mimeType = "text/plain", contentBase64 = base64Of("x")))
    i = i + 1
  }
  match storeAttachments(sid, inputs) {
    case Ok(_) -> assertTrue(false, "more than 10 files must be rejected")
    case Err(e) -> assertEqualInt(e.code, 400, "too many files -> 400")
  }
}

test "storeAttachments rejects the whole request atomically when only a LATER file pushes the cumulative total over budget (#992)" {
  val dbPath = useFreshTestDb("attach-cumulative")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-attach-5"
  mkSession(sid)

  // Two files right AT the 20 MiB per-file cap (each individually allowed),
  // then a third well under the per-file cap but large enough that the
  // cumulative total (41,943,040 + 10,485,761 = 52,428,801) crosses the
  // 50 MiB per-message cap (52,428,800) only once THIS file is counted. An
  // earlier version of storeAttachments checked the cumulative cap
  // interleaved with the actual writes, so the first two files would already
  // be on disk and in session_attachments (with messageId stuck at '' since
  // the request as a whole still fails) by the time this one was rejected.
  val fileBytes = stringOfLength(20971520)
  val overflowBytes = stringOfLength(10485761)
  val inputs: slice[AttachmentInput] = [
    AttachmentInput(fileName = "a.bin", mimeType = "application/octet-stream", contentBase64 = base64Of(fileBytes)),
    AttachmentInput(fileName = "b.bin", mimeType = "application/octet-stream", contentBase64 = base64Of(fileBytes)),
    AttachmentInput(fileName = "c.bin", mimeType = "application/octet-stream", contentBase64 = base64Of(overflowBytes))
  ]
  match storeAttachments(sid, inputs) {
    case Ok(_) -> assertTrue(false, "the cumulative 50 MiB budget must be enforced")
    case Err(e) -> assertEqualInt(e.code, 400, "over-budget -> 400")
  }
  // Nothing from ANY of the three files — including the first two, each
  // individually within the per-file cap — was written or recorded.
  match CloudAgents.Repository.listAttachments(sid) {
    case Ok(l) -> assertEqualInt(l.length.toInt(), 0, "no rows were persisted for the rejected request")
    case Err(e) -> assertTrue(false, "list failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── listAttachmentsHandler / downloadAttachmentHandler ─────────────────────
test "listAttachmentsHandler and downloadAttachmentHandler serve what storeAttachments wrote" {
  val dbPath = useFreshTestDb("attach-handlers")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val sid = "sess-attach-4"
  mkSession(sid)

  val inputs: slice[AttachmentInput] = [
    AttachmentInput(fileName = "report.pdf", mimeType = "application/pdf", contentBase64 = base64Of("pdf bytes"))
  ]
  val stored = match storeAttachments(sid, inputs) {
    case Ok(s) -> s
    case Err(e) -> panic("store failed: " + e.message)
  }
  val attachmentId = stored.attachments[0].id

  // Not yet linked to a message — messageId is still "".
  match listAttachmentsHandler(sid) {
    case Ok(l) -> {
      assertEqualInt(l.attachments.length.toInt(), 1, "one attachment listed")
      assertEqual(l.attachments[0].messageId, "", "unlinked until a message references it")
    }
    case Err(e) -> assertTrue(false, "list failed: status " + toString(e.status))
  }

  match CloudAgents.Repository.linkAttachmentToMessage(attachmentId, "msg-1") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "link failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match listAttachmentsHandler(sid) {
    case Ok(l) -> assertEqual(l.attachments[0].messageId, "msg-1", "messageId round-trips after linking")
    case Err(e) -> assertTrue(false, "list failed: status " + toString(e.status))
  }

  match downloadAttachmentHandler(sid, attachmentId) {
    case Ok(resp) -> assertEqualInt(resp.status, 200, "download succeeds")
    case Err(e) -> assertTrue(false, "download failed: status " + toString(e.status))
  }

  // A second, unrelated session can never download this one's attachment.
  mkSession("sess-attach-4-other")
  match downloadAttachmentHandler("sess-attach-4-other", attachmentId) {
    case Ok(_) -> assertTrue(false, "a foreign session must not be able to fetch another session's attachment")
    case Err(e) -> assertEqualInt(e.status, 404, "cross-session fetch is a 404, not a 200 or a 403 that would confirm existence")
  }

  match downloadAttachmentHandler(sid, "no-such-id") {
    case Ok(_) -> assertTrue(false, "an unknown attachment id must 404")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown id -> 404")
  }
}
