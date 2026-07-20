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

// (The Phase-3 draft helpers workspaceVolumeName/homeVolumeName were removed
// as dead code (#443): they were never wired into docker_manager.l and used a
// naming shape inconsistent with the *BindFor functions below that actually
// mount volumes — docs/review-2026-07-03*.md reference them historically.)
/// Container-side $HOME mount path for a harness image. Each harness image
/// runs as its own user with its own home directory (#409); unknown or empty
/// harness falls back to the claude image's path, matching
/// `homeVolumeBindForHarness`.
pub func homeMountPathForHarness(harness: in String): String {
  if harness == "codex" {
    return "/home/codex-user"
  }
  if harness == "opencode" {
    return "/home/opencode-user"
  }
  if harness == "gemini" {
    return "/home/gemini-user"
  }
  return "/home/claude-user"
}

/// Home-volume bind (volume:containerPath) for a harness's runner container,
/// shared across all legacy/operator sessions. Each harness image runs as
/// its own user with its own $HOME, so each harness gets its own shared
/// volume mounted at that image's home path — previously every harness
/// shared claude's volume mounted at /home/claude-user, so
/// Codex/OpenCode/Gemini CLI config and history never persisted between runs
/// (#409). Claude keeps its legacy volume name so existing installs keep
/// their authenticated ~/.claude. Kept in this pure package (not
/// CloudAgents.Docker) so tests can invoke it — a @test_module cannot call
/// into an async-bearing package (docs/lyric/gotchas.md). OAuth tenants get
/// per-user volumes instead — see `homeVolumeBindFor`.
pub func homeVolumeBindForHarness(harness: in String): String {
  if harness == "codex" {
    return "codex-home-default:" + homeMountPathForHarness(harness)
  }
  if harness == "opencode" {
    return "opencode-home-default:" + homeMountPathForHarness(harness)
  }
  if harness == "gemini" {
    return "gemini-home-default:" + homeMountPathForHarness(harness)
  }
  return "claude-home-default:" + homeMountPathForHarness(harness)
}

/// Home-volume bind (volume:containerPath) keyed by tenant. The operator
/// identity ("default" — see CloudAgents.Auth.operatorUserId; empty is
/// treated the same defensively) keeps the legacy per-harness shared volumes
/// from `homeVolumeBindForHarness` so existing installs keep their
/// authenticated ~/.claude etc. OAuth tenants (gh-<digits>) get a per-user
/// volume per harness: `user-<userId>-<harness>-home`. An empty harness is
/// normalised to "claude" in the volume name so it matches the image
/// actually used (imageForHarness falls back to the claude image).
pub func homeVolumeBindFor(userId: in String, harness: in String): String {
  if userId == "" or userId == "default" {
    return homeVolumeBindForHarness(harness)
  }
  // Normalise ANYTHING that isn't a recognised harness to "claude" — not
  // just the empty string — so the volume name always agrees with the mount
  // path and image, which both fall back to claude's for unknown values
  // (homeMountPathForHarness / imageForHarness). Unreachable today
  // (isKnownHarness rejects unknown harnesses upstream), but a divergent
  // name here would silently split a tenant's claude state in two (#437).
  val harnessName = if harness == "codex" or harness == "opencode" or harness == "gemini" then harness else "claude"
  return "user-" + userId + "-" + harnessName + "-home:" + homeMountPathForHarness(harness)
}

/// Workspace-volume bind (volume:/workspace) keyed by tenant. The operator
/// identity ("default"/empty) keeps the legacy `session-<sessionId>-workspace`
/// name so existing installs keep their workspaces; OAuth tenants get
/// `session-<userId>-<sessionId>-workspace`. Docker volume names allow
/// [a-zA-Z0-9_.-]; user ids are gh-<digits> and session ids are UUIDs, both
/// safe to embed verbatim.
pub func workspaceVolumeBindFor(userId: in String, sessionId: in String): String {
  if userId == "" or userId == "default" {
    return "session-" + sessionId + "-workspace:/workspace"
  }
  return "session-" + userId + "-" + sessionId + "-workspace:/workspace"
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
  return "INSERT INTO sessions (" + sessionColumns + ") VALUES (" + sqlLiteral(id) + ", " + sqlLiteral(userId) + ", " +
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
  return "UPDATE sessions SET container_id = '' WHERE id = " + sqlLiteral(id) + " AND user_id = " + sqlLiteral(userId) +
    " AND container_id = " +
    sqlLiteral(containerId)
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
  return "UPDATE sessions SET status = 'RUNNING', last_message_at = " + sqlLiteral(ts) + " WHERE id = " + sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId) +
    " AND status <> 'RUNNING'"
}

/// Return a session to IDLE after a run completes (success or failure).
pub func endRunSql(id: in String, userId: in String, ts: in String): String {
  return "UPDATE sessions SET status = 'IDLE', last_message_at = " + sqlLiteral(ts) + " WHERE id = " + sqlLiteral(id) +
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

// ─── Session repositories (multi-repo sessions) ─────────────────────────────
//
// Extra git repositories linked to a session beyond its primary repo_url, so an
// agent can work across several checkouts in one run. Rows are reached only
// through an owner-scoped session lookup in the handler (the same indirection
// comments/todos rely on), so this table carries no user_id of its own —
// ownership is enforced by the getSession() check the handler makes first. All
// TEXT affinity; `branch` may be '' meaning the repo's default branch.
/// DDL for the session-repositories table. UNIQUE(session_id, repo_url) makes
/// the handler's duplicate-URL pre-check race-proof: a concurrent second link
/// of the same URL hits the constraint (a DB error the handler surfaces)
/// instead of inserting a duplicate row (#451).
pub func sessionReposSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS session_repos (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "repo_url TEXT NOT NULL, " +
    "branch TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "UNIQUE(session_id, repo_url))"
}

/// Index for the per-session lookups every session-repo query filters on.
pub func sessionReposSessionIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_session_repos_session_id ON session_repos(session_id)"
}

/// INSERT a linked repository for a session.
pub func insertSessionRepoSql(
  id: in String,
  sessionId: in String,
  repoUrl: in String,
  branch: in String,
  createdAt: in String,
): String {
  return "INSERT INTO session_repos (id, session_id, repo_url, branch, created_at) VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(sessionId) +
    ", " +
    sqlLiteral(repoUrl) +
    ", " +
    sqlLiteral(branch) +
    ", " +
    sqlLiteral(createdAt) +
    ")"
}

/// SELECT a session's linked repositories, oldest first.
pub func selectSessionReposSql(sessionId: in String): String {
  return "SELECT id, session_id, repo_url, branch, created_at FROM session_repos " + "WHERE session_id = " +
    sqlLiteral(sessionId) +
    " ORDER BY created_at ASC"
}

/// COUNT a session's linked repositories (as TEXT for the GetString-only
/// driver), so the handler can cap how many a session may carry.
pub func countSessionReposSql(sessionId: in String): String {
  return "SELECT CAST(COUNT(*) AS TEXT) FROM session_repos WHERE session_id = " + sqlLiteral(sessionId)
}

/// SELECT the id of a session's linked repo with a given URL (duplicate
/// detection so re-linking the same repo returns 400, not a second clone).
pub func selectSessionRepoByUrlSql(sessionId: in String, repoUrl: in String): String {
  return "SELECT id FROM session_repos WHERE session_id = " + sqlLiteral(sessionId) + " AND repo_url = " +
    sqlLiteral(repoUrl)
}

