//! src/v2_transport.l — CloudAgents.Shim.V2Transport: the wire records and
//! HTTP transport seam for the three phase-6 §7 v2 tools (request_secret,
//! add_followup_task, report_artifact), mirroring CloudAgents.Callbacks'
//! new handlers (cloud-agents' src/handlers/callbacks.l) field-for-field —
//! keep these two in sync by hand.
//!
//! Deliberately its own file rather than an extension of
//! CloudAgents.Shim.Transport: that package is shared with the §8 work
//! landing in parallel on `callbacks_client.l` in the same repo, and this
//! avoids widening the shared `CallbackTransport` interface (which
//! `tests/fakes.l` also implements) while that work is in flight. This
//! module reuses CloudAgents.Shim.Transport's already-audited HTTP
//! primitives (`getWithBearer`/`postJsonWithBearer`) rather than
//! redeclaring the `HttpWebRequest` externs.
package CloudAgents.Shim.V2Transport

import Std.Core
import CloudAgents.Shim.Transport

// ── Wire records — mirror CloudAgents.Callbacks (cloud-agents'
// src/handlers/callbacks.l) field-for-field. ──────────────────────────────────
@generate(Json)
pub record CreateSecretRequestRequest {
  pub name: String
  pub reason: String
}

@generate(Json)
pub record CreateSecretRequestResponse {
  pub id: String
  pub status: String
}

@generate(Json)
pub record SecretDecision {
  pub status: String
  pub value: String
}

@generate(Json)
pub record CreateFollowupTaskRequest {
  pub description: String
}

@generate(Json)
pub record CreateFollowupTaskResponse {
  pub id: String
}

@generate(Json)
pub record UploadArtifactRequest {
  pub fileName: String
  pub mimeType: String
  pub description: String
  pub contentBase64: String
}

@generate(Json)
pub record UploadArtifactResponse {
  pub id: String
}

// Phase 7 §4 repo-scoped memory (remember / recall) — mirror
// CloudAgents.Callbacks field-for-field.
@generate(Json)
pub record RememberRequest {
  pub key: String
  pub value: String
}

@generate(Json)
pub record RememberResponse {
  pub key: String
}

@generate(Json)
pub record MemoryEntry {
  pub key: String
  pub value: String
}

@generate(Json)
pub record MemoryListResponse {
  pub entries: slice[MemoryEntry]
}

// ── Decoding helpers ─────────────────────────────────────────────────────────
// Same defensive shape as CloudAgents.Shim.Transport's tryDecode* helpers: a
// syntactically invalid JSON body throws a raw JsonException instead of
// returning Err, so these fold both failure modes into Option.
pub func tryDecodeCreateSecretRequestResponse(body: in String): Option[CreateSecretRequestResponse] {
  try {
    match CreateSecretRequestResponse.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

pub func tryDecodeSecretDecision(body: in String): Option[SecretDecision] {
  try {
    match SecretDecision.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

pub func tryDecodeCreateFollowupTaskResponse(body: in String): Option[CreateFollowupTaskResponse] {
  try {
    match CreateFollowupTaskResponse.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

pub func tryDecodeUploadArtifactResponse(body: in String): Option[UploadArtifactResponse] {
  try {
    match UploadArtifactResponse.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

pub func tryDecodeRememberResponse(body: in String): Option[RememberResponse] {
  try {
    match RememberResponse.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

pub func tryDecodeMemoryListResponse(body: in String): Option[MemoryListResponse] {
  try {
    match MemoryListResponse.fromJson(body) {
      case Ok(r) -> Some(value = r)
      case Err(_) -> None
    }
  } catch Bug as b {
    None
  }
}

// ── Transport seam ───────────────────────────────────────────────────────────
/// The shim's outbound calls to the host for the v2 tools, as an interface
/// so CloudAgents.Shim.V2Client's state machines can be tested against an
/// in-memory fake (tests/v2_fakes.l) with no real socket.
pub interface V2CallbackTransport {
  func createSecret(name: in String, reason: in String): Result[String, String]
  func pollSecret(requestId: in String): Result[String, String]
  func createTodo(description: in String): Result[String, String]
  func uploadArtifact(fileName: in String, mimeType: in String, description: in String, contentBase64: in String): Result[String, String]
  func remember(key: in String, value: in String): Result[String, String]
  func recallAll(): Result[String, String]
}

/// Real V2CallbackTransport against the cloud-agents host API. Route shapes
/// match CloudAgents.Callbacks / src/main.l's route table exactly
/// (docs/phase6-mcp-callbacks.md §7): POST .../callbacks/secret, GET
/// .../callbacks/secret/{rid}, POST .../callbacks/todo, POST
/// .../callbacks/artifact.
pub record HttpV2CallbackTransport {
  pub baseUrl: String
  pub sessionId: String
  pub token: String
}

impl V2CallbackTransport for HttpV2CallbackTransport {
  func createSecret(name: in String, reason: in String): Result[String, String] {
    val body = CreateSecretRequestRequest(name = name, reason = reason).toJson()
    CloudAgents.Shim.Transport.postJsonWithBearer(
      self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/secret",
      self.token,
      body
    )
  }

  func pollSecret(requestId: in String): Result[String, String] {
    CloudAgents.Shim.Transport.getWithBearer(
      self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/secret/" + requestId,
      self.token
    )
  }

  func createTodo(description: in String): Result[String, String] {
    val body = CreateFollowupTaskRequest(description = description).toJson()
    CloudAgents.Shim.Transport.postJsonWithBearer(
      self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/todo",
      self.token,
      body
    )
  }

  func uploadArtifact(
    fileName: in String, mimeType: in String, description: in String, contentBase64: in String
  ): Result[String, String] {
    val body = UploadArtifactRequest(fileName = fileName, mimeType = mimeType, description = description, contentBase64 = contentBase64).toJson()
    CloudAgents.Shim.Transport.postJsonWithBearer(
      self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/artifact",
      self.token,
      body
    )
  }

  func remember(key: in String, value: in String): Result[String, String] {
    val body = RememberRequest(key = key, value = value).toJson()
    CloudAgents.Shim.Transport.postJsonWithBearer(
      self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/memory",
      self.token,
      body
    )
  }

  func recallAll(): Result[String, String] {
    CloudAgents.Shim.Transport.getWithBearer(
      self.baseUrl + "/api/sessions/" + self.sessionId + "/callbacks/memory",
      self.token
    )
  }
}
