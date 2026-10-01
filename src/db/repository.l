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
import Std.File
import CloudAgents.Crypto
import CloudAgents.GraphIngestOutbox
import CloudAgents.Pg
import CloudAgents.Scope
import CloudAgents.Db
import CloudAgents.ToolPolicy
import CloudAgents.Capture
import CloudAgents.Ledger.Schema
import Std.Collections
import extern System.Environment as Env
import extern System.String as DotNetString
import CloudAgents.PgStore
import CloudAgents.PgStore.Credentials
import CloudAgents.PgStore.GraphIngest
import CloudAgents.PgStore.Interactive
import CloudAgents.PgStore.Jobs
import CloudAgents.PgStore.Library
import CloudAgents.PgStore.Messages
import CloudAgents.PgStore.Prompts
import CloudAgents.PgStore.SessionData
import CloudAgents.PgStore.SessionEvents
import CloudAgents.PgStore.TokenCache
import CloudAgents.PgStore.Webhooks

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
  /// 'pending' | 'in_progress' | 'done' (migration 0021). `done` is the
  /// derived two-state view and stays in lockstep.
  pub status: String
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

/// Wall-clock epoch milliseconds as a numeric Long, for callers that compare or
/// subtract timestamps (e.g. the streaming run loop's elapsed-time cap) rather
/// than store them as TEXT.
pub func nowMillisLong(): Long {
  return dtoToUnixMillis(dtoUtcNow())
}

/// Milliseconds since system start, as an `Int` (`System.Environment.
/// TickCount`, NOT the 64-bit `TickCount64`) — deliberately `Int`, not
/// `Long`: a repeated `Long` (Int64) subtract-and-compare in a large/complex
/// function can crash the process with an AccessViolationException (see
/// docs/BUILD.md, docs/lyric/gotchas.md). `TickCount` wraps to negative
/// roughly every 24.9 days of host uptime; acceptable for the short
/// (seconds-to-minutes) wall-clock budgets this is used for — understating a
/// timeout on the rare wraparound is far cheaper than the crash this works
/// around.
///
/// Shared (#863) so every wall-clock-budget caller — `CloudAgents.Docker`'s
/// `waitForContainer`/`streamSessionMessage` and `CloudAgents.Highlights`'s
/// `refreshHighlightsHandler` — binds `System.Environment.get_TickCount`
/// exactly once instead of each package re-declaring its own copy of the
/// same extern binding and safety-margin reasoning.
@externTarget("System.Environment.get_TickCount")
pub func tickCountMs(): Int = 0

extern type CultureInfo = "System.Globalization.CultureInfo"

@externTarget("System.Globalization.CultureInfo.get_InvariantCulture")
func invariantCulture(): CultureInfo = ()

// The (format, provider) overload, so the format is rendered against the
// invariant culture — NOT the process's current culture (#1022). Some cultures
// shape digits (e.g. Arabic-Indic) or otherwise alter numeric output; the
// checkpoint format requires ASCII `YYYY-MM-DDTHH:MM:SSZ`, and this timestamp
// feeds content-addressed ids, so a culture-dependent rendering would be wrong.
@externInstance
@externTarget("System.DateTimeOffset.ToString")
func dtoToStringFmt(t: in DateTimeOffset, format: in String, provider: in CultureInfo): String = ()

/// Wall-clock instant as a strict RFC 3339 UTC second-precision timestamp
/// (`YYYY-MM-DDTHH:MM:SSZ`) — the format the Testamur checkpoint format requires
/// for `Session.startedAt`/`Step.at` (`Model.isRfc3339UtcSeconds`). `dtoUtcNow()`
/// is a UTC `DateTimeOffset`, so the literal `Z` is correct. Rendered against the
/// INVARIANT culture (#1022) so no locale can shape the digits/separators. Shared
/// so the runner (`docker_manager.l`) can stamp a checkpoint's `startedAt` without
/// re-binding the clock. `'T'`/`'Z'` are quoted as literals (both are custom-format
/// letters in .NET and would otherwise be interpreted or throw).
pub func nowRfc3339Utc(): String {
  return dtoToStringFmt(dtoUtcNow(), "yyyy-MM-dd'T'HH:mm:ss'Z'", invariantCulture())
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
pub func parseNatString(s: in String): Int {
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


/// A liveness probe against the database.
pub func ping(): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.ping()
}


/// Append a message to a session's transcript and return the stored record
/// (with its freshly minted id and sequence number).
pub func addMessage(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, role: in String, content: in String
): Result[Message, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.addMessage(sessionId, sc, role, content)
}

/// All messages in a session, oldest first.
pub func listMessages(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[Message], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.listMessages(sessionId, sc)
}

/// Full-text search across every message in the caller's own sessions,
/// newest first. `term` is the user's raw search text: each whitespace-
/// separated word must match as a prefix (CloudAgents.Db.buildFts5MatchExpr
/// turns it into a safe FTS5 MATCH expression). A term with no words
/// matches nothing.
pub func searchMessages(
  sc: in CloudAgents.Pg.TenantScope, term: in String, limit: in Int
): Result[slice[Message], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.searchMessages(sc, term, limit)
}

/// Look up the session that owns a message. Used to bind comments to the
/// correct session without trusting client-supplied sessionId values.
pub func getMessageSessionId(
  messageId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.getMessageSessionId(messageId, sc)
}

/// Attach a comment to a message.
pub func addComment(
  messageId: in String, sc: in CloudAgents.Pg.TenantScope, sessionId: in String, body: in String
): Result[Comment, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.addComment(messageId, sc, sessionId, body)
}

/// All comments on a message, oldest first.
pub func listComments(
  messageId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[Comment], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.listComments(messageId, sc)
}

/// Create a todo / bookmark, optionally anchored to a message (pass "" for a
/// free-standing todo). New todos start 'pending'.
pub func addTodo(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, messageId: in String, note: in String
): Result[Todo, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.addTodo(sessionId, sc, messageId, note)
}

/// Replace a session's plan-ingested todos (source = 'plan') with the
/// agent's latest restated plan, in a SINGLE transaction (#791 — the same
/// delete+insert-multiple shape addPromptWithTags runs transactionally, so
/// a partial failure can never leave the plan half-replaced). `notes` and
/// `statuses` are parallel slices (extra entries in the longer one are
/// ignored); each row is anchored to `messageId`, the agent message the
/// plan was parsed from. Never touches human/tool-created rows (source '').
pub func replacePlanTodos(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  messageId: in String,
  notes: in slice[String],
  statuses: in slice[String],
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.replacePlanTodos(sessionId, sc, messageId, notes, statuses)
}

/// Set a todo's lifecycle status directly (pending/in_progress/done) — the
/// three-state counterpart of toggleTodo. `done` is kept in lockstep by the
/// SQL itself. Validation of the status literal happens in the handlers.
pub func setTodoStatus(
  id: in String, sc: in CloudAgents.Pg.TenantScope, status: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.setTodoStatus(id, sc, status)
}

/// The poll-loop-relevant view of one changed todo, for `todo_update` SSE
/// forwarding — deliberately NOT the full Todo record (and not JSON-generated),
/// so the wire shape shim/frontend already decode stays untouched.
pub record TodoUpdate {
  pub id: String
  pub note: String
  pub status: String
  pub updatedAt: String
}

/// Todos changed strictly after `afterUpdatedAt`, oldest change first —
/// mirrors artifactsCreatedAfter for SSE emission.
pub func todosUpdatedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterUpdatedAt: in String
): Result[slice[TodoUpdate], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.todosUpdatedAfter(sessionId, sc, afterUpdatedAt)
}

/// Look up the session that owns a todo — the container-originated status
/// endpoint verifies the todo belongs to the calling session before mutating
/// it (mirrors getMessageSessionId).
pub func getTodoSessionId(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.getTodoSessionId(id, sc)
}

/// All todos for a session, newest first.
pub func listTodos(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[Todo], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.listTodos(sessionId, sc)
}

/// Flip a todo's done flag.
pub func toggleTodo(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.toggleTodo(id, sc)
}

/// Delete a todo.
pub func deleteTodo(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.deleteTodo(id, sc)
}

/// A (prompt_id, tag) pair, used to attach tags to a whole list of prompts from
/// a single query rather than one lookup per prompt (#246).
pub record PromptTag {
  pub promptId: String
  pub tag: String
}

/// Replace a prompt's tag set atomically (clear, then insert each). Returned by
/// callers through executeTransaction so the set is consistent on partial fail.
pub func setPromptTags(
  promptId: in String, sc: in CloudAgents.Pg.TenantScope, tags: in slice[String]
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Prompts.setPromptTags(promptId, sc, tags)
}

/// Save a new prompt to a user's library and return the stored record (no tags
/// yet). Kept for callers/tests that don't set tags; the handler uses the
/// transactional addPromptWithTags.
pub func addPrompt(
  sc: in CloudAgents.Pg.TenantScope, name: in String, body: in String
): Result[Prompt, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Prompts.addPrompt(sc, name, body)
}

/// Save a new prompt AND its tag set in a single transaction (#244), returning
/// the stored record with tags attached — so the prompt row and its tags are
/// never left inconsistent by a partial failure.
pub func addPromptWithTags(
  sc: in CloudAgents.Pg.TenantScope, name: in String, body: in String, tags: in slice[String]
): Result[Prompt, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Prompts.addPromptWithTags(sc, name, body, tags)
}

/// All prompts in a user's library, alphabetical by name (each with its tags).
pub func listPrompts(sc: in CloudAgents.Pg.TenantScope): Result[slice[Prompt], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Prompts.listPrompts(sc)
}

/// A user's prompts, most-used first (ties alphabetical).
pub func listPromptsByUsage(sc: in CloudAgents.Pg.TenantScope): Result[slice[Prompt], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Prompts.listPromptsByUsage(sc)
}

