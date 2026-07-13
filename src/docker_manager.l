package CloudAgents.Docker

import Std.Core
import Std.Task
import Lyric.Docker
import CloudAgents.Auth
import CloudAgents.NetworkPolicy
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite

pub record ResultCell {
  pub var isSuccess: Bool = false
  pub var output: String = ""
  pub var error: String = ""
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
pub async func createRunnerContainer(
  repoUrl: in String,
  branch: in String,
  prompt: in String,
  sessionId: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String,
  profileId: in String,
): Result[String, String] {
  val workspaceVolume = "session-" + sessionId + "-workspace"
  val homeVolume = "claude-home-default" // Phase 1 default, Phase 3 user-specific
  val userId = CloudAgents.Auth.currentUserId()

  var envs = [
    "PROMPT=" + prompt,
    "REPO_URL=" + repoUrl,
    "BRANCH=" + branch,
    "HARNESS=" + harness,
    "MODEL=" + model,
    "NATIVE_SESSION_ID=" + nativeSessionId
  ]

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
  val networkMode = CloudAgents.NetworkPolicy.networkModeForPolicy(policy)

  val binds = [workspaceVolume + ":/workspace", homeVolume + ":/home/claude-user"]

  val image = imageForHarness(harness)
  val client = makeDockerClient()
  val createRes = await createContainerWithNetwork(client, image, envs, binds, networkMode)
  match createRes {
    case Ok(id) -> Ok(value = id)
    case Err(e) -> Err(error = "Docker API error: " + e.message)
  }
}

/// Start the created runner container.
pub async func startRunnerContainer(containerId: in String): Result[Unit, String] {
  val client = makeDockerClient()
  val startRes = await startContainer(client, containerId)
  match startRes {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "Failed to start container: " + e.message)
  }
}

/// Stop the running container.
pub async func stopRunnerContainer(containerId: in String): Result[Unit, String] {
  val client = makeDockerClient()
  val stopRes = await stopContainer(client, containerId)
  match stopRes {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "Failed to stop container: " + e.message)
  }
}

/// Wait for a container's process to exit before reading its output.
pub async func waitForContainer(containerId: in String): Result[Unit, String] {
  val client = makeDockerClient()
  val waitRes = await waitContainer(client, containerId)
  match waitRes {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "Failed to wait for container: " + e.message)
  }
}

/// Delete the container.
pub async func deleteRunnerContainer(containerId: in String): Result[Unit, String] {
  val client = makeDockerClient()
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
async func cleanupRunnerContainer(containerId: in String, sessionId: in String): Unit {
  match await deleteRunnerContainer(containerId) {
    case Ok(_) -> ()
    case Err(e) -> println("WARNING: failed to remove container " + containerId + ": " + e)
  }
  val _ = CloudAgents.SessionStore.clearSessionContainerIfMatches(sessionId, containerId)
}

/// Retrieve output logs of the runner container.
pub async func getRunnerLogs(containerId: in String): Result[String, String] {
  val client = makeDockerClient()
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
  val logsResult = await getRunnerLogs(containerId)
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

/// Run a session message synchronously by orchestrating async container actions.
pub func runSessionMessage(
  repoUrl: in String,
  branch: in String,
  prompt: in String,
  sessionId: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String,
  profileId: in String,
): Result[String, String] {
  val cell = ResultCell(isSuccess = false, output = "", error = "")
  val t = runSessionMessageAsync(repoUrl, branch, prompt, sessionId, harness, model, nativeSessionId, profileId, cell)
  val completed = taskWaitMs(t, 1800000) // 30-minute hard cap
  if not completed {
    return Err(error = "Container run timed out after 30 minutes")
  }
  if cell.isSuccess {
    return Ok(value = cell.output)
  } else {
    return Err(error = cell.error)
  }
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
  cell: in ResultCell,
): Unit {
  val createResult = await createRunnerContainer(repoUrl, branch, prompt, sessionId, harness, model, nativeSessionId, profileId)
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
  val _ = CloudAgents.SessionStore.updateSessionContainer(sessionId, containerId)

  val startResult = await startRunnerContainer(containerId)
  match startResult {
    case Ok(_) -> ()
    case Err(msg) -> {
      cell.isSuccess = false
      cell.error = msg
      // Best-effort cleanup: remove the container even if start failed.
      await cleanupRunnerContainer(containerId, sessionId)
      return ()
    }
  }

  // Block until the container process exits. If the wait call itself fails
  // (daemon unreachable, container vanished, etc.) we cannot safely fetch
  // complete logs, so we clean up and surface the error immediately.
  val waitResult = await waitForContainer(containerId)
  match waitResult {
    case Ok(_) -> ()
    case Err(msg) -> {
      await cleanupRunnerContainer(containerId, sessionId)
      cell.isSuccess = false
      cell.error = msg
      return ()
    }
  }

  val logsResult = await getRunnerLogs(containerId)

  // Always remove the ephemeral container after the run. Session state
  // (workspace and home volumes) persists independently of the container.
  await cleanupRunnerContainer(containerId, sessionId)

  match logsResult {
    case Ok(logs) -> {
      cell.isSuccess = true
      cell.output = logs
    }
    case Err(msg) -> {
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
  // Stop is best-effort: the container may already have exited (Docker returns
  // 304/404 in that case). We always attempt remove regardless.
  val _ = await stopRunnerContainer(containerId)
  val deleteResult = await deleteRunnerContainer(containerId)
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