/// DELETE one linked repository from a session (scoped by session so a repo id
/// can't be unlinked from another user's session).
pub func deleteSessionRepoSql(sessionId: in String, repoId: in String): String {
  return "DELETE FROM session_repos WHERE id = " + sqlLiteral(repoId) + " AND session_id = " + sqlLiteral(sessionId)
}

/// DELETE every linked repository for a session (cleanup when the session is
/// deleted).
pub func deleteSessionReposForSessionSql(sessionId: in String): String {
  return "DELETE FROM session_repos WHERE session_id = " + sqlLiteral(sessionId)
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
  return "INSERT INTO prompts (id, user_id, name, body, use_count, created_at, updated_at) VALUES (" + sqlLiteral(id) +
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
  return "INSERT INTO prompt_tags (id, prompt_id, user_id, tag) VALUES (" + sqlLiteral(id) + ", " + sqlLiteral(promptId) +
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

/// SELECT the full prompt rows carrying a given tag, ordered by name — so
/// listPromptsByTag can fetch matching prompts in one query (then attach tags in
/// a second batched query) instead of a per-id getPrompt round trip (#339). The
/// column list matches selectPromptsSql so rowToPrompt reads the same indices.
pub func selectPromptsByTagSql(userId: in String, tag: in String): String {
  return "SELECT p.id, p.user_id, p.name, p.body, p.use_count, p.created_at, p.updated_at " +
    "FROM prompts p JOIN prompt_tags pt ON pt.prompt_id = p.id " +
    "WHERE pt.user_id = " +
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
  return "UPDATE profiles SET name = " + sqlLiteral(name) + ", harness = " + sqlLiteral(harness) + ", network_policy = " +
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

// ─── Library: skills, subagents, MCP servers ───────────────────────────────────
//
// A per-user library of harness-agnostic building blocks a profile can grant
// to a session: skills (SKILL.md-format instructions — the format has
// converged across Claude Code, Codex CLI, Gemini CLI, and OpenCode as of
// 2026, so one stored body renders unchanged into every harness's own skills
// directory), subagents (a name/description/system-prompt triple rendered
// into each harness's own subagent format), and MCP servers (a stdio command
// or remote URL rendered into each harness's own MCP config). Library items
// are owned resources like profiles/credentials/prompts; a profile grants a
// subset via the profile_skills/profile_subagents/profile_mcp_servers join
// tables (mirroring profile_credentials). All TEXT affinity, user_id-scoped.
//
// mcp_server_args / mcp_server_env hold the ordered argv / env entries for a
// stdio-transport server as one row per entry (like profile_credentials, not
// a delimited blob) — `position` is a plain base-10 string ("0", "1", ...,
// "11") and callers sort with `CAST(position AS INTEGER)` rather than
// zero-padding, since string ops beyond `.length`/`.substring`/`.append()`
// are not reliably confirmed working in this toolchain (docs/lyric/gotchas.md).
/// DDL for the skills table.
pub func skillsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS skills (" + "id TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "description TEXT NOT NULL, " +
    "body TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL, " +
    "UNIQUE(user_id, name))"
}

/// DDL for the subagents table.
pub func subagentsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS subagents (" + "id TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "description TEXT NOT NULL, " +
    "system_prompt TEXT NOT NULL, " +
    "model TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL, " +
    "UNIQUE(user_id, name))"
}

/// DDL for the MCP servers table. transport: 'stdio' (command + args + env)
/// | 'url' (remote endpoint). `env` entries here are literal, non-secret
/// config only ("DEBUG=1") — anything secret flows through the existing
/// credential-grant mechanism by matching env var name, so this feature does
/// not introduce a second secret store.
pub func mcpServersSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS mcp_servers (" + "id TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "transport TEXT NOT NULL, " +
    "command TEXT NOT NULL, " +
    "url TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL, " +
    "UNIQUE(user_id, name))"
}

/// DDL for a stdio MCP server's ordered command-line arguments.
pub func mcpServerArgsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS mcp_server_args (" + "id TEXT PRIMARY KEY, " + "mcp_server_id TEXT NOT NULL, " +
    "user_id TEXT NOT NULL, " +
    "position TEXT NOT NULL, " +
    "value TEXT NOT NULL)"
}

/// DDL for a stdio MCP server's literal (non-secret) env entries, each a
/// full "KEY=VALUE" string.
pub func mcpServerEnvSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS mcp_server_env (" + "id TEXT PRIMARY KEY, " + "mcp_server_id TEXT NOT NULL, " +
    "user_id TEXT NOT NULL, " +
    "position TEXT NOT NULL, " +
    "value TEXT NOT NULL)"
}

/// DDL for the join table naming which skills a profile grants.
pub func profileSkillsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS profile_skills (" + "id TEXT PRIMARY KEY, " + "profile_id TEXT NOT NULL, " +
    "user_id TEXT NOT NULL, " +
    "skill_id TEXT NOT NULL, " +
    "UNIQUE(profile_id, skill_id))"
}

/// DDL for the join table naming which subagents a profile grants.
pub func profileSubagentsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS profile_subagents (" + "id TEXT PRIMARY KEY, " + "profile_id TEXT NOT NULL, " +
    "user_id TEXT NOT NULL, " +
    "subagent_id TEXT NOT NULL, " +
    "UNIQUE(profile_id, subagent_id))"
}

/// DDL for the join table naming which MCP servers a profile grants.
pub func profileMcpServersSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS profile_mcp_servers (" + "id TEXT PRIMARY KEY, " + "profile_id TEXT NOT NULL, " +
    "user_id TEXT NOT NULL, " +
    "mcp_server_id TEXT NOT NULL, " +
    "UNIQUE(profile_id, mcp_server_id))"
}

pub func skillsUserIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_skills_user_id ON skills(user_id)"
}

pub func subagentsUserIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_subagents_user_id ON subagents(user_id)"
}

pub func mcpServersUserIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_mcp_servers_user_id ON mcp_servers(user_id)"
}

pub func mcpServerArgsServerIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_mcp_server_args_server_id ON mcp_server_args(mcp_server_id)"
}

pub func mcpServerEnvServerIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_mcp_server_env_server_id ON mcp_server_env(mcp_server_id)"
}

pub func profileSkillsProfileIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_profile_skills_profile_id ON profile_skills(profile_id)"
}

pub func profileSubagentsProfileIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_profile_subagents_profile_id ON profile_subagents(profile_id)"
}

pub func profileMcpServersProfileIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_profile_mcp_servers_profile_id ON profile_mcp_servers(profile_id)"
}

// ─── Skills ─────────────────────────────────────────────────────────────────
pub func insertSkillSql(
  id: in String,
  userId: in String,
  name: in String,
  description: in String,
  body: in String,
  createdAt: in String,
): String {
  return "INSERT INTO skills (id, user_id, name, description, body, created_at, updated_at) VALUES (" + sqlLiteral(id) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(name) +
    ", " +
    sqlLiteral(description) +
    ", " +
    sqlLiteral(body) +
    ", " +
    sqlLiteral(createdAt) +
    ", " +
    sqlLiteral(createdAt) +
    ")"
}

val skillColumns = "id, user_id, name, description, body, created_at, updated_at"

pub func selectSkillsSql(userId: in String): String {
  return "SELECT " + skillColumns + " FROM skills WHERE user_id = " + sqlLiteral(userId) + " ORDER BY name ASC"
}

pub func selectSkillByIdSql(id: in String, userId: in String): String {
  return "SELECT " + skillColumns + " FROM skills WHERE id = " + sqlLiteral(id) + " AND user_id = " + sqlLiteral(userId)
}

