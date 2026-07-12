package CloudAgents.Db

import Std.Core

/// Phase 2 groundwork: session lifecycle state and the SQLite schema.
///
/// The session state machine (docs/phase2-session-management.md):
///
///   CREATED -> CLONING -> IDLE -> RUNNING -> WARM -> IDLE ...
///   (any state) -> DESTROYED
///
/// The actual SQL execution is performed through the `lyric-db` library once
/// it is wired in; this module owns the pure, host-independent pieces — the
/// status vocabulary and the schema text — so they can be unit-tested without
/// a database.
/// Lifecycle state of a session.
pub enum SessionStatus {

  case Created
  case Cloning
  case Idle
  case Running
  case Warm
  case Destroyed
}

/// Canonical uppercase string stored in the `status` column.
pub func statusToString(s: in SessionStatus): String {
  return match s {
    case Created -> "CREATED"
    case Cloning -> "CLONING"
    case Idle -> "IDLE"
    case Running -> "RUNNING"
    case Warm -> "WARM"
    case Destroyed -> "DESTROYED"
  }
}

/// Parse a status string from the database back into the enum.
/// Returns `None` for an unrecognised value.
pub func statusFromString(s: in String): Option[SessionStatus] {
  if s == "CREATED" {
    return Some(value = Created)
  }
  if s == "CLONING" {
    return Some(value = Cloning)
  }
  if s == "IDLE" {
    return Some(value = Idle)
  }
  if s == "RUNNING" {
    return Some(value = Running)
  }
  if s == "WARM" {
    return Some(value = Warm)
  }
  if s == "DESTROYED" {
    return Some(value = Destroyed)
  }
  return None
}

/// Whether a session in this state currently holds (or expects) a live
/// container. Used by the idle-recycling sweep to decide what to stop.
pub func hasLiveContainer(s: in SessionStatus): Bool {
  return match s {
    case Created -> false
    case Cloning -> true
    case Idle -> false
    case Running -> true
    case Warm -> true
    case Destroyed -> false
  }
}

// ─── State machine ────────────────────────────────────────────────────────────
//
// Drives the transitions in docs/phase2-session-management.md. Modelled as a
// total function so the compiler's exhaustiveness check guarantees every
// (state, event) pair is considered — illegal pairs return `Invalid` rather
// than silently doing the wrong thing.
/// Events that can drive a session between states.
pub enum SessionEvent {
  case CloneStarted
  case CloneFinished
  case MessageReceived
  case ProcessExited
  case IdleTimeout
  case Deleted
}

/// Result of attempting a transition: a new status, or `Invalid` when the
/// event is not legal in the current state.
pub union Transition {
  case To(status: SessionStatus)
  case Invalid
}

