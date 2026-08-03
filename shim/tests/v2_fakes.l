//! tests/v2_fakes.l — CloudAgents.Shim.V2TestFakes: an in-memory
//! V2CallbackTransport fake, shared by tests/v2_client_tests.l and
//! tests/v2_tools_tests.l. Mirrors tests/fakes.l's FakeTransport exactly —
//! see that file's header comment for why each one-shot outcome is a
//! Bool/String/String triple rather than a `Result[String, String]` field
//! (a confirmed self-hosted MSIL codegen bug, docs/lyric/gotchas.md).
//!
//! Registered under [project.packages] in lyric.toml, not [project.tests],
//! purely so both `@test_module` files can `import` it by package name.
package CloudAgents.Shim.V2TestFakes

import Std.Core
import Std.Collections
import CloudAgents.Shim.V2Transport

pub record FakeV2Transport {
  pub var createSecretOk: Bool
  pub var createSecretBody: String
  pub var createSecretError: String
  pub var lastSecretName: String
  pub var lastSecretReason: String

  pub var pollSecretBodies: List[String]
  pub var pollSecretCallCount: Int

  pub var createTodoOk: Bool
  pub var createTodoBody: String
  pub var createTodoError: String
  pub var lastTodoDescription: String

  pub var uploadArtifactOk: Bool
  pub var uploadArtifactBody: String
  pub var uploadArtifactError: String
  pub var lastUploadFileName: String
  pub var lastUploadMimeType: String
  pub var lastUploadDescription: String
  pub var lastUploadContentBase64: String
  pub var lastUploadArtifactScope: String
  pub var uploadArtifactCallCount: Int

  pub var rememberOk: Bool
  pub var rememberBody: String
  pub var rememberError: String
  pub var lastRememberKey: String
  pub var lastRememberValue: String

  pub var recallOk: Bool
  pub var recallBody: String
  pub var recallError: String
  pub var recallCallCount: Int

  pub var recallByKeyOk: Bool
  pub var recallByKeyBody: String
  pub var recallByKeyError: String
  pub var lastRecallKey: String
  pub var recallByKeyCallCount: Int

  pub var forgetOk: Bool
  pub var forgetBody: String
  pub var forgetError: String
  pub var lastForgetKey: String

  pub var createTaskOk: Bool
  pub var createTaskBody: String
  pub var createTaskError: String
  pub var lastTaskDescription: String

  pub var listTasksOk: Bool
  pub var listTasksBody: String
  pub var listTasksError: String
  pub var lastTaskStatusFilter: String

  pub var completeTaskOk: Bool
  pub var completeTaskBody: String
  pub var completeTaskError: String
  pub var lastCompleteTaskId: String

  pub var notifyOk: Bool
  pub var notifyBody: String
  pub var notifyError: String
  pub var lastNotifySummary: String
  pub var lastNotifyLevel: String
  pub var notifyCallCount: Int

  pub var createSessionTodoOk: Bool
  pub var createSessionTodoBody: String
  pub var createSessionTodoError: String
  pub var lastSessionTodoNote: String

  pub var listSessionTodosOk: Bool
  pub var listSessionTodosBody: String
  pub var listSessionTodosError: String

  pub var setSessionTodoStatusOk: Bool
  pub var setSessionTodoStatusBody: String
  pub var setSessionTodoStatusError: String
  pub var lastSessionTodoId: String
  pub var lastSessionTodoStatus: String

  pub var scheduleJobOk: Bool
  pub var scheduleJobBody: String
  pub var scheduleJobError: String
  pub var lastScheduleJobName: String
  pub var lastScheduleJobPrompt: String
  pub var lastScheduleJobRunAtEpochMillis: String
  pub var lastScheduleJobIntervalSeconds: String

  pub var listJobsOk: Bool
  pub var listJobsBody: String
  pub var listJobsError: String

  pub var updateJobOk: Bool
  pub var updateJobBody: String
  pub var updateJobError: String
  pub var lastUpdateJobId: String
  pub var lastUpdateJobPrompt: String
  pub var lastUpdateJobProfileId: String
  pub var lastUpdateJobRunAtEpochMillis: String
  pub var lastUpdateJobIntervalSeconds: String
  pub var lastUpdateJobStatus: String

  pub var cancelJobOk: Bool
  pub var cancelJobBody: String
  pub var cancelJobError: String
  pub var lastCancelJobId: String
}