pub func selectSkillIdByNameSql(userId: in String, name: in String): String {
  return "SELECT id FROM skills WHERE user_id = " + sqlLiteral(userId) + " AND name = " + sqlLiteral(name)
}

pub func updateSkillSql(
  id: in String,
  userId: in String,
  name: in String,
  description: in String,
  body: in String,
  updatedAt: in String,
): String {
  return "UPDATE skills SET name = " + sqlLiteral(name) + ", description = " + sqlLiteral(description) + ", body = " +
    sqlLiteral(body) +
    ", updated_at = " +
    sqlLiteral(updatedAt) +
    " WHERE id = " +
    sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId)
}

pub func deleteSkillSql(id: in String, userId: in String): String {
  return "DELETE FROM skills WHERE id = " + sqlLiteral(id) + " AND user_id = " + sqlLiteral(userId)
}

// ─── Subagents ──────────────────────────────────────────────────────────────
pub func insertSubagentSql(
  id: in String,
  userId: in String,
  name: in String,
  description: in String,
  systemPrompt: in String,
  model: in String,
  createdAt: in String,
): String {
  return "INSERT INTO subagents (id, user_id, name, description, system_prompt, model, created_at, updated_at) VALUES (" +
    sqlLiteral(id) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(name) +
    ", " +
    sqlLiteral(description) +
    ", " +
    sqlLiteral(systemPrompt) +
    ", " +
    sqlLiteral(model) +
    ", " +
    sqlLiteral(createdAt) +
    ", " +
    sqlLiteral(createdAt) +
    ")"
}

val subagentColumns = "id, user_id, name, description, system_prompt, model, created_at, updated_at"

pub func selectSubagentsSql(userId: in String): String {
  return "SELECT " + subagentColumns + " FROM subagents WHERE user_id = " + sqlLiteral(userId) + " ORDER BY name ASC"
}

pub func selectSubagentByIdSql(id: in String, userId: in String): String {
  return "SELECT " + subagentColumns + " FROM subagents WHERE id = " + sqlLiteral(id) + " AND user_id = " +
    sqlLiteral(userId)
}

pub func selectSubagentIdByNameSql(userId: in String, name: in String): String {
  return "SELECT id FROM subagents WHERE user_id = " + sqlLiteral(userId) + " AND name = " + sqlLiteral(name)
}

pub func updateSubagentSql(
  id: in String,
  userId: in String,
  name: in String,
  description: in String,
  systemPrompt: in String,
  model: in String,
  updatedAt: in String,
): String {
  return "UPDATE subagents SET name = " + sqlLiteral(name) + ", description = " + sqlLiteral(description) +
    ", system_prompt = " +
    sqlLiteral(systemPrompt) +
    ", model = " +
    sqlLiteral(model) +
    ", updated_at = " +
    sqlLiteral(updatedAt) +
    " WHERE id = " +
    sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId)
}

pub func deleteSubagentSql(id: in String, userId: in String): String {
  return "DELETE FROM subagents WHERE id = " + sqlLiteral(id) + " AND user_id = " + sqlLiteral(userId)
}

// ─── MCP servers ────────────────────────────────────────────────────────────
pub func insertMcpServerSql(
  id: in String,
  userId: in String,
  name: in String,
  transport: in String,
  command: in String,
  url: in String,
  createdAt: in String,
): String {
  return "INSERT INTO mcp_servers (id, user_id, name, transport, command, url, created_at, updated_at) VALUES (" +
    sqlLiteral(id) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(name) +
    ", " +
    sqlLiteral(transport) +
    ", " +
    sqlLiteral(command) +
    ", " +
    sqlLiteral(url) +
    ", " +
    sqlLiteral(createdAt) +
    ", " +
    sqlLiteral(createdAt) +
    ")"
}

val mcpServerColumns = "id, user_id, name, transport, command, url, created_at, updated_at"

pub func selectMcpServersSql(userId: in String): String {
  return "SELECT " + mcpServerColumns + " FROM mcp_servers WHERE user_id = " + sqlLiteral(userId) + " ORDER BY name ASC"
}

pub func selectMcpServerByIdSql(id: in String, userId: in String): String {
  return "SELECT " + mcpServerColumns + " FROM mcp_servers WHERE id = " + sqlLiteral(id) + " AND user_id = " +
    sqlLiteral(userId)
}

pub func selectMcpServerIdByNameSql(userId: in String, name: in String): String {
  return "SELECT id FROM mcp_servers WHERE user_id = " + sqlLiteral(userId) + " AND name = " + sqlLiteral(name)
}

pub func updateMcpServerSql(
  id: in String,
  userId: in String,
  name: in String,
  transport: in String,
  command: in String,
  url: in String,
  updatedAt: in String,
): String {
  return "UPDATE mcp_servers SET name = " + sqlLiteral(name) + ", transport = " + sqlLiteral(transport) + ", command = " +
    sqlLiteral(command) +
    ", url = " +
    sqlLiteral(url) +
    ", updated_at = " +
    sqlLiteral(updatedAt) +
    " WHERE id = " +
    sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId)
}

pub func deleteMcpServerSql(id: in String, userId: in String): String {
  return "DELETE FROM mcp_servers WHERE id = " + sqlLiteral(id) + " AND user_id = " + sqlLiteral(userId)
}

pub func insertMcpServerArgSql(
  id: in String,
  mcpServerId: in String,
  userId: in String,
  position: in String,
  value: in String,
): String {
  return "INSERT INTO mcp_server_args (id, mcp_server_id, user_id, position, value) VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(mcpServerId) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(position) +
    ", " +
    sqlLiteral(value) +
    ")"
}

pub func selectMcpServerArgsSql(mcpServerId: in String, userId: in String): String {
  return "SELECT value FROM mcp_server_args WHERE mcp_server_id = " + sqlLiteral(mcpServerId) + " AND user_id = " +
    sqlLiteral(userId) +
    " ORDER BY CAST(position AS INTEGER) ASC"
}

pub func deleteMcpServerArgsSql(mcpServerId: in String, userId: in String): String {
  return "DELETE FROM mcp_server_args WHERE mcp_server_id = " + sqlLiteral(mcpServerId) + " AND user_id = " +
    sqlLiteral(userId)
}

pub func insertMcpServerEnvSql(
  id: in String,
  mcpServerId: in String,
  userId: in String,
  position: in String,
  value: in String,
): String {
  return "INSERT INTO mcp_server_env (id, mcp_server_id, user_id, position, value) VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(mcpServerId) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(position) +
    ", " +
    sqlLiteral(value) +
    ")"
}

pub func selectMcpServerEnvSql(mcpServerId: in String, userId: in String): String {
  return "SELECT value FROM mcp_server_env WHERE mcp_server_id = " + sqlLiteral(mcpServerId) + " AND user_id = " +
    sqlLiteral(userId) +
    " ORDER BY CAST(position AS INTEGER) ASC"
}

pub func deleteMcpServerEnvSql(mcpServerId: in String, userId: in String): String {
  return "DELETE FROM mcp_server_env WHERE mcp_server_id = " + sqlLiteral(mcpServerId) + " AND user_id = " +
    sqlLiteral(userId)
}

// ─── Profile grants: skills / subagents / MCP servers ──────────────────────────
pub func insertProfileSkillSql(id: in String, profileId: in String, userId: in String, skillId: in String): String {
  return "INSERT INTO profile_skills (id, profile_id, user_id, skill_id) VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(profileId) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(skillId) +
    ") ON CONFLICT(profile_id, skill_id) DO NOTHING"
}