/// Compute the next state for a (current state, event) pair.
pub func nextStatus(current: in SessionStatus, event: in SessionEvent): Transition {
  return match current {
    case Created -> match event { case CloneStarted -> To(status = Cloning); case Deleted -> To(status = Destroyed); case CloneFinished -> Invalid; case MessageReceived -> Invalid; case ProcessExited -> Invalid; case IdleTimeout -> Invalid }
    case Cloning -> match event { case CloneFinished -> To(status = Idle); case Deleted -> To(status = Destroyed); case CloneStarted -> Invalid; case MessageReceived -> Invalid; case ProcessExited -> Invalid; case IdleTimeout -> Invalid }
    case Idle -> match event { case MessageReceived -> To(status = Running); case Deleted -> To(status = Destroyed); case CloneStarted -> Invalid; case CloneFinished -> Invalid; case ProcessExited -> Invalid; case IdleTimeout -> Invalid }
    case Running -> match event { case ProcessExited -> To(status = Warm); case Deleted -> To(status = Destroyed); case CloneStarted -> Invalid; case CloneFinished -> Invalid; case MessageReceived -> Invalid; case IdleTimeout -> Invalid }
    case Warm -> match event { case MessageReceived -> To(status = Running); case IdleTimeout -> To(status = Idle); case Deleted -> To(status = Destroyed); case CloneStarted -> Invalid; case CloneFinished -> Invalid; case ProcessExited -> Invalid }
    case Destroyed -> Invalid
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

/// How long an idle session is kept before its container metadata is dropped
/// and it is treated as fully cold (1 hour).
pub func coldWindowMillis(): Long {
  return 3600000.toLong()
}

/// Action the idle sweep should take for a session.
pub enum RecycleAction {
  case StopAndIdle
  case EvictCold
  case NoAction
}

/// Decide what the idle sweep should do given a session's state and how long
/// it has been since its last message.
pub func recycleDecision(status: in SessionStatus, idleMillis: in Long): RecycleAction {
  return match status {
    case Warm -> if idleMillis >= warmWindowMillis() then StopAndIdle else NoAction
    case Idle -> if idleMillis >= coldWindowMillis() then EvictCold else NoAction
    case Created -> NoAction
    case Cloning -> NoAction
    case Running -> NoAction
    case Destroyed -> NoAction
  }
}

/// DDL for the `sessions` table. Every column is TEXT affinity so the
/// CloudAgents.Sqlite driver can read rows with GetString (same rule as the
/// messages/comments/todos/prompts tables — the original Phase 2 draft used
/// INTEGER/TIMESTAMP columns, which the GetString-only driver cannot read).
/// Applied at startup with `CREATE TABLE IF NOT EXISTS`.
pub func sessionsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS sessions (" + "id TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "repo_url TEXT NOT NULL, " +
    "branch TEXT NOT NULL, " +
    "container_id TEXT NOT NULL, " +
    "harness TEXT NOT NULL, " +
    "model TEXT NOT NULL, " +
    "native_session_id TEXT NOT NULL, " +
    "status TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "last_message_at TEXT NOT NULL)"
}

/// Name of the per-session workspace volume (Phase 3 keys by GitHub user).
pub func workspaceVolumeName(githubUserId: in String, sessionId: in String): String {
  return "session-" + githubUserId + "-" + sessionId
}

/// Name of the per-user home volume holding the `.claude` credentials.
pub func homeVolumeName(githubUserId: in String): String {
  return "user-" + githubUserId + "-home"
}

// ─── Session SQL ──────────────────────────────────────────────────────────────
//
// Assembled with `sqlLiteral` escaping like every other statement in this
// package (an earlier draft used `?` placeholders for a lyric-db binding
// layer that was never wired in — the CloudAgents.Sqlite driver does no
// parameter binding). Every read and mutation is scoped by `user_id` so a
// user can only ever touch their own sessions (Phase 3 ownership
// enforcement, docs/phase3 §4).
val sessionColumns = "id, user_id, repo_url, branch, container_id, harness, model, native_session_id, status, created_at, last_message_at"

/// INSERT a new session row (status starts IDLE; last_message_at = created_at).
pub func insertSessionSql(
  id: in String,
  userId: in String,
  repoUrl: in String,
  branch: in String,
  containerId: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String,
  createdAt: in String,
): String {
  return "INSERT INTO sessions (" + sessionColumns + ") VALUES (" + sqlLiteral(id) + ", " + sqlLiteral(userId) +
    ", " +
    sqlLiteral(repoUrl) +
    ", " +
    sqlLiteral(branch) +
    ", " +
    sqlLiteral(containerId) +
    ", " +
    sqlLiteral(harness) +
    ", " +
    sqlLiteral(model) +
    ", " +
    sqlLiteral(nativeSessionId) +
    ", 'IDLE', " +
    sqlLiteral(createdAt) +
    ", " +
    sqlLiteral(createdAt) +
    ")"
}

/// SELECT a single session owned by a user.
pub func selectSessionByIdSql(id: in String, userId: in String): String {
  return "SELECT " + sessionColumns + " FROM sessions WHERE id = " + sqlLiteral(id) + " AND user_id = " +
    sqlLiteral(userId)
}

/// SELECT all sessions owned by a user, most recently active first.
pub func listSessionsByUserSql(userId: in String): String {
  return "SELECT " + sessionColumns + " FROM sessions WHERE user_id = " + sqlLiteral(userId) +
    " ORDER BY last_message_at DESC"
}

/// UPDATE a session's container id.
pub func updateSessionContainerSql(id: in String, userId: in String, containerId: in String): String {
  return "UPDATE sessions SET container_id = " + sqlLiteral(containerId) + " WHERE id = " + sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId)
}

/// Clear the container id only if it still equals `containerId` — a
/// compare-and-clear (#45). A run whose outer request already timed out can
/// finish long after a newer run for the same session started and stored a new
/// container id; an unconditional clear would then wipe the newer id and orphan
/// its container.
pub func clearSessionContainerIfMatchesSql(id: in String, userId: in String, containerId: in String): String {
  return "UPDATE sessions SET container_id = '' WHERE id = " + sqlLiteral(id) +
    " AND user_id = " + sqlLiteral(userId) +
    " AND container_id = " + sqlLiteral(containerId)
}

/// UPDATE a session's model.
pub func updateSessionModelSql(id: in String, userId: in String, model: in String): String {
  return "UPDATE sessions SET model = " + sqlLiteral(model) + " WHERE id = " + sqlLiteral(id) + " AND user_id = " +
    sqlLiteral(userId)
}

/// Atomically claim a session for a run: flips status to RUNNING only when
/// it is not already RUNNING, in one statement, so two concurrent sends
/// cannot both win (rows affected = 1 means the claim succeeded).
pub func tryBeginRunSql(id: in String, userId: in String, ts: in String): String {
  return "UPDATE sessions SET status = 'RUNNING', last_message_at = " + sqlLiteral(ts) + " WHERE id = " +
    sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId) +
    " AND status <> 'RUNNING'"
}

/// Return a session to IDLE after a run completes (success or failure).
pub func endRunSql(id: in String, userId: in String, ts: in String): String {
  return "UPDATE sessions SET status = 'IDLE', last_message_at = " + sqlLiteral(ts) + " WHERE id = " +
    sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId)
}

/// DELETE a session.
pub func deleteSessionSql(id: in String, userId: in String): String {
  return "DELETE FROM sessions WHERE id = " + sqlLiteral(id) + " AND user_id = " + sqlLiteral(userId)
}

/// Container ids of sessions stranded RUNNING/WARM (across all users), for the
/// startup sweep to terminate before recoverDanglingSessionsSql blanks them —
/// otherwise those containers are orphaned. Un-scoped: startup recovery is
/// system-wide, not per-request.
pub func selectStrandedContainerIdsSql(): String {
  return "SELECT container_id FROM sessions WHERE (status = 'RUNNING' OR status = 'WARM') AND container_id <> ''"
}