/// A user's prompts carrying a given tag, alphabetical by name. Each prompt
/// carries its *full* tag set (not just the filter tag). Fetches the matching
/// rows and all tag pairs in two queries rather than a per-prompt getPrompt
/// round trip (#339), reusing the same batching as listPrompts (#246).
pub func listPromptsByTag(
  sc: in CloudAgents.Pg.TenantScope, tag: in String
): Result[slice[Prompt], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Prompts.listPromptsByTag(sc, tag)
}

/// A single prompt owned by a user (with tags), or None.
pub func getPrompt(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Option[Prompt], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Prompts.getPrompt(id, sc)
}

/// Update a prompt's name/body. Returns the number of rows affected (0 when
/// the prompt does not exist or is not owned by the user — the handler maps
/// that to 404).
pub func updatePrompt(
  id: in String, sc: in CloudAgents.Pg.TenantScope, name: in String, body: in String
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Prompts.updatePrompt(id, sc, name, body)
}

/// Update a prompt's name/body AND replace its tag set in one transaction
/// (#244). Returns rows affected on the prompt (0 = not found / not owned) —
/// taken from the transaction's own UPDATE on the prompts row (deliberately
/// the last statement), not from the pre-check below, so a prompt removed by
/// a concurrent request between the pre-check and this transaction correctly
/// reports 0 rather than a stale 1 (same class of gap as #238, fixed the same
/// way here since executeTransaction now returns a rows-affected count).
pub func updatePromptWithTags(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  body: in String,
  tags: in slice[String],
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Prompts.updatePromptWithTags(id, sc, name, body, tags)
}

/// Record one use of a prompt. Returns rows affected (0 = not found).
pub func markPromptUsed(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Prompts.markPromptUsed(id, sc)
}

/// Delete a prompt and its tags in one transaction (#254), consistent with the
/// atomicity standard used for profiles and prompt writes. Returns rows
/// affected on the prompt (0 = not found) — taken from the transaction's own
/// DELETE on the prompts row (deliberately the last statement), not from the
/// pre-check below, for the same reason as deleteProfile (#238).
pub func deletePrompt(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Prompts.deletePrompt(id, sc)
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
  case Db(error: CloudAgents.Db.DbError)
  case Crypto(error: CloudAgents.Crypto.CryptoError)
}

pub func credentialErrorMessage(e: in CredentialError): String {
  return match e {
    case Db(dbErr) -> CloudAgents.Db.dbErrorMessage(dbErr)
    case Crypto(cErr) -> CloudAgents.Crypto.cryptoErrorMessage(cErr)
  }
}

/// Store (or replace) a user's credential, encrypting the value at rest.
pub func putCredential(
  sc: in CloudAgents.Pg.UserScope, name: in String, value: in String
): Result[Unit, CredentialError] {
  return CloudAgents.PgStore.Credentials.putCredential(sc, name, value)
}

/// List a user's credential names (never values).
pub func listCredentialNames(sc: in CloudAgents.Pg.UserScope): Result[slice[CredentialName], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Credentials.listCredentialNames(sc)
}

/// Delete a credential by name. Returns rows affected (0 = not found).
/// Deleting GITHUB_TOKEN also drops any GitHub OAuth refresh-token metadata
/// (#668): otherwise a still-valid refresh token would silently re-vault a
/// fresh GITHUB_TOKEN on the tenant's next request, resurrecting a
/// credential the tenant just deleted. Best-effort — a cleanup failure here
/// must never block the credential deletion itself.
pub func deleteCredential(sc: in CloudAgents.Pg.UserScope, name: in String): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Credentials.deleteCredential(sc, name)
}

/// Whether a user has a credential stored under exactly `name`. Used by
/// request_secret's fail-fast validation (docs/phase6-mcp-callbacks.md
/// §7.1): the create endpoint refuses a request for a name that isn't
/// actually configured, instead of creating a pending row a human could
/// only ever deny.
pub func credentialNameExists(
  sc: in CloudAgents.Pg.UserScope, name: in String
): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Credentials.credentialNameExists(sc, name)
}

/// Decrypt a user's stored credentials for injection into a container
/// environment. Best-effort per credential: a single undecryptable row (a
/// rotated ENCRYPTION_KEY, a tampered value) is skipped with a warning rather
/// than failing the whole batch — otherwise one bad secret would block every
/// future run, including runs that never needed it. A database-read failure
/// (can't reach the store at all) is still fatal.
pub func decryptedCredentials(sc: in CloudAgents.Pg.UserScope): Result[slice[CredentialValue], CredentialError] {
  return CloudAgents.PgStore.Credentials.decryptedCredentials(sc)
}

/// Decrypt a single named credential for server-side use (the CloudAgents.Proxy
/// endpoints call provider APIs with vault keys). Returns Ok(None) when the
/// user has no credential of that name — decided BEFORE any decryption, so a
/// deployment without ENCRYPTION_KEY (or with an unreadable blob) still
/// answers "absent" cleanly for an empty vault instead of erroring. Unlike
/// the injection paths above, a present-but-undecryptable value is an error,
/// not a skip: the caller asked for exactly this credential, so silently
/// treating it as absent would misreport a rotated-key problem as "no key".
pub func decryptedCredentialValue(
  sc: in CloudAgents.Pg.UserScope, name: in String
): Result[Option[String], CredentialError] {
  return CloudAgents.PgStore.Credentials.decryptedCredentialValue(sc, name)
}

// ─── GitHub OAuth token refresh ─────────────────────────────────────────────────
//
// Most GitHub OAuth Apps issue non-expiring user tokens, but ones enrolled in
// GitHub's "expiring user access tokens" feature (common for corporate/
// enterprise-governed OAuth Apps) additionally return a refresh_token,
// expires_in, and refresh_token_expires_in on exchange. A tenant with no row
// here simply has a non-expiring token — the common case is unaffected.
/// A tenant's decoded GitHub OAuth refresh-token status.
pub record GitHubOAuthRefreshStatus {
  pub refreshToken: String
  pub accessTokenExpired: Bool
  pub refreshTokenExpired: Bool
}

/// Store (or replace) a tenant's refresh-token metadata after a successful
/// GitHub OAuth exchange or refresh, encrypting the refresh token at rest.
/// `accessExpiresInSeconds`/`refreshExpiresInSeconds` are GitHub's own
/// `expires_in`/`refresh_token_expires_in` response fields, verbatim.
pub func upsertGitHubOAuthRefresh(
  sc: in CloudAgents.Pg.UserScope,
  refreshToken: in String,
  accessExpiresInSeconds: in String,
  refreshExpiresInSeconds: in String,
): Result[Unit, CredentialError] {
  return CloudAgents.PgStore.Credentials.upsertGitHubOAuthRefresh(sc, refreshToken, accessExpiresInSeconds, refreshExpiresInSeconds)
}

/// Look up a tenant's refresh-token status: the decrypted refresh token plus
/// whether the access token and/or refresh token have expired. Returns
/// Ok(None) for a tenant with no expiring-token metadata (the common case).
pub func githubOAuthRefreshStatus(
  sc: in CloudAgents.Pg.UserScope
): Result[Option[GitHubOAuthRefreshStatus], CredentialError] {
  return CloudAgents.PgStore.Credentials.githubOAuthRefreshStatus(sc)
}

