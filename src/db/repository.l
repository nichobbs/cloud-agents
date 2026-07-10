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

/// Create every table if it does not already exist. Safe to call at every
/// startup.
pub func initSchema(): Result[Unit, CloudAgents.Sqlite.DbError] {
  // Create every table before any index. Each statement is `IF NOT EXISTS`, so
  // this is safe to re-run, but ordering matters for robustness: if an index
  // statement ever fails (e.g. a hand-migrated DB whose table predates a column
  // the index needs), all tables still exist rather than aborting partway and
  // leaving a later table — credentials in particular — uncreated.
  CloudAgents.Sqlite.execute(CloudAgents.Db.messagesSchemaSql())?
  CloudAgents.Sqlite.execute(CloudAgents.Db.commentsSchemaSql())?
  CloudAgents.Sqlite.execute(CloudAgents.Db.todosSchemaSql())?
  CloudAgents.Sqlite.execute(CloudAgents.Db.promptsSchemaSql())?
  CloudAgents.Sqlite.execute(CloudAgents.Db.sessionsSchemaSql())?
  CloudAgents.Sqlite.execute(CloudAgents.Db.credentialsSchemaSql())?
  CloudAgents.Sqlite.execute(CloudAgents.Db.promptsUserIndexSql())?
  CloudAgents.Sqlite.execute(CloudAgents.Db.sessionsUserIndexSql())?
  CloudAgents.Sqlite.execute(CloudAgents.Db.credentialsUserIndexSql())?
  return Ok(value = ())
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
func rowToPrompt(r: in CloudAgents.Sqlite.Row): Prompt {
  return Prompt(
    id = colAt(r.cols, 0),
    userId = colAt(r.cols, 1),
    name = colAt(r.cols, 2),
    body = colAt(r.cols, 3),
    useCount = colAt(r.cols, 4),
    createdAt = colAt(r.cols, 5),
    updatedAt = colAt(r.cols, 6)
  )
}

/// Save a new prompt to a user's library and return the stored record.
pub func addPrompt(userId: in String, name: in String, body: in String): Result[Prompt, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = nowMillis()
  CloudAgents.Sqlite.execute(CloudAgents.Db.insertPromptSql(id, userId, name, body, ts))?
  return Ok(
    value = Prompt(id = id, userId = userId, name = name, body = body, useCount = "0", createdAt = ts, updatedAt = ts)
  )
}

/// All prompts in a user's library, alphabetical by name.
pub func listPrompts(userId: in String): Result[slice[Prompt], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectPromptsSql(userId))?
  var acc: slice[Prompt] = []
  var i = 0
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  while i < len {
    acc = acc.append(rowToPrompt(CloudAgents.Sqlite.getRowArrayValue(rows, i)))
    i = i + 1
  }
  return Ok(value = acc)
}

/// A single prompt owned by a user, or None.
pub func getPrompt(id: in String, userId: in String): Result[Option[Prompt], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.Sqlite.query(CloudAgents.Db.selectPromptByIdSql(id, userId))?
  val len = CloudAgents.Sqlite.getRowArrayLength(rows)
  if len == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = rowToPrompt(CloudAgents.Sqlite.getRowArrayValue(rows, 0))))
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

/// Record one use of a prompt. Returns rows affected (0 = not found).
pub func markPromptUsed(id: in String, userId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  val ts = nowMillis()
  return CloudAgents.Sqlite.execute(CloudAgents.Db.touchPromptUsedSql(id, userId, ts))
}

/// Delete a prompt. Returns rows affected (0 = not found).
pub func deletePrompt(id: in String, userId: in String): Result[Int, CloudAgents.Sqlite.DbError] {
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
