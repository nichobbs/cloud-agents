//! Persistence for the conversation transcript, comments and todos.
//!
//! Builds SQL with the pure CloudAgents.Db builders and runs it through the
//! CloudAgents.Sqlite driver, mapping result rows to domain records. This is
//! the seam the HTTP handlers depend on — they never see SQL or `extern`
//! handles, only records and `Result`.
@runtime_checked
package CloudAgents.Repository

import Std.Core
import Std.Uuid
import CloudAgents.Crypto
import CloudAgents.Db
import CloudAgents.Sqlite

@generate(Json)
pub record Message {
  pub id: String
  pub sessionId: String
  pub role: String
  pub content: String
  pub seq: String
  pub createdAt: String
}

@generate(Json)
pub record Comment {
  pub id: String
  pub messageId: String
  pub sessionId: String
  pub body: String
  pub createdAt: String
}

@generate(Json)
pub record Todo {
  pub id: String
  pub sessionId: String
  pub messageId: String
  pub note: String
  pub done: String
  pub createdAt: String
}

@generate(Json)
pub record Prompt {
  pub id: String
  pub userId: String
  pub name: String
  pub body: String
  pub useCount: String
  pub createdAt: String
  pub updatedAt: String
  pub tags: slice[String]
}

@generate(Json)
pub record PromptList {
  pub prompts: slice[Prompt]
}

@generate(Json)
pub record MessageList {
  pub messages: slice[Message]
}

@generate(Json)
pub record CommentList {
  pub comments: slice[Comment]
}

@generate(Json)
pub record TodoList {
  pub todos: slice[Todo]
}

// ─── Small helpers ─────────────────────────────────────────────────────────────
func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

// Std.Time.Instant.now() emits a broken extern binding in the current
// toolchain — it fails at runtime with "Method not found: 'Void
// System.DateTime.now()'" (lowercase `now`, which the BCL has never had).
// Surfaced by the live-DB tests, the first code path to ever execute this;
// bind the BCL clock directly instead. See docs/lyric/gotchas.md.
extern type DateTimeOffset = "System.DateTimeOffset"

@externTarget("System.DateTimeOffset.get_UtcNow")
func dtoUtcNow(): DateTimeOffset = ()

@externInstance
@externTarget("System.DateTimeOffset.ToUnixTimeMilliseconds")
func dtoToUnixMillis(t: in DateTimeOffset): Long = ()

/// Wall-clock epoch milliseconds as the TEXT the schema stores. Exported so
/// other storage packages (SessionStore) share one working clock binding.
pub func nowMillis(): String {
  return toString(dtoToUnixMillis(dtoUtcNow()))
}

func digitValue(c: in String): Int {
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

/// Parse a run of decimal digits into an Int, ignoring non-digit characters.
func parseNatString(s: in String): Int {
  var n = 0
  var i = 0
  while i < s.length {
    val d = digitValue(s.substring(i, 1))
    if d >= 0 {
      n = n * 10 + d
    }
    i = i + 1
  }
  return n
}

func colAt(cols: in CloudAgents.Sqlite.StringArray, i: in Int): String {
  val len = CloudAgents.Sqlite.getStringArrayLength(cols)
  if i < len {
    return CloudAgents.Sqlite.getStringArrayValue(cols, i)
  }
  return ""
}

// ─── Schema ────────────────────────────────────────────────────────────────────
/// Verify the database is reachable. Used by the health endpoint.
pub func ping(): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute("SELECT 1")?
  return Ok(value = ())
}

/// One ordered schema migration: a stable version id and the statements that
/// bring the schema up to that version. Statements run in order, exactly once
/// per database (tracked in the schema_migrations ledger).
pub record Migration {
  pub version: String
  pub statements: slice[String]
}

