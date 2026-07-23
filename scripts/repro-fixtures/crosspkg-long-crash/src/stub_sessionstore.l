package CloudAgents.SessionStore

import Std.Core
import CloudAgents.Sqlite

pub record AgentSession {
  pub sessionId: String
  pub repoUrl: String
  pub branch: String
  pub containerId: String
  pub harness: String
  pub model: String
  pub nativeSessionId: String
}

pub func clearSessionContainerIfMatchesFor(sessionId: in String, userId: in String, containerId: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  return Ok(value = ())
}

pub func getSession(sessionId: in String): Result[Option[AgentSession], CloudAgents.Sqlite.DbError] {
  return Ok(value = None)
}

pub func mintCallbackToken(sessionId: in String, userId: in String): Result[String, CloudAgents.Sqlite.DbError] {
  return Ok(value = "")
}

pub func updateSessionContainerFor(sessionId: in String, userId: in String, containerId: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  return Ok(value = ())
}