/// Drop a tenant's refresh-token metadata — the refresh token itself expired
/// or GitHub rejected it, so there's no point retrying a dead refresh token
/// on the next request.
pub func deleteGitHubOAuthRefresh(sc: in CloudAgents.Pg.UserScope): Result[Unit, CredentialError] {
  return CloudAgents.PgStore.Credentials.deleteGitHubOAuthRefresh(sc)
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
  pub skillIds: slice[String]
  pub subagentIds: slice[String]
  pub mcpServerIds: slice[String]
  pub toolMode: String
  pub tools: slice[String]
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
pub func profileNetworkPolicy(
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[String, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.profileNetworkPolicy(sc, profileId)
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

/// First `runPreviewMaxLen` characters of a prompt, for the lean run record.
pub func promptPreview(prompt: in String): String {
  if prompt.length <= runPreviewMaxLen {
    return prompt
  }
  return prompt.substring(0, runPreviewMaxLen)
}

/// Record the start of a run (status 'running'), returning the run id so the
/// caller can finish it. Best-effort bookkeeping — a failure here must not stop
/// the actual run, so callers ignore the error and pass "" as the run id.
pub func recordRunStart(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  prompt: in String,
  harness: in String,
  model: in String,
): Result[String, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.recordRunStart(sessionId, sc, prompt, harness, model)
}

/// Move a run to a terminal status ('succeeded' | 'failed' | 'cancelled').
pub func recordRunEnd(
  runId: in String, sc: in CloudAgents.Pg.TenantScope, status: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.recordRunEnd(runId, sc, status)
}

/// Mark every still-'running' run for a session terminal — used when a run ends
/// without the run id in hand (a cancel from another request), so history never
/// strands a phantom 'running' row.
pub func finishSessionRuns(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, status: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.finishSessionRuns(sessionId, sc, status)
}

/// A session's run history, newest first.
pub func listRuns(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[Run], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.listRuns(sessionId, sc)
}

// ─── Session repositories (multi-repo sessions) ─────────────────────────────
//
// Extra git repositories linked to a session beyond its primary repo, so an
// agent can work across several checkouts in one run. Access is always scoped
// through an owner-checked session lookup in the handler layer (the table has
// no user_id of its own), the same indirection comments/todos use.
@generate(Json)
pub record SessionRepo {
  pub id: String
  pub sessionId: String
  pub repoUrl: String
  pub branch: String
  pub createdAt: String
}

@generate(Json)
pub record SessionRepoList {
  pub repos: slice[SessionRepo]
}

/// A session's linked repositories, oldest first.
pub func listSessionRepos(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[SessionRepo], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.listSessionRepos(sessionId, sc)
}

/// How many repositories are linked to a session (for the per-session cap).
pub func countSessionRepos(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.countSessionRepos(sessionId, sc)
}

/// Whether a session already has a repo linked at the given URL (duplicate guard).
pub func sessionRepoUrlExists(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, repoUrl: in String
): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.sessionRepoUrlExists(sessionId, sc, repoUrl)
}

/// Link a repository to a session and return the stored record.
pub func addSessionRepo(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, repoUrl: in String, branch: in String
): Result[SessionRepo, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.addSessionRepo(sessionId, sc, repoUrl, branch)
}

/// Unlink a repository from a session. Returns rows affected (0 = not found).
pub func deleteSessionRepo(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, repoId: in String
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.deleteSessionRepo(sessionId, sc, repoId)
}

/// Remove every repository linked to a session (session-deletion cleanup).
pub func deleteSessionReposForSession(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.deleteSessionReposForSession(sessionId, sc)
}

// ─── Session groups (tree) ───────────────────────────────────────────────────
//
// User-owned, tree-shaped groups sessions can be filed under (migration
// 0029). userId is passed explicitly (the handlers capture
// CloudAgents.Auth.currentUserId()) and scopes every statement; the record
// carries only the wire-shape fields (no userId), matching
// selectSessionGroupsSql's projection.
@generate(Json)
pub record SessionGroup {
  pub id: String
  pub name: String
  pub parentId: String
  pub createdAt: String
}

@generate(Json)
pub record SessionGroupList {
  pub groups: slice[SessionGroup]
}

/// One user's groups, alphabetical by name.
pub func listSessionGroups(sc: in CloudAgents.Pg.TenantScope): Result[slice[SessionGroup], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.listSessionGroups(sc)
}

/// A single group owned by a user, or None (unknown and foreign look the same).
pub func getSessionGroup(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[SessionGroup], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.getSessionGroup(id, sc)
}

/// Create a group and return the stored record.
pub func addSessionGroup(
  sc: in CloudAgents.Pg.TenantScope, name: in String, parentId: in String
): Result[SessionGroup, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.addSessionGroup(sc, name, parentId)
}

/// Full update of a group's name and parent. Returns rows affected (0 = not
/// found / not owned). Parent-chain validation happens in the handler.
pub func updateSessionGroup(
  id: in String, sc: in CloudAgents.Pg.TenantScope, name: in String, parentId: in String
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.updateSessionGroup(id, sc, name, parentId)
}

/// Delete a group, reparenting its child groups AND reassigning its sessions
/// to the deleted group's own parent (`newParentId`, '' when it was a root) —
/// all three statements in ONE transaction so a mid-delete failure can never
/// leave orphaned children pointing at a gone group.
pub func deleteSessionGroupReparenting(
  id: in String, sc: in CloudAgents.Pg.TenantScope, newParentId: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.deleteSessionGroupReparenting(id, sc, newParentId)
}

// ─── Webhooks (transactional outbox) ─────────────────────────────────────────────
//
// Registered target URLs + an outbox of run-completion events. HTTP delivery is
// external (a worker polls listPendingWebhookEvents and marks rows delivered),
// so this layer is pure storage — see CloudAgents.Db for the design note.
@generate(Json)
pub record Webhook {
  pub id: String
  pub userId: String
  pub url: String
  pub createdAt: String
}

@generate(Json)
pub record WebhookList {
  pub webhooks: slice[Webhook]
}

@generate(Json)
pub record WebhookEvent {
  pub id: String
  pub userId: String
  pub sessionId: String
  pub runId: String
  pub status: String
  pub createdAt: String
}

@generate(Json)
pub record WebhookEventList {
  pub events: slice[WebhookEvent]
}

/// Register a webhook target URL (idempotent per (user, url)); returns the
/// actually-persisted record. Because the insert is ON CONFLICT DO NOTHING, a
/// re-registration is a no-op — so we read the row back by (user, url) and
/// return its real id/created_at rather than the freshly-minted ones, which for
/// an already-registered URL would not match any stored row (#255).
pub func addWebhook(sc: in CloudAgents.Pg.TenantScope, url: in String): Result[Webhook, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Webhooks.addWebhook(sc, url)
}

/// A user's registered webhooks, newest first.
pub func listWebhooks(sc: in CloudAgents.Pg.TenantScope): Result[slice[Webhook], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Webhooks.listWebhooks(sc)
}

/// Delete a webhook by id. Returns rows affected (0 = not found).
pub func deleteWebhook(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Webhooks.deleteWebhook(id, sc)
}

/// Whether a user has at least one registered webhook.
pub func userHasWebhooks(sc: in CloudAgents.Pg.TenantScope): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Webhooks.userHasWebhooks(sc)
}

/// Enqueue a run-completion event for delivery — but only when the user has a
/// registered webhook, so the outbox doesn't grow unbounded on a deployment
/// that never configured one (#251). Best-effort bookkeeping: a failure here
/// must not affect the run, so callers ignore the error.
pub func enqueueWebhookEvent(
  sc: in CloudAgents.Pg.TenantScope,
  sessionId: in String,
  runId: in String,
  status: in String,
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Webhooks.enqueueWebhookEvent(sc, sessionId, runId, status)
}

/// A user's undelivered outbox events, oldest first (for the external deliverer).
pub func listPendingWebhookEvents(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[WebhookEvent], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Webhooks.listPendingWebhookEvents(sc)
}

/// Mark an outbox event delivered. Returns rows affected (0 = not found).
pub func markWebhookEventDelivered(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Webhooks.markWebhookEventDelivered(id, sc)
}

/// Save a new profile and its granted credential/skill/subagent/MCP-server
/// sets, returning the stored record.
pub func addProfile(
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  harness: in String,
  networkPolicy: in String,
  credentialMode: in String,
  credentials: in slice[String],
  skillIds: in slice[String],
  subagentIds: in slice[String],
  mcpServerIds: in slice[String],
  toolMode: in String,
  tools: in slice[String],
): Result[Profile, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.addProfile(sc, name, harness, networkPolicy, credentialMode, credentials, skillIds, subagentIds, mcpServerIds, toolMode, tools)
}

/// All of a user's profiles (each with its granted credential names and
/// library-item ids), by name.
pub func listProfiles(sc: in CloudAgents.Pg.TenantScope): Result[slice[Profile], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.listProfiles(sc)
}

/// The id of a user's profile with the given name, or None if the name is
/// free. Used to turn a duplicate name into a 400 instead of a UNIQUE-constraint
/// 500 (#236).
pub func profileIdByName(
  sc: in CloudAgents.Pg.TenantScope, name: in String
): Result[Option[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.profileIdByName(sc, name)
}

/// A single profile owned by a user (with its granted credentials and
/// library-item ids), or None.
pub func getProfile(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[Profile], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.getProfile(id, sc)
}

/// Update a profile's settings and every grant set. Returns rows affected
/// on the profiles row (0 = not found / not owned, mapped to 404 by the handler).
pub func updateProfile(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  harness: in String,
  networkPolicy: in String,
  credentialMode: in String,
  credentials: in slice[String],
  skillIds: in slice[String],
  subagentIds: in slice[String],
  mcpServerIds: in slice[String],
  toolMode: in String,
  tools: in slice[String],
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.updateProfile(id, sc, name, harness, networkPolicy, credentialMode, credentials, skillIds, subagentIds, mcpServerIds, toolMode, tools)
}

/// Delete a profile and every grant set (atomically, #230). Returns rows
/// affected (0 = not found / not owned) — taken from the transaction's own
/// DELETE on the profiles row (deliberately the last statement), not from the
/// pre-check below, so a profile removed by a concurrent request between the
/// pre-check and this transaction correctly reports 0 rather than a stale 1
/// (#238).
pub func deleteProfile(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.deleteProfile(id, sc)
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
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[slice[CredentialValue], CredentialError] {
  return CloudAgents.PgStore.Credentials.decryptedCredentialsForProfile(sc, profileId)
}

/// The CLOUD_AGENTS_ENABLED_TOOLS value to inject for a profile's session,
/// via CloudAgents.ToolPolicy.enabledToolsEnvValue: "" means no restriction
/// (register every tool — the shim's own default).
///
/// Deliberately fails OPEN rather than closed, unlike
/// decryptedCredentialsForProfile above: an empty profileId, an 'all'-mode
/// profile, AND a profile that no longer resolves (deleted after the
/// session was created) all resolve to "" (docs/phase7-autonomy.md §7).
/// Tool enablement is not a hard security boundary in v1 — host-side
/// rejection of a disabled tool's callback endpoint is an explicit
/// follow-up, not this slice — so a dangling profile reference should not
/// silently disable every tool in the session; it should behave exactly
/// like "no profile" instead.
pub func enabledToolsForProfile(
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[String, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.enabledToolsForProfile(sc, profileId)
}

// ─── Library: skills, subagents, MCP servers ───────────────────────────────────
//
// A per-user library of harness-agnostic building blocks, grantable to
// profiles exactly like credentials (profile_skills/profile_subagents/
// profile_mcp_servers mirror profile_credentials). See CloudAgents.Db's
// "Library" section for the field vocabulary. Name/content validation lives
// in CloudAgents.Library (the handler package) — these functions trust an
// already-validated caller, matching addProfile/updateProfile above.
@generate(Json)
pub record Skill {
  pub id: String
  pub userId: String
  pub name: String
  pub description: String
  pub body: String
  pub createdAt: String
  pub updatedAt: String
}

@generate(Json)
pub record SkillList {
  pub skills: slice[Skill]
}

@generate(Json)
pub record Subagent {
  pub id: String
  pub userId: String
  pub name: String
  pub description: String
  pub systemPrompt: String
  pub model: String
  pub createdAt: String
  pub updatedAt: String
}

@generate(Json)
pub record SubagentList {
  pub subagents: slice[Subagent]
}

/// transport: 'stdio' (command + args + env) | 'url' (remote endpoint).
/// enabled: '1' | '0' (TEXT flag, matching AgentSession.isArchived's
/// convention) — '0' means saved but withheld from every profile's
/// container injection (see mcpServersForProfile below), for a server whose
/// required credential/config isn't in place yet.
@generate(Json)
pub record McpServer {
  pub id: String
  pub userId: String
  pub name: String
  pub transport: String
  pub command: String
  pub args: slice[String]
  pub url: String
  pub env: slice[String]
  pub createdAt: String
  pub updatedAt: String
  pub enabled: String = "1"
  // Literal "Name=Value" HTTP header entries — only meaningful for
  // transport 'url' (see CloudAgents.Db.mcpServerHeadersSchemaSql). No
  // default (like `args`/`env` above): every construction site is updated
  // explicitly rather than relying on slice-typed record-field defaults,
  // which have no precedent elsewhere in this codebase.
  pub headers: slice[String]
}

@generate(Json)
pub record McpServerList {
  pub mcpServers: slice[McpServer]
}

/// Save a new skill.
pub func addSkill(
  sc: in CloudAgents.Pg.TenantScope, name: in String, description: in String, body: in String
): Result[Skill, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.addSkill(sc, name, description, body)
}

/// All of a user's skills, by name.
pub func listSkills(sc: in CloudAgents.Pg.TenantScope): Result[slice[Skill], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.listSkills(sc)
}

pub func skillIdByName(
  sc: in CloudAgents.Pg.TenantScope, name: in String
): Result[Option[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.skillIdByName(sc, name)
}

pub func getSkill(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Option[Skill], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.getSkill(id, sc)
}

/// Returns rows affected on the skills row (0 = not found / not owned) — the
/// real count `execute` returns, not a hardcoded 1 (#598, same class of gap
/// as updateProfile/#238): a concurrent delete between the pre-check below
/// and this UPDATE would otherwise still report success.
pub func updateSkill(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  description: in String,
  body: in String,
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.updateSkill(id, sc, name, description, body)
}

/// Delete a skill and every profile grant referencing it (#230-style
/// atomicity — a dangling grant would otherwise silently no-op at injection
/// time, which is harmless, but cleaning it up keeps profile_skills honest).
/// Returns rows affected on the skills row (0 = not found / not owned) —
/// taken from the transaction's own DELETE on the skills row (deliberately
/// the last statement), not from the pre-check below or a hardcoded 1
/// (#598), so a skill removed by a concurrent request between the pre-check
/// and this transaction correctly reports 0.
pub func deleteSkill(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.deleteSkill(id, sc)
}

/// Save a new subagent.
pub func addSubagent(
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  description: in String,
  systemPrompt: in String,
  model: in String,
): Result[Subagent, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.addSubagent(sc, name, description, systemPrompt, model)
}

/// All of a user's subagents, by name.
pub func listSubagents(sc: in CloudAgents.Pg.TenantScope): Result[slice[Subagent], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.listSubagents(sc)
}

pub func subagentIdByName(
  sc: in CloudAgents.Pg.TenantScope, name: in String
): Result[Option[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.subagentIdByName(sc, name)
}

pub func getSubagent(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[Subagent], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.getSubagent(id, sc)
}

/// Returns rows affected on the subagents row (0 = not found / not owned) —
/// the real count `execute` returns, not a hardcoded 1 (#598), matching
/// updateSkill above.
pub func updateSubagent(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  description: in String,
  systemPrompt: in String,
  model: in String,
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.updateSubagent(id, sc, name, description, systemPrompt, model)
}

/// Returns rows affected on the subagents row (0 = not found / not owned) —
/// taken from the transaction's own DELETE on the subagents row (deliberately
/// the last statement), not a hardcoded 1 (#598), matching deleteSkill above.
pub func deleteSubagent(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.deleteSubagent(id, sc)
}

/// Save a new MCP server and its ordered args/env/headers.
pub func addMcpServer(
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  transport: in String,
  command: in String,
  args: in slice[String],
  url: in String,
  env: in slice[String],
  enabled: in String = "1",
  headers: in slice[String] = [],
): Result[McpServer, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.addMcpServer(sc, name, transport, command, args, url, env, enabled, headers)
}

/// All of a user's MCP servers (each with its args/env/headers), by name.
pub func listMcpServers(sc: in CloudAgents.Pg.TenantScope): Result[slice[McpServer], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.listMcpServers(sc)
}

pub func mcpServerIdByName(
  sc: in CloudAgents.Pg.TenantScope, name: in String
): Result[Option[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.mcpServerIdByName(sc, name)
}

pub func getMcpServer(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[McpServer], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.getMcpServer(id, sc)
}

/// Returns rows affected on the mcp_servers row (0 = not found / not owned) —
/// taken from the transaction's own UPDATE on the mcp_servers row
/// (deliberately the LAST statement — see the reordering note below), not a
/// hardcoded 1 (#598).
pub func updateMcpServer(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  transport: in String,
  command: in String,
  args: in slice[String],
  url: in String,
  env: in slice[String],
  enabled: in String = "1",
  headers: in slice[String] = [],
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.updateMcpServer(id, sc, name, transport, command, args, url, env, enabled, headers)
}

/// Returns rows affected on the mcp_servers row (0 = not found / not owned) —
/// taken from the transaction's own DELETE on the mcp_servers row
/// (deliberately the last statement), not a hardcoded 1 (#598).
pub func deleteMcpServer(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.deleteMcpServer(id, sc)
}

/// The skills a profile grants, resolved to full records. Dangling ids
/// (the skill was deleted after being granted) are silently skipped — same
/// tolerance as a stale credential grant name matching nothing at injection
/// time. Empty profileId -> no grants (unlike credentials/network policy,
/// there is no "fall open to everything" for a sessionless/profileless run,
/// since library items are opt-in additions, not access-control scope).
pub func skillsForProfile(
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[slice[Skill], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.skillsForProfile(sc, profileId)
}

/// The subagents a profile grants, resolved to full records. See
/// skillsForProfile for the dangling-id and empty-profile semantics.
pub func subagentsForProfile(
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[slice[Subagent], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.subagentsForProfile(sc, profileId)
}

/// The MCP servers a profile grants, resolved to full records — EXCLUDING
/// any granted server whose `enabled` is '0'. This is the one call site
/// that must filter: CloudAgents.Docker's container-injection path (the
/// only consumer of this function) is the sole place a disabled server
/// could actually reach a running container, so gating here is sufficient
/// on its own (docker/inject-library.sh trusts whatever JSON it's handed
/// completely, with no enabled/disabled concept of its own). getMcpServer/
/// listMcpServers deliberately do NOT filter — the library CRUD UI needs to
/// show a user their disabled servers so they can be edited/enabled, this
/// function's callers is not those callers. See skillsForProfile for the
/// dangling-id and empty-profile semantics, both unchanged here.
pub func mcpServersForProfile(
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[slice[McpServer], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Library.mcpServersForProfile(sc, profileId)
}

// ─── GitHub OAuth token-validation cache ────────────────────────────────────
//
// Successful bearer validations (api.github.com/user round trips) are cached
// for a short TTL, keyed by the token's SHA-256 so the table never stores a
// usable secret. Reads exclude expired rows in SQL (CAST comparison, like the
// warm-reap query); writes opportunistically sweep expired rows first.
/// A cached, still-valid token validation.
pub record GitHubTokenCacheEntry {
  pub userId: String
  pub login: String
}

/// Cache a successful validation. The expired-row sweep is best-effort.
pub func cacheGitHubToken(
  tokenHash: in String, userId: in String, login: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.TokenCache.cacheGitHubToken(tokenHash, userId, login)
}

/// Cache a *denial* briefly — an empty userId marks the entry as negative.
/// Only for tokens GitHub itself rejected (no identity to re-check); a
/// whitelist miss caches the real identity positively instead, so whitelist
/// additions take effect immediately (#429). Blunts repeated presentations
/// of the same bad bearer, which would otherwise each cost an outbound
/// GitHub round trip that blocks a request thread (#425).
pub func cacheGitHubTokenDenied(tokenHash: in String): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.TokenCache.cacheGitHubTokenDenied(tokenHash)
}

/// How many distinct bad bearers are currently negatively cached (i.e. seen
/// within the last minute). The authentication path uses this as a global
/// flood backstop (#425).
pub func activeNegativeGitHubTokens(): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.TokenCache.activeNegativeGitHubTokens()
}

/// Record a GitHub-rejected authorization code (marker login 'oauth-code',
/// so these never count toward the bearer backstop and vice versa — #434).
pub func cacheOAuthCodeRejected(codeHash: in String): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.TokenCache.cacheOAuthCodeRejected(codeHash)
}

/// How many distinct GitHub-rejected authorization codes are in-window (#434).
pub func activeRejectedOAuthCodes(): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.TokenCache.activeRejectedOAuthCodes()
}

/// The still-valid cache entry for a token hash, or None (missing or expired).
pub func cachedGitHubToken(tokenHash: in String): Result[Option[GitHubTokenCacheEntry], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.TokenCache.cachedGitHubToken(tokenHash)
}

/// Look up a token's cache entry even if expired (for identifying the tenant during token refresh).
pub func lookupHistoricalGitHubToken(
  tokenHash: in String
): Result[Option[GitHubTokenCacheEntry], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.TokenCache.lookupHistoricalGitHubToken(tokenHash)
}

/// Look up the GitHub login handle for a given userId from the token cache.
pub func lookupGitHubLoginForUser(userId: in String): Result[String, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.TokenCache.lookupGitHubLoginForUser(userId)
}

/// Server-side logout: delete a token's cache row so the next presentation of
/// that token must revalidate live. Deleting a row that does not exist is
/// still Ok — logout is idempotent.
pub func invalidateGitHubToken(tokenHash: in String): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.TokenCache.invalidateGitHubToken(tokenHash)
}

/// A still-fresh cached listing body for (user, provider), or None.
pub func cachedModelListing(
  sc: in CloudAgents.Pg.UserScope, provider: in String
): Result[Option[String], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Credentials.cachedModelListing(sc, provider)
}

/// Cache a provider's freshly-fetched listing body for a user. Sweeps expired
/// rows first (best-effort), mirroring the token cache's write path (#432).
pub func cacheModelListing(
  sc: in CloudAgents.Pg.UserScope, provider: in String, body: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Credentials.cacheModelListing(sc, provider, body)
}

// ─── Phase 6: MCP callbacks ──────────────────────────────────────────────────
//
// Permission requests / user questions / allow-always rules / progress
// (docs/phase6-mcp-callbacks.md; schema in CloudAgents.Db). Every function
// here is deliberately UNSCOPED by user_id: a container's callback bearer
// token (verified one layer up, in CloudAgents.Callbacks) is the
// authorization, not a user identity the container doesn't have — and the
// human "answer" path derives its ownership check from the parent session
// lookup (CloudAgents.SessionStore.getSession, owner-scoped) before ever
// reaching these functions, the same indirection comments/todos use via
// getMessageSessionId.
@generate(Json)
pub record PermissionRequest {
  pub id: String
  pub sessionId: String
  pub toolName: String
  pub inputJson: String
  pub status: String
  pub updatedInputJson: String
  pub note: String
  pub createdAt: String
  pub decidedAt: String
}

@generate(Json)
pub record UserQuestion {
  pub id: String
  pub sessionId: String
  pub question: String
  pub optionsJson: String
  pub status: String
  pub answer: String
  pub createdAt: String
  pub decidedAt: String
}

@generate(Json)
pub record SessionProgress {
  pub summary: String
  pub percent: String
}

/// Create a permission request. When `preApproved` is true (an allow-always
/// rule already matched this exact (tool, input) pair for the session) the
/// row is created already decided ('allowed', with an explanatory note) so
/// the container's very first poll sees the decision — no prompt round trip.
pub func createPermissionRequest(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  toolName: in String,
  inputJson: in String,
  preApproved: in Bool,
): Result[PermissionRequest, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.createPermissionRequest(sessionId, sc, toolName, inputJson, preApproved)
}

/// A permission request by id, or None.
pub func getPermissionRequest(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[PermissionRequest], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.getPermissionRequest(id, sc)
}

/// Permission requests created for a session strictly after `afterCreatedAt`,
/// oldest first — used by the streaming poll loop to discover new requests to
/// emit as SSE events.
pub func permissionRequestsCreatedAfter(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  afterCreatedAt: in String,
): Result[slice[PermissionRequest], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.permissionRequestsCreatedAfter(sessionId, sc, afterCreatedAt)
}

/// Answer a still-pending permission request. Returns rows affected (0 = not
/// pending anymore — already answered, or already timed out — the handler
/// maps that to 409).
pub func answerPermissionRequest(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  status: in String,
  updatedInputJson: in String,
  note: in String,
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.answerPermissionRequest(id, sc, status, updatedInputJson, note)
}

/// Host-side fail-closed timeout backstop (docs/phase6-mcp-callbacks.md §3
/// step 4): deny a still-pending request once it has been pending at least
/// `timeoutMillis`. Write-once — safe to call on every poll.
pub func timeoutPendingPermissionRequest(
  id: in String, sc: in CloudAgents.Pg.TenantScope, timeoutMillis: in Long
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.timeoutPendingPermissionRequest(id, sc, timeoutMillis)
}

/// Whether an allow-always rule exists for this exact (session, tool, input).
pub func permissionRuleMatches(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  toolName: in String,
  inputJson: in String,
): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.permissionRuleMatches(sessionId, sc, toolName, inputJson)
}

/// Persist an allow-always rule for a (session, tool, input) triple.
/// Idempotent (ON CONFLICT DO NOTHING at the SQL layer).
pub func addPermissionRule(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  toolName: in String,
  inputJson: in String,
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.addPermissionRule(sessionId, sc, toolName, inputJson)
}

/// Create a user question (ask_user MCP tool). `optionsJson` is "" for a
/// free-text question or a JSON array of choices for multiple-choice.
pub func createUserQuestion(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  question: in String,
  optionsJson: in String,
): Result[UserQuestion, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.createUserQuestion(sessionId, sc, question, optionsJson)
}

/// A user question by id, or None.
pub func getUserQuestion(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[UserQuestion], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.getUserQuestion(id, sc)
}

/// User questions created for a session strictly after `afterCreatedAt`,
/// oldest first — mirrors permissionRequestsCreatedAfter for SSE emission.
pub func userQuestionsCreatedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterCreatedAt: in String
): Result[slice[UserQuestion], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.userQuestionsCreatedAfter(sessionId, sc, afterCreatedAt)
}

/// Answer a still-pending question. Returns rows affected (0 = already
/// answered/timed out — the handler maps that to 409).
pub func answerUserQuestion(
  id: in String, sc: in CloudAgents.Pg.TenantScope, answer: in String
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.answerUserQuestion(id, sc, answer)
}

/// Host-side fail-closed timeout backstop for questions: marks a still-pending
/// question 'timed_out' (distinct from an empty-string answer) once it has
/// been pending at least `timeoutMillis`.
pub func timeoutPendingUserQuestion(
  id: in String, sc: in CloudAgents.Pg.TenantScope, timeoutMillis: in Long
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.timeoutPendingUserQuestion(id, sc, timeoutMillis)
}

/// Set a session's latest reported progress (report_progress MCP tool,
/// fire-and-forget).
pub func updateSessionProgress(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  summary: in String,
  percent: in String,
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.updateSessionProgress(sessionId, sc, summary, percent)
}

/// A session's latest reported progress (both fields "" if never reported).
pub func sessionProgress(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[SessionProgress, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.sessionProgress(sessionId, sc)
}

// ─── Phase 6 §7: request_secret ──────────────────────────────────────────────
//
// docs/phase6-mcp-callbacks.md §7.1. `secret_requests` is the audit trail
// itself (name, reason, decision-as-status, timestamps) — there is
// deliberately no column anywhere in this table for the credential value.
// The decrypted value is fetched fresh from CloudAgents.Repository's
// existing encrypted credential store (decryptedCredentialValue) only at
// the moment of first delivery, by CloudAgents.Callbacks, and is never
// passed into or returned from any function in this section.
@generate(Json)
pub record SecretRequest {
  pub id: String
  pub sessionId: String
  pub name: String
  pub reason: String
  pub status: String
  pub createdAt: String
  pub decidedAt: String
}

/// Create a secret request (request_secret MCP tool). Callers must have
/// already verified the named credential exists for the session owner
/// (CloudAgents.Callbacks does this before calling here) — this function
/// itself does not re-check, matching createPermissionRequest/
/// createUserQuestion's division of labor (validation lives one layer up).
pub func createSecretRequest(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, name: in String, reason: in String
): Result[SecretRequest, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.createSecretRequest(sessionId, sc, name, reason)
}

/// A secret request by id, or None.
pub func getSecretRequest(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[SecretRequest], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.getSecretRequest(id, sc)
}

/// Secret requests created for a session strictly after `afterCreatedAt`,
/// oldest first — for the `secret_request` SSE event (name/reason only,
/// never a value, so this is safe to stream unconditionally).
pub func secretRequestsCreatedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterCreatedAt: in String
): Result[slice[SecretRequest], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.secretRequestsCreatedAfter(sessionId, sc, afterCreatedAt)
}

/// Answer a still-pending secret request. `status` is 'approved' or
/// 'denied' — this IS the audit trail's decision column, written once.
/// Returns rows affected (0 = not pending anymore, the handler maps that to
/// 409, mirroring answerPermissionRequest).
pub func answerSecretRequest(
  id: in String, sc: in CloudAgents.Pg.TenantScope, status: in String
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.answerSecretRequest(id, sc, status)
}

/// Host-side fail-closed timeout backstop, mirroring
/// timeoutPendingPermissionRequest.
pub func timeoutPendingSecretRequest(
  id: in String, sc: in CloudAgents.Pg.TenantScope, timeoutMillis: in Long
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.timeoutPendingSecretRequest(id, sc, timeoutMillis)
}

/// Write-once delivery guard (docs/phase6 §7.1 step 3: the decrypted value
/// is returned in the long-poll response AT MOST ONCE). Returns true when
/// THIS call is the one that flips the guard — i.e. the caller may now
/// decrypt and hand back the value; false means some earlier poll already
/// delivered it.
pub func markSecretRequestDelivered(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.markSecretRequestDelivered(id, sc)
}

// ─── Phase 6 §7: report_artifact ─────────────────────────────────────────────
//
// docs/phase6-mcp-callbacks.md §7.3. Metadata only — bytes live on disk
// under artifactsBaseDir()/<sessionId>/<storedName>; CloudAgents.Callbacks
// owns the actual file I/O, this section only owns the DB row.
@generate(Json)
pub record Artifact {
  pub id: String
  pub sessionId: String
  pub fileName: String
  pub storedName: String
  pub mimeType: String
  pub description: String
  pub sizeBytes: String
  pub createdAt: String
  pub repoKey: String
  pub ownerUserId: String
}

/// Base directory for artifact bytes, mirroring CloudAgents.Db.dbPath's
/// override convention: CLOUD_AGENTS_ARTIFACTS_DIR when set, else a relative
/// default in the working directory. Actual files live at
/// `<this>/<sessionId>/<storedName>`. Exported so CloudAgents.Callbacks
/// (which owns the file I/O) and tests share one definition.
pub func artifactsBaseDir(): String {
  val p = Env.GetEnvironmentVariable("CLOUD_AGENTS_ARTIFACTS_DIR")
  if DotNetString.IsNullOrEmpty(p) {
    return "cloud-agents-artifacts"
  }
  return p
}

/// Record an uploaded artifact's metadata (the caller has already written
/// the bytes to disk). `sizeBytes` is the decoded byte count as a decimal
/// string, matching this schema's TEXT-for-numerics convention. `repoKey` is
/// '' for a session-only artifact (today's exact behavior) or the normalized
/// repo identity for a repo-scoped one (docs/phase7-autonomy.md §6);
/// `sessionId` is always the reporting session either way. `ownerUserId` is
/// '' for a session-only artifact (unused — session ownership already
/// covers it) or the reporting session's owner for a repo-scoped one,
/// denormalized so the artifact's ownership survives the reporting session
/// being deleted (#619).
pub func createArtifact(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  fileName: in String,
  storedName: in String,
  mimeType: in String,
  description: in String,
  sizeBytes: in String,
  repoKey: in String,
  ownerUserId: in String,
): Result[Artifact, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.createArtifact(sessionId, sc, fileName, storedName, mimeType, description, sizeBytes, repoKey, ownerUserId)
}

/// An artifact by id, or None.
pub func getArtifact(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[Artifact], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.getArtifact(id, sc)
}

/// A session's artifacts, oldest first.
pub func listArtifacts(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[Artifact], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.listArtifacts(sessionId, sc)
}

/// A repo's durable artifacts for ONE user, oldest first
/// (docs/phase7-autonomy.md §6). Scoped by (user_id, repo_key) — never by
/// repo_key alone, since repoKeys derive from public git URLs and are not
/// secret.
pub func listRepoArtifacts(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String
): Result[slice[Artifact], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.listRepoArtifacts(sc, repoKey)
}

/// A single repo-scoped artifact by id, owner-scoped by `owner_user_id`
/// (#619) — never by the reporting session, so this survives that session
/// being deleted. Backs the session-independent repo-artifact download
/// route; returns None for an unknown id, a session-scoped artifact, or one
/// owned by a different user.
pub func getRepoArtifactById(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[Artifact], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.getRepoArtifactById(id, sc)
}

// ─── Session attachments (chat uploads) ──────────────────────────────────────
//
// Metadata only — bytes live on disk under
// attachmentsBaseDir()/<sessionId>/<storedName>; CloudAgents.Handlers owns
// the actual file I/O (mirrors the Phase 6 §7 artifacts section above, the
// same split but for container-reported output rather than user input).
// `messageId` is '' until linkAttachmentToMessage sets it, right after the
// user message row is created — an upload is validated and written to disk
// BEFORE the message exists, so the message id can't be known at insert time.
@generate(Json)
pub record Attachment {
  pub id: String
  pub sessionId: String
  pub messageId: String
  pub fileName: String
  pub storedName: String
  pub mimeType: String
  /// 'image' or 'document', derived from mimeType at upload time.
  pub kind: String
  pub sizeBytes: String
  pub createdAt: String
}

/// Base directory for uploaded attachment bytes, mirroring artifactsBaseDir's
/// override convention: CLOUD_AGENTS_ATTACHMENTS_DIR when set, else a
/// relative default in the working directory. Actual files live at
/// `<this>/<sessionId>/<storedName>`. Exported so CloudAgents.Handlers (which
/// owns the file I/O) and CloudAgents.Docker (which bind-mounts a session's
/// directory into the runner container) share one definition.
pub func attachmentsBaseDir(): String {
  val p = Env.GetEnvironmentVariable("CLOUD_AGENTS_ATTACHMENTS_DIR")
  if DotNetString.IsNullOrEmpty(p) {
    return "cloud-agents-attachments"
  }
  return p
}

/// Record an uploaded attachment's metadata (the caller has already written
/// the bytes to disk). `sizeBytes` is the decoded byte count as a decimal
/// string, matching this schema's TEXT-for-numerics convention. `messageId`
/// starts '' — linkAttachmentToMessage sets it once the user message this
/// attachment was sent with has been persisted.
pub func createAttachment(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  fileName: in String,
  storedName: in String,
  mimeType: in String,
  kind: in String,
  sizeBytes: in String,
): Result[Attachment, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.createAttachment(sessionId, sc, fileName, storedName, mimeType, kind, sizeBytes)
}

/// Link a stored attachment to the user message it was sent with.
/// Best-effort from the caller's perspective (streamSendMessage tolerates a
/// failure here the same way it tolerates addMessage failing) — a missed
/// link only means the attachment won't show up grouped under its message in
/// the transcript; it still lists under the session and its bytes are
/// already safely on disk.
pub func linkAttachmentToMessage(
  id: in String, sc: in CloudAgents.Pg.TenantScope, messageId: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.linkAttachmentToMessage(id, sc, messageId)
}

/// An attachment by id, or None.
pub func getAttachment(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[Attachment], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.getAttachment(id, sc)
}

/// Remove one attachment row by id. Best-effort rollback helper for
/// storeAttachments' pass-2 partial-failure cleanup (#1003) — not used on any
/// normal (non-error) path, so callers ignore the Result (`val _ = ...`)
/// exactly as this codebase's other best-effort cleanup calls do.
pub func deleteAttachment(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.deleteAttachment(id, sc)
}

/// A session's attachments, oldest first.
pub func listAttachments(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[Attachment], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.listAttachments(sessionId, sc)
}

// ─── Phase 7: repo-scoped memory (remember / recall) ─────────────────────────
//
// docs/phase7-autonomy.md §4. Memory is scoped to (user_id, repo_key); the
// callback handler resolves both from the session (owner + normalized
// repo_url) before calling in here.
/// A session's owning user id + primary repo_url, resolved together for the
/// container-originated memory endpoints (unscoped by current identity).
pub record SessionOwnerRepo {
  pub userId: String
  pub repoUrl: String
}

pub func sessionOwnerAndRepo(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[SessionOwnerRepo], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.sessionOwnerAndRepo(id, sc)
}

/// One stored memory entry (the API-relevant columns of a `memory` row).
pub record MemoryRecord {
  pub memKey: String
  pub value: String
  pub updatedAt: String
}

/// Upsert a memory entry under a per-repo entry cap, atomically (#575, #586).
/// Overwriting an existing key is always allowed (it doesn't grow the store);
/// a NEW key is written only while the repo holds fewer than `maxEntries`.
/// created_at is preserved on overwrite. Returns true when the entry was
/// written, false when the cap blocked a new key — race-free, since the whole
/// decision is a single serialized SQLite statement, not a check-then-act.
pub func upsertMemoryCapped(
  sc: in CloudAgents.Pg.TenantScope,
  repoKey: in String,
  memKey: in String,
  value: in String,
  maxEntries: in Int,
): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.upsertMemoryCapped(sc, repoKey, memKey, value, maxEntries)
}

/// All memory entries for (user, repo), key-ordered.
pub func listMemory(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String
): Result[slice[MemoryRecord], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.listMemory(sc, repoKey)
}

/// Single memory entry lookup by exact (user, repo, key) (#590). Returns
/// None when no such key exists in the repo's store. Backs a keyed
/// `recall(key)` with a targeted row fetch instead of `listMemory` + a
/// client-side filter.
pub func getMemory(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String, memKey: in String
): Result[Option[MemoryRecord], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.getMemory(sc, repoKey, memKey)
}

/// Delete a memory entry by key (#592). Returns true when a row was removed,
/// false when no entry existed under that key.
pub func deleteMemory(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String, memKey: in String
): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.deleteMemory(sc, repoKey, memKey)
}

/// Artifacts reported for a session strictly after `afterCreatedAt`, oldest
/// first — for the `artifact_reported` SSE event.
pub func artifactsCreatedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterCreatedAt: in String
): Result[slice[Artifact], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.artifactsCreatedAfter(sessionId, sc, afterCreatedAt)
}