/// Every migration, oldest first. Append new migrations to the END with a new
/// version id — never edit or reorder an applied one, or databases will diverge.
///
/// 0001_init is the full baseline: all tables + indexes as they stood before
/// the ledger existed. Its statements are all `IF NOT EXISTS`, so recording it
/// against a pre-ledger database that already has these tables is a harmless
/// no-op that simply back-fills the ledger.
pub func allMigrations(): slice[Migration] {
  return [
    Migration(
      version = "0001_init",
      statements = [
        CloudAgents.Db.messagesSchemaSql(),
        CloudAgents.Db.commentsSchemaSql(),
        CloudAgents.Db.todosSchemaSql(),
        CloudAgents.Db.promptsSchemaSql(),
        CloudAgents.Db.sessionsSchemaSql(),
        CloudAgents.Db.credentialsSchemaSql(),
        CloudAgents.Db.promptsUserIndexSql(),
        CloudAgents.Db.sessionsUserIndexSql(),
        CloudAgents.Db.credentialsUserIndexSql()
      ]
    ),
    Migration(
      version = "0002_profiles",
      statements = [
        CloudAgents.Db.profilesSchemaSql(),
        CloudAgents.Db.profileCredentialsSchemaSql(),
        CloudAgents.Db.profilesUserIndexSql(),
        CloudAgents.Db.profileCredentialsProfileIndexSql()
      ]
    ),
    Migration(
      version = "0003_session_profile",
      statements = [
        CloudAgents.Db.alterSessionsAddProfileSql()
      ]
    ),
    Migration(
      version = "0004_runs",
      statements = [
        CloudAgents.Db.runsSchemaSql(),
        CloudAgents.Db.runsSessionIndexSql(),
        CloudAgents.Db.runsUserIndexSql()
      ]
    ),
    Migration(
      version = "0005_prompt_tags",
      statements = [
        CloudAgents.Db.promptTagsSchemaSql(),
        CloudAgents.Db.promptTagsPromptIndexSql(),
        CloudAgents.Db.promptTagsTagIndexSql()
      ]
    )
  ]
}

/// Whether a migration version has already been recorded as applied.
func migrationApplied(version: in String): Result[Bool, CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.countMigrationSql(version))?
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  if len == 0 {
    return Ok(value = false)
  }
  val r0 = CloudAgents.Sqlite.getRowArrayValue(rows, 0)
  return Ok(value = parseNatString(colAt(r0.cols, 0)) > 0)
}

/// Apply every not-yet-applied migration in order, recording each in the
/// ledger. Idempotent: a database already at the latest version is a no-op.
pub func runMigrations(): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(CloudAgents.Db.migrationsSchemaSql())?
  for m in allMigrations() {
    val applied = migrationApplied(m.version)?
    if not applied {
      // Run the migration's statements AND its ledger record in one
      // transaction: either the whole migration applies and is recorded, or
      // nothing is, so a mid-migration failure (e.g. a bad ALTER) leaves the
      // database at the prior version and the next startup retries cleanly
      // rather than getting stuck half-applied (review #229).
      var stmts = m.statements
      stmts = stmts.append(CloudAgents.Db.recordMigrationSql(m.version, nowMillis()))
      CloudAgents.Sqlite.executeTransaction(stmts)?
    }
  }
  return Ok(value = ())
}

/// Bring the database schema up to date. Safe to call at every startup.
/// Delegates to the versioned migration runner (`runMigrations`); the name is
/// kept for its many call sites (main, tests).
pub func initSchema(): Result[Unit, CloudAgents.Sqlite.DbError] {
  return runMigrations()
}

// ─── Messages ──────────────────────────────────────────────────────────────────
func rowToMessage(r: in CloudAgents.Sqlite.Row): Message {
  return Message(
    id = colAt(r.cols, 0),
    sessionId = colAt(r.cols, 1),
    role = colAt(r.cols, 2),
    content = colAt(r.cols, 3),
    seq = colAt(r.cols, 4),
    createdAt = colAt(r.cols, 5)
  )
}

/// Next sequence number for a session (its current message count).
func nextSeq(sessionId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.countMessagesSql(sessionId))?
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  if len == 0 {
    return Ok(value = 0)
  }
  val r0 = CloudAgents.Sqlite.getRowArrayValue(rows, 0)
  return Ok(value = parseNatString(colAt(r0.cols, 0)))
}

/// Append a message to a session's transcript and return the stored record
/// (with its freshly minted id and sequence number).
pub func addMessage(
  sessionId: in String, role: in String, content: in String
): Result[Message, CloudAgents.Sqlite.DbError] {
  val seqN = nextSeq(sessionId)?
  val id = newId()
  val ts = nowMillis()
  val seqStr = CloudAgents.Db.padSeq(seqN)
  CloudAgents.Sqlite.execute(CloudAgents.Db.insertMessageSql(id, sessionId, role, content, seqStr, ts))?
  return Ok(
    value = Message(id = id, sessionId = sessionId, role = role, content = content, seq = seqStr, createdAt = ts)
  )
}

