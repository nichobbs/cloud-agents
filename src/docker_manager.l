package CloudAgents.Docker

import Std.Core
import Std.Environment
import Std.Task
import Web
import Lyric.Docker
import CloudAgents.Db
import CloudAgents.NetworkPolicy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Streaming

pub record ResultCell {
  pub var isSuccess: Bool = false
  pub var output: String = ""
  pub var error: String = ""
}

/// Connect to the Docker daemon. Prefers `CLOUD_AGENTS_DOCKER_TCP_HOST`
/// ("host:port") when set, over the Unix-socket default `makeDockerClient()`
/// uses — the socket transport depends on `Lyric.Cli.Aot.UnixSocketHttpClient`,
/// which is absent from a standalone compiled program's output outside the
/// `lyric` CLI process itself (see `Lyric.Docker.makeDockerClientTcp`'s doc
/// comment). Run `dockerd -H unix:///var/run/docker.sock -H tcp://127.0.0.1:2375`
/// and set `CLOUD_AGENTS_DOCKER_TCP_HOST=127.0.0.1:2375` until that's fixed
/// upstream.
///
/// SECURITY: the Docker Engine API has no authentication of its own — anyone
/// who can reach the TCP host:port can create/exec/delete containers with
/// host-level privileges. Only ever point `CLOUD_AGENTS_DOCKER_TCP_HOST` at
/// `127.0.0.1`/a loopback-only listener, never a host/port reachable from
/// outside this machine (no `0.0.0.0`, no public/LAN interface). This is a
/// local dev/CI workaround, not a deployment-ready transport.
func dockerClient(): DockerClient {
  match Std.Environment.getVar("CLOUD_AGENTS_DOCKER_TCP_HOST") {
    case Ok(hostPort) -> if hostPort.length > 0 { makeDockerClientTcp(hostPort) } else { makeDockerClient() }
    case Err(_) -> makeDockerClient()
  }
}

/// Returns true if the task completed within timeoutMs, false on timeout.
@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWaitMs[T](t: in T, timeoutMs: in Int): Bool = false

/// Docker image name for the given harness.
func imageForHarness(harness: in String): String {
  if harness == "codex" {
    return "codex:base"
  }
  if harness == "opencode" {
    return "opencode:base"
  }
  if harness == "gemini" {
    return "gemini:base"
  }
  return "claude-code:base"
}