// ─── Phase 7 §8: repo-scoped task list (add_task / list_tasks / complete_task)
//
// docs/phase7-autonomy.md §8. A cross-session, repo-scoped worklist with an
// open->done lifecycle, distinct from the session ledger's per-session work
// items (docs/session-ledger.md): this is an agent-completable
// shared backlog scoped to (user_id, repo_key), reusing sessionOwnerAndRepo
// and CloudAgents.RepoKey exactly as the memory slice does.
/// One stored task (the API-relevant columns of a `repo_tasks` row).
pub record RepoTask {
  pub id: String
  pub description: String
  pub status: String
  pub createdAt: String
  pub updatedAt: String
}

/// The outcome of a capped task creation: whether a new row was actually
/// written (false = the open-task cap blocked it), and the id that was (or
/// would have been) minted — a record rather than a tuple since this crosses
/// the CloudAgents.Callbacks package boundary (idioms: named records over
/// tuples for pub functions).
pub record AddTaskResult {
  pub created: Bool
  pub id: String
}

/// Create a brand-new OPEN task under a per-repo OPEN-task entry cap,
/// atomically (mirrors upsertMemoryCapped, but simpler: there is no existing
/// key to overwrite, every call is a fresh row). The cap counts only
/// currently-open tasks, so completing a task frees capacity for a new one.
pub func addTaskCapped(
  sc: in CloudAgents.Pg.TenantScope,
  repoKey: in String,
  description: in String,
  maxOpenTasks: in Int,
): Result[AddTaskResult, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.addTaskCapped(sc, repoKey, description, maxOpenTasks)
}