pub func selectProfileSkillIdsSql(profileId: in String, userId: in String): String {
  return "SELECT skill_id FROM profile_skills WHERE profile_id = " + sqlLiteral(profileId) + " AND user_id = " +
    sqlLiteral(userId) +
    " ORDER BY skill_id ASC"
}

pub func deleteProfileSkillsSql(profileId: in String, userId: in String): String {
  return "DELETE FROM profile_skills WHERE profile_id = " + sqlLiteral(profileId) + " AND user_id = " +
    sqlLiteral(userId)
}

pub func insertProfileSubagentSql(id: in String, profileId: in String, userId: in String, subagentId: in String): String {
  return "INSERT INTO profile_subagents (id, profile_id, user_id, subagent_id) VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(profileId) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(subagentId) +
    ") ON CONFLICT(profile_id, subagent_id) DO NOTHING"
}

pub func selectProfileSubagentIdsSql(profileId: in String, userId: in String): String {
  return "SELECT subagent_id FROM profile_subagents WHERE profile_id = " + sqlLiteral(profileId) + " AND user_id = " +
    sqlLiteral(userId) +
    " ORDER BY subagent_id ASC"
}

pub func deleteProfileSubagentsSql(profileId: in String, userId: in String): String {
  return "DELETE FROM profile_subagents WHERE profile_id = " + sqlLiteral(profileId) + " AND user_id = " +
    sqlLiteral(userId)
}

pub func insertProfileMcpServerSql(
  id: in String, profileId: in String, userId: in String, mcpServerId: in String
): String {
  return "INSERT INTO profile_mcp_servers (id, profile_id, user_id, mcp_server_id) VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(profileId) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(mcpServerId) +
    ") ON CONFLICT(profile_id, mcp_server_id) DO NOTHING"
}

pub func selectProfileMcpServerIdsSql(profileId: in String, userId: in String): String {
  return "SELECT mcp_server_id FROM profile_mcp_servers WHERE profile_id = " + sqlLiteral(profileId) + " AND user_id = " +
    sqlLiteral(userId) +
    " ORDER BY mcp_server_id ASC"
}

pub func deleteProfileMcpServersSql(profileId: in String, userId: in String): String {
  return "DELETE FROM profile_mcp_servers WHERE profile_id = " + sqlLiteral(profileId) + " AND user_id = " +
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
  return "UPDATE runs SET status = " + sqlLiteral(status) + ", ended_at = " + sqlLiteral(endedAt) +
    " WHERE session_id = " +
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
  id: in String,
  userId: in String,
  sessionId: in String,
  runId: in String,
  status: in String,
  createdAt: in String,
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

// ─── GitHub OAuth token-validation cache ────────────────────────────────────
//
// Validating a GitHub bearer means a round trip to api.github.com/user, so
// successful validations are cached (docs/phase3 §1). The table stores the
// token's SHA-256 (never the token) and an absolute expiry in epoch millis —
// TEXT affinity like every other column, with CAST-based comparisons like
// selectReapableWarmSql.
/// DDL for the GitHub-token validation cache.
pub func githubTokenCacheSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS github_token_cache (" + "token_hash TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "login TEXT NOT NULL, " +
    "expires_at TEXT NOT NULL)"
}

/// Upsert a validated token's identity. The expiry is computed in SQL
/// (now + ttl) so no epoch arithmetic happens on TEXT values in Lyric.
pub func upsertGitHubTokenSql(
  tokenHash: in String,
  userId: in String,
  login: in String,
  nowMillis: in String,
  ttlMillis: in String,
): String {
  return "INSERT OR REPLACE INTO github_token_cache (token_hash, user_id, login, expires_at) VALUES (" +
    sqlLiteral(tokenHash) +
    ", " +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(login) +
    ", CAST(CAST(" +
    sqlLiteral(nowMillis) +
    " AS INTEGER) + CAST(" +
    sqlLiteral(ttlMillis) +
    " AS INTEGER) AS TEXT))"
}

/// SELECT a still-valid cache entry for a token hash (expired rows never match).
pub func selectGitHubTokenSql(tokenHash: in String, nowMillis: in String): String {
  return "SELECT user_id, login FROM github_token_cache WHERE token_hash = " + sqlLiteral(tokenHash) +
    " AND CAST(expires_at AS INTEGER) > CAST(" +
    sqlLiteral(nowMillis) +
    " AS INTEGER)"
}

/// DELETE one token's cache row (server-side logout): the next presentation
/// of that token must go through live validation again.
pub func deleteGitHubTokenSql(tokenHash: in String): String {
  return "DELETE FROM github_token_cache WHERE token_hash = " + sqlLiteral(tokenHash)
}

/// Housekeeping: drop expired entries (run opportunistically on cache writes).
pub func deleteExpiredGitHubTokensSql(nowMillis: in String): String {
  return "DELETE FROM github_token_cache WHERE CAST(expires_at AS INTEGER) <= CAST(" + sqlLiteral(nowMillis) +
    " AS INTEGER)"
}

/// Count (as TEXT for the GetString-only driver) the still-active negative
/// BEARER entries — one per distinct bad bearer seen in the last minute
/// (rejected-code entries carry the 'oauth-code' login marker and are
/// counted separately, #434). The flood backstop reads this before spending
/// an outbound validation (#425).
pub func countActiveNegativeGitHubTokensSql(nowMillis: in String): String {
  return "SELECT CAST(COUNT(*) AS TEXT) FROM github_token_cache WHERE user_id = '' AND login = '' AND CAST(expires_at AS INTEGER) > CAST(" +
    sqlLiteral(nowMillis) +
    " AS INTEGER)"
}

/// Count still-active REJECTED-CODE entries (login marker 'oauth-code').
/// Kept separate from the bearer counter so a bearer flood can never trip
/// the sign-in backstop and vice versa (#433/#434).
pub func countActiveRejectedOAuthCodesSql(nowMillis: in String): String {
  return "SELECT CAST(COUNT(*) AS TEXT) FROM github_token_cache WHERE user_id = '' AND login = 'oauth-code' AND CAST(expires_at AS INTEGER) > CAST(" +
    sqlLiteral(nowMillis) +
    " AS INTEGER)"
}

// ─── Model-listing cache ────────────────────────────────────────────────────
//
// The models proxy (CloudAgents.Proxy.modelsHandler) calls each provider's
// models API sequentially on every request. This caches each provider's raw
// response body per user for a short TTL so the sequential fetch cost is paid
// at most once per window rather than on every call (#446). Scoped by
// (user_id, provider) — a provider's catalogue can differ by key/tenant, so a
// user only ever reads back a listing fetched with their own vault key. All
// TEXT affinity, CAST-based freshness comparison like the token cache.
/// DDL for the model-listing cache.
pub func modelListingCacheSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS model_listing_cache (" + "user_id TEXT NOT NULL, " + "provider TEXT NOT NULL, " +
    "body TEXT NOT NULL, " +
    "fetched_at TEXT NOT NULL, " +
    "PRIMARY KEY(user_id, provider))"
}

/// Upsert a provider's freshly-fetched listing for a user.
pub func upsertModelListingSql(userId: in String, provider: in String, body: in String, fetchedAt: in String): String {
  return "INSERT OR REPLACE INTO model_listing_cache (user_id, provider, body, fetched_at) VALUES (" +
    sqlLiteral(userId) +
    ", " +
    sqlLiteral(provider) +
    ", " +
    sqlLiteral(body) +
    ", " +
    sqlLiteral(fetchedAt) +
    ")"
}

/// SELECT a still-fresh cached listing (rows older than the TTL never match).
/// Freshness is `now - fetched_at < ttl`, computed in SQL so no epoch
/// arithmetic touches the TEXT values in Lyric.
pub func selectModelListingSql(
  userId: in String, provider: in String, nowMillis: in String, ttlMillis: in String
): String {
  return "SELECT body FROM model_listing_cache WHERE user_id = " + sqlLiteral(userId) + " AND provider = " +
    sqlLiteral(provider) +
    " AND (CAST(" +
    sqlLiteral(nowMillis) +
    " AS INTEGER) - CAST(fetched_at AS INTEGER)) < CAST(" +
    sqlLiteral(ttlMillis) +
    " AS INTEGER)"
}

/// Housekeeping: drop entries older than the TTL (run opportunistically on
/// cache writes, like the token cache's expired-row sweep #432).
pub func deleteExpiredModelListingsSql(nowMillis: in String, ttlMillis: in String): String {
  return "DELETE FROM model_listing_cache WHERE (CAST(" + sqlLiteral(nowMillis) +
    " AS INTEGER) - CAST(fetched_at AS INTEGER)) >= CAST(" +
    sqlLiteral(ttlMillis) +
    " AS INTEGER)"
}

// ─── Phase 6: MCP callbacks (permission requests, user questions, progress) ──
//
// docs/phase6-mcp-callbacks.md. A per-session callback bearer token (minted at
// container creation, stored on the session row) authenticates
// container-originated calls; permission_requests / user_questions are the
// pending/answered records the in-container MCP shim polls and a human
// answers from the UI; permission_rules stores session-scoped "allow always"
// rules so an identical (tool, input) pair is auto-approved without prompting
// again; progress_summary/progress_percent on `sessions` hold the latest
// fire-and-forget report_progress state. All TEXT affinity, sqlLiteral-escaped
// like every other statement in this package.
/// ALTER adding the per-session callback bearer token. Empty means callbacks
/// were never minted for this session (pre-Phase-6 session, or the
/// CLOUD_AGENTS_MCP_CALLBACKS feature flag is off) — CloudAgents.Callbacks
/// treats an empty stored token as "callbacks not enabled" rather than a
/// comparable secret.
pub func alterSessionsAddCallbackTokenSql(): String {
  return "ALTER TABLE sessions ADD COLUMN callback_token TEXT NOT NULL DEFAULT ''"
}

/// ALTER adding the latest report_progress summary. Empty means no progress
/// has been reported yet.
pub func alterSessionsAddProgressSql(): String {
  return "ALTER TABLE sessions ADD COLUMN progress_summary TEXT NOT NULL DEFAULT ''"
}

/// ALTER adding the latest report_progress percent-complete (as digit text,
/// "" when unknown).
pub func alterSessionsAddProgressPercentSql(): String {
  return "ALTER TABLE sessions ADD COLUMN progress_percent TEXT NOT NULL DEFAULT ''"
}

/// Set (or clear) a session's callback bearer token. Scoped by owner — minted
/// server-side at container creation with the owning user id already known
/// (the same explicit-userId pattern as updateSessionContainerSql, since this
/// runs off the request thread).
pub func updateSessionCallbackTokenSql(id: in String, userId: in String, token: in String): String {
  return "UPDATE sessions SET callback_token = " + sqlLiteral(token) + " WHERE id = " + sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId)
}