/// All messages in a session, oldest first.
pub func listMessages(sessionId: in String): Result[slice[Message], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectMessagesSql(sessionId))?
  var acc: slice[Message] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(rowToMessage(CloudAgents.Sqlite.getRowArrayValue(rows, i)))
    i = i + 1
  }
  return Ok(value = acc)
}

/// Look up the session that owns a message. Used to bind comments to the
/// correct session without trusting client-supplied sessionId values.
pub func getMessageSessionId(messageId: in String): Result[Option[String], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectMessageSessionIdSql(messageId))?
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  if len == 0 {
    return Ok(value = None)
  }
  val r0 = CloudAgents.Sqlite.getRowArrayValue(rows, 0)
  return Ok(value = Some(value = colAt(r0.cols, 0)))
}

// ─── Comments ──────────────────────────────────────────────────────────────────
func rowToComment(r: in CloudAgents.Sqlite.Row): Comment {
  return Comment(
    id = colAt(r.cols, 0),
    messageId = colAt(r.cols, 1),
    sessionId = colAt(r.cols, 2),
    body = colAt(r.cols, 3),
    createdAt = colAt(r.cols, 4)
  )
}

/// Attach a comment to a message.
pub func addComment(
  messageId: in String, sessionId: in String, body: in String
): Result[Comment, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = nowMillis()
  CloudAgents.Sqlite.execute(CloudAgents.Db.insertCommentSql(id, messageId, sessionId, body, ts))?
  return Ok(value = Comment(id = id, messageId = messageId, sessionId = sessionId, body = body, createdAt = ts))
}

/// All comments on a message, oldest first.
pub func listComments(messageId: in String): Result[slice[Comment], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectCommentsSql(messageId))?
  var acc: slice[Comment] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(rowToComment(CloudAgents.Sqlite.getRowArrayValue(rows, i)))
    i = i + 1
  }
  return Ok(value = acc)
}

// ─── Todos ─────────────────────────────────────────────────────────────────────
func rowToTodo(r: in CloudAgents.Sqlite.Row): Todo {
  return Todo(
    id = colAt(r.cols, 0),
    sessionId = colAt(r.cols, 1),
    messageId = colAt(r.cols, 2),
    note = colAt(r.cols, 3),
    done = colAt(r.cols, 4),
    createdAt = colAt(r.cols, 5)
  )
}

/// Create a todo / bookmark, optionally anchored to a message (pass "" for a
/// free-standing todo).
pub func addTodo(sessionId: in String, messageId: in String, note: in String): Result[Todo, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = nowMillis()
  CloudAgents.Sqlite.execute(CloudAgents.Db.insertTodoSql(id, sessionId, messageId, note, ts))?
  return Ok(
    value = Todo(id = id, sessionId = sessionId, messageId = messageId, note = note, done = "0", createdAt = ts)
  )
}

/// All todos for a session, newest first.
pub func listTodos(sessionId: in String): Result[slice[Todo], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectTodosSql(sessionId))?
  var acc: slice[Todo] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(rowToTodo(CloudAgents.Sqlite.getRowArrayValue(rows, i)))
    i = i + 1
  }
  return Ok(value = acc)
}

/// Flip a todo's done flag.
pub func toggleTodo(id: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(CloudAgents.Db.toggleTodoSql(id))?
  return Ok(value = ())
}

/// Delete a todo.
pub func deleteTodo(id: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(CloudAgents.Db.deleteTodoSql(id))?
  return Ok(value = ())
}

// ─── Prompt library ────────────────────────────────────────────────────────────
func rowToPrompt(r: in CloudAgents.Sqlite.Row, tags: in slice[String]): Prompt {
  return Prompt(
    id = colAt(r.cols, 0),
    userId = colAt(r.cols, 1),
    name = colAt(r.cols, 2),
    body = colAt(r.cols, 3),
    useCount = colAt(r.cols, 4),
    createdAt = colAt(r.cols, 5),
    updatedAt = colAt(r.cols, 6),
    tags = tags
  )
}

/// A prompt's tags, alphabetical (empty when none).
func promptTagNames(promptId: in String, userId: in String): Result[slice[String], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectPromptTagsSql(promptId, userId))?
  var acc: slice[String] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(colAt(CloudAgents.Sqlite.getRowArrayValue(rows, i).cols, 0))
    i = i + 1
  }
  return Ok(value = acc)
}