/// Reset any sessions still marked RUNNING or WARM back to IDLE. Used by the
/// startup recovery routine after a Docker daemon or VM restart (docs/phase2
/// §Constraints). No params.
pub func recoverDanglingSessionsSql(): String {
  return "UPDATE sessions SET status = 'IDLE', container_id = '' " + "WHERE status = 'RUNNING' OR status = 'WARM'"
}

/// ALTER adding the profile association to an existing sessions table. A
/// non-idempotent statement (ADD COLUMN fails if the column already exists),
/// so it lives in a versioned migration that runs exactly once. The DEFAULT ''
/// backfills every existing row to "no profile" (legacy behaviour). Appended as
/// the last column, so the fixed sessionColumns indices above are unaffected.
pub func alterSessionsAddProfileSql(): String {
  return "ALTER TABLE sessions ADD COLUMN profile_id TEXT NOT NULL DEFAULT ''"
}

/// Set (or clear) a session's profile association. Scoped by owner.
pub func updateSessionProfileSql(id: in String, userId: in String, profileId: in String): String {
  return "UPDATE sessions SET profile_id = " + sqlLiteral(profileId) + " WHERE id = " + sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId)
}

/// Read a session's profile id (empty string when none). Kept off the fixed
/// sessionColumns projection so that column order stays stable.
pub func selectSessionProfileIdSql(id: in String, userId: in String): String {
  return "SELECT profile_id FROM sessions WHERE id = " + sqlLiteral(id) + " AND user_id = " + sqlLiteral(userId)
}

// ─── Conversation transcript, comments and todos ───────────────────────────────
//
// These tables back the "addressable agent responses" feature: each user
// prompt and each agent reply is stored as a `messages` row with a stable id,
// so comments and todo items can link back to a specific point in the run.
//
// The lyric-db parameter binding used for `sessions` above is not available
// through the minimal CloudAgents.Sqlite driver, so statements that take values
// are assembled here with `sqlLiteral` escaping. Every column is declared with
// TEXT affinity so the driver can read each one with `GetString`.
/// Quote and escape a value as a SQLite single-quoted string literal. The only
/// metacharacter inside a single-quoted SQLite string is `'`, which is escaped
/// by doubling it — this is injection-safe for any text interpolated into a
/// quoted literal position.
pub func sqlLiteral(s: in String): String {
  var acc = "'"
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    if c == "'" {
      acc = acc + "''"
    } else {
      acc = acc + c
    }
    i = i + 1
  }
  return acc + "'"
}

/// Left-pad a sequence number to a fixed width so lexical ordering on the TEXT
/// `seq` column matches numeric ordering.
pub func padSeq(n: in Int): String {
  var s = toString(n)
  while s.length < 12 {
    s = "0" + s
  }
  return s
}

/// DDL for the conversation transcript. `role` is 'user' or 'agent'; `seq` is a
/// zero-padded monotonic counter within a session.
pub func messagesSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS messages (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "role TEXT NOT NULL, " +
    "content TEXT NOT NULL, " +
    "seq TEXT NOT NULL, " +
    "created_at TEXT NOT NULL)"
}

/// DDL for comments attached to a specific message.
pub func commentsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS comments (" + "id TEXT PRIMARY KEY, " + "message_id TEXT NOT NULL, " +
    "session_id TEXT NOT NULL, " +
    "body TEXT NOT NULL, " +
    "created_at TEXT NOT NULL)"
}

/// DDL for todo / bookmark items. `message_id` links back to the source message
/// (empty string when a todo is not anchored to a message). `done` is '0'/'1'.
pub func todosSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS todos (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "message_id TEXT NOT NULL, " +
    "note TEXT NOT NULL, " +
    "done TEXT NOT NULL, " +
    "created_at TEXT NOT NULL)"
}

/// INSERT one transcript message with all values inlined as escaped literals.
pub func insertMessageSql(
  id: in String,
  sessionId: in String,
  role: in String,
  content: in String,
  seq: in String,
  createdAt: in String,
): String {
  return "INSERT INTO messages (id, session_id, role, content, seq, created_at) VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(sessionId) +
    ", " +
    sqlLiteral(role) +
    ", " +
    sqlLiteral(content) +
    ", " +
    sqlLiteral(seq) +
    ", " +
    sqlLiteral(createdAt) +
    ")"
}

/// SELECT the session_id that owns a given message. Used by the comments
/// handler to derive ownership without trusting the client.
pub func selectMessageSessionIdSql(messageId: in String): String {
  return "SELECT session_id FROM messages WHERE id = " + sqlLiteral(messageId)
}

/// SELECT a session's transcript, oldest first. Column order matches the
/// mapping in CloudAgents.Repository.
pub func selectMessagesSql(sessionId: in String): String {
  return "SELECT id, session_id, role, content, seq, created_at FROM messages " + "WHERE session_id = " +
    sqlLiteral(sessionId) +
    " ORDER BY seq ASC"
}

/// COUNT messages in a session, cast to TEXT so the driver can read it with
/// GetString. Used to compute the next `seq`.
pub func countMessagesSql(sessionId: in String): String {
  return "SELECT CAST(COUNT(*) AS TEXT) FROM messages WHERE session_id = " + sqlLiteral(sessionId)
}

