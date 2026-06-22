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
  taskWaitUnit(t)
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
    return ()
  }

  val logsResult = await getRunnerLogs(containerId)
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
  taskWaitUnit(t)
  if cell.isSuccess {
    return Ok(value = ())
  } else {
    return Err(error = cell.error)
  }
}

async func terminateSessionContainerAsync(containerId: in String, cell: in ResultCell): Unit {
  val stopResult = await stopRunnerContainer(containerId)
  val deleteResult = await deleteRunnerContainer(containerId)
  if not stopResult.isOk() {
    cell.isSuccess = false
    cell.error = "Stop failed: " + stopResult.unwrapErrOr("unknown")
    return ()
  }
  if not deleteResult.isOk() {
    cell.isSuccess = false
    cell.error = "Delete failed: " + deleteResult.unwrapErrOr("unknown")
    return ()
  }
  cell.isSuccess = true
  cell.output = ""
}
