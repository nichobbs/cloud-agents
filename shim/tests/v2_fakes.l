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

  pub var forgetOk: Bool
  pub var forgetBody: String
  pub var forgetError: String
  pub var lastForgetKey: String
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
    forgetOk = false,
    forgetBody = "",
    forgetError = "FakeV2Transport: forget not configured",
    lastForgetKey = ""
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
    fileName: in String, mimeType: in String, description: in String, contentBase64: in String
  ): Result[String, String] {
    self.uploadArtifactCallCount = self.uploadArtifactCallCount + 1
    self.lastUploadFileName = fileName
    self.lastUploadMimeType = mimeType
    self.lastUploadDescription = description
    self.lastUploadContentBase64 = contentBase64
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

  func forget(key: in String): Result[String, String] {
    self.lastForgetKey = key
    if self.forgetOk {
      Ok(value = self.forgetBody)
    } else {
      Err(error = self.forgetError)
    }
  }
}