/// INSERT a comment on a message.
pub func insertCommentSql(
  id: in String,
  messageId: in String,
  sessionId: in String,
  body: in String,
  createdAt: in String,
): String {
  return "INSERT INTO comments (id, message_id, session_id, body, created_at) VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(messageId) +
    ", " +
    sqlLiteral(sessionId) +
    ", " +
    sqlLiteral(body) +
    ", " +
    sqlLiteral(createdAt) +
    ")"
}

/// SELECT comments on a message, oldest first.
pub func selectCommentsSql(messageId: in String): String {
  return "SELECT id, message_id, session_id, body, created_at FROM comments " + "WHERE message_id = " +
    sqlLiteral(messageId) +
    " ORDER BY created_at ASC"
}

/// INSERT a todo / bookmark.
pub func insertTodoSql(
  id: in String, sessionId: in String, messageId: in String, note: in String, createdAt: in String
): String {
  return "INSERT INTO todos (id, session_id, message_id, note, done, created_at) VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(sessionId) +
    ", " +
    sqlLiteral(messageId) +
    ", " +
    sqlLiteral(note) +
    ", '0', " +
    sqlLiteral(createdAt) +
    ")"
}

/// SELECT all todos for a session, newest first.
pub func selectTodosSql(sessionId: in String): String {
  return "SELECT id, session_id, message_id, note, done, created_at FROM todos " + "WHERE session_id = " +
    sqlLiteral(sessionId) +
    " ORDER BY created_at DESC"
}

/// Toggle a todo's done flag by id.
pub func toggleTodoSql(id: in String): String {
  return "UPDATE todos SET done = CASE done WHEN '1' THEN '0' ELSE '1' END WHERE id = " + sqlLiteral(id)
}

/// DELETE a todo by id.
pub func deleteTodoSql(id: in String): String {
  return "DELETE FROM todos WHERE id = " + sqlLiteral(id)
}

// ─── Prompt library ───────────────────────────────────────────────────────────
//
// Saved, reusable prompts. Scoped by `user_id` from day one (Phase 3
// multi-tenancy readiness): in the current static-token deployment every
// request resolves to the single operator identity, but the schema and every
// query are already ownership-scoped so the GitHub-OAuth follow-up only has
// to change where the identity comes from. Every column is TEXT affinity so
// the CloudAgents.Sqlite driver can read rows with GetString.
/// DDL for the prompt library.
pub func promptsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS prompts (" + "id TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "body TEXT NOT NULL, " +
    "use_count TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL)"
}

/// INSERT a new saved prompt (use_count starts at '0').
pub func insertPromptSql(
  id: in String, userId: in String, name: in String, body: in String, createdAt: in String
): String {
  return "INSERT INTO prompts (id, user_id, name, body, use_count, created_at, updated_at) VALUES (" +
    sqlLiteral(id) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(name) +
    ", " +
    sqlLiteral(body) +
    ", '0', " +
    sqlLiteral(createdAt) +
    ", " +
    sqlLiteral(createdAt) +
    ")"
}

/// SELECT one user's prompts, alphabetical by name.
pub func selectPromptsSql(userId: in String): String {
  return "SELECT id, user_id, name, body, use_count, created_at, updated_at FROM prompts " + "WHERE user_id = " +
    sqlLiteral(userId) +
    " ORDER BY name ASC"
}

/// SELECT one user's prompts, most-used first (ties broken alphabetically). The
/// TEXT use_count is CAST to INTEGER so ordering is numeric, not lexical.
pub func selectPromptsByUsageSql(userId: in String): String {
  return "SELECT id, user_id, name, body, use_count, created_at, updated_at FROM prompts " + "WHERE user_id = " +
    sqlLiteral(userId) +
    " ORDER BY CAST(use_count AS INTEGER) DESC, name ASC"
}

/// SELECT a single prompt owned by a user.
pub func selectPromptByIdSql(id: in String, userId: in String): String {
  return "SELECT id, user_id, name, body, use_count, created_at, updated_at FROM prompts " + "WHERE id = " +
    sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId)
}

/// UPDATE a prompt's name and body.
pub func updatePromptSql(
  id: in String, userId: in String, name: in String, body: in String, updatedAt: in String
): String {
  return "UPDATE prompts SET name = " + sqlLiteral(name) + ", body = " + sqlLiteral(body) + ", updated_at = " +
    sqlLiteral(updatedAt) +
    " WHERE id = " +
    sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId)
}

/// Record one use of a prompt (numeric bump on the TEXT column).
pub func touchPromptUsedSql(id: in String, userId: in String, usedAt: in String): String {
  return "UPDATE prompts SET use_count = CAST(CAST(use_count AS INTEGER) + 1 AS TEXT), updated_at = " +
    sqlLiteral(usedAt) +
    " WHERE id = " +
    sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId)
}

/// DELETE a prompt owned by a user.
pub func deletePromptSql(id: in String, userId: in String): String {
  return "DELETE FROM prompts WHERE id = " + sqlLiteral(id) + " AND user_id = " + sqlLiteral(userId)
}

/// Index for the owner column every prompt query filters on (review #182).
pub func promptsUserIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_prompts_user_id ON prompts(user_id)"
}