// Network-policy resolution (networkModeForPolicy / proxyEnvForPolicy) lives in
// the pure CloudAgents.NetworkPolicy package so it can be unit-tested — a test
// can't invoke functions in this async package without hitting the "signature
// is incorrect" harness limitation (docs/lyric/gotchas.md), even pure ones.
/// Create an ephemeral container for the given session.
/// HARNESS, MODEL, and NATIVE_SESSION_ID are passed as env vars so each
/// container image can invoke the right CLI with the right resume flag. The
/// session's profile (profileId, "" for none) governs which credentials are
/// injected (least privilege) and the container's network access.
///
/// `userId` is passed explicitly (captured on the request thread by the
/// caller) because this async body runs on a worker thread, where the
/// per-request thread-local identity in CloudAgents.Auth does not flow —
/// reading currentUserId() here would silently resolve the wrong tenant.
pub async func createRunnerContainer(
  client: in DockerClient,
  repoUrl: in String,
  branch: in String,
  prompt: in String,
  sessionId: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String,
  profileId: in String,
  userId: in String,
  extraRepos: in String,
): Result[String, String] {
  var envs = [
    "PROMPT=" + prompt,
    "REPO_URL=" + repoUrl,
    "BRANCH=" + branch,
    "HARNESS=" + harness,
    "MODEL=" + model,
    "NATIVE_SESSION_ID=" + nativeSessionId
  ]

  // Additional repositories linked to this session (multi-repo sessions): a
  // single space-separated "url|branch ..." value the entrypoint clones into
  // /workspace/repos/<name>. Only set when non-empty so single-repo sessions
  // pass no EXTRA_REPOS at all. Values are validated at link time, so they are
  // safe to embed in the env value verbatim.
  if extraRepos.length > 0 {
    envs = envs.append("EXTRA_REPOS=" + extraRepos)
  }

  // Phase 6 (docs/phase6-mcp-callbacks.md §2/§5/§6 stage 2): mint a per-session
  // callback bearer token and inject it plus the host API's callback origin,
  // so the in-container MCP shim (stage 3, not shipped yet) can request
  // permission decisions, ask the human a question, and report progress
  // mid-run. Entirely gated behind CLOUD_AGENTS_MCP_CALLBACKS — off by
  // default, so nothing about this run changes until an operator opts in AND
  // the shim binary actually ships in the runner image
  // (docker/entrypoint.sh/mcp.json.template are gated by the same flag).
  // Best-effort: a mint failure must not abort the run — callbacks simply
  // won't work for this one run, same tolerance as the credential/network
  // resolution failures logged elsewhere in this function.
  if CloudAgents.NetworkPolicy.callbacksFeatureEnabled() {
    match CloudAgents.SessionStore.mintCallbackToken(sessionId, userId) {
      case Ok(token) -> {
        envs = envs.append("CLOUD_AGENTS_API_URL=" + CloudAgents.NetworkPolicy.callbackApiUrl())
        envs = envs.append("CLOUD_AGENTS_CALLBACK_TOKEN=" + token)
        val timeoutOverride = CloudAgents.NetworkPolicy.callbackTimeoutOverride()
        if timeoutOverride.length > 0 {
          envs = envs.append("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS=" + timeoutOverride)
        }
      }
      case Err(e) -> println("WARNING: failed to mint MCP-callback token for session " + sessionId + ": " + CloudAgents.Sqlite.dbErrorMessage(e))
    }
  }

  // Inject the credentials the profile grants (least privilege): 'selected'
  // profiles inject only their named grants, 'all'/no-profile inject every
  // credential. Decrypted here and never logged. Best-effort per credential —
  // an individual undecryptable secret (rotated ENCRYPTION_KEY, tampered value)
  // is skipped with a warning so one bad row can't block every run, while a
  // database-read failure (can't reach the store at all) still aborts the run.
  // GITHUB_TOKEN in particular flows on to the container's mcp.json via the
  // entrypoint template, finally wiring up the GitHub MCP server.
  match CloudAgents.Repository.decryptedCredentialsForProfile(userId, profileId) {
    case Ok(creds) -> {
      var i = 0
      while i < creds.length {
        envs = envs.append(creds[i].name + "=" + creds[i].value)
        i = i + 1
      }
    }
    case Err(e) -> return Err(error = "Failed to load credentials: " + CloudAgents.Repository.credentialErrorMessage(e))
  }

  // Resolve the profile's network policy: sets the container NetworkMode and,
  // for 'restricted', any proxy env vars. A DB error must FAIL the run, not
  // fall open to full network: a transient read failure on a locked-down
  // session must never silently re-open its network (#233), mirroring the
  // credential path above (which propagates its DB error). Both privilege
  // boundaries fail closed together.
  val policy = match CloudAgents.Repository.profileNetworkPolicy(userId, profileId) {
    case Ok(p) -> p
    case Err(e) -> return Err(error = "Failed to resolve network policy: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  val proxyEnv = CloudAgents.NetworkPolicy.proxyEnvForPolicy(policy)
  var pi = 0
  while pi < proxyEnv.length {
    envs = envs.append(proxyEnv[pi])
    pi = pi + 1
  }
  // Extends "none" to also admit the callback origin when callbacks are
  // enabled AND an operator has provisioned a dedicated callback-only network
  // (CLOUD_AGENTS_CALLBACK_NETWORK) — a no-op, identical to
  // networkModeForPolicy, in every other configuration (docs/phase6 §5).
  val networkMode = CloudAgents.NetworkPolicy.networkModeForPolicyWithCallbacks(
    policy,
    CloudAgents.NetworkPolicy.callbacksFeatureEnabled()
  )

  // Per-user, per-harness volumes so tenants never share workspace or home
  // state: OAuth tenants (gh-<id>) get user-<id>-<harness>-home and
  // session-<id>-<sessionId>-workspace, while the operator identity
  // ("default") keeps the legacy shared names — per-harness home volumes
  // (#409) and session-<sessionId>-workspace — so existing installs keep
  // their authenticated ~/.claude and workspaces.
  val binds = [
    CloudAgents.Db.workspaceVolumeBindFor(userId, sessionId),
    CloudAgents.Db.homeVolumeBindFor(userId, harness)
  ]

  val image = imageForHarness(harness)
  val createRes = await createContainerWithNetwork(client, image, envs, binds, networkMode)
  match createRes {
    case Ok(id) -> Ok(value = id)
    case Err(e) -> {
      // Previously silent server-side (only the caller's SSE error frame
      // carried any detail, and even that was just e.message verbatim) —
      // a missing runner image ("no such image") is the single most common
      // cause (Coolify deploys don't build these automatically; see
      // deploy/COOLIFY.md), so name which image was being created in both
      // the log line and the returned message rather than making an
      // operator guess or reproduce from the frontend to find out.
      println("WARNING: container creation failed for session " + sessionId + " (image " + image + "): " + e.message)
      return Err(error = "Docker API error creating container from image '" + image + "': " + e.message)
    }
  }
}

/// Start the created runner container.
pub async func startRunnerContainer(client: in DockerClient, containerId: in String): Result[Unit, String] {
  val startRes = await startContainer(client, containerId)
  match startRes {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> {
      println("WARNING: failed to start container " + containerId + ": " + e.message)
      return Err(error = "Failed to start container: " + e.message)
    }
  }
}

/// Stop the running container.
pub async func stopRunnerContainer(client: in DockerClient, containerId: in String): Result[Unit, String] {
  val stopRes = await stopContainer(client, containerId)
  match stopRes {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> {
      println("WARNING: failed to stop container " + containerId + ": " + e.message)
      return Err(error = "Failed to stop container: " + e.message)
    }
  }
}

/// Wait for a container's process to exit before reading its output.
pub async func waitForContainer(client: in DockerClient, containerId: in String): Result[Unit, String] {
  val waitRes = await waitContainer(client, containerId)
  match waitRes {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> {
      println("WARNING: failed to wait for container " + containerId + ": " + e.message)
      return Err(error = "Failed to wait for container: " + e.message)
    }
  }
}

/// Delete the container.
pub async func deleteRunnerContainer(client: in DockerClient, containerId: in String): Result[Unit, String] {
  val deleteRes = await removeContainer(client, containerId)
  match deleteRes {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "Failed to delete container: " + e.message)
  }
}

/// Best-effort teardown of an ephemeral runner container: remove it and clear
/// the session's stored container id. A delete failure is logged (not fatal)
/// rather than silently dropped (#42) — the run's own outcome is decided by the
/// caller. Factored out of the three identical cleanup sites below (#322).
/// `userId` is explicit for the same worker-thread reason as
/// createRunnerContainer.
async func cleanupRunnerContainer(
  client: in DockerClient,
  containerId: in String,
  sessionId: in String,
  userId: in String,
): Unit {
  match await deleteRunnerContainer(client, containerId) {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: failed to remove container " + containerId + ": " + e)
  }
  val _ = CloudAgents.SessionStore.clearSessionContainerIfMatchesFor(sessionId, userId, containerId)
}

/// Retrieve output logs of the runner container.
pub async func getRunnerLogs(client: in DockerClient, containerId: in String): Result[String, String] {
  val logsRes = await getContainerLogs(client, containerId)
  match logsRes {
    case Ok(logs) -> Ok(value = logs)
    case Err(e) -> Err(error = "Failed to retrieve logs: " + e.message)
  }
}

/// Read a running (or just-finished) container's logs-so-far synchronously,
/// without waiting for it to exit. Docker's logs endpoint returns the current
/// buffered output immediately, so this is safe to poll while a run is in
/// flight to drive incremental output. Returns "" (not an error) if the logs
/// cannot be fetched — a transient fetch failure during polling should not
/// surface as a hard error to the client.
pub func partialContainerLogs(containerId: in String): String {
  val cell = ResultCell(isSuccess = false, output = "", error = "")
  val t = partialContainerLogsAsync(containerId, cell)
  // Cap the block at the client's ~1.5s poll interval, not 10s (#227): partial
  // log fetches are normally sub-second, and a longer block lets requests pile
  // up faster than they drain once Lyric.Web dispatches them concurrently. A
  // fetch that doesn't finish in time returns "" — partial logs are best-effort
  // and the next poll retries.
  val completed = taskWaitMs(t, 1500)
  if not completed {
    return ""
  }
  if cell.isSuccess {
    return cell.output
  }
  return ""
}

async func partialContainerLogsAsync(containerId: in String, cell: in ResultCell): Unit {
  // A standalone poll (called repeatedly on a timer while a run is in
  // flight), not part of one sequential lifecycle chain, so it creates its
  // own client rather than sharing one threaded through runSessionMessageAsync.
  val client = dockerClient()
  val logsResult = await getRunnerLogs(client, containerId)
  match logsResult {
    case Ok(logs) -> {
      cell.isSuccess = true
      cell.output = logs
    }
    case Err(_) -> {
      cell.isSuccess = false
    }
  }
}

/// The session's current container id ("" when unknown / not owned by the
/// caller). Owner-scoped via getSession; runs on the request thread where the
/// identity is stamped, matching getRunOutputFrom.
func sessionContainerId(sessionId: in String): String {
  return match CloudAgents.SessionStore.getSession(sessionId) {
    case Ok(Some(s)) -> s.containerId
    case Ok(None) -> ""
    case Err(_) -> ""
  }
}

/// Run a session message and stream the container's output to `w` as SSE
/// `data:` frames while it runs, returning the full captured logs on success
/// (for transcript persistence) or an error. `userId` must be the request's
/// authenticated identity, captured on the request thread.
///
/// The run itself is driven by the unchanged `runSessionMessageAsync`
/// (create → start → wait → logs → cleanup); this wrapper only OBSERVES that
/// task's container, polling its logs-so-far on a short interval and writing
/// just the new bytes. `taskWaitMs` on the run task doubles as the poll timer
/// AND the completion signal. A bug in this loop can't corrupt the run or the
/// persisted transcript — worst case the live view is imperfect and the client
/// reloads the transcript. On a client disconnect (writeChunk `Err`) the
/// container is terminated so the run doesn't continue into the void.
pub func streamSessionMessage(
  repoUrl: in String,
  branch: in String,
  prompt: in String,
  sessionId: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String,
  profileId: in String,
  userId: in String,
  extraRepos: in String,
  w: in Web.ResponseWriter,
): Result[String, String] {
  val cell = ResultCell(isSuccess = false, output = "", error = "")
  val t = runSessionMessageAsync(
    repoUrl,
    branch,
    prompt,
    sessionId,
    harness,
    model,
    nativeSessionId,
    profileId,
    userId,
    extraRepos,
    cell
  )
  val startMs = CloudAgents.Repository.nowMillisLong()
  val runTimeoutMs = 1800000.toLong() // 30-minute hard cap (matches the old runSessionMessage)
  // Give up on the client only after several CONSECUTIVE failed writes, not the
  // first (#491): a single writeChunk Err can be a transient proxy/network blip,
  // and terminating on it would discard an in-progress run the old buffered
  // handler would have survived. On a failure we keep the offset put so the same
  // delta is retried next tick; a genuinely-gone client fails every retry and is
  // concluded gone within a few seconds.
  val maxConsecutiveWriteFailures = 3
  var writeFailures = 0
  // Adaptive poll cadence (#495): poll responsively while output is flowing,
  // but back off toward maxPollMs during quiet stretches so a long, idle run
  // doesn't refetch the whole container log every second (each tick opens a
  // fresh Docker client + refetches the full log), matching the frontend's own
  // 1.5s->6s backoff. Reset to minPollMs the moment new output appears.
  val minPollMs = 1000
  val maxPollMs = 5000
  var pollMs = minPollMs
  var offset = 0
  var finished = false
  var clientGone = false
  var timedOut = false
  // The container id is stored by the async task via updateSessionContainerFor
  // shortly after creation. Resolve it once and cache it — re-querying the DB
  // every ~400ms tick for the whole run is needless load (#483). getSession is
  // owner-scoped and runs on the request thread where the identity is stamped,
  // matching getRunOutputFrom.
  var containerId = ""
  // Phase 6 (docs/phase6-mcp-callbacks.md §5): when MCP callbacks are enabled,
  // this same poll loop also watches for new permission requests / user
  // questions / progress reports the container's MCP calls create mid-run,
  // and forwards each as its own SSE event. This is the only place in the
  // whole request lifecycle holding an open ResponseWriter for the session's
  // active stream — the callback HANDLERS themselves (CloudAgents.Callbacks)
  // run on a SEPARATE HTTP request from the container and have no writer to
  // push through directly. Cursors start at the run's own start time so a
  // request/question/progress report from a PRIOR run is never re-emitted.
  val callbacksOn = CloudAgents.NetworkPolicy.callbacksFeatureEnabled()
  var permissionCursor = toString(startMs)
  var questionCursor = toString(startMs)
  var lastProgressSummary = ""
  var lastProgressPercent = ""
  // Poll on a ~1s cadence. taskWaitMs blocks up to that waiting for the run to
  // finish (true = the whole run completed), so the loop wakes on either a
  // timer tick or run completion. The interval is deliberately NOT tighter
  // (#489): each tick's partialContainerLogs blocks up to ~1.5s AND refetches
  // the WHOLE container log (Lyric.Docker's logs wrapper has no incremental
  // fetch), so a shorter interval just multiplies full-log refetches for a
  // long, chatty run without meaningfully improving perceived latency.
  while not finished and not clientGone and not timedOut {
    finished = taskWaitMs(t, pollMs)
    if containerId.length == 0 {
      containerId = sessionContainerId(sessionId)
    }
    if containerId.length > 0 {
      val delta = CloudAgents.Streaming.outputDelta(partialContainerLogs(containerId), offset)
      if delta.length > 0 {
        // Fresh output — stay responsive.
        pollMs = minPollMs
        match Web.writeChunk(w, CloudAgents.Streaming.toSseChunk(delta)) {
          case Ok(_) -> {
            // Only advance PAST bytes actually delivered, so a failed write
            // re-sends the same delta next tick rather than losing it (#491).
            offset = offset + delta.length.toInt()
            writeFailures = 0
          }
          case Err(_) -> {
            writeFailures = writeFailures + 1
            if writeFailures >= maxConsecutiveWriteFailures {
              clientGone = true
            }
          }
        }
      } else {
        // Quiet tick — no new output. Send a keepalive comment frame (#499): the
        // only way to learn the client has vanished is to attempt a write, and
        // writes otherwise happen solely when there IS new output, so a client
        // that disconnects during a long silence would go undetected until the
        // next chunk or the 30-minute cap. The keepalive carries no data (the
        // frontend parser skips it), so it costs nothing in the transcript but
        // exercises the connection — a gone client fails it and is concluded gone
        // via the same consecutive-failure counter as a real chunk.
        match Web.writeChunk(w, CloudAgents.Streaming.sseKeepalive()) {
          case Ok(_) -> {
            writeFailures = 0
          }
          case Err(_) -> {
            writeFailures = writeFailures + 1
            if writeFailures >= maxConsecutiveWriteFailures {
              clientGone = true
            }
          }
        }
        // Back off (doubling, capped) to spare the Docker daemon. The
        // doubling-and-cap math lives in a pure, unit-tested helper so the
        // backoff has coverage without Docker (#498).
        pollMs = CloudAgents.Streaming.nextPollMs(pollMs, maxPollMs)
      }
    }
    // Phase 6 (docs/phase6-mcp-callbacks.md §5): forward any permission
    // requests / user questions / progress reports the container's MCP calls
    // created since the last tick. Best-effort — a write or read failure here
    // must never affect the run's own success/failure or trip the
    // output-stream disconnect counter above, since these are supplementary
    // events on top of the primary output stream.
    if callbacksOn {
      match CloudAgents.Repository.permissionRequestsCreatedAfter(sessionId, permissionCursor) {
        case Ok(reqs) -> {
          var ri = 0
          while ri < reqs.length {
            val pr = reqs[ri]
            match Web.writeChunk(w, CloudAgents.Streaming.ssePermissionRequest(pr.id, pr.toolName, pr.inputJson)) {
              case Ok(_) -> ()
              case Err(_) -> ()
            }
            permissionCursor = pr.createdAt
            ri = ri + 1
          }
        }
        case Err(_) -> ()
      }
      match CloudAgents.Repository.userQuestionsCreatedAfter(sessionId, questionCursor) {
        case Ok(qs) -> {
          var qi = 0
          while qi < qs.length {
            val q = qs[qi]
            match Web.writeChunk(w, CloudAgents.Streaming.sseUserQuestion(q.id, q.question, q.optionsJson)) {
              case Ok(_) -> ()
              case Err(_) -> ()
            }
            questionCursor = q.createdAt
            qi = qi + 1
          }
        }
        case Err(_) -> ()
      }
      match CloudAgents.Repository.sessionProgress(sessionId) {
        case Ok(p) -> {
          if p.summary.length > 0 and (p.summary != lastProgressSummary or p.percent != lastProgressPercent) {
            lastProgressSummary = p.summary
            lastProgressPercent = p.percent
            match Web.writeChunk(w, CloudAgents.Streaming.sseProgressUpdate(p.summary, p.percent)) {
              case Ok(_) -> ()
              case Err(_) -> ()
            }
          }
        }
        case Err(_) -> ()
      }
    }
    // Hard cap the whole run (#481): a hung container with a still-connected
    // client would otherwise hold the session's RUNNING claim forever, where
    // the old runSessionMessage bounded it with a 30-minute taskWaitMs.
    if CloudAgents.Repository.nowMillisLong() - startMs > runTimeoutMs {
      timedOut = true
    }
  }
  // Bail ONLY when the run did not actually finish (#488). A client disconnect
  // is only detectable on an attempted write, and writes only happen when there
  // is new output — so a client that vanished during a quiet stretch is often
  // "discovered" on the run's FINAL flush, the same tick `finished` becomes
  // true. `finished` therefore wins: a completed run's real outcome
  // (cell.isSuccess) must be honoured — its reply persisted and history marked
  // succeeded — even if clientGone/timedOut also flipped on that last tick.
  if not finished {
    // The run is still executing (we bailed early on a mid-run disconnect or the
    // hard cap), so terminate its container.
    //
    // The background run task (runSessionMessageAsync, `t`) is still live and
    // will ALSO try to remove this container in its own cleanup — but that race
    // is benign (#487): removeContainer on an already-removed container is
    // best-effort (Docker 304/404, swallowed), and the container-id clear is a
    // compare-and-clear (clearSessionContainerIfMatchesFor, #45) that only wipes
    // the row if it still points at THIS container, so a newer run's id is never
    // clobbered. Terminating here just makes the still-running task's blocking
    // waitContainer return promptly instead of hanging for the full run.
    if containerId.length == 0 {
      containerId = sessionContainerId(sessionId)
    }
    if containerId.length > 0 {
      val _ = terminateSessionContainer(containerId)
    }
    if timedOut {
      return Err(error = "Container run timed out after 30 minutes")
    }
    return Err(error = "client disconnected")
  }
  // The run finished. Honour its real outcome regardless of a last-tick
  // disconnect (a gone client just won't receive the final frames).
  if cell.isSuccess {
    // Flush any output produced since the last poll (best-effort — the write
    // fails harmlessly if the client is gone). cell.output is authoritative.
    val finalLogs = cell.output
    val delta = CloudAgents.Streaming.outputDelta(finalLogs, offset)
    if delta.length > 0 {
      match Web.writeChunk(w, CloudAgents.Streaming.toSseChunk(delta)) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }
    }
    return Ok(value = finalLogs)
  }
  // Failure path: no final flush is attempted here (#497). runSessionMessageAsync
  // only ever writes cell.output on SUCCESS — on failure cell.output stays "" and
  // cell.error carries the reason — so an outputDelta against it would be a no-op.
  // Any partial container output the run DID produce before failing was already
  // streamed by the loop above (it writes each delta as it appears, independent of
  // the eventual success/failure). The caller (streamSendMessage) turns this Err
  // into a terminal `event: error` SSE frame.
  return Err(error = cell.error)
}