/// Read a session's callback token by id ONLY — deliberately unscoped by
/// user_id. The container presenting this token has no user identity of its
/// own yet; the token itself, compared in constant time against this stored
/// value, IS the authentication (mirrors the GitHub-token-cache's hash-keyed
/// lookup, not an ownership check).
pub func selectSessionCallbackTokenSql(id: in String): String {
  return "SELECT callback_token FROM sessions WHERE id = " + sqlLiteral(id)
}

/// Set a session's latest reported progress. Unscoped (system-style write,
/// like reapSessionContainerSql) — authorization happens one layer up, at the
/// callback-token check.
pub func updateSessionProgressSql(id: in String, summary: in String, percent: in String): String {
  return "UPDATE sessions SET progress_summary = " + sqlLiteral(summary) + ", progress_percent = " + sqlLiteral(percent) +
    " WHERE id = " +
    sqlLiteral(id)
}

/// Read a session's latest reported progress (summary, percent). Unscoped by
/// user_id like the write above.
pub func selectSessionProgressSql(id: in String): String {
  return "SELECT progress_summary, progress_percent FROM sessions WHERE id = " + sqlLiteral(id)
}

// ─── Permission requests ──────────────────────────────────────────────────────
//
// One row per `request_permission` MCP-tool call: created by the container
// (status 'pending', or already 'allowed' when an allow-always rule matches
// at creation time), polled by the container, and terminally decided either
// by a human's answer or by the host-side timeout backstop (status 'denied',
// fail-closed — docs/phase6-mcp-callbacks.md §3 step 4).
val permissionRequestColumns = "id, session_id, tool_name, input_json, status, updated_input_json, note, created_at, decided_at"

pub func permissionRequestsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS permission_requests (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "tool_name TEXT NOT NULL, " +
    "input_json TEXT NOT NULL, " +
    "status TEXT NOT NULL, " +
    "updated_input_json TEXT NOT NULL DEFAULT '', " +
    "note TEXT NOT NULL DEFAULT '', " +
    "created_at TEXT NOT NULL, " +
    "decided_at TEXT NOT NULL DEFAULT '')"
}

pub func permissionRequestsSessionIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_permission_requests_session_id ON permission_requests(session_id)"
}

/// INSERT a permission request. `status` is 'pending' for a fresh request or
/// 'allowed' when an allow-always rule matched at creation time (in which case
/// the caller also supplies a populated `note`/`decidedAt`).
pub func insertPermissionRequestSql(
  id: in String,
  sessionId: in String,
  toolName: in String,
  inputJson: in String,
  status: in String,
  note: in String,
  createdAt: in String,
  decidedAt: in String,
): String {
  return "INSERT INTO permission_requests (" + permissionRequestColumns + ") VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(sessionId) +
    ", " +
    sqlLiteral(toolName) +
    ", " +
    sqlLiteral(inputJson) +
    ", " +
    sqlLiteral(status) +
    ", '', " +
    sqlLiteral(note) +
    ", " +
    sqlLiteral(createdAt) +
    ", " +
    sqlLiteral(decidedAt) +
    ")"
}

pub func selectPermissionRequestByIdSql(id: in String): String {
  return "SELECT " + permissionRequestColumns + " FROM permission_requests WHERE id = " + sqlLiteral(id)
}

/// SELECT permission requests created for a session strictly after
/// `afterCreatedAt`, oldest first — the poll-loop's "what's new since I last
/// looked" query for SSE emission.
pub func selectPermissionRequestsCreatedAfterSql(sessionId: in String, afterCreatedAt: in String): String {
  return "SELECT " + permissionRequestColumns + " FROM permission_requests WHERE session_id = " + sqlLiteral(sessionId) +
    " AND created_at > " +
    sqlLiteral(afterCreatedAt) +
    " ORDER BY created_at ASC"
}