// ─── Prompt tags ────────────────────────────────────────────────────────────────
//
// Tags/categories for prompts, in a join table (same shape as
// profile_credentials) so the prompts column mapping stays stable. user_id is
// denormalised so every read is ownership-scoped.
/// DDL for the prompt-tag join table.
pub func promptTagsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS prompt_tags (" + "id TEXT PRIMARY KEY, " + "prompt_id TEXT NOT NULL, " +
    "user_id TEXT NOT NULL, " +
    "tag TEXT NOT NULL, " +
    "UNIQUE(prompt_id, tag))"
}

/// Index for per-prompt tag reads.
pub func promptTagsPromptIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_prompt_tags_prompt_id ON prompt_tags(prompt_id)"
}

/// Index for tag-filtered listing (owner + tag).
pub func promptTagsTagIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_prompt_tags_user_tag ON prompt_tags(user_id, tag)"
}

/// INSERT one tag for a prompt (idempotent per (prompt, tag)).
pub func insertPromptTagSql(id: in String, promptId: in String, userId: in String, tag: in String): String {
  return "INSERT INTO prompt_tags (id, prompt_id, user_id, tag) VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(promptId) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(tag) +
    ") ON CONFLICT(prompt_id, tag) DO NOTHING"
}

/// SELECT a prompt's tags, alphabetical.
pub func selectPromptTagsSql(promptId: in String, userId: in String): String {
  return "SELECT tag FROM prompt_tags WHERE prompt_id = " + sqlLiteral(promptId) + " AND user_id = " +
    sqlLiteral(userId) +
    " ORDER BY tag ASC"
}

/// SELECT every (prompt_id, tag) pair for a user's prompts in one query, so a
/// list of N prompts can attach tags with 2 queries instead of 1 + N (#246).
/// Ordered by tag within each prompt so tags come out alphabetical, matching
/// selectPromptTagsSql.
pub func selectAllPromptTagsSql(userId: in String): String {
  return "SELECT prompt_id, tag FROM prompt_tags WHERE user_id = " + sqlLiteral(userId) +
    " ORDER BY prompt_id ASC, tag ASC"
}

/// DELETE all of a prompt's tags (to replace the set on update / clean up on delete).
pub func deletePromptTagsSql(promptId: in String, userId: in String): String {
  return "DELETE FROM prompt_tags WHERE prompt_id = " + sqlLiteral(promptId) + " AND user_id = " + sqlLiteral(userId)
}

/// SELECT the ids of a user's prompts carrying a given tag, ordered by prompt
/// name (joined so the "alphabetical" contract the repository documents holds).
pub func selectPromptIdsByTagSql(userId: in String, tag: in String): String {
  return "SELECT pt.prompt_id FROM prompt_tags pt JOIN prompts p ON p.id = pt.prompt_id " + "WHERE pt.user_id = " +
    sqlLiteral(userId) +
    " AND pt.tag = " +
    sqlLiteral(tag) +
    " ORDER BY p.name ASC"
}

/// Index for the owner column every session query filters on.
pub func sessionsUserIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id)"
}

// ─── Credential store ─────────────────────────────────────────────────────────
//
// Per-user secrets (GitHub tokens, cloud credentials, arbitrary env vars),
// encrypted at rest by CloudAgents.Crypto before they ever reach this layer —
// `value_encrypted` is always ciphertext, never plaintext. Scoped by
// (user_id, name); a fresh upsert replaces the previous value. The value is
// never selected back out to any HTTP response; it is only decrypted
// server-side when building a runner container's environment.
/// DDL for the credential store. `name` is the env-var name injected into
/// containers; `value_encrypted` is the base64 AES-256-CBC + HMAC-SHA256 blob.
pub func credentialsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS credentials (" + "id TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "value_encrypted TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL, " +
    "UNIQUE(user_id, name))"
}

/// Composite index for the (owner, name) lookups every query uses.
pub func credentialsUserIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_credentials_user_id ON credentials(user_id)"
}

/// UPSERT a credential: insert, or replace the encrypted value on name clash.
/// (SQLite UPSERT keeps the original id/created_at on conflict.)
pub func upsertCredentialSql(
  id: in String, userId: in String, name: in String, valueEncrypted: in String, ts: in String
): String {
  return "INSERT INTO credentials (id, user_id, name, value_encrypted, created_at, updated_at) VALUES (" +
    sqlLiteral(id) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(name) +
    ", " +
    sqlLiteral(valueEncrypted) +
    ", " +
    sqlLiteral(ts) +
    ", " +
    sqlLiteral(ts) +
    ") ON CONFLICT(user_id, name) DO UPDATE SET value_encrypted = " +
    sqlLiteral(valueEncrypted) +
    ", updated_at = " +
    sqlLiteral(ts)
}

/// SELECT the names of a user's credentials (never the values), alphabetical.
pub func selectCredentialNamesSql(userId: in String): String {
  return "SELECT name, updated_at FROM credentials WHERE user_id = " + sqlLiteral(userId) + " ORDER BY name ASC"
}

/// SELECT every (name, encrypted value) for a user, for container injection.
pub func selectCredentialsForInjectionSql(userId: in String): String {
  return "SELECT name, value_encrypted FROM credentials WHERE user_id = " + sqlLiteral(userId) + " ORDER BY name ASC"
}