/// A ready-to-use fake with sensible not-configured-yet defaults: creating
/// any of the three request kinds fails outright. Override the fields a
/// given test actually exercises.
pub func newFakeV2Transport(): FakeV2Transport {
  FakeV2Transport(
    createSecretOk = false,
    createSecretBody = "",
    createSecretError = "FakeV2Transport: createSecret not configured",
    lastSecretName = "",
    lastSecretReason = "",
    pollSecretBodies = newList(),
    pollSecretCallCount = 0,
    createTodoOk = false,
    createTodoBody = "",
    createTodoError = "FakeV2Transport: createTodo not configured",
    lastTodoDescription = "",
    uploadArtifactOk = false,
    uploadArtifactBody = "",
    uploadArtifactError = "FakeV2Transport: uploadArtifact not configured",
    lastUploadFileName = "",
    lastUploadMimeType = "",
    lastUploadDescription = "",
    lastUploadContentBase64 = "",
    lastUploadArtifactScope = "",
    uploadArtifactCallCount = 0,
    rememberOk = false,
    rememberBody = "",
    rememberError = "FakeV2Transport: remember not configured",
    lastRememberKey = "",
    lastRememberValue = "",
    recallOk = false,
    recallBody = "",
    recallError = "FakeV2Transport: recallAll not configured",
    recallCallCount = 0,
    recallByKeyOk = false,
    recallByKeyBody = "",
    recallByKeyError = "FakeV2Transport: recallByKey not configured",
    lastRecallKey = "",
    recallByKeyCallCount = 0,
    forgetOk = false,
    forgetBody = "",
    forgetError = "FakeV2Transport: forget not configured",
    lastForgetKey = "",
    createTaskOk = false,
    createTaskBody = "",
    createTaskError = "FakeV2Transport: createTask not configured",
    lastTaskDescription = "",
    listTasksOk = false,
    listTasksBody = "",
    listTasksError = "FakeV2Transport: listTasks not configured",
    lastTaskStatusFilter = "",
    completeTaskOk = false,
    completeTaskBody = "",
    completeTaskError = "FakeV2Transport: completeTask not configured",
    lastCompleteTaskId = "",
    notifyOk = false,
    notifyBody = "",
    notifyError = "FakeV2Transport: notify not configured",
    lastNotifySummary = "",
    lastNotifyLevel = "",
    notifyCallCount = 0,
    createSessionTodoOk = false,
    createSessionTodoBody = "",
    createSessionTodoError = "FakeV2Transport: createSessionTodo not configured",
    lastSessionTodoNote = "",
    listSessionTodosOk = false,
    listSessionTodosBody = "",
    listSessionTodosError = "FakeV2Transport: listSessionTodos not configured",
    setSessionTodoStatusOk = false,
    setSessionTodoStatusBody = "",
    setSessionTodoStatusError = "FakeV2Transport: setSessionTodoStatus not configured",
    lastSessionTodoId = "",
    lastSessionTodoStatus = "",
    scheduleJobOk = false,
    scheduleJobBody = "",
    scheduleJobError = "FakeV2Transport: scheduleJob not configured",
    lastScheduleJobName = "",
    lastScheduleJobPrompt = "",
    lastScheduleJobRunAtEpochMillis = "",
    lastScheduleJobIntervalSeconds = "",
    listJobsOk = false,
    listJobsBody = "",
    listJobsError = "FakeV2Transport: listJobs not configured",
    updateJobOk = false,
    updateJobBody = "",
    updateJobError = "FakeV2Transport: updateJob not configured",
    lastUpdateJobId = "",
    lastUpdateJobPrompt = "",
    lastUpdateJobProfileId = "",
    lastUpdateJobRunAtEpochMillis = "",
    lastUpdateJobIntervalSeconds = "",
    lastUpdateJobStatus = "",
    cancelJobOk = false,
    cancelJobBody = "",
    cancelJobError = "FakeV2Transport: cancelJob not configured",
    lastCancelJobId = ""
  )
}

func nextScripted(bodies: in List[String], callCount: in Int): String {
  val idx = if callCount < bodies.count { callCount } else { bodies.count - 1 }
  return bodies[idx]
}

impl V2CallbackTransport for FakeV2Transport {
  func createSecret(name: in String, reason: in String): Result[String, String] {
    self.lastSecretName = name
    self.lastSecretReason = reason
    if self.createSecretOk {
      Ok(value = self.createSecretBody)
    } else {
      Err(error = self.createSecretError)
    }
  }

  func pollSecret(requestId: in String): Result[String, String] {
    val body = nextScripted(self.pollSecretBodies, self.pollSecretCallCount)
    self.pollSecretCallCount = self.pollSecretCallCount + 1
    Ok(value = body)
  }

  func createTodo(description: in String): Result[String, String] {
    self.lastTodoDescription = description
    if self.createTodoOk {
      Ok(value = self.createTodoBody)
    } else {
      Err(error = self.createTodoError)
    }
  }

  func uploadArtifact(
    fileName: in String,
    mimeType: in String,
    description: in String,
    contentBase64: in String,
    artifactScope: in String,
  ): Result[String, String] {
    self.uploadArtifactCallCount = self.uploadArtifactCallCount + 1
    self.lastUploadFileName = fileName
    self.lastUploadMimeType = mimeType
    self.lastUploadDescription = description
    self.lastUploadContentBase64 = contentBase64
    self.lastUploadArtifactScope = artifactScope
    if self.uploadArtifactOk {
      Ok(value = self.uploadArtifactBody)
    } else {
      Err(error = self.uploadArtifactError)
    }
  }

