package CloudAgents.Docker

import Std.Core
import Std.Task
import Lyric.Docker
import CloudAgents.SessionStore

pub record ResultCell {
  pub var isSuccess: Bool = false
  pub var output: String = ""
  pub var error: String = ""
}

@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWaitUnit[T](t: in T): Unit = ()

/// Returns true if the task completed within timeoutMs, false on timeout.
@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWaitMs[T](t: in T, timeoutMs: in Int): Bool = false

/// Docker image name for the given harness.
func imageForHarness(harness: in String): String {
  if harness == "codex" { return "codex:base" }
  if harness == "opencode" { return "opencode:base" }
  return "claude-code:base"
}

/// Create an ephemeral container for the given session.
/// HARNESS, MODEL, and NATIVE_SESSION_ID are passed as env vars so each
/// container image can invoke the right CLI with the right resume flag.
pub async func createRunnerContainer(
  repoUrl: in String,
  branch: in String,
  prompt: in String,
  sessionId: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String
): Result[String, String] {
  val client = defaultClient()

  val workspaceVolume = "session-" + sessionId + "-workspace"
  val homeVolume = "claude-home-default" // Phase 1 default, Phase 3 user-specific

  val envs = [
    "PROMPT=" + prompt,
    "REPO_URL=" + repoUrl,
    "BRANCH=" + branch,
    "HARNESS=" + harness,
    "MODEL=" + model,
    "NATIVE_SESSION_ID=" + nativeSessionId
  ]
  val binds = [
    workspaceVolume + ":/workspace",
    homeVolume + ":/home/claude-user"
  ]

  val image = imageForHarness(harness)
  val createRes = await createContainer(client, image = image, env = envs, binds = binds)
  match createRes {
    case Ok(id) -> Ok(value = id)
    case Err(e) -> Err(error = "Docker API error: " + e.message)
  }
}

/// Start the created runner container.
pub async func startRunnerContainer(containerId: in String): Result[Unit, String] {
  val client = defaultClient()
  val startRes = await startContainer(client, containerId)
  match startRes {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "Failed to start container: " + e.message)
  }
}

/// Stop the running container.
pub async func stopRunnerContainer(containerId: in String): Result[Unit, String] {
  val client = defaultClient()
  val stopRes = await stopContainer(client, containerId)
  match stopRes {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "Failed to stop container: " + e.message)
  }
}

/// Wait for a container's process to exit before reading its output.
pub async func waitForContainer(containerId: in String): Result[Unit, String] {
  val client = defaultClient()
  val waitRes = await waitContainer(client, containerId)
  match waitRes {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "Failed to wait for container: " + e.message)
  }
}

/// Delete the container.
pub async func deleteRunnerContainer(containerId: in String): Result[Unit, String] {
  val client = defaultClient()
  val deleteRes = await removeContainer(client, containerId)
  match deleteRes {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "Failed to delete container: " + e.message)
  }
}

/// Retrieve output logs of the runner container.
pub async func getRunnerLogs(containerId: in String): Result[String, String] {
  val client = defaultClient()
  val logsRes = await getContainerLogs(client, containerId)
  match logsRes {
    case Ok(logs) -> Ok(value = logs)
    case Err(e) -> Err(error = "Failed to retrieve logs: " + e.message)
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
  nativeSessionId: in String
): Result[String, String] {
  val cell = ResultCell(isSuccess = false, output = "", error = "")
  val t = runSessionMessageAsync(repoUrl, branch, prompt, sessionId, harness, model, nativeSessionId, cell)
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

async func runSessionMessageAsync(
  repoUrl: in String,
  branch: in String,
  prompt: in String,
  sessionId: in String,
  harness: in String,
  model: in String,
  nativeSessionId: in String,
  cell: in ResultCell
): Unit {
  val createResult = await createRunnerContainer(repoUrl, branch, prompt, sessionId, harness, model, nativeSessionId)
  if not createResult.isOk() {
    cell.isSuccess = false
    cell.error = createResult.unwrapErrOr("unknown error")
    return ()
  }
  val containerId = createResult.unwrapResult()

  // Persist container ID to the session store
  CloudAgents.SessionStore.updateSessionContainer(sessionId, containerId)

  val startResult = await startRunnerContainer(containerId)
  if not startResult.isOk() {
    cell.isSuccess = false
    cell.error = startResult.unwrapErrOr("unknown error")
    // Best-effort cleanup: remove the container even if start failed
    val _ = await deleteRunnerContainer(containerId)
    CloudAgents.SessionStore.updateSessionContainer(sessionId, "")
    return ()
  }

  // Block until the container process exits. If the wait call itself fails
  // (daemon unreachable, container vanished, etc.) we cannot safely fetch
  // complete logs, so we clean up and surface the error immediately.
  val waitResult = await waitForContainer(containerId)
  if not waitResult.isOk() {
    val _ = await deleteRunnerContainer(containerId)
    CloudAgents.SessionStore.updateSessionContainer(sessionId, "")
    cell.isSuccess = false
    cell.error = waitResult.unwrapErrOr("unknown error")
    return ()
  }

  val logsResult = await getRunnerLogs(containerId)

  // Always remove the ephemeral container after the run. Session state
  // (workspace and home volumes) persists independently of the container.
  val _ = await deleteRunnerContainer(containerId)
  CloudAgents.SessionStore.updateSessionContainer(sessionId, "")

  if not logsResult.isOk() {
    cell.isSuccess = false
    cell.error = logsResult.unwrapErrOr("unknown error")
    return ()
  }
  cell.isSuccess = true
  cell.output = logsResult.unwrapResult()
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
  if not deleteResult.isOk() {
    cell.isSuccess = false
    cell.error = "Delete failed: " + deleteResult.unwrapErrOr("unknown")
    return ()
  }
  cell.isSuccess = true
  cell.output = ""
}