// NOTE: all Result inspection below is match-based. The Std.Core convenience
// methods (.isOk(), .unwrapResult(), .unwrapErrOr()) compile as dot-calls but
// fail at runtime with "unsupported method" in the current toolchain — see
// docs/lyric/gotchas.md. This code had used them before any container run
// path had ever actually executed.
async func runSessionMessageAsync(
  repoUrl: in String,
  branch: in String,
  prompt: in String,
  sessionId: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String,
  profileId: in String,
  userId: in String,
  extraRepos: in String,
  cell: in ResultCell,
): Unit {
  // One client for the whole create-start-wait-logs-delete lifecycle below,
  // instead of a fresh client per call (#372).
  val client = dockerClient()
  val createResult = await createRunnerContainer(client, repoUrl, branch, prompt, sessionId, harness, model, nativeSessionId, profileId, userId, extraRepos)
  val containerId = match createResult {
    case Ok(id) -> id
    case Err(msg) -> {
      cell.isSuccess = false
      cell.error = msg
      return ()
    }
  }

  // Persist container ID to the session store (best-effort: the run matters
  // more than the bookkeeping).
  val _ = CloudAgents.SessionStore.updateSessionContainerFor(sessionId, userId, containerId)

  val startResult = await startRunnerContainer(client, containerId)
  match startResult {
    case Ok(_) -> ()
    case Err(msg) -> {
      cell.isSuccess = false
      cell.error = msg
      // Best-effort cleanup: remove the container even if start failed.
      await cleanupRunnerContainer(client, containerId, sessionId, userId)
      return ()
    }
  }

  // Block until the container process exits. If the wait call itself fails
  // (daemon unreachable, container vanished, etc.) we cannot safely fetch
  // complete logs, so we clean up and surface the error immediately.
  val waitResult = await waitForContainer(client, containerId)
  match waitResult {
    case Ok(_) -> ()
    case Err(msg) -> {
      await cleanupRunnerContainer(client, containerId, sessionId, userId)
      cell.isSuccess = false
      cell.error = msg
      return ()
    }
  }

  val logsResult = await getRunnerLogs(client, containerId)

  // Always remove the ephemeral container after the run. Session state
  // (workspace and home volumes) persists independently of the container.
  await cleanupRunnerContainer(client, containerId, sessionId, userId)

  match logsResult {
    case Ok(logs) -> {
      cell.isSuccess = true
      cell.output = logs
    }
    case Err(msg) -> {
      println("WARNING: failed to retrieve final logs for container " + containerId + ": " + msg)
      cell.isSuccess = false
      cell.error = msg
    }
  }
}

/// Terminate and delete a session container synchronously.
pub func terminateSessionContainer(containerId: in String): Result[Unit, String] {
  val cell = ResultCell(isSuccess = false, output = "", error = "")
  val t = terminateSessionContainerAsync(containerId, cell)
  val completed = taskWaitMs(t, 60000) // 60-second cap for stop+delete
  if not completed {
    return Err(error = "Container terminate timed out after 60 seconds")
  }
  if cell.isSuccess {
    return Ok(value = ())
  } else {
    return Err(error = cell.error)
  }
}

async func terminateSessionContainerAsync(containerId: in String, cell: in ResultCell): Unit {
  // One client shared across the stop+delete pair below (#372).
  val client = dockerClient()
  // Stop is best-effort: the container may already have exited (Docker returns
  // 304/404 in that case). We always attempt remove regardless.
  val _ = await stopRunnerContainer(client, containerId)
  val deleteResult = await deleteRunnerContainer(client, containerId)
  match deleteResult {
    case Ok(_) -> {
      cell.isSuccess = true
      cell.output = ""
    }
    case Err(msg) -> {
      cell.isSuccess = false
      cell.error = "Delete failed: " + msg
    }
  }
}