  func remember(key: in String, value: in String): Result[String, String] {
    self.lastRememberKey = key
    self.lastRememberValue = value
    if self.rememberOk {
      Ok(value = self.rememberBody)
    } else {
      Err(error = self.rememberError)
    }
  }

  func recallAll(): Result[String, String] {
    self.recallCallCount = self.recallCallCount + 1
    if self.recallOk {
      Ok(value = self.recallBody)
    } else {
      Err(error = self.recallError)
    }
  }

  func recallByKey(key: in String): Result[String, String] {
    self.lastRecallKey = key
    self.recallByKeyCallCount = self.recallByKeyCallCount + 1
    if self.recallByKeyOk {
      Ok(value = self.recallByKeyBody)
    } else {
      Err(error = self.recallByKeyError)
    }
  }

  func forget(key: in String): Result[String, String] {
    self.lastForgetKey = key
    if self.forgetOk {
      Ok(value = self.forgetBody)
    } else {
      Err(error = self.forgetError)
    }
  }

  func createTask(description: in String): Result[String, String] {
    self.lastTaskDescription = description
    if self.createTaskOk {
      Ok(value = self.createTaskBody)
    } else {
      Err(error = self.createTaskError)
    }
  }

  func listTasks(statusFilter: in String): Result[String, String] {
    self.lastTaskStatusFilter = statusFilter
    if self.listTasksOk {
      Ok(value = self.listTasksBody)
    } else {
      Err(error = self.listTasksError)
    }
  }

  func completeTask(taskId: in String): Result[String, String] {
    self.lastCompleteTaskId = taskId
    if self.completeTaskOk {
      Ok(value = self.completeTaskBody)
    } else {
      Err(error = self.completeTaskError)
    }
  }

  func notify(summary: in String, level: in String): Result[String, String] {
    self.notifyCallCount = self.notifyCallCount + 1
    self.lastNotifySummary = summary
    self.lastNotifyLevel = level
    if self.notifyOk {
      Ok(value = self.notifyBody)
    } else {
      Err(error = self.notifyError)
    }
  }

  func createSessionTodo(note: in String): Result[String, String] {
    self.lastSessionTodoNote = note
    if self.createSessionTodoOk {
      Ok(value = self.createSessionTodoBody)
    } else {
      Err(error = self.createSessionTodoError)
    }
  }

  func listSessionTodos(): Result[String, String] {
    if self.listSessionTodosOk {
      Ok(value = self.listSessionTodosBody)
    } else {
      Err(error = self.listSessionTodosError)
    }
  }

  func setSessionTodoStatus(todoId: in String, status: in String): Result[String, String] {
    self.lastSessionTodoId = todoId
    self.lastSessionTodoStatus = status
    if self.setSessionTodoStatusOk {
      Ok(value = self.setSessionTodoStatusBody)
    } else {
      Err(error = self.setSessionTodoStatusError)
    }
  }

  func scheduleJob(
    name: in String, prompt: in String, runAtEpochMillis: in String, intervalSeconds: in String
  ): Result[String, String] {
    self.lastScheduleJobName = name
    self.lastScheduleJobPrompt = prompt
    self.lastScheduleJobRunAtEpochMillis = runAtEpochMillis
    self.lastScheduleJobIntervalSeconds = intervalSeconds
    if self.scheduleJobOk {
      Ok(value = self.scheduleJobBody)
    } else {
      Err(error = self.scheduleJobError)
    }
  }

  func listJobs(): Result[String, String] {
    if self.listJobsOk {
      Ok(value = self.listJobsBody)
    } else {
      Err(error = self.listJobsError)
    }
  }

  func updateJob(
    jobId: in String,
    prompt: in String,
    profileId: in String,
    runAtEpochMillis: in String,
    intervalSeconds: in String,
    status: in String,
  ): Result[String, String] {
    self.lastUpdateJobId = jobId
    self.lastUpdateJobPrompt = prompt
    self.lastUpdateJobProfileId = profileId
    self.lastUpdateJobRunAtEpochMillis = runAtEpochMillis
    self.lastUpdateJobIntervalSeconds = intervalSeconds
    self.lastUpdateJobStatus = status
    if self.updateJobOk {
      Ok(value = self.updateJobBody)
    } else {
      Err(error = self.updateJobError)
    }
  }

  func cancelJob(jobId: in String): Result[String, String] {
    self.lastCancelJobId = jobId
    if self.cancelJobOk {
      Ok(value = self.cancelJobBody)
    } else {
      Err(error = self.cancelJobError)
    }
  }
}