/// Build a Prompt from a row, fetching its tags.
func rowToPromptWithTags(r: in CloudAgents.Sqlite.Row, userId: in String): Result[Prompt, CloudAgents.Sqlite.DbError] {
  val tags = promptTagNames(colAt(r.cols, 0), userId)?
  return Ok(value = rowToPrompt(r, tags))
}

/// Replace a prompt's tag set atomically (clear, then insert each). Returned by
/// callers through executeTransaction so the set is consistent on partial fail.
pub func setPromptTags(promptId: in String, userId: in String, tags: in slice[String]): Result[Unit, CloudAgents.Sqlite.DbError] {
  var stmts: slice[String] = []
  stmts = stmts.append(CloudAgents.Db.deletePromptTagsSql(promptId, userId))
  for t in tags {
    stmts = stmts.append(CloudAgents.Db.insertPromptTagSql(newId(), promptId, userId, t))
  }
  CloudAgents.Sqlite.executeTransaction(stmts)?
  return Ok(value = ())
}

/// Save a new prompt to a user's library and return the stored record (no tags
/// yet). Kept for callers/tests that don't set tags; the handler uses the
/// transactional addPromptWithTags.
pub func addPrompt(userId: in String, name: in String, body: in String): Result[Prompt, CloudAgents.Sqlite.DbError] {
  val noTags: slice[String] = []
  return addPromptWithTags(userId, name, body, noTags)
}

/// Save a new prompt AND its tag set in a single transaction (#244), returning
/// the stored record with tags attached — so the prompt row and its tags are
/// never left inconsistent by a partial failure.
pub func addPromptWithTags(
  userId: in String, name: in String, body: in String, tags: in slice[String]
): Result[Prompt, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = nowMillis()
  var stmts: slice[String] = []
  stmts = stmts.append(CloudAgents.Db.insertPromptSql(id, userId, name, body, ts))
  for t in tags {
    stmts = stmts.append(CloudAgents.Db.insertPromptTagSql(newId(), id, userId, t))
  }
  CloudAgents.Sqlite.executeTransaction(stmts)?
  return Ok(
    value = Prompt(id = id, userId = userId, name = name, body = body, useCount = "0", createdAt = ts, updatedAt = ts, tags = tags)
  )
}

/// All prompts in a user's library, alphabetical by name (each with its tags).
pub func listPrompts(userId: in String): Result[slice[Prompt], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectPromptsSql(userId))?
  var acc: slice[Prompt] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    val p = rowToPromptWithTags(CloudAgents.Sqlite.getRowArrayValue(rows, i), userId)?
    acc = acc.append(p)
    i = i + 1
  }
  return Ok(value = acc)
}

/// A user's prompts, most-used first (ties alphabetical).
pub func listPromptsByUsage(userId: in String): Result[slice[Prompt], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectPromptsByUsageSql(userId))?
  var acc: slice[Prompt] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    val p = rowToPromptWithTags(CloudAgents.Sqlite.getRowArrayValue(rows, i), userId)?
    acc = acc.append(p)
    i = i + 1
  }
  return Ok(value = acc)
}

/// A user's prompts carrying a given tag, alphabetical by name.
pub func listPromptsByTag(userId: in String, tag: in String): Result[slice[Prompt], CloudAgents.Sqlite.DbError] {
  val idRows = CloudAgents.Sqlite.query(CloudAgents.Db.selectPromptIdsByTagSql(userId, tag))?
  var acc: slice[Prompt] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(idRows)
  while i < len {
    val pid = colAt(CloudAgents.Sqlite.getRowArrayValue(idRows, i).cols, 0)
    match getPrompt(pid, userId)? {
      case Some(p) -> {
        acc = acc.append(p)
      }
      case None -> ()
    }
    i = i + 1
  }
  return Ok(value = acc)
}

/// A single prompt owned by a user (with tags), or None.
pub func getPrompt(id: in String, userId: in String): Result[Option[Prompt], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectPromptByIdSql(id, userId))?
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  if len == 0 {
    return Ok(value = None)
  }
  val p = rowToPromptWithTags(CloudAgents.Sqlite.getRowArrayValue(rows, 0), userId)?
  return Ok(value = Some(value = p))
}

/// Update a prompt's name/body. Returns the number of rows affected (0 when
/// the prompt does not exist or is not owned by the user — the handler maps
/// that to 404).
pub func updatePrompt(
  id: in String, userId: in String, name: in String, body: in String
): Result[Int, CloudAgents.Sqlite.DbError] {
  val ts = nowMillis()
  return CloudAgents.Sqlite.execute(CloudAgents.Db.updatePromptSql(id, userId, name, body, ts))
}

