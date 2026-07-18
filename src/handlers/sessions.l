package CloudAgents.Handlers

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Docker
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Streaming
import CloudAgents.Text
import CloudAgents.Webhooks
import Std.Uuid

pub func generateSessionId(): String {
  val u = Std.Uuid.newUuid()
  return Std.Uuid.uuidToString(u)
}

val maxPromptLen = 131072
val maxRepoUrlLen = 2048
val maxBranchLen = 255
val maxModelLen = 128

func isHttpsUrl(url: in String): Bool {
  // startsWith already handles a URL shorter than the prefix; no need to
  // hand-roll the length check + substring compare (#44).
  return url.startsWith("https://")
}

func isSafeRepoUrl(url: in String): Bool {
  if not CloudAgents.Text.withinMaxLength(url, maxRepoUrlLen) {
    return false
  }
  if url.contains(" ") or url.contains("\"") or url.contains("\\") {
    return false
  }
  return not CloudAgents.Text.containsControlChar(url)
}

/// Whether a repoUrl points at an internal/loopback/private host that the runner
/// must not `git clone` from (SSRF, #33). Reuses the webhook registration
/// blocklist — the same loopback/private/link-local + non-dotted-IP-literal
/// rules, already hardened against authority-parsing bypasses (#257/#260/#264/
/// #266) — rather than duplicating (and risking drift from) that logic. Assumes
/// the `https://` prefix is already verified (webhookHost parses from offset 8).
///
/// Only inspects the literal hostname string, not a resolved IP — a public DNS
/// name an attacker controls (e.g. resolving to 169.254.169.254) passes this
/// check and the actual SSRF happens later, at `git clone` time, when the clone
/// runs inside the session's Docker container (#300). Unlike the webhook path
/// this reuses the blocklist from, there is no secondary backstop here for the
/// common case: a session's default `network_policy` is `'full'` (unrestricted
/// bridge network — see `createRunnerContainer` in docker_manager.l) unless its
/// profile explicitly sets `'restricted'`/`'none'`, so this hostname check is
/// the only control against metadata-endpoint SSRF via `git clone` today.
func isBlockedRepoHost(url: in String): Bool {
  return CloudAgents.Webhooks.isBlockedWebhookHost(CloudAgents.Webhooks.webhookHost(url))
}

/// Git ref-name safety: rejects names git itself refuses, plus anything that
/// could be misread as a command-line option (leading '-').
func isSafeBranchName(branch: in String): Bool {
  if branch.length == 0 or not CloudAgents.Text.withinMaxLength(branch, maxBranchLen) {
    return false
  }
  if branch == "@" {
    return false // reserved ref name
  }
  if branch.startsWith("-") or branch.startsWith("/") or branch.endsWith("/") or branch.endsWith(".") or
    branch.endsWith(".lock") {
    return false
  }
  // No component may start with '.' (covers a leading '.' and 'x/.y').
  if branch.startsWith(".") or branch.contains("/.") {
    return false
  }
  if branch.contains(" ") or branch.contains("\"") or branch.contains("\\") or branch.contains("~") or
    branch.contains("^") or
    branch.contains(":") or
    branch.contains("?") or
    branch.contains("*") or
    branch.contains("[") or
    branch.contains("..") or
    branch.contains("@{") {
    return false
  }
  return not CloudAgents.Text.containsControlChar(branch)
}

func isSafeModelName(model: in String): Bool {
  if not CloudAgents.Text.withinMaxLength(model, maxModelLen) {
    return false
  }
  if model.contains(" ") or model.contains("\"") or model.contains("\\") or model.contains("{") or
    model.contains("}") {
    return false
  }
  return not CloudAgents.Text.containsControlChar(model)
}

func isKnownHarness(harness: in String): Bool {
  return harness == "claude" or harness == "codex" or harness == "opencode" or harness == "gemini"
}

@generate(Json)
pub record CreateSessionRequest {
  pub repoUrl: String
  pub branch: String
  pub harness: String
  pub model: String
}

@generate(Json)
pub record SetProfileRequest {
  pub profileId: String
}

@generate(Json)
pub record SessionProfileRef {
  pub profileId: String
}

@generate(Json)
pub record UpdateSessionRequest {
  pub model: String
}

@generate(Json)
pub record CreateSessionResponse {
  pub sessionId: String
}

@generate(Json)
pub record SendMessageRequest {
  pub text: String
}

@generate(Json)
pub record AddRepoRequest {
  pub repoUrl: String
  pub branch: String
}