/// DELETE one credential by name.
pub func deleteCredentialSql(userId: in String, name: in String): String {
  return "DELETE FROM credentials WHERE user_id = " + sqlLiteral(userId) + " AND name = " + sqlLiteral(name)
}

// ─── Profiles ─────────────────────────────────────────────────────────────────
//
// A profile is a per-container policy object (à la Claude remote environments):
// which harness runs, what network access the container gets, and which of the
// user's credentials are injected (least privilege). A session may reference a
// profile; with none, the legacy behaviour applies (all credentials, full
// network). Scoped by user_id like every other resource. All TEXT affinity.
//
//   network_policy  : 'full' (default bridge) | 'none' (isolated) | 'restricted'
//                     ('restricted' is a documented seam — sets proxy env vars,
//                      egress allowlist enforcement is a follow-up)
//   credential_mode : 'all' (inject every credential) | 'selected'
//                     (inject only names listed in profile_credentials)
//   harness         : '' (session chooses) | a specific harness the profile pins
/// DDL for the profiles table.
pub func profilesSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS profiles (" + "id TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "harness TEXT NOT NULL, " +
    "network_policy TEXT NOT NULL, " +
    "credential_mode TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL, " +
    "UNIQUE(user_id, name))"
}

/// DDL for the join table naming which credentials a 'selected'-mode profile
/// grants. user_id is denormalised so every read stays ownership-scoped.
pub func profileCredentialsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS profile_credentials (" + "id TEXT PRIMARY KEY, " + "profile_id TEXT NOT NULL, " +
    "user_id TEXT NOT NULL, " +
    "credential_name TEXT NOT NULL, " +
    "UNIQUE(profile_id, credential_name))"
}

/// Index for the owner column every profile query filters on.
pub func profilesUserIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_profiles_user_id ON profiles(user_id)"
}

/// Index for the profile_id lookups the injection path uses.
pub func profileCredentialsProfileIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_profile_credentials_profile_id ON profile_credentials(profile_id)"
}

/// INSERT a new profile.
pub func insertProfileSql(
  id: in String,
  userId: in String,
  name: in String,
  harness: in String,
  networkPolicy: in String,
  credentialMode: in String,
  createdAt: in String,
): String {
  return "INSERT INTO profiles (id, user_id, name, harness, network_policy, credential_mode, created_at, updated_at) VALUES (" +
    sqlLiteral(id) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(name) +
    ", " +
    sqlLiteral(harness) +
    ", " +
    sqlLiteral(networkPolicy) +
    ", " +
    sqlLiteral(credentialMode) +
    ", " +
    sqlLiteral(createdAt) +
    ", " +
    sqlLiteral(createdAt) +
    ")"
}

val profileColumns = "id, user_id, name, harness, network_policy, credential_mode, created_at, updated_at"

/// SELECT one user's profiles, alphabetical by name.
pub func selectProfilesSql(userId: in String): String {
  return "SELECT " + profileColumns + " FROM profiles WHERE user_id = " + sqlLiteral(userId) + " ORDER BY name ASC"
}

/// SELECT a single profile owned by a user.
pub func selectProfileByIdSql(id: in String, userId: in String): String {
  return "SELECT " + profileColumns + " FROM profiles WHERE id = " + sqlLiteral(id) + " AND user_id = " +
    sqlLiteral(userId)
}

/// SELECT the id of a user's profile with a given name (for duplicate-name
/// detection so a UNIQUE clash returns 400, not a 500). Empty result = free.
pub func selectProfileIdByNameSql(userId: in String, name: in String): String {
  return "SELECT id FROM profiles WHERE user_id = " + sqlLiteral(userId) + " AND name = " + sqlLiteral(name)
}

/// UPDATE a profile's settings.
pub func updateProfileSql(
  id: in String,
  userId: in String,
  name: in String,
  harness: in String,
  networkPolicy: in String,
  credentialMode: in String,
  updatedAt: in String,
): String {
  return "UPDATE profiles SET name = " + sqlLiteral(name) + ", harness = " + sqlLiteral(harness) +
    ", network_policy = " +
    sqlLiteral(networkPolicy) +
    ", credential_mode = " +
    sqlLiteral(credentialMode) +
    ", updated_at = " +
    sqlLiteral(updatedAt) +
    " WHERE id = " +
    sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId)
}

/// DELETE a profile owned by a user.
pub func deleteProfileSql(id: in String, userId: in String): String {
  return "DELETE FROM profiles WHERE id = " + sqlLiteral(id) + " AND user_id = " + sqlLiteral(userId)
}

/// INSERT one credential grant for a profile.
pub func insertProfileCredentialSql(
  id: in String, profileId: in String, userId: in String, credentialName: in String
): String {
  return "INSERT INTO profile_credentials (id, profile_id, user_id, credential_name) VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(profileId) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(credentialName) +
    ") ON CONFLICT(profile_id, credential_name) DO NOTHING"
}

/// SELECT the credential names a profile grants, alphabetical.
pub func selectProfileCredentialsSql(profileId: in String, userId: in String): String {
  return "SELECT credential_name FROM profile_credentials WHERE profile_id = " + sqlLiteral(profileId) +
    " AND user_id = " +
    sqlLiteral(userId) +
    " ORDER BY credential_name ASC"
}