/// Update a prompt's name/body AND replace its tag set in one transaction
/// (#244). Returns rows affected on the prompt (0 = not found / not owned).
/// Existence is pre-checked for the 0-rows signal since executeTransaction
/// returns no count, mirroring updateProfile.
pub func updatePromptWithTags(
  id: in String, userId: in String, name: in String, body: in String, tags: in slice[String]
): Result[Int, CloudAgents.Sqlite.DbError] {
  match getPrompt(id, userId)? {
    case None -> return Ok(value = 0)
    case Some(_) -> ()
  }
  val ts = nowMillis()
  var stmts: slice[String] = []
  stmts = stmts.append(CloudAgents.Db.updatePromptSql(id, userId, name, body, ts))
  stmts = stmts.append(CloudAgents.Db.deletePromptTagsSql(id, userId))
  for t in tags {
    stmts = stmts.append(CloudAgents.Db.insertPromptTagSql(newId(), id, userId, t))
  }
  CloudAgents.Sqlite.executeTransaction(stmts)?
  return Ok(value = 1)
}

/// Record one use of a prompt. Returns rows affected (0 = not found).
pub func markPromptUsed(id: in String, userId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  val ts = nowMillis()
  return CloudAgents.Sqlite.execute(CloudAgents.Db.touchPromptUsedSql(id, userId, ts))
}

/// Delete a prompt and its tags. Returns rows affected on the prompt (0 = not
/// found). Tag cleanup is best-effort — orphaned tag rows are unreachable once
/// the prompt is gone.
pub func deletePrompt(id: in String, userId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  val _ = CloudAgents.Sqlite.execute(CloudAgents.Db.deletePromptTagsSql(id, userId))
  return CloudAgents.Sqlite.execute(CloudAgents.Db.deletePromptSql(id, userId))
}

// ─── Credentials ─────────────────────────────────────────────────────────────
//
// Values are AES-256-CBC + HMAC-SHA256 encrypted (CloudAgents.Crypto) before they touch SQLite,
// and decrypted only when building a container's environment — never returned
// to any HTTP response. The store surfaces credential *names* to the API, not
// their values.
@generate(Json)
pub record CredentialName {
  pub name: String
  pub updatedAt: String
}

@generate(Json)
pub record CredentialNameList {
  pub credentials: slice[CredentialName]
}

/// One decrypted secret ready to inject into a container's environment.
pub record CredentialValue {
  pub name: String
  pub value: String
}

/// Failure at the credential layer: either the database or the crypto boundary.
pub union CredentialError {
  case Db(error: CloudAgents.Sqlite.DbError)
  case Crypto(error: CloudAgents.Crypto.CryptoError)
}

pub func credentialErrorMessage(e: in CredentialError): String {
  return match e {
    case Db(dbErr) -> CloudAgents.Sqlite.dbErrorMessage(dbErr)
    case Crypto(cErr) -> CloudAgents.Crypto.cryptoErrorMessage(cErr)
  }
}

/// Store (or replace) a user's credential, encrypting the value at rest.
pub func putCredential(userId: in String, name: in String, value: in String): Result[Unit, CredentialError] {
  val encrypted = match CloudAgents.Crypto.encrypt(value) {
    case Ok(blob) -> blob
    case Err(e) -> return Err(Crypto(error = e))
  }
  val id = newId()
  val ts = nowMillis()
  match CloudAgents.Sqlite.execute(CloudAgents.Db.upsertCredentialSql(id, userId, name, encrypted, ts)) {
    case Ok(_) -> return Ok(value = ())
    case Err(e) -> return Err(Db(error = e))
  }
}

/// List a user's credential names (never values).
pub func listCredentialNames(userId: in String): Result[slice[CredentialName], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectCredentialNamesSql(userId))?
  var acc: slice[CredentialName] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    val r = CloudAgents.Sqlite.getRowArrayValue(rows, i)
    acc = acc.append(CredentialName(name = colAt(r.cols, 0), updatedAt = colAt(r.cols, 1)))
    i = i + 1
  }
  return Ok(value = acc)
}

/// Delete a credential by name. Returns rows affected (0 = not found).
pub func deleteCredential(userId: in String, name: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  return CloudAgents.Sqlite.execute(CloudAgents.Db.deleteCredentialSql(userId, name))
}