/// Answer a still-pending request (write-once: only a 'pending' row is
/// updated, so a second answer — or an answer racing the timeout sweep — sees
/// 0 rows affected rather than clobbering the first decision).
pub func answerPermissionRequestSql(
  id: in String,
  status: in String,
  updatedInputJson: in String,
  note: in String,
  decidedAt: in String,
): String {
  return "UPDATE permission_requests SET status = " + sqlLiteral(status) + ", updated_input_json = " +
    sqlLiteral(updatedInputJson) +
    ", note = " +
    sqlLiteral(note) +
    ", decided_at = " +
    sqlLiteral(decidedAt) +
    " WHERE id = " +
    sqlLiteral(id) +
    " AND status = 'pending'"
}

/// Host-side fail-closed timeout backstop: deny a still-pending request once
/// it has been pending at least `timeoutMillis`. Write-once (status = 'pending'
/// guard), so this can be called on every poll with no effect once the request
/// is already decided.
pub func timeoutPendingPermissionRequestSql(id: in String, nowMillis: in String, timeoutMillis: in String): String {
  return "UPDATE permission_requests SET status = 'denied', note = 'timed out waiting for a human response', decided_at = " +
    sqlLiteral(nowMillis) +
    " WHERE id = " +
    sqlLiteral(id) +
    " AND status = 'pending' AND (CAST(" +
    sqlLiteral(nowMillis) +
    " AS INTEGER) - CAST(created_at AS INTEGER)) >= CAST(" +
    sqlLiteral(timeoutMillis) +
    " AS INTEGER)"
}

// ─── Permission rules ("allow always") ───────────────────────────────────────
//
// Session-scoped in v1 (docs/phase6-mcp-callbacks.md §3): an exact (session,
// tool, input) match auto-approves a subsequent identical request without
// prompting again.
pub func permissionRulesSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS permission_rules (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "tool_name TEXT NOT NULL, " +
    "input_json TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "UNIQUE(session_id, tool_name, input_json))"
}

pub func permissionRulesSessionIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_permission_rules_session_id ON permission_rules(session_id)"
}

pub func insertPermissionRuleSql(
  id: in String,
  sessionId: in String,
  toolName: in String,
  inputJson: in String,
  createdAt: in String,
): String {
  return "INSERT INTO permission_rules (id, session_id, tool_name, input_json, created_at) VALUES (" + sqlLiteral(id) +
    ", " +
    sqlLiteral(sessionId) +
    ", " +
    sqlLiteral(toolName) +
    ", " +
    sqlLiteral(inputJson) +
    ", " +
    sqlLiteral(createdAt) +
    ") ON CONFLICT(session_id, tool_name, input_json) DO NOTHING"
}

pub func selectPermissionRuleMatchSql(sessionId: in String, toolName: in String, inputJson: in String): String {
  return "SELECT id FROM permission_rules WHERE session_id = " + sqlLiteral(sessionId) + " AND tool_name = " +
    sqlLiteral(toolName) +
    " AND input_json = " +
    sqlLiteral(inputJson)
}

// ─── User questions ───────────────────────────────────────────────────────────
//
// One row per `ask_user` MCP-tool call: created by the container (status
// 'pending'), polled by the container, and terminally 'answered' by a human or
// 'timed_out' by the host-side backstop (distinct from an empty-string
// answer).
val userQuestionColumns = "id, session_id, question, options_json, status, answer, created_at, decided_at"

pub func userQuestionsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS user_questions (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "question TEXT NOT NULL, " +
    "options_json TEXT NOT NULL DEFAULT '', " +
    "status TEXT NOT NULL, " +
    "answer TEXT NOT NULL DEFAULT '', " +
    "created_at TEXT NOT NULL, " +
    "decided_at TEXT NOT NULL DEFAULT '')"
}

pub func userQuestionsSessionIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_user_questions_session_id ON user_questions(session_id)"
}

pub func insertUserQuestionSql(
  id: in String,
  sessionId: in String,
  question: in String,
  optionsJson: in String,
  createdAt: in String,
): String {
  return "INSERT INTO user_questions (" + userQuestionColumns + ") VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(sessionId) +
    ", " +
    sqlLiteral(question) +
    ", " +
    sqlLiteral(optionsJson) +
    ", 'pending', '', " +
    sqlLiteral(createdAt) +
    ", '')"
}

pub func selectUserQuestionByIdSql(id: in String): String {
  return "SELECT " + userQuestionColumns + " FROM user_questions WHERE id = " + sqlLiteral(id)
}

pub func selectUserQuestionsCreatedAfterSql(sessionId: in String, afterCreatedAt: in String): String {
  return "SELECT " + userQuestionColumns + " FROM user_questions WHERE session_id = " + sqlLiteral(sessionId) +
    " AND created_at > " +
    sqlLiteral(afterCreatedAt) +
    " ORDER BY created_at ASC"
}

pub func answerUserQuestionSql(id: in String, answer: in String, decidedAt: in String): String {
  return "UPDATE user_questions SET status = 'answered', answer = " + sqlLiteral(answer) + ", decided_at = " +
    sqlLiteral(decidedAt) +
    " WHERE id = " +
    sqlLiteral(id) +
    " AND status = 'pending'"
}

pub func timeoutPendingUserQuestionSql(id: in String, nowMillis: in String, timeoutMillis: in String): String {
  return "UPDATE user_questions SET status = 'timed_out', decided_at = " + sqlLiteral(nowMillis) + " WHERE id = " +
    sqlLiteral(id) +
    " AND status = 'pending' AND (CAST(" +
    sqlLiteral(nowMillis) +
    " AS INTEGER) - CAST(created_at AS INTEGER)) >= CAST(" +
    sqlLiteral(timeoutMillis) +
    " AS INTEGER)"
}

// ─── Phase 6 §7: v2 MCP callback tools ──────────────────────────────────────
//
// docs/phase6-mcp-callbacks.md §7. Two new tables: `secret_requests` (the
// request_secret audit trail — name/reason/decision/timestamps only, NEVER
// the credential value) and `artifacts` (report_artifact metadata; the bytes
// themselves live on disk under CloudAgents.Repository.artifactsBaseDir(),
// not in SQLite). Also: a session-owner lookup unscoped by the current
// identity (mirrors selectSessionCallbackTokenSql — a container has no user
// identity of its own) and a credential-existence probe used by
// request_secret's fail-fast validation.
/// Read a session's owning user id by session id ONLY — deliberately
/// unscoped by the current identity, mirroring selectSessionCallbackTokenSql.
/// Used by request_secret's create path (container-originated: the caller's
/// stamped identity is the operator, not the session owner) to resolve whose
/// credential store to check.
pub func selectSessionOwnerIdSql(id: in String): String {
  return "SELECT user_id FROM sessions WHERE id = " + sqlLiteral(id)
}

/// Whether a user has a credential stored under exactly `name`. Used by
/// request_secret's fail-fast validation (docs/phase6 §7.1: "the credential
/// must exist in the session owner's credential store") — cheaper than
/// selectCredentialNamesSql's full alphabetical listing since it only needs
/// existence.
pub func selectCredentialExistsSql(userId: in String, name: in String): String {
  return "SELECT 1 FROM credentials WHERE user_id = " + sqlLiteral(userId) + " AND name = " + sqlLiteral(name) +
    " LIMIT 1"
}

// ─── Secret requests (request_secret) ────────────────────────────────────────
//
// One row per `request_secret` MCP-tool call. Status vocabulary is
// pending/approved/denied/timed_out (docs/phase6 §7.1) — deliberately no
// allow-always rule table (every request prompts). `delivered_at` is NOT
// part of the audit vocabulary; it is a mechanical write-once guard so the
// decrypted value is handed back in the long-poll response at most ONCE
// (docs/phase6 §7.1 step 3) even if the container polls the same request id
// again after a successful delivery.
val secretRequestColumns = "id, session_id, name, reason, status, created_at, decided_at, delivered_at"

