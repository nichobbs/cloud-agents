package CloudAgents.Repository

import Std.Core
import CloudAgents.Sqlite
import CloudAgents.Crypto

pub record CredentialValue {
  pub name: String
  pub value: String
}

@generate(Json)
pub record SkillList {
  pub skills: slice[Skill]
}

@generate(Json)
pub record SubagentList {
  pub subagents: slice[Subagent]
}

@generate(Json)
pub record McpServerList {
  pub mcpServers: slice[McpServer]
}

pub union CredentialError {
  case Db(error: CloudAgents.Sqlite.DbError)
  case Crypto(error: CloudAgents.Crypto.CryptoError)
}

pub record Skill {
  pub id: String
  pub userId: String
  pub name: String
  pub description: String
  pub body: String
  pub createdAt: String
  pub updatedAt: String
}

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
}

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

pub record SessionProgress {
  pub summary: String
  pub percent: String
}

pub record SecretRequest {
  pub id: String
  pub sessionId: String
  pub name: String
  pub reason: String
  pub status: String
  pub createdAt: String
  pub decidedAt: String
}

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

pub record Notification {
  pub id: String
  pub sessionId: String
  pub level: String
  pub summary: String
  pub createdAt: String
  pub readAt: String
}

pub func artifactsCreatedAfter(sessionId: in String, afterCreatedAt: in String): Result[slice[Artifact], CloudAgents.Sqlite.DbError] {
  return Ok(value = [])
}

pub func credentialErrorMessage(e: in CredentialError): String {
  return "credential error"
}

pub func decryptedCredentialsForProfile(userId: in String, profileId: in String): Result[slice[CredentialValue], CredentialError] {
  return Ok(value = [])
}

pub func enabledToolsForProfile(userId: in String, profileId: in String): Result[String, CloudAgents.Sqlite.DbError] {
  return Ok(value = "")
}

pub func mcpServersForProfile(userId: in String, profileId: in String): Result[slice[McpServer], CloudAgents.Sqlite.DbError] {
  return Ok(value = [])
}

pub func notificationsCreatedAfter(sessionId: in String, afterCreatedAt: in String): Result[slice[Notification], CloudAgents.Sqlite.DbError] {
  return Ok(value = [])
}

pub func nowMillisLong(): Long {
  return 1000.toLong()
}

pub func permissionRequestsCreatedAfter(sessionId: in String, afterCreatedAt: in String): Result[slice[PermissionRequest], CloudAgents.Sqlite.DbError] {
  return Ok(value = [])
}

pub func profileNetworkPolicy(userId: in String, profileId: in String): Result[String, CloudAgents.Sqlite.DbError] {
  return Ok(value = "none")
}

pub func secretRequestsCreatedAfter(sessionId: in String, afterCreatedAt: in String): Result[slice[SecretRequest], CloudAgents.Sqlite.DbError] {
  return Ok(value = [])
}

pub func sessionProgress(sessionId: in String): Result[SessionProgress, CloudAgents.Sqlite.DbError] {
  return Ok(value = SessionProgress(summary = "", percent = ""))
}

pub func skillsForProfile(userId: in String, profileId: in String): Result[slice[Skill], CloudAgents.Sqlite.DbError] {
  return Ok(value = [])
}

pub func subagentsForProfile(userId: in String, profileId: in String): Result[slice[Subagent], CloudAgents.Sqlite.DbError] {
  return Ok(value = [])
}

pub func userQuestionsCreatedAfter(sessionId: in String, afterCreatedAt: in String): Result[slice[UserQuestion], CloudAgents.Sqlite.DbError] {
  return Ok(value = [])
}