/// Decrypt a user's stored credentials for injection into a container
/// environment. Best-effort per credential: a single undecryptable row (a
/// rotated ENCRYPTION_KEY, a tampered value) is skipped with a warning rather
/// than failing the whole batch — otherwise one bad secret would block every
/// future run, including runs that never needed it. A database-read failure
/// (can't reach the store at all) is still fatal.
pub func decryptedCredentials(userId: in String): Result[slice[CredentialValue], CredentialError] {
  val rows = match CloudAgents.Sqlite.query(CloudAgents.Db.selectCredentialsForInjectionSql(userId)) {
    case Ok(r) -> r
    case Err(e) -> return Err(Db(error = e))
  }
  var acc: slice[CredentialValue] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    val r = CloudAgents.Sqlite.getRowArrayValue(rows, i)
    val name = colAt(r.cols, 0)
    match CloudAgents.Crypto.decrypt(colAt(r.cols, 1)) {
      case Ok(p) -> {
        acc = acc.append(CredentialValue(name = name, value = p))
      }
      case Err(e) -> {
        println("WARNING: skipping undecryptable credential '" + name + "': " + CloudAgents.Crypto.cryptoErrorMessage(e))
      }
    }
    i = i + 1
  }
  return Ok(value = acc)
}

// ─── Profiles ──────────────────────────────────────────────────────────────────
//
// A per-container policy: which harness runs, what network access the container
// gets, and which credentials are injected (least privilege). See
// CloudAgents.Db profiles DDL for the field vocabulary. The `credentials` slice
// on the record is the set of granted credential names (empty unless
// credentialMode == "selected").
@generate(Json)
pub record Profile {
  pub id: String
  pub userId: String
  pub name: String
  pub harness: String
  pub networkPolicy: String
  pub credentialMode: String
  pub credentials: slice[String]
  pub createdAt: String
  pub updatedAt: String
}

@generate(Json)
pub record ProfileList {
  pub profiles: slice[Profile]
}

/// The network policy a session's profile pins. Drives the container's
/// NetworkMode in CloudAgents.Docker. Consistent with decryptedCredentialsForProfile
/// (#231): an empty profileId means "no profile" -> "full" (legacy default),
/// but a non-empty profileId that can't be resolved fails closed to "none"
/// (isolated), so a session whose profile was deleted doesn't silently regain
/// full network access.
pub func profileNetworkPolicy(userId: in String, profileId: in String): Result[String, CloudAgents.Sqlite.DbError] {
  if profileId.length == 0 {
    return Ok(value = "full")
  }
  match getProfile(profileId, userId)? {
    case None -> return Ok(value = "none")
    case Some(p) -> {
      if p.networkPolicy.length == 0 {
        return Ok(value = "full")
      }
      return Ok(value = p.networkPolicy)
    }
  }
}

/// Whether a string slice contains a value (small linear scan).
func sliceContains(xs: in slice[String], target: in String): Bool {
  var i = 0
  while i < xs.length {
    if xs[i] == target {
      return true
    }
    i = i + 1
  }
  return false
}

// ─── Run history ───────────────────────────────────────────────────────────────
//
// A compact per-run record (status + timing + a bounded prompt preview) for
// history/usage views. The full prompt lives in `messages`; this table is the
// lifecycle/audit surface. Scoped by user_id.
val runPreviewMaxLen = 500

@generate(Json)
pub record Run {
  pub id: String
  pub sessionId: String
  pub userId: String
  pub promptPreview: String
  pub harness: String
  pub model: String
  pub status: String
  pub startedAt: String
  pub endedAt: String
}

@generate(Json)
pub record RunList {
  pub runs: slice[Run]
}

func rowToRun(r: in CloudAgents.Sqlite.Row): Run {
  return Run(
    id = colAt(r.cols, 0),
    sessionId = colAt(r.cols, 1),
    userId = colAt(r.cols, 2),
    promptPreview = colAt(r.cols, 3),
    harness = colAt(r.cols, 4),
    model = colAt(r.cols, 5),
    status = colAt(r.cols, 6),
    startedAt = colAt(r.cols, 7),
    endedAt = colAt(r.cols, 8)
  )
}

/// First `runPreviewMaxLen` characters of a prompt, for the lean run record.
func promptPreview(prompt: in String): String {
  if prompt.length <= runPreviewMaxLen {
    return prompt
  }
  return prompt.substring(0, runPreviewMaxLen)
}