/// Upper bound on repositories linked to one session, so the EXTRA_REPOS env
/// value passed to a container stays bounded.
val maxSessionRepos = 20


/// Create a persistent session workspace.
pub func createSession(req: in CreateSessionRequest): Result[CreateSessionResponse, Web.ApiError] {
  if req.repoUrl.length == 0 {
    return Err(Web.badRequest("repoUrl is required"))
  }
  if not isHttpsUrl(req.repoUrl) {
    return Err(Web.badRequest("repoUrl must use the https:// scheme"))
  }
  if not isSafeRepoUrl(req.repoUrl) {
    return Err(Web.badRequest("repoUrl contains invalid characters or is too long"))
  }
  // Reject internal/loopback/private targets before the runner clones the repo
  // (SSRF, #33). isHttpsUrl above guarantees the prefix webhookHost expects.
  if isBlockedRepoHost(req.repoUrl) {
    return Err(Web.badRequest("repoUrl must not point at an internal, loopback, or private host"))
  }
  if req.branch.length == 0 {
    return Err(Web.badRequest("branch is required"))
  }
  if not isSafeBranchName(req.branch) {
    return Err(Web.badRequest("branch is not a valid git branch name"))
  }
  if req.harness.length > 0 and not isKnownHarness(req.harness) {
    return Err(Web.badRequest("harness must be one of: claude, codex, opencode, gemini"))
  }
  if not isSafeModelName(req.model) {
    return Err(Web.badRequest("model contains invalid characters or is too long"))
  }

  val sessionId = generateSessionId()
  val harness = if req.harness.length == 0 { "claude" } else { req.harness }
  val model = if req.model.length == 0 { CloudAgents.SessionStore.defaultModelForHarness(harness) } else { req.model }
  val session = makeAgentSession(
    sessionId = sessionId,
    repoUrl = req.repoUrl,
    branch = req.branch,
    containerId = "",
    harness = harness,
    model = model,
    nativeSessionId = sessionId
  )  // pre-assigned so every run gets a stable resume ID

  match addSession(session) {
    case Ok(_) -> return Ok(CreateSessionResponse(sessionId = sessionId))
    case Err(e) -> return Err(Web.internalError("failed to persist session: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
}

/// Attach a profile to a session (or clear it with an empty profileId). The
/// profile governs credential injection and network access on the session's
/// runs, and pins the harness if it sets one (applied at send time). Kept
/// separate from session creation so existing create-session clients are
/// unaffected and a session's profile can be changed later.
pub func setSessionProfileHandler(id: in String, req: in SetProfileRequest): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  val userId = CloudAgents.Auth.currentUserId()
  // The session must exist and be owned by the caller.
  match getSession(id) {
    case Ok(Some(_)) -> ()
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  // A non-empty profile must exist and be owned by the caller.
  if req.profileId.length > 0 {
    match CloudAgents.Repository.getProfile(req.profileId, userId) {
      case Ok(Some(_)) -> ()
      case Ok(None) -> return Err(Web.badRequest("profileId does not reference a known profile"))
      case Err(e) -> return Err(Web.internalError("profile lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
    }
  }
  match CloudAgents.SessionStore.setSessionProfile(id, req.profileId) {
    case Ok(_) -> return Ok(())
    case Err(e) -> return Err(Web.internalError("failed to attach profile: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
}

/// The profile currently attached to a session ("" when none). Lets the UI
/// reflect the stored profile — the session list projection doesn't carry it.
/// 404 for an unknown/foreign session (#270).
pub func getSessionProfileHandler(id: in String): Result[SessionProfileRef, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  match CloudAgents.SessionStore.sessionProfileId(id) {
    case Ok(Some(pid)) -> return Ok(SessionProfileRef(profileId = pid))
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(Web.internalError("session profile lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
}

/// List every stored session as `{"sessions":[...]}`. Lets a client rebuild
/// its session list after local state is lost (new browser, cleared storage)
/// instead of stranding server-side sessions forever. The projection —
/// including status/createdAt/lastMessageAt, excluding infrastructure handles
/// (containerId, nativeSessionId) — is built in CloudAgents.SessionStore,
/// where the raw rows with those bookkeeping columns are visible.
pub func listSessions(): Result[String, Web.ApiError] {
  match CloudAgents.SessionStore.sessionSummariesJson() {
    case Ok(json) -> return Ok(value = json)
    case Err(e) -> return Err(Web.internalError("failed to list sessions: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
}

// ── Linked repositories (multi-repo sessions) ────────────────────────────────
//
// A session may have additional repositories linked beyond its primary repo, so
// an agent can work across several checkouts in one run. These handlers touch
// only CloudAgents.Repository + CloudAgents.SessionStore (no CloudAgents.Docker),
// so — unlike sendMessage — they can be invoked directly from the test harness.

/// The extra repositories linked to a session (beyond its primary repo). 404
/// for an unknown/foreign session, consistent with the other session
/// sub-resource endpoints.
pub func listSessionReposHandler(id: in String): Result[SessionRepoList, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  match getSession(id) {
    case Ok(Some(_)) -> ()
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match CloudAgents.Repository.listSessionRepos(id) {
    case Ok(repos) -> return Ok(SessionRepoList(repos = repos))
    case Err(e) -> return Err(Web.internalError("failed to list linked repositories: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
}

/// Link an additional repository to a session. Same URL / host / branch
/// validation as session creation, except the branch may be empty (meaning the
/// repo's default branch). 404 unknown session; 400 invalid input, duplicate,
/// or over the per-session cap.
pub func addSessionRepoHandler(id: in String, req: in AddRepoRequest): Result[SessionRepo, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if req.repoUrl.length == 0 {
    return Err(Web.badRequest("repoUrl is required"))
  }
  if not isHttpsUrl(req.repoUrl) {
    return Err(Web.badRequest("repoUrl must use the https:// scheme"))
  }
  if not isSafeRepoUrl(req.repoUrl) {
    return Err(Web.badRequest("repoUrl contains invalid characters or is too long"))
  }
  // Reject internal/loopback/private targets before the runner ever clones the
  // repo (SSRF, #33), exactly as createSession does for the primary repo.
  if isBlockedRepoHost(req.repoUrl) {
    return Err(Web.badRequest("repoUrl must not point at an internal, loopback, or private host"))
  }
  // Branch is optional for a linked repo: empty means the repo's default
  // branch (the entrypoint clones without --branch). A non-empty branch must
  // still be a valid git ref name.
  if req.branch.length > 0 and not isSafeBranchName(req.branch) {
    return Err(Web.badRequest("branch is not a valid git branch name"))
  }
  // A '|' would corrupt the "url|branch" packing these linked repos travel in
  // (EXTRA_REPOS) — unlike the primary repo, which rides its own REPO_URL /
  // BRANCH env vars — so reject it here specifically. The general validators
  // above don't cover it because it's only a delimiter in this one encoding.
  if req.repoUrl.contains("|") {
    return Err(Web.badRequest("repoUrl must not contain the '|' character"))
  }
  if req.branch.contains("|") {
    return Err(Web.badRequest("branch must not contain the '|' character"))
  }
  // The session must exist and be owned by the caller (getSession is owner-scoped).
  match getSession(id) {
    case Ok(Some(_)) -> ()
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  // Cap the number of linked repos (keeps the EXTRA_REPOS env bounded).
  match CloudAgents.Repository.countSessionRepos(id) {
    case Ok(n) -> if n >= maxSessionRepos { return Err(Web.badRequest("too many linked repositories (max " + toString(maxSessionRepos) + ")")) }
    case Err(e) -> return Err(Web.internalError("failed to count linked repositories: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  // Refuse a duplicate URL so a repo is never cloned twice into the workspace.
  match CloudAgents.Repository.sessionRepoUrlExists(id, req.repoUrl) {
    case Ok(exists) -> if exists { return Err(Web.badRequest("repository already linked to this session")) }
    case Err(e) -> return Err(Web.internalError("failed to check linked repositories: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match CloudAgents.Repository.addSessionRepo(id, req.repoUrl, req.branch) {
    case Ok(repo) -> return Ok(repo)
    case Err(e) -> return Err(Web.internalError("failed to link repository: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
}

/// Unlink a repository from a session. 404 for an unknown session or an unknown
/// repo id under it.
pub func deleteSessionRepoHandler(id: in String, repoId: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if repoId.length == 0 {
    return Err(Web.badRequest("repo id is required"))
  }
  match getSession(id) {
    case Ok(Some(_)) -> ()
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match CloudAgents.Repository.deleteSessionRepo(id, repoId) {
    case Ok(n) -> {
      if n > 0 {
        return Ok(())
      }
      return Err(Web.notFound("Linked repository not found"))
    }
    case Err(e) -> return Err(Web.internalError("failed to unlink repository: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
}

/// Build the EXTRA_REPOS env value from a session's linked repos: one
/// `url|branch` entry per repo, space-separated. Values are pre-validated at
/// link time (no spaces, quotes, or backslashes in a URL; git-ref-safe
/// branches), so neither the space separators nor the '|' delimiter can ever
/// appear inside a value — the entrypoint splits on them unambiguously. An
/// empty branch is emitted as `url|`, which the entrypoint reads as "clone the
/// default branch". pub so the formatting can be tested without invoking the
/// Docker-referencing send path.
pub func extraReposEnvValue(repos: in slice[CloudAgents.Repository.SessionRepo]): String {
  var acc = ""
  var i = 0
  while i < repos.length {
    if i > 0 {
      acc = acc + " "
    }
    acc = acc + repos[i].repoUrl + "|" + repos[i].branch
    i = i + 1
  }
  return acc
}

/// Write a pre-stream error as a normal (non-streamed) HTTP response: a status
/// code + JSON body, committed before any SSE chunk. Used for validation and
/// lookup failures the client should see as a real 4xx/5xx (the frontend's
/// api.sendMessage throws on a non-2xx, exactly as it did for the old buffered
/// handler). Safe only before the first writeChunk — once output has streamed,
/// the 200/headers are already on the wire.
pub func writeStreamError(w: in Web.ResponseWriter, code: in Int, msg: in String): Unit {
  Web.writeStatus(w, code)
  Web.writeHeader(w, "Content-Type", "application/json")
  val _ = Web.writeChunk(w, "{\"error\":\"" + CloudAgents.Streaming.jsonEscape(msg) + "\"}")
  return ()
}

/// Accept a user prompt and STREAM the container's output back as it is
/// produced, using Lyric.Web 0.4.33's streaming-handler API: each new slice of
/// container output is written as a `data: {"chunk":"..."}` SSE frame the
/// moment it appears, and a terminal `done` frame carries the persisted agent
/// message id. This replaces the old buffer-the-whole-run-then-return handler;
/// the `/output` + `/output/{offset}` polling endpoints remain only as a bridge
/// for the pre-first-chunk window and as a fallback for older clients.
///
/// Lifecycle (claim run -> persist prompt -> resolve profile/harness -> record
/// run -> stream -> persist reply -> done frame) mirrors the old handler; only
/// the transport changed. An error BEFORE the first chunk becomes a real
/// 4xx/5xx via writeStreamError; a failure once streaming has begun is surfaced
/// as an error line in the stream, since status/headers are already committed.
pub func streamSendMessage(id: in String, text: in String, w: in Web.ResponseWriter): Unit {
  if id.length == 0 {
    writeStreamError(w, 400, "id is required")
    return ()
  }
  if text.length == 0 {
    writeStreamError(w, 400, "text is required")
    return ()
  }
  if not CloudAgents.Text.withinMaxLength(text, maxPromptLen) {
    writeStreamError(w, 400, "text is too long (max " + toString(maxPromptLen) + " characters)")
    return ()
  }

  // Capture identity + linked repos on the request thread (the async run body
  // can't read the thread-local identity) — same rationale as the old handler.
  val userId = CloudAgents.Auth.currentUserId()
  val extraRepos = match CloudAgents.Repository.listSessionRepos(id) {
    case Ok(rs) -> extraReposEnvValue(rs)
    case Err(_) -> ""
  }

  val maybeSession = match getSession(id) {
    case Ok(m) -> m
    case Err(e) -> {
      writeStreamError(w, 500, "session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      return ()
    }
  }
  match maybeSession {
    case None -> {
      writeStreamError(w, 404, "Session not found")
      return ()
    }
    case Some(session) -> {
      // One run per session: atomically claim RUNNING (a guarded UPDATE) so two
      // concurrent sends cannot both win and race the workspace volume.
      val began = match CloudAgents.SessionStore.tryBeginRun(id) {
        case Ok(b) -> b
        case Err(e) -> {
          writeStreamError(w, 500, "failed to claim session for run: " + CloudAgents.Sqlite.dbErrorMessage(e))
          return ()
        }
      }
      if not began {
        writeStreamError(w, 409, "a run is already in progress for this session")
        return ()
      }

      // Release the claim on every exit (normal, error, or a Bug/panic) so a
      // failure can never strand the session in RUNNING (#208).
      defer {
        match CloudAgents.SessionStore.endRun(id) {
          case Ok(_) -> ()
          case Err(e) -> println("WARNING: failed to release run claim for session " + id + " (stays RUNNING until recovery): " + CloudAgents.Sqlite.dbErrorMessage(e))
        }
      }

      // Persist the user's prompt (best-effort — a storage hiccup must not stop
      // the run).
      match CloudAgents.Repository.addMessage(id, "user", text) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }

      // The session's profile governs credential injection and network access;
      // a DB error resolving it must FAIL the run, not fall open to "no profile"
      // (#232). Ok(None) genuinely means no profile.
      val profileId = match CloudAgents.SessionStore.sessionProfileId(id) {
        case Ok(Some(pid)) -> pid
        case Ok(None) -> ""
        case Err(e) -> {
          writeStreamError(w, 500, "failed to resolve session profile: " + CloudAgents.Sqlite.dbErrorMessage(e))
          return ()
        }
      }
      // Profile-pinned harness (empty = the session's own). Not a privilege
      // boundary, so a lookup miss/error is best-effort; credentials and network
      // fail closed in the layers below.
      var harness = session.harness
      if profileId.length > 0 {
        match CloudAgents.Repository.getProfile(profileId, userId) {
          case Ok(Some(p)) -> if p.harness.length > 0 { harness = p.harness }
          case Ok(None) -> ()
          case Err(_) -> ()
        }
      }

      // Record the run (best-effort bookkeeping; proceed with an empty id).
      val runId = match CloudAgents.Repository.recordRunStart(id, userId, text, harness, session.model) {
        case Ok(rid) -> rid
        case Err(_) -> ""
      }

      // Commit the SSE stream: status + headers are still settable (no chunk
      // written yet), then hand the writer to the streaming run loop. 200 is
      // set explicitly (it is also the default) to mirror the error paths and
      // the upstream usage example.
      Web.writeStatus(w, 200)
      Web.writeHeader(w, "Content-Type", "text/event-stream")
      Web.writeHeader(w, "Cache-Control", "no-cache")

      val streamResult = CloudAgents.Docker.streamSessionMessage(
        repoUrl = session.repoUrl,
        branch = session.branch,
        prompt = text,
        sessionId = id,
        harness = harness,
        model = session.model,
        nativeSessionId = session.nativeSessionId,
        profileId = profileId,
        userId = userId,
        extraRepos = extraRepos,
        w = w
      )

      match streamResult {
        case Ok(logs) -> {
          if runId.length > 0 {
            val _ = CloudAgents.Repository.recordRunEnd(runId, userId, "succeeded")
            val _ = CloudAgents.Repository.enqueueWebhookEvent(userId, id, runId, "succeeded")
          }
          // Persist the agent reply and close the stream with a done frame that
          // carries the message id (so the client can anchor comments/todos).
          match CloudAgents.Repository.addMessage(id, "agent", logs) {
            case Ok(m) -> { val _ = Web.writeChunk(w, CloudAgents.Streaming.sseDoneWithMessage(m.id)) }
            case Err(e) -> {
              println("WARNING: failed to persist agent message for session " + id + ": " + CloudAgents.Sqlite.dbErrorMessage(e))
              val _ = Web.writeChunk(w, CloudAgents.Streaming.sseDone())
            }
          }
        }
        case Err(err) -> {
          if runId.length > 0 {
            val _ = CloudAgents.Repository.recordRunEnd(runId, userId, "failed")
            val _ = CloudAgents.Repository.enqueueWebhookEvent(userId, id, runId, "failed")
          }
          // Status/headers are already committed (200 sent at the first chunk),
          // so the failure can't be an HTTP status. Emit a distinct `event:
          // error` frame the frontend recognises as a failed send (#485) — NOT
          // a plain data chunk, which the client would fold into the transcript
          // as if the run succeeded. A client-disconnect error makes this write
          // fail harmlessly.
          val _ = Web.writeChunk(w, CloudAgents.Streaming.sseError(err))
        }
      }
    }
  }
}

/// Cancel an in-progress run by terminating its container. The blocking send
/// then fails and its `defer` releases the session; the run's history row is
/// marked 'cancelled' first (write-once, so the send's own 'failed' won't
/// overwrite it). 409 when nothing is running. Note: if the container has not
/// been created yet (the claim is set synchronously, just before creation),
/// there is nothing to terminate and the send proceeds — cancellation takes
/// effect once the container exists.
pub func cancelRun(id: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  val userId = CloudAgents.Auth.currentUserId()
  val maybeSession = match getSession(id) {
    case Ok(m) -> m
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match maybeSession {
    case None -> return Err(Web.notFound("Session not found"))
    case Some(session) -> {
      val status = match CloudAgents.SessionStore.sessionStatus(id) {
        case Ok(s) -> s
        case Err(e) -> return Err(Web.internalError("status lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
      }
      val isRunning = match status {
        case Some(s) -> s == "RUNNING"
        case None -> false
      }
      if not isRunning {
        return Err(Web.conflict("no run is in progress for this session"))
      }
      // The status flips to RUNNING synchronously, before the container is
      // created. If we get here in that window (no container id yet), there is
      // nothing to terminate and the run would keep executing — so DON'T mark
      // history 'cancelled' (write-once would then block the real terminal
      // status forever, #243). Report that the run is still starting instead.
      if session.containerId.length == 0 {
        return Err(Web.conflict("run is still starting (container not created yet) — retry shortly"))
      }
      // Capture the active run's id BEFORE finishSessionRuns marks it
      // 'cancelled', so the completion webhook can carry the real run id rather
      // than an empty one (#258). Best-effort: on a lookup miss/error we skip
      // the event rather than emit one with an empty run_id (same rationale as
      // #256). There is at most one 'running' row per session.
      var runId = ""
      match CloudAgents.Repository.listRuns(id, userId) {
        case Ok(runs) -> {
          var k = 0
          while k < runs.length and runId.length == 0 {
            if runs[k].status == "running" {
              runId = runs[k].id
            }
            k = k + 1
          }
        }
        case Err(_) -> ()
      }
      // Terminate first; only record 'cancelled' once the container is actually
      // gone, so history never claims a cancel that didn't take effect.
      match CloudAgents.Docker.terminateSessionContainer(session.containerId) {
        case Ok(_) -> {
          val _ = CloudAgents.Repository.finishSessionRuns(id, userId, "cancelled")
          // A cancel is a run completion too — notify like succeeded/failed
          // (#252), but only with a real run id (#258).
          if runId.length > 0 {
            val _ = CloudAgents.Repository.enqueueWebhookEvent(userId, id, runId, "cancelled")
          }
          return Ok(())
        }
        case Err(e) -> return Err(Web.internalError("failed to terminate container: " + e))
      }
    }
  }
}

/// A session's run history, newest first. 404 for an unknown/foreign session,
/// consistent with the other session sub-resource endpoints (#239).
pub func getRuns(id: in String): Result[RunList, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  match getSession(id) {
    case Ok(Some(_)) -> ()
    case Ok(None) -> return Err(Web.notFound("Session not found"))
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match CloudAgents.Repository.listRuns(id, CloudAgents.Auth.currentUserId()) {
    case Ok(rs) -> return Ok(RunList(runs = rs))
    case Err(e) -> return Err(Web.internalError("failed to list runs: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
}

/// Stop WARM containers idle past the warm window and free their session rows.
/// A maintenance endpoint for an external scheduler to poll (Lyric.Web has no
/// in-process timer yet); safe to call repeatedly — it no-ops when nothing is
/// reapable. Returns `{"reaped":N}`.
pub func reapContainers(): Result[String, Web.ApiError] {
  val targets = match CloudAgents.SessionStore.reapableWarmContainers() {
    case Ok(t) -> t
    case Err(e) -> return Err(Web.internalError("failed to list reapable containers: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  var reaped = 0
  var i = 0
  while i < targets.length {
    val t = targets[i]
    // Terminate is best-effort (the container may already be gone); blank the
    // session row regardless so it returns to IDLE.
    match CloudAgents.Docker.terminateSessionContainer(t.containerId) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
    val _ = CloudAgents.SessionStore.reapSessionContainer(t.sessionId)
    reaped = reaped + 1
    i = i + 1
  }
  return Ok(value = "{\"reaped\":" + toString(reaped) + "}")
}

/// Live output for an in-progress run. The frontend polls this while a send is
/// outstanding to show incremental container output, since the send itself
/// blocks until the run finishes and Lyric.Web cannot stream a response.
///
/// A run is in progress exactly when the session's status is `RUNNING` (set
/// synchronously at send time, before the container exists, and cleared when
/// the run ends). While running, we return the container's logs-so-far once it
/// exists; otherwise `running` is false and the client stops polling and
/// reloads the persisted transcript. Status — not container id — drives this,
/// so the first poll (which races container creation) doesn't see an empty id
/// and wrongly report "not running"; see the inline comment below.
/// Returns `{"running":"true|false","output":"..."}` as a hand-built JSON
/// string, mirroring listSessions — no @generate(Json) response record on this
/// path (a fresh record here tripped the JSON source generator at runtime with
/// "The signature is incorrect").
pub func getRunOutput(id: in String): Result[String, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  val maybeStatus = match CloudAgents.SessionStore.sessionStatus(id) {
    case Ok(m) -> m
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match maybeStatus {
    case None -> return Err(Web.notFound("Session not found"))
    case Some(status) -> {
      // A run is in progress while status is RUNNING (set synchronously at
      // send time, before the container is created). Basing this on the
      // container id would make the first poll — which races container
      // creation — see an empty id and report "not running", causing the
      // client to stop polling for the whole run.
      if status != "RUNNING" {
        return Ok(value = "{\"running\":\"false\",\"output\":\"\"}")
      }
      // Logs only once the container exists; until then the run is up but has
      // produced nothing to fetch yet.
      val containerId = match getSession(id) {
        case Ok(Some(s)) -> s.containerId
        case Ok(None) -> ""
        case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
      }
      val logs = if containerId.length > 0 { CloudAgents.Docker.partialContainerLogs(containerId) } else { "" }
      return Ok(value = "{\"running\":\"true\",\"output\":\"" + CloudAgents.Streaming.jsonEscape(logs) + "\"}")
    }
  }
}

// ── Incremental run output ────────────────────────────────────────────────────

// Decimal digit value of a single-character string, -1 when not a digit.
// Mirrors the parser helper in src/main.l's isValidPort — that digitValue is
// package CloudAgents (non-pub) and not importable from here, so Handlers
// keeps its own copy.
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

/// Parse a client-supplied output offset: 1..9 decimal digits, so the value
/// fits comfortably in Int (999,999,999 is far beyond any realistic container
/// log). Returns -1 for anything else — empty, too long, sign, non-digit —
/// which getRunOutputFrom maps to a 400. pub so the test suite can cover the
/// validation boundary directly (the handler itself references
/// CloudAgents.Docker and cannot be invoked from tests — see the getRunOutput
/// NOTE in tests/session_tests.l).
pub func parseOutputOffset(offsetStr: in String): Int {
  if offsetStr.length == 0 or offsetStr.length > 9 {
    return -1
  }
  var n = 0
  var i = 0
  while i < offsetStr.length {
    val d = digitValue(offsetStr.substring(i, 1))
    if d < 0 {
      return -1
    }
    n = n * 10 + d
    i = i + 1
  }
  return n
}

/// Build the `{"running":..,"length":..,"chunk":..}` body for the incremental
/// output endpoint. `length` is the CURRENT total log length; the client feeds
/// it back as its next offset. All values are strings, matching the TEXT-only
/// hand-built JSON style of getRunOutput/listSessions (a fresh
/// @generate(Json) record on this path tripped the JSON source generator at
/// runtime — see getRunOutput's doc comment).
///
/// IMPORTANT resync subtlety: an offset PAST the current total means the
/// client polled across a log truncation (e.g. a new run replaced the
/// container, so the log restarted from empty). That offset is treated as
/// offset = 0 and the FULL log is returned as the chunk with the new length —
/// the client sees `length` below the offset it sent and REPLACES its
/// accumulated output instead of appending, resyncing in one round trip. An
/// offset EQUAL to the total means the client is caught up: empty chunk.
pub func runOutputDeltaJson(running: in Bool, logs: in String, offset: in Int): String {
  val total = logs.length.toInt()
  val effective = if offset > total { 0 } else { offset }
  val chunk = if effective >= total { "" } else { logs.substring(effective, total - effective) }
  val runningStr = if running { "true" } else { "false" }
  return "{\"running\":\"" + runningStr + "\",\"length\":\"" + toString(total) +
    "\",\"chunk\":\"" + CloudAgents.Streaming.jsonEscape(chunk) + "\"}"
}

/// Incremental live output for an in-progress run — GET
/// /api/sessions/{id}/output/{offset}. Same status/container lookups as
/// getRunOutput above, but instead of returning the ENTIRE container log on
/// every poll tick, returns only the bytes past the client's `offset` as
/// `{"running":"true|false","length":"<total>","chunk":"<escaped>"}`, so a
/// long, chatty run's polling cost is proportional to NEW output rather than
/// to the whole accumulated log on every tick. The client feeds the returned
/// `length` back as its next offset; when `length` comes back below the
/// offset it sent, the chunk is the full (truncated/replaced) log and the
/// client resyncs — see runOutputDeltaJson for the exact rule.
///
/// `offsetStr` must be 1..9 decimal digits (parseOutputOffset); anything else
/// is a 400. When the session is not RUNNING the body is
/// `{"running":"false","length":"0","chunk":""}` and the client stops
/// polling. The plain /output route is kept untouched for older clients.
pub func getRunOutputFrom(id: in String, offsetStr: in String): Result[String, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  val offset = parseOutputOffset(offsetStr)
  if offset < 0 {
    return Err(Web.badRequest("offset must be a decimal integer of 1 to 9 digits"))
  }
  val maybeStatus = match CloudAgents.SessionStore.sessionStatus(id) {
    case Ok(m) -> m
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match maybeStatus {
    case None -> return Err(Web.notFound("Session not found"))
    case Some(status) -> {
      // Status — not container id — decides "running", for the same
      // first-poll-races-container-creation reason documented on getRunOutput.
      if status != "RUNNING" {
        return Ok(value = runOutputDeltaJson(false, "", 0))
      }
      val containerId = match getSession(id) {
        case Ok(Some(s)) -> s.containerId
        case Ok(None) -> ""
        case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
      }
      val logs = if containerId.length > 0 { CloudAgents.Docker.partialContainerLogs(containerId) } else { "" }
      return Ok(value = runOutputDeltaJson(true, logs, offset))
    }
  }
}

/// Stop and tear down container and associated session synchronously.
pub func deleteSession(id: in String): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }

  // Terminate the container BEFORE dropping the session record: if teardown
  // fails, the session (and its containerId) survives so the delete can be
  // retried, instead of orphaning a running container with no record of it.
  val maybeSession = match getSession(id) {
    case Ok(m) -> m
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match maybeSession {
    case None -> return Err(Web.notFound("Session not found"))
    case Some(session) -> {
      // Refuse to delete a session with a run in flight (#210): a mid-run delete
      // would race the blocking send (which still holds the claim and writes the
      // run record on exit), risking an orphaned container the send re-creates
      // and a dangling run row. Cancel the run first, then delete.
      val status = match CloudAgents.SessionStore.sessionStatus(id) {
        case Ok(s) -> s
        case Err(e) -> return Err(Web.internalError("status lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
      }
      match status {
        case Some(s) -> if s == "RUNNING" { return Err(Web.conflict("a run is in progress; cancel it before deleting the session")) }
        case None -> ()
      }
      val containerId = session.containerId
      if containerId.length > 0 {
        val terminateResult = CloudAgents.Docker.terminateSessionContainer(containerId)
        match terminateResult {
          case Ok(_) -> ()
          case Err(err) -> return Err(Web.internalError("Failed to terminate container (session retained, retry delete): " + err))
        }
      }
      // Drop any linked repositories first (best-effort: leftover rows are
      // only reachable through this now-deleted session, so a failure here is
      // harmless bookkeeping, not a blocker for the delete).
      val _ = CloudAgents.Repository.deleteSessionReposForSession(id)
      // We already fetched and existence-checked the session above, so delete
      // the row directly rather than via removeSession (which would re-read it)
      // — avoids a redundant second lookup (#172).
      match CloudAgents.SessionStore.deleteSessionRecord(id) {
        case Ok(_) -> return Ok(())
        case Err(e) -> return Err(Web.internalError("failed to remove session: " + CloudAgents.Sqlite.dbErrorMessage(e)))
      }
    }
  }
}

/// Switch the active model for a session (stays on the same harness).
/// The next message will use this model; existing transcript is unaffected.
pub func updateSessionModel(id: in String, req: in UpdateSessionRequest): Result[Unit, Web.ApiError] {
  if id.length == 0 {
    return Err(Web.badRequest("id is required"))
  }
  if req.model.length == 0 {
    return Err(Web.badRequest("model is required"))
  }
  if not isSafeModelName(req.model) {
    return Err(Web.badRequest("model contains invalid characters or is too long"))
  }
  val maybeSession = match getSession(id) {
    case Ok(m) -> m
    case Err(e) -> return Err(Web.internalError("session lookup failed: " + CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  match maybeSession {
    case None -> return Err(Web.notFound("Session not found"))
    case Some(_) -> match CloudAgents.SessionStore.updateSessionModel(id, req.model) {
      case Ok(_) -> return Ok(())
      case Err(e) -> return Err(Web.internalError("failed to update model: " + CloudAgents.Sqlite.dbErrorMessage(e)))
    }
  }
}

/// Retrieve service health, including a live SQLite probe.
pub func checkHealth(): Result[String, Web.ApiError] {
  match CloudAgents.Repository.ping() {
    case Ok(_) -> return Ok("Healthy")
    case Err(e) -> {
      // /api/health is reachable unauthenticated; the raw DB error can include
      // the SQLite file path, so log the detail server-side and return a
      // generic message to the caller (#55).
      println("WARNING: health probe failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
      return Err(Web.internalError("database unavailable"))
    }
  }
}