/// All tasks for (user, repo), newest first. `statusFilter` None/empty means
/// every status; Some("open")/Some("done") filters to just that status.
pub func listTasks(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String, statusFilter: in Option[String]
): Result[slice[RepoTask], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.listTasks(sc, repoKey, statusFilter)
}

/// The result of attempting to complete a task: whether it existed in this
/// exact (user, repo) scope at all, and if so, whether this call is the one
/// that flipped it to done (as opposed to it already being done — a
/// no-op success per complete_task's idempotency contract, docs/phase7 §8).
pub union CompleteTaskOutcome {
  case TaskNotFound
  case TaskAlreadyDone
  case TaskCompleted
}

/// Mark a task done. Looks the task up scoped to (userId, repoKey) FIRST, so
/// a task id that exists but belongs to a different scope reports
/// TaskNotFound exactly like a genuinely absent id (no scope leak, mirroring
/// downloadArtifactHandler's session-scope check) — then applies a
/// write-once guarded UPDATE (status = 'open' in the WHERE clause) so a
/// concurrent second completion can never double-apply.
pub func completeTask(
  sc: in CloudAgents.Pg.TenantScope, repoKey: in String, taskId: in String
): Result[CompleteTaskOutcome, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.completeTask(sc, repoKey, taskId)
}