/// DELETE every credential grant for a profile (used to replace the set on
/// update, and to clean up when a profile is deleted).
pub func deleteProfileCredentialsSql(profileId: in String, userId: in String): String {
  return "DELETE FROM profile_credentials WHERE profile_id = " + sqlLiteral(profileId) + " AND user_id = " +
    sqlLiteral(userId)
}

// ─── Run history ──────────────────────────────────────────────────────────────
//
// One row per agent run (a send that actually claimed the session): a compact
// audit/usage record with status and timing, separate from the full transcript
// in `messages`. `prompt_preview` is a bounded slice of the prompt (the full
// text lives in messages), so this table stays lean even for long prompts.
// Scoped by user_id. status: 'running' | 'succeeded' | 'failed' | 'cancelled'.
/// DDL for the run-history table.
pub func runsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS runs (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "user_id TEXT NOT NULL, " +
    "prompt_preview TEXT NOT NULL, " +
    "harness TEXT NOT NULL, " +
    "model TEXT NOT NULL, " +
    "status TEXT NOT NULL, " +
    "started_at TEXT NOT NULL, " +
    "ended_at TEXT NOT NULL)"
}

/// Indexes for the two lookups run history uses (per session, per user).
pub func runsSessionIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_runs_session_id ON runs(session_id)"
}

pub func runsUserIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_runs_user_id ON runs(user_id)"
}

/// INSERT a run at the moment it is claimed (status 'running', ended_at '').
pub func insertRunSql(
  id: in String,
  sessionId: in String,
  userId: in String,
  promptPreview: in String,
  harness: in String,
  model: in String,
  startedAt: in String,
): String {
  return "INSERT INTO runs (id, session_id, user_id, prompt_preview, harness, model, status, started_at, ended_at) VALUES (" +
    sqlLiteral(id) +
    ", " +
    sqlLiteral(sessionId) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(promptPreview) +
    ", " +
    sqlLiteral(harness) +
    ", " +
    sqlLiteral(model) +
    ", 'running', " +
    sqlLiteral(startedAt) +
    ", '')"
}

/// UPDATE a run to a terminal status with its end time. Scoped by owner, and
/// write-once (only a still-'running' run is moved), so a cancel that already
/// marked the run 'cancelled' from another request is not overwritten by the
/// run's own 'failed'/'succeeded' when its terminated container makes it exit.
pub func finishRunSql(id: in String, userId: in String, status: in String, endedAt: in String): String {
  return "UPDATE runs SET status = " + sqlLiteral(status) + ", ended_at = " + sqlLiteral(endedAt) + " WHERE id = " +
    sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId) +
    " AND status = 'running'"
}

/// SELECT a session's run history, newest first. Scoped by owner.
pub func selectRunsBySessionSql(sessionId: in String, userId: in String): String {
  return "SELECT id, session_id, user_id, prompt_preview, harness, model, status, started_at, ended_at FROM runs " +
    "WHERE session_id = " +
    sqlLiteral(sessionId) +
    " AND user_id = " +
    sqlLiteral(userId) +
    " ORDER BY started_at DESC"
}

/// Mark any still-'running' runs for a session as the given terminal status.
/// Used when a run ends without the caller holding the run id (e.g. a cancel
/// from another request), so history doesn't leave phantom 'running' rows.
pub func finishSessionRunsSql(sessionId: in String, userId: in String, status: in String, endedAt: in String): String {
  return "UPDATE runs SET status = " + sqlLiteral(status) + ", ended_at = " + sqlLiteral(endedAt) + " WHERE session_id = " +
    sqlLiteral(sessionId) +
    " AND user_id = " +
    sqlLiteral(userId) +
    " AND status = 'running'"
}

// ─── Idle container reaping ─────────────────────────────────────────────────────
/// Sessions (system-wide) that still hold a WARM container that has been idle
/// at least `warmWindowMillis`, i.e. ready for the reaper to stop. The age
/// filter is done in SQL (SQLite's integer arithmetic is 64-bit) so Lyric never
/// has to parse epoch-millis into a Long. Returns (id, container_id). Un-scoped:
/// reaping is a system maintenance task, not a per-user request.
pub func selectReapableWarmSql(nowMillis: in String, warmWindowMillis: in String): String {
  return "SELECT id, container_id FROM sessions WHERE status = 'WARM' AND container_id <> '' AND (CAST(" +
    sqlLiteral(nowMillis) +
    " AS INTEGER) - CAST(last_message_at AS INTEGER)) >= CAST(" +
    sqlLiteral(warmWindowMillis) +
    " AS INTEGER)"
}

/// Stop tracking a session's container after its container has been reaped:
/// blank the container id and return the session to IDLE. Un-scoped (system
/// maintenance). Params: id.
pub func reapSessionContainerSql(id: in String): String {
  return "UPDATE sessions SET status = 'IDLE', container_id = '' WHERE id = " + sqlLiteral(id)
}

// ─── Webhooks (transactional outbox) ────────────────────────────────────────────
//
// Run-completion notifications. Registered target URLs live in `webhooks`; each
// finished run enqueues a `webhook_events` row (an outbox). Actual HTTP delivery
// is done by an external worker that polls the pending endpoint and marks rows
// delivered — the same "expose to an external scheduler" approach as reaping,
// since Lyric.Web has no in-process timer and reliable outbound HTTPS from Lyric
// isn't available yet. delivered is '0'/'1'. All TEXT affinity, user_id-scoped.
/// DDL for registered webhook target URLs.
pub func webhooksSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS webhooks (" + "id TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "url TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "UNIQUE(user_id, url))"
}