/// Record the start of a run (status 'running'), returning the run id so the
/// caller can finish it. Best-effort bookkeeping — a failure here must not stop
/// the actual run, so callers ignore the error and pass "" as the run id.
pub func recordRunStart(
  sessionId: in String, userId: in String, prompt: in String, harness: in String, model: in String
): Result[String, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = nowMillis()
  CloudAgents.Sqlite.execute(
    CloudAgents.Db.insertRunSql(id, sessionId, userId, promptPreview(prompt), harness, model, ts)
  )?
  return Ok(value = id)
}

/// Move a run to a terminal status ('succeeded' | 'failed' | 'cancelled').
pub func recordRunEnd(runId: in String, userId: in String, status: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(CloudAgents.Db.finishRunSql(runId, userId, status, nowMillis()))?
  return Ok(value = ())
}

/// Mark every still-'running' run for a session terminal — used when a run ends
/// without the run id in hand (a cancel from another request), so history never
/// strands a phantom 'running' row.
pub func finishSessionRuns(sessionId: in String, userId: in String, status: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  CloudAgents.Sqlite.execute(CloudAgents.Db.finishSessionRunsSql(sessionId, userId, status, nowMillis()))?
  return Ok(value = ())
}

/// A session's run history, newest first.
pub func listRuns(sessionId: in String, userId: in String): Result[slice[Run], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectRunsBySessionSql(sessionId, userId))?
  var acc: slice[Run] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(rowToRun(CloudAgents.Sqlite.getRowArrayValue(rows, i)))
    i = i + 1
  }
  return Ok(value = acc)
}

/// The granted credential names for a profile (empty for 'all' mode).
func profileCredentialNames(profileId: in String, userId: in String): Result[slice[String], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectProfileCredentialsSql(profileId, userId))?
  var acc: slice[String] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(colAt(CloudAgents.Sqlite.getRowArrayValue(rows, i).cols, 0))
    i = i + 1
  }
  return Ok(value = acc)
}

func rowToProfile(r: in CloudAgents.Sqlite.Row, creds: in slice[String]): Profile {
  return Profile(
    id = colAt(r.cols, 0),
    userId = colAt(r.cols, 1),
    name = colAt(r.cols, 2),
    harness = colAt(r.cols, 3),
    networkPolicy = colAt(r.cols, 4),
    credentialMode = colAt(r.cols, 5),
    credentials = creds,
    createdAt = colAt(r.cols, 6),
    updatedAt = colAt(r.cols, 7)
  )
}

/// Statements that replace a profile's granted credential set: clear, then one
/// insert per name. Returned as a list (not executed) so callers can run them
/// in the same transaction as the profile row itself (review #230), keeping the
/// profile and its grants consistent on partial failure.
func profileCredentialStatements(profileId: in String, userId: in String, names: in slice[String]): slice[String] {
  var stmts: slice[String] = []
  stmts = stmts.append(CloudAgents.Db.deleteProfileCredentialsSql(profileId, userId))
  for name in names {
    stmts = stmts.append(CloudAgents.Db.insertProfileCredentialSql(newId(), profileId, userId, name))
  }
  return stmts
}

/// Save a new profile and its granted credential set, returning the stored record.
pub func addProfile(
  userId: in String,
  name: in String,
  harness: in String,
  networkPolicy: in String,
  credentialMode: in String,
  credentials: in slice[String],
): Result[Profile, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = nowMillis()
  // Profile row + its credential grants commit together (#230).
  var stmts: slice[String] = []
  stmts = stmts.append(CloudAgents.Db.insertProfileSql(id, userId, name, harness, networkPolicy, credentialMode, ts))
  for s in profileCredentialStatements(id, userId, credentials) {
    stmts = stmts.append(s)
  }
  CloudAgents.Sqlite.executeTransaction(stmts)?
  return Ok(
    value = Profile(
      id = id,
      userId = userId,
      name = name,
      harness = harness,
      networkPolicy = networkPolicy,
      credentialMode = credentialMode,
      credentials = credentials,
      createdAt = ts,
      updatedAt = ts
    )
  )
}

/// All of a user's profiles (each with its granted credential names), by name.
pub func listProfiles(userId: in String): Result[slice[Profile], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectProfilesSql(userId))?
  var acc: slice[Profile] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    val r = CloudAgents.Sqlite.getRowArrayValue(rows, i)
    val creds = profileCredentialNames(colAt(r.cols, 0), userId)?
    acc = acc.append(rowToProfile(r, creds))
    i = i + 1
  }
  return Ok(value = acc)
}