// ─── Phase 7 §5: notify ─────────────────────────────────────────────────────────
//
// docs/phase7-autonomy.md §5. A fire-and-forget push a container sends the
// human at a milestone (done/blocked/needs input). Session-scoped, unlike
// memory — notify has no repo-scoping story in v1.
pub record Notification {
  pub id: String
  pub sessionId: String
  pub level: String
  pub summary: String
  pub createdAt: String
  pub readAt: String
}

/// Record a fire-and-forget notification for a session.
pub func createNotification(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  level: in String,
  summary: in String,
): Result[Notification, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.createNotification(sessionId, sc, level, summary)
}

/// A session's notifications, newest first — for the UI feed.
pub func listNotifications(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[Notification], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.listNotifications(sessionId, sc)
}

/// Notifications for a session strictly after `afterCreatedAt`, oldest
/// first — for the `notification` SSE event, mirroring artifactsCreatedAfter.
pub func notificationsCreatedAfter(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterCreatedAt: in String
): Result[slice[Notification], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Interactive.notificationsCreatedAfter(sessionId, sc, afterCreatedAt)
}

// ─── Session highlights ─────────────────────────────────────────────────────────
//
// Migration 0022: notable items an operator-configured summarizer model
// extracted from agent responses (discoveries, issues, workarounds, reverts,
// incomplete work) — see CloudAgents.Highlights. `highlight_scans` tracks the
// highest transcript seq already scanned per session so a refresh only ever
// summarizes new agent messages.
/// One stored highlight row.
@generate(Json)
pub record Highlight {
  pub id: String
  pub sessionId: String
  pub messageId: String
  pub kind: String
  pub title: String
  pub detail: String
  pub createdAt: String
}