pub func secretRequestsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS secret_requests (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "reason TEXT NOT NULL DEFAULT '', " +
    "status TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "decided_at TEXT NOT NULL DEFAULT '', " +
    "delivered_at TEXT NOT NULL DEFAULT '')"
}

pub func secretRequestsSessionIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_secret_requests_session_id ON secret_requests(session_id)"
}

pub func insertSecretRequestSql(
  id: in String,
  sessionId: in String,
  name: in String,
  reason: in String,
  createdAt: in String,
): String {
  return "INSERT INTO secret_requests (" + secretRequestColumns + ") VALUES (" + sqlLiteral(id) + ", " +
    sqlLiteral(sessionId) +
    ", " +
    sqlLiteral(name) +
    ", " +
    sqlLiteral(reason) +
    ", 'pending', " +
    sqlLiteral(createdAt) +
    ", '', '')"
}

pub func selectSecretRequestByIdSql(id: in String): String {
  return "SELECT " + secretRequestColumns + " FROM secret_requests WHERE id = " + sqlLiteral(id)
}

/// Secret requests created for a session strictly after `afterCreatedAt`,
/// oldest first — mirrors selectPermissionRequestsCreatedAfterSql for SSE
/// emission (the `secret_request` event never carries the value, so this is
/// safe to stream unconditionally).
pub func selectSecretRequestsCreatedAfterSql(sessionId: in String, afterCreatedAt: in String): String {
  return "SELECT " + secretRequestColumns + " FROM secret_requests WHERE session_id = " + sqlLiteral(sessionId) +
    " AND created_at > " +
    sqlLiteral(afterCreatedAt) +
    " ORDER BY created_at ASC"
}

/// Answer a still-pending request (write-once: only a 'pending' row is
/// updated). `status` is 'approved' or 'denied' — never a value column.
pub func answerSecretRequestSql(id: in String, status: in String, decidedAt: in String): String {
  return "UPDATE secret_requests SET status = " + sqlLiteral(status) + ", decided_at = " + sqlLiteral(decidedAt) +
    " WHERE id = " +
    sqlLiteral(id) +
    " AND status = 'pending'"
}

/// Host-side fail-closed timeout backstop, mirroring
/// timeoutPendingPermissionRequestSql.
pub func timeoutPendingSecretRequestSql(id: in String, nowMillis: in String, timeoutMillis: in String): String {
  return "UPDATE secret_requests SET status = 'timed_out', decided_at = " + sqlLiteral(nowMillis) + " WHERE id = " +
    sqlLiteral(id) +
    " AND status = 'pending' AND (CAST(" +
    sqlLiteral(nowMillis) +
    " AS INTEGER) - CAST(created_at AS INTEGER)) >= CAST(" +
    sqlLiteral(timeoutMillis) +
    " AS INTEGER)"
}

/// Write-once delivery guard: flips `delivered_at` from '' to `deliveredAt`
/// ONLY for a still-'approved', not-yet-delivered row. A caller that affects
/// 1 row is the FIRST poll to observe the approval and may hand back the
/// decrypted value; 0 rows affected means some earlier poll already
/// delivered it (docs/phase6 §7.1 step 3: "returns the decrypted value
/// ONCE").
pub func markSecretRequestDeliveredSql(id: in String, deliveredAt: in String): String {
  return "UPDATE secret_requests SET delivered_at = " + sqlLiteral(deliveredAt) + " WHERE id = " + sqlLiteral(id) +
    " AND status = 'approved' AND delivered_at = ''"
}

// ─── Artifacts (report_artifact) ─────────────────────────────────────────────
//
// Metadata only — the bytes live on disk (CloudAgents.Repository
// artifactsBaseDir()/<sessionId>/<storedName>). `stored_name` is the
// collision-proof on-disk file name (artifact id + sanitized basename);
// `file_name` is the human-facing sanitized basename used for
// Content-Disposition and listings. `size_bytes` is the decoded byte count,
// stored as TEXT like every other numeric column in this schema.
val artifactColumns = "id, session_id, file_name, stored_name, mime_type, description, size_bytes, created_at"

pub func artifactsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS artifacts (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "file_name TEXT NOT NULL, " +
    "stored_name TEXT NOT NULL, " +
    "mime_type TEXT NOT NULL, " +
    "description TEXT NOT NULL DEFAULT '', " +
    "size_bytes TEXT NOT NULL, " +
    "created_at TEXT NOT NULL)"
}

pub func artifactsSessionIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_artifacts_session_id ON artifacts(session_id)"
}

pub func insertArtifactSql(
  id: in String,
  sessionId: in String,
  fileName: in String,
  storedName: in String,
  mimeType: in String,
  description: in String,
  sizeBytes: in String,
  createdAt: in String,
): String {
  return "INSERT INTO artifacts (" + artifactColumns + ") VALUES (" + sqlLiteral(id) + ", " + sqlLiteral(sessionId) +
    ", " +
    sqlLiteral(fileName) +
    ", " +
    sqlLiteral(storedName) +
    ", " +
    sqlLiteral(mimeType) +
    ", " +
    sqlLiteral(description) +
    ", " +
    sqlLiteral(sizeBytes) +
    ", " +
    sqlLiteral(createdAt) +
    ")"
}

pub func selectArtifactByIdSql(id: in String): String {
  return "SELECT " + artifactColumns + " FROM artifacts WHERE id = " + sqlLiteral(id)
}

/// A session's artifacts, oldest first.
pub func selectArtifactsBySessionSql(sessionId: in String): String {
  return "SELECT " + artifactColumns + " FROM artifacts WHERE session_id = " + sqlLiteral(sessionId) +
    " ORDER BY created_at ASC"
}

/// Artifacts reported for a session strictly after `afterCreatedAt`, oldest
/// first — mirrors selectPermissionRequestsCreatedAfterSql for SSE emission.
pub func selectArtifactsCreatedAfterSql(sessionId: in String, afterCreatedAt: in String): String {
  return "SELECT " + artifactColumns + " FROM artifacts WHERE session_id = " + sqlLiteral(sessionId) +
    " AND created_at > " +
    sqlLiteral(afterCreatedAt) +
    " ORDER BY created_at ASC"
}

// ─── Phase 7: repo-scoped memory (remember / recall) ─────────────────────────
//
// docs/phase7-autonomy.md §4. A key/value store scoped to
// (user_id, repo_key), where repo_key is the normalized host/owner/repo
// identity (CloudAgents.RepoKey), so a later session on the same repo can read
// back what an earlier one learned. `mem_key` avoids SQL's reserved `key`.
/// Read a session's owning user id AND primary repo_url by id ONLY —
/// deliberately unscoped by the current identity, mirroring
/// selectSessionOwnerIdSql. The repo-memory callback endpoints are
/// container-originated (the caller is stamped as the operator, not the
/// session owner), so scoping memory to the owner + the session's repo needs
/// this unscoped lookup.
pub func selectSessionOwnerAndRepoSql(id: in String): String {
  return "SELECT user_id, repo_url FROM sessions WHERE id = " + sqlLiteral(id)
}

val memoryColumns = "id, user_id, repo_key, mem_key, value, created_at, updated_at"

pub func repoMemorySchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS memories (" + "id TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "repo_key TEXT NOT NULL, " +
    "mem_key TEXT NOT NULL, " +
    "value TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL, " +
    "UNIQUE(user_id, repo_key, mem_key))"
}