/// The id of a user's profile with the given name, or None if the name is
/// free. Used to turn a duplicate name into a 400 instead of a UNIQUE-constraint
/// 500 (#236).
pub func profileIdByName(userId: in String, name: in String): Result[Option[String], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectProfileIdByNameSql(userId, name))?
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  if len == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = colAt(CloudAgents.Sqlite.getRowArrayValue(rows, 0).cols, 0)))
}

/// A single profile owned by a user (with its granted credentials), or None.
pub func getProfile(id: in String, userId: in String): Result[Option[Profile], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectProfileByIdSql(id, userId))?
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  if len == 0 {
    return Ok(value = None)
  }
  val r = CloudAgents.Sqlite.getRowArrayValue(rows, 0)
  val creds = profileCredentialNames(id, userId)?
  return Ok(value = Some(value = rowToProfile(r, creds)))
}

/// Update a profile's settings and granted credentials. Returns rows affected
/// on the profiles row (0 = not found / not owned, mapped to 404 by the handler).
pub func updateProfile(
  id: in String,
  userId: in String,
  name: in String,
  harness: in String,
  networkPolicy: in String,
  credentialMode: in String,
  credentials: in slice[String],
): Result[Int, CloudAgents.Sqlite.DbError] {
  // Pre-check existence for the 404 signal: executeTransaction returns no
  // rows-affected count, so the caller's "0 = not found" contract is derived
  // from this ownership-scoped lookup instead.
  match getProfile(id, userId)? {
    case None -> return Ok(value = 0)
    case Some(_) -> ()
  }
  val ts = nowMillis()
  // Profile row + its credential grants commit together (#230).
  var stmts: slice[String] = []
  stmts = stmts.append(CloudAgents.Db.updateProfileSql(id, userId, name, harness, networkPolicy, credentialMode, ts))
  for s in profileCredentialStatements(id, userId, credentials) {
    stmts = stmts.append(s)
  }
  CloudAgents.Sqlite.executeTransaction(stmts)?
  return Ok(value = 1)
}

/// Delete a profile and its credential grants (atomically, #230). Returns rows
/// affected (0 = not found / not owned).
pub func deleteProfile(id: in String, userId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  match getProfile(id, userId)? {
    case None -> return Ok(value = 0)
    case Some(_) -> ()
  }
  var stmts: slice[String] = []
  stmts = stmts.append(CloudAgents.Db.deleteProfileCredentialsSql(id, userId))
  stmts = stmts.append(CloudAgents.Db.deleteProfileSql(id, userId))
  CloudAgents.Sqlite.executeTransaction(stmts)?
  return Ok(value = 1)
}

/// Decrypt only the credentials a profile grants, for least-privilege
/// injection. In 'all' mode this is every credential (identical to
/// decryptedCredentials); in 'selected' mode only the named grants are
/// included. Best-effort per credential, exactly like decryptedCredentials.
///
/// Fail-closed on an unresolved profile (review #231): an EMPTY profileId means
/// "no profile" and falls open to all credentials (the explicit legacy opt-out),
/// but a NON-EMPTY profileId that can't be resolved (e.g. the profile was
/// deleted after the session was created) injects NOTHING rather than silently
/// escalating a scoped session to every secret.
pub func decryptedCredentialsForProfile(
  userId: in String, profileId: in String
): Result[slice[CredentialValue], CredentialError] {
  if profileId.length == 0 {
    return decryptedCredentials(userId)
  }
  val profile = match getProfile(profileId, userId) {
    case Ok(p) -> p
    case Err(e) -> return Err(Db(error = e))
  }
  match profile {
    case None -> {
      // Referenced profile is gone: fail closed, inject no credentials.
      val empty: slice[CredentialValue] = []
      return Ok(value = empty)
    }
    case Some(p) -> {
      if p.credentialMode != "selected" {
        return decryptedCredentials(userId)
      }
      val all = decryptedCredentials(userId)?
      var acc: slice[CredentialValue] = []
      var i = 0
      while i < all.length {
        if sliceContains(p.credentials, all[i].name) {
          acc = acc.append(all[i])
        }
        i = i + 1
      }
      return Ok(value = acc)
    }
  }
}