@generate(Json)
pub record HighlightList {
  pub highlights: slice[Highlight]
}

/// Store one extracted highlight, anchored to the agent message it came from.
pub func addHighlight(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  messageId: in String,
  kind: in String,
  title: in String,
  detail: in String,
): Result[Highlight, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.addHighlight(sessionId, sc, messageId, kind, title, detail)
}

/// A session's highlights, newest first.
pub func listHighlights(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[slice[Highlight], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.listHighlights(sessionId, sc)
}

/// The highest transcript seq already scanned for highlights, or "" when the
/// session has never been scanned.
pub func highlightScanSeq(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[String, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.highlightScanSeq(sessionId, sc)
}

/// Record the highest transcript seq scanned for highlights.
pub func setHighlightScanSeq(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, lastSeq: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.setHighlightScanSeq(sessionId, sc, lastSeq)
}

/// Append a session's captured events in one transaction (all-or-nothing, so a
/// stored chain never has a hole). Inserts are `INSERT OR IGNORE` on
/// `(session_id, seq)`, so re-appending an already-stored prefix that is
/// byte-identical (a resumed or retried capture) is an idempotent no-op.
/// Returns the number of events *submitted* (`events.length`) — because
/// `INSERT OR IGNORE` silently skips a row already present, this is the
/// submitted count, not necessarily the count newly inserted (query back with
/// `sessionEventsAfterSeq` for the stored set).
///
/// Tamper-evidence boundary (#965): before inserting anything, the incoming
/// batch's seq range is compared against what is already stored for those
/// seqs. If any already-stored `(session_id, seq)` carries a DIFFERENT
/// `payload`/`hash` than the incoming event for that same seq, the whole batch
/// is rejected as `ValidationFailed` — no partial insert — rather than
/// silently discarding the divergent content via `INSERT OR IGNORE`. This
/// keeps the store from masking a genuine tamper/corruption signal (or a bug
/// elsewhere producing a divergent re-parse) behind the "idempotent no-op"
/// path, which is meant for byte-identical retries only. A caller that
/// legitimately needs to replace stored events (not just append/retry) must go
/// through some other, explicit path — this accessor never overwrites.
pub func appendSessionEvents(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  events: in slice[CloudAgents.Capture.CaptureEvent],
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionEvents.appendSessionEvents(sessionId, sc, events)
}

/// A session's captured events with seq strictly greater than `afterSeq`,
/// oldest first — decoded back into CaptureEvents so a reader can
/// `CloudAgents.Capture.verifyChain` them. Pass "" for "from the beginning":
/// CaptureEvent seq starts at 0, so the empty cursor maps to the sentinel "-1"
/// (`seq > -1` includes seq 0), NOT "0" (which, as a real `after=0` cursor,
/// excludes the first event).
pub func sessionEventsAfterSeq(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterSeq: in String
): Result[slice[CloudAgents.Capture.CaptureEvent], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionEvents.sessionEventsAfterSeq(sessionId, sc, afterSeq)
}

/// A session's captured events in the window `fromExclusive < seq <=
/// toInclusive` (bounded to 500), ascending — for ledger transcript excerpts.
pub func sessionEventsInRange(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  fromExclusive: in String,
  toInclusive: in String,
): Result[slice[CloudAgents.Capture.CaptureEvent], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionEvents.sessionEventsInRange(sessionId, sc, fromExclusive, toInclusive)
}

/// The highest captured event seq for a session, or "" when nothing has been
/// captured yet — the transcript position a ledger entry is anchored to.
/// Up to `limit` captured events after `afterSeq`, oldest first: one
/// observer window's worth, without loading the whole session.
pub func sessionEventsAfterSeqLimited(
  sessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  afterSeq: in String,
  limit: in Int,
): Result[slice[CloudAgents.Capture.CaptureEvent], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionEvents.sessionEventsAfterSeqLimited(sessionId, sc, afterSeq, limit)
}

pub func latestSessionEventSeq(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[String, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionEvents.latestSessionEventSeq(sessionId, sc)
}

/// The hash-chain cursor a fresh run's capture must resume from: one past the
/// highest stored seq, and that highest event's own hash (the `prevHash` the
/// next captured event must chain from). Defaults to (0, "") — a fresh
/// chain's start — when the session has no captured events yet.
pub record SessionEventCursor {
  pub nextSeq: Long = 0.toLong()
  pub lastHash: String = ""
}

/// The cursor `docker_manager.l`'s `streamSessionMessage` must seed `nextSeq`/
/// `lastHash` from at the start of EVERY run against a session, not just its
/// first: each run parses its OWN container's log from byte 0, but
/// `session_events` accumulates across every run for the session, so
/// restarting the hash chain at (0, "") on the second and later runs collides
/// with the first run's already-stored seq 0.. and `appendSessionEvents`'
/// tamper-evidence check (#965) rejects the whole batch as a content
/// mismatch, silently dropping that run's capture provenance.
pub func latestSessionEventCursor(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope
): Result[SessionEventCursor, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionEvents.latestSessionEventCursor(sessionId, sc)
}

/// A session's agent messages with a sequence number above `afterSeq`.
pub func agentMessagesAfterSeq(
  sessionId: in String, sc: in CloudAgents.Pg.TenantScope, afterSeq: in String
): Result[slice[Message], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Messages.agentMessagesAfterSeq(sessionId, sc, afterSeq)
}

// ─── Phase 8: scheduled jobs (docs/phase8-scheduling.md) ────────────────────
//
// A job pairs a prompt + optional profile with either a one-shot run time, a
// recurring interval, or both. `sessionId` starts empty; the first trigger
// creates a session (or, for a job an in-container schedule_job call
// created, attaches the calling session immediately) and every later trigger
// continues that same session, so the agent's work accumulates across runs.
pub record ScheduledJob {
  pub id: String
  pub userId: String
  pub name: String
  pub prompt: String
  pub profileId: String
  pub repoUrl: String
  pub branch: String
  pub harness: String
  pub model: String
  pub runAt: String
  pub intervalSeconds: String
  pub nextRunAt: String
  pub lastRunAt: String
  pub sessionId: String
  pub status: String
  pub createdAt: String
}

/// Create a new job owned by the caller. `nextRunAt` is `runAt` when a
/// one-shot/start time was given, else "now" (a pure-interval job fires on
/// the very next poll tick, then recurs from there).
pub func createScheduledJob(
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  prompt: in String,
  profileId: in String,
  repoUrl: in String,
  branch: in String,
  harness: in String,
  model: in String,
  runAt: in String,
  intervalSeconds: in String,
): Result[ScheduledJob, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Jobs.createScheduledJob(sc, name, prompt, profileId, repoUrl, branch, harness, model, runAt, intervalSeconds)
}

/// Create a new job with `sessionId` already attached, atomically — used
/// only by the schedule_job MCP callback, which always attaches the calling
/// session immediately. Doing the insert and the attach in one transaction
/// closes a race (#877): a pure-interval job is due at once, so a two-step
/// insert-then-attach could let a concurrent trigger poll claim the job and
/// attach a different, freshly created session in the gap.
pub func createScheduledJobWithSession(
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  prompt: in String,
  runAt: in String,
  intervalSeconds: in String,
  sessionId: in String,
): Result[ScheduledJob, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Jobs.createScheduledJobWithSession(sc, name, prompt, runAt, intervalSeconds, sessionId)
}

/// One of the caller's jobs, or None (unknown id or foreign owner — both
/// look identical to the caller, mirroring getProfile).
pub func getScheduledJob(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[ScheduledJob], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Jobs.getScheduledJob(id, sc)
}

/// All of the caller's jobs, newest first.
pub func listScheduledJobs(sc: in CloudAgents.Pg.TenantScope): Result[slice[ScheduledJob], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Jobs.listScheduledJobs(sc)
}

/// A job this caller claimed to fire (docs/phase11-postgres-tenancy.md
/// §5.3a). The claim has already stamped the row's `last_run_at` with
/// `claimedAt` and advanced its schedule (`claimedNextRunAt`, "" for a
/// one-shot, which the claim also marked `completed`), so no other caller can
/// fire the same slot and nothing needs recording after the run. `job` is the
/// row as it was just before the claim: its `nextRunAt` is the slot it was
/// due at. `tenantScope` is the job owner's scope in the job's tenant; the
/// whole run happens in it.
pub record ClaimedJob {
  pub tenantScope: CloudAgents.Pg.TenantScope
  pub job: ScheduledJob
  pub claimedAt: String
  pub claimedNextRunAt: String
  pub claimedStatus: String
}

/// Claim up to `limit` due jobs across every tenant, earliest-due first. Each
/// claim is a conditional UPDATE (claimDueScheduledJobSql), so overlapping
/// trigger polls never fire the same slot twice. A run that is interrupted
/// (the instance dies) is not re-fired: its slot is already advanced.
pub func claimDueScheduledJobs(limit: in Int): Result[slice[ClaimedJob], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Jobs.claimDueScheduledJobs(limit)
}

/// Undo a claim whose run was skipped (its session was busy), so the slot is
/// retried on the next poll. A no-op if the row changed since the claim (an
/// edit, pause or cancel), which then stands.
pub func releaseScheduledJobClaim(c: in ClaimedJob): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Jobs.releaseScheduledJobClaim(c)
}

/// Attach a session to a job on its first run (or immediately, for a job an
/// in-container schedule_job call created for its own calling session) — a
/// no-op if the job already has one (attachScheduledJobSessionSql's guard).
pub func attachScheduledJobSession(
  id: in String, sc: in CloudAgents.Pg.TenantScope, sessionId: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Jobs.attachScheduledJobSession(id, sc, sessionId)
}

/// Update one of the caller's jobs. Returns the affected row count (0 means
/// no such job under this owner). `writeNextRunAt` (#891) controls whether
/// `next_run_at` is written at all: an ordinary edit that doesn't touch the
/// schedule passes `false`, so it can't write back a stale slot over one a
/// concurrent claim just advanced.
pub func updateScheduledJob(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  prompt: in String,
  profileId: in String,
  runAt: in String,
  intervalSeconds: in String,
  nextRunAt: in String,
  status: in String,
  writeNextRunAt: in Bool,
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Jobs.updateScheduledJob(id, sc, name, prompt, profileId, runAt, intervalSeconds, nextRunAt, status, writeNextRunAt)
}

/// Delete one of the caller's jobs. Returns the affected row count.
pub func deleteScheduledJob(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.Jobs.deleteScheduledJob(id, sc)
}

// ─── Chat Thread Branching ────────────────────────────────────────────────────
record IdMapEntry {
  pub oldId: String
  pub newId: String
}

pub func copyFileIfExists(sourcePath: in String, targetDir: in String, targetPath: in String): Unit {
  match Std.File.readBytes(sourcePath) {
    case Ok(b) -> {
      match Std.File.createDir(targetDir) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }
      match Std.File.writeBytes(targetPath, b) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }
    }
    case Err(_) -> ()
  }
}