pub func repoMemoryIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_memories_user_repo ON memories(user_id, repo_key)"
}

/// Atomic capped upsert of one memory entry (#575, #586). A single statement,
/// so the per-repo entry cap is enforced race-free: SQLite serializes writers,
/// and the `WHERE` sub-selects are evaluated against committed state within the
/// one statement. The row is written when EITHER the repo is under `maxEntries`
/// (a new key) OR the key already exists (an overwrite is always allowed and
/// doesn't grow the store); `ON CONFLICT … DO UPDATE` performs the overwrite.
/// created_at is preserved on overwrite (records first-seen time). Affects 1
/// row when written, 0 when the cap blocked a new key.
pub func upsertMemoryCappedSql(
  id: in String,
  userId: in String,
  repoKey: in String,
  memKey: in String,
  value: in String,
  createdAt: in String,
  updatedAt: in String,
  maxEntries: in Int,
): String {
  val scopeClause = "user_id = " + sqlLiteral(userId) + " AND repo_key = " + sqlLiteral(repoKey)
  return "INSERT INTO memories (" + memoryColumns + ") SELECT " + sqlLiteral(id) + ", " + sqlLiteral(userId) + ", " +
    sqlLiteral(repoKey) +
    ", " +
    sqlLiteral(memKey) +
    ", " +
    sqlLiteral(value) +
    ", " +
    sqlLiteral(createdAt) +
    ", " +
    sqlLiteral(updatedAt) +
    " WHERE ((SELECT COUNT(*) FROM memories WHERE " +
    scopeClause +
    ") < " +
    toString(maxEntries) +
    " OR EXISTS(SELECT 1 FROM memories WHERE " +
    scopeClause +
    " AND mem_key = " +
    sqlLiteral(memKey) +
    ")) ON CONFLICT(user_id, repo_key, mem_key) DO UPDATE SET value = " +
    sqlLiteral(value) +
    ", updated_at = " +
    sqlLiteral(updatedAt)
}

/// All memory entries for (user_id, repo_key), ordered by key for stable
/// listing (recall with no key).
pub func selectMemoryBySql(userId: in String, repoKey: in String): String {
  return "SELECT " + memoryColumns + " FROM memories WHERE user_id = " + sqlLiteral(userId) + " AND repo_key = " +
    sqlLiteral(repoKey) +
    " ORDER BY mem_key ASC"
}

/// Delete one memory entry by key (#592, backs the `forget` tool so an entry
/// can be pruned to free a slot under the cap). Affects 1 row when the key
/// existed, 0 otherwise.
pub func deleteMemorySql(userId: in String, repoKey: in String, memKey: in String): String {
  return "DELETE FROM memories WHERE user_id = " + sqlLiteral(userId) + " AND repo_key = " + sqlLiteral(repoKey) +
    " AND mem_key = " +
    sqlLiteral(memKey)
}

// ─── Phase 7 §8: repo-scoped task list (add_task / list_tasks / complete_task)
//
// docs/phase7-autonomy.md §8. Same (user_id, repo_key) scoping as repo
// memory, but with an open/done lifecycle instead of a key/value overwrite:
// `add_task` always inserts a brand-new row (there is no natural unique key
// to conflict on, unlike memory's mem_key), so the capped insert only needs
// the plain "under the cap" WHERE guard, no ON CONFLICT branch. The cap
// counts OPEN tasks only — completing a task frees capacity for a new one,
// since done tasks are history, not backlog.
val taskColumns = "id, user_id, repo_key, description, status, created_at, updated_at"

pub func repoTasksSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS repo_tasks (" + "id TEXT PRIMARY KEY, " + "user_id TEXT NOT NULL, " +
    "repo_key TEXT NOT NULL, " +
    "description TEXT NOT NULL, " +
    "status TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL)"
}

pub func repoTasksIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_repo_tasks_user_repo_status ON repo_tasks(user_id, repo_key, status)"
}

/// Atomic capped insert of a brand-new task, always status 'open' (the cap
/// counts open tasks only — docs/phase7-autonomy.md §8). A single statement
/// so the per-repo OPEN-task cap is enforced race-free, the
/// same technique as upsertMemoryCappedSql: SQLite serializes writers, and
/// the WHERE sub-select is evaluated within the one statement. Simpler than
/// memory's version — there is no existing-key overwrite branch, since every
/// call inserts a distinct new row. Affects 1 row when written, 0 when the
/// cap blocked the insert.
pub func insertTaskCappedSql(
  id: in String,
  userId: in String,
  repoKey: in String,
  description: in String,
  createdAt: in String,
  updatedAt: in String,
  maxOpenTasks: in Int,
): String {
  return "INSERT INTO repo_tasks (" + taskColumns + ") SELECT " + sqlLiteral(id) + ", " + sqlLiteral(userId) + ", " +
    sqlLiteral(repoKey) +
    ", " +
    sqlLiteral(description) +
    ", 'open', " +
    sqlLiteral(createdAt) +
    ", " +
    sqlLiteral(updatedAt) +
    " WHERE (SELECT COUNT(*) FROM repo_tasks WHERE user_id = " +
    sqlLiteral(userId) +
    " AND repo_key = " +
    sqlLiteral(repoKey) +
    " AND status = 'open') < " +
    toString(maxOpenTasks)
}

/// All tasks for (user_id, repo_key), newest first, optionally filtered to a
/// single status. `statusFilter` empty means "all statuses" (list_tasks with
/// no argument).
pub func selectTasksSql(userId: in String, repoKey: in String, statusFilter: in String): String {
  var sql = "SELECT " + taskColumns + " FROM repo_tasks WHERE user_id = " + sqlLiteral(userId) + " AND repo_key = " +
    sqlLiteral(repoKey)
  if statusFilter.length > 0 {
    sql = sql + " AND status = " + sqlLiteral(statusFilter)
  }
  return sql + " ORDER BY created_at DESC"
}

/// A single task, scoped to (id, user_id, repo_key) — used by complete_task
/// to distinguish "not found in this scope" (no row) from "already done"
/// (row present, status already 'done') before attempting the guarded update
/// below, mirroring the 404-on-wrong-scope pattern downloadArtifactHandler
/// uses.
pub func selectTaskByIdScopedSql(id: in String, userId: in String, repoKey: in String): String {
  return "SELECT " + taskColumns + " FROM repo_tasks WHERE id = " + sqlLiteral(id) + " AND user_id = " +
    sqlLiteral(userId) +
    " AND repo_key = " +
    sqlLiteral(repoKey)
}

/// Mark a task done, guarded by `status = 'open'` so a concurrent second
/// completion never double-applies (the same write-once guard shape as
/// answerSecretRequestSql's `WHERE status = 'pending'`). Affects 1 row when
/// this call is the one that flipped it, 0 when it was already done (caller
/// pre-checks existence/scope with selectTaskByIdScopedSql, so a 0 here
/// after that check means a race lost to a concurrent completion — still a
/// success from the caller's point of view, since the task ends up done
/// either way).
pub func completeTaskSql(id: in String, userId: in String, repoKey: in String, updatedAt: in String): String {
  return "UPDATE repo_tasks SET status = 'done', updated_at = " + sqlLiteral(updatedAt) + " WHERE id = " +
    sqlLiteral(id) +
    " AND user_id = " +
    sqlLiteral(userId) +
    " AND repo_key = " +
    sqlLiteral(repoKey) +
    " AND status = 'open'"
}