/// DDL for the outbox of run-completion events awaiting delivery.
pub func webhookEventsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS webhook_events (" + "id TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "session_id TEXT NOT NULL, " +
    "run_id TEXT NOT NULL, " +
    "status TEXT NOT NULL, " +
    "delivered TEXT NOT NULL, " +
    "created_at TEXT NOT NULL)"
}

pub func webhooksUserIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_webhooks_user_id ON webhooks(user_id)"
}

/// Index for the pending-events poll (owner + delivered flag).
pub func webhookEventsPendingIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_webhook_events_pending ON webhook_events(user_id, delivered)"
}

/// INSERT (register) a webhook URL, idempotent per (user, url).
pub func insertWebhookSql(id: in String, userId: in String, url: in String, createdAt: in String): String {
  return "INSERT INTO webhooks (id, user_id, url, created_at) VALUES (" + sqlLiteral(id) + ", " + sqlLiteral(userId) +
    ", " +
    sqlLiteral(url) +
    ", " +
    sqlLiteral(createdAt) +
    ") ON CONFLICT(user_id, url) DO NOTHING"
}

/// SELECT a user's registered webhooks, newest first.
pub func selectWebhooksSql(userId: in String): String {
  return "SELECT id, user_id, url, created_at FROM webhooks WHERE user_id = " + sqlLiteral(userId) +
    " ORDER BY created_at DESC"
}

/// SELECT a single webhook by (user, url) — used after an idempotent register
/// to return the actually-persisted row rather than a freshly-minted one.
pub func selectWebhookByUrlSql(userId: in String, url: in String): String {
  return "SELECT id, user_id, url, created_at FROM webhooks WHERE user_id = " + sqlLiteral(userId) + " AND url = " +
    sqlLiteral(url)
}

/// DELETE a webhook by id, scoped by owner.
pub func deleteWebhookSql(id: in String, userId: in String): String {
  return "DELETE FROM webhooks WHERE id = " + sqlLiteral(id) + " AND user_id = " + sqlLiteral(userId)
}

/// COUNT a user's registered webhooks (as TEXT for the GetString-only driver),
/// so an event is only enqueued when there is somewhere to deliver it.
pub func countWebhooksSql(userId: in String): String {
  return "SELECT CAST(COUNT(*) AS TEXT) FROM webhooks WHERE user_id = " + sqlLiteral(userId)
}

/// INSERT a run-completion event into the outbox (delivered '0').
pub func insertWebhookEventSql(
  id: in String, userId: in String, sessionId: in String, runId: in String, status: in String, createdAt: in String
): String {
  return "INSERT INTO webhook_events (id, user_id, session_id, run_id, status, delivered, created_at) VALUES (" +
    sqlLiteral(id) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(sessionId) +
    ", " +
    sqlLiteral(runId) +
    ", " +
    sqlLiteral(status) +
    ", '0', " +
    sqlLiteral(createdAt) +
    ")"
}

/// SELECT a user's undelivered events, oldest first (FIFO delivery).
pub func selectPendingWebhookEventsSql(userId: in String): String {
  return "SELECT id, user_id, session_id, run_id, status, created_at FROM webhook_events " + "WHERE user_id = " +
    sqlLiteral(userId) +
    " AND delivered = '0' ORDER BY created_at ASC"
}

/// Mark an outbox event delivered. Scoped by owner.
pub func markWebhookEventDeliveredSql(id: in String, userId: in String): String {
  return "UPDATE webhook_events SET delivered = '1' WHERE id = " + sqlLiteral(id) + " AND user_id = " +
    sqlLiteral(userId)
}

// ─── Schema migrations ────────────────────────────────────────────────────────
//
// A tiny versioned-migration ledger. Every schema change is expressed as an
// ordered migration with a stable version id; `schema_migrations` records which
// versions have run so non-idempotent statements (ALTER TABLE ADD COLUMN, which
// errors if the column already exists) execute exactly once. Idempotent DDL
// (CREATE TABLE/INDEX IF NOT EXISTS) is still safe to re-run, but the ledger is
// what lets later migrations evolve existing tables without a bespoke detect-
// and-patch dance (the class of upgrade hazard raised in review #225).
/// DDL for the migration ledger itself. Applied before any migration runs.
pub func migrationsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS schema_migrations (" + "version TEXT PRIMARY KEY, " + "applied_at TEXT NOT NULL)"
}

/// Count (as TEXT so the GetString-only driver can read it) how many times a
/// version has been recorded — 0 means the migration still needs to run.
pub func countMigrationSql(version: in String): String {
  return "SELECT CAST(COUNT(*) AS TEXT) FROM schema_migrations WHERE version = " + sqlLiteral(version)
}

/// Record a migration as applied.
pub func recordMigrationSql(version: in String, appliedAt: in String): String {
  return "INSERT INTO schema_migrations (version, applied_at) VALUES (" + sqlLiteral(version) + ", " +
    sqlLiteral(appliedAt) +
    ")"
}