/// Branch an existing session from a specified message turn into a new child session.
/// Copies transcript messages up to the chosen message (or all if forkedMessageId is empty),
/// creates new message IDs while preserving sequence numbers, and clones anchored comments,
/// attachments (with disk files), todos, highlights, linked repos, and profile settings.
pub func branchSession(
  parentSessionId: in String,
  forkedMessageId: in String,
  newSessionId: in String,
  sc: in CloudAgents.Pg.TenantScope,
  newBranch: in String,
): Result[Unit, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.SessionData.branchSession(parentSessionId, forkedMessageId, newSessionId, sc, newBranch)
}

// ─── Graph ingest outbox (docs/capture-ingest-outbox.md) ────────────────────
//
// Durable, at-least-once storage for the runner's provenance-object POST to
// the platform's graph service, replacing the old fire-and-forget send.
// `CloudAgents.GraphIngestDrain` (src/handlers/graph_ingest_drain.l) is the
// only caller of the write accessors below — this layer is pure storage,
// same division as the webhook outbox above.
/// One durable outbox row: a session's emitted graph-ingest body, its
/// delivery destination, and its retry state.
@generate(Json)
pub record GraphIngestOutboxRow {
  pub id: String
  pub sessionId: String
  pub body: String
  pub url: String
  pub createdAt: String
  pub attempts: String
  pub nextAttemptAt: String
  pub lastError: String
  pub deliveredAt: String
}

/// A row a drain has claimed, with the scope its outcome is recorded under.
pub record ClaimedGraphIngest {
  pub tenantScope: CloudAgents.Pg.TenantScope
  pub row: GraphIngestOutboxRow
}

/// Enqueue a session's emitted ingest body for durable delivery. Idempotent
/// per (sessionId, body) — a byte-identical re-enqueue (e.g. a retried
/// `emitRunnerCheckpoint` reproducing the same mapped objects) returns the
/// EXISTING row (whatever its current attempts/delivered state actually is)
/// rather than minting a duplicate, mirroring `addWebhook`'s
/// insert-then-read-back-by-natural-key idiom for an `ON CONFLICT DO NOTHING`
/// insert. The caller (`CloudAgents.GraphIngestDrain.enqueueAndAttemptDelivery`)
/// then claims the row before its immediate delivery attempt, so an
/// already-delivered or mid-backoff row is never re-POSTed early.
pub func enqueueGraphIngest(
  sessionId: in String, body: in String, url: in String, sc: in CloudAgents.Pg.TenantScope
): Result[GraphIngestOutboxRow, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.GraphIngest.enqueueGraphIngest(sessionId, body, url, sc)
}

/// One row by id, or None.
pub func getGraphIngest(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[GraphIngestOutboxRow], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.GraphIngest.getGraphIngest(id, sc)
}

/// Claim one row for an immediate delivery attempt: true when the row is
/// undelivered, due and not held by another claim, in which case the caller
/// now holds it for `CloudAgents.GraphIngestOutbox.leaseSeconds`
/// (docs/phase11-postgres-tenancy.md §5.3a).
pub func claimGraphIngest(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Bool, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.GraphIngest.claimGraphIngest(id, sc)
}

/// Claim up to `limit` due rows across every user, earliest-due first. Each
/// claimed row is held for `leaseSeconds` (see
/// `CloudAgents.GraphIngestOutbox.drainLeaseSeconds`): no
/// other drain or immediate attempt takes it until its outcome is recorded
/// or the lease runs out, so a drain that dies mid-row leaves it for a later
/// one. Each row carries its session owner's scope.
pub func claimDueGraphIngest(
  limit: in Int, leaseSeconds: in Int
): Result[slice[ClaimedGraphIngest], CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.GraphIngest.claimDueGraphIngest(limit, leaseSeconds)
}

/// Record a retryable delivery failure: bump `attempts` to the caller-computed
/// new count, store the (already-bounded) error, and schedule the next
/// attempt at `nowMillisStr + delayMillis` (computed in SQL — see
/// `updateGraphIngestOutboxAttemptSql`'s doc comment), releasing the claim.
/// Returns rows affected (0 if the row was concurrently delivered or no
/// longer exists).
pub func markGraphIngestAttempt(
  id: in String,
  newAttempts: in String,
  error: in String,
  nowMillisStr: in String,
  delayMillis: in Int,
  sc: in CloudAgents.Pg.TenantScope,
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.GraphIngest.markGraphIngestAttempt(id, newAttempts, error, nowMillisStr, delayMillis, sc)
}

/// Record that a row has exhausted its retry budget: bump `attempts`, store
/// the terminal-labelled error, and exclude it from every later claim.
/// Returns rows affected.
pub func markGraphIngestTerminal(
  id: in String,
  newAttempts: in String,
  error: in String,
  sc: in CloudAgents.Pg.TenantScope,
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.GraphIngest.markGraphIngestTerminal(id, newAttempts, error, sc)
}

/// Mark a row delivered. Returns rows affected (0 = already delivered by a
/// concurrent drain, or the row no longer exists).
pub func markGraphIngestDelivered(
  id: in String, deliveredAt: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.GraphIngest.markGraphIngestDelivered(id, deliveredAt, sc)
}

/// Delete delivered rows older than `retentionDays`, across every user.
/// Returns rows deleted. Best-effort housekeeping — a caller
/// (`CloudAgents.GraphIngestDrain`) runs this on every drain call and doesn't
/// fail the drain if it errors.
pub func pruneDeliveredGraphIngest(retentionDays: in Int): Result[Int, CloudAgents.Db.DbError] {
  return CloudAgents.PgStore.GraphIngest.pruneDeliveredGraphIngest(retentionDays)
}
