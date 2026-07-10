//! HTTP handlers for the per-user credential store.
//!
//! Write-only by design: values can be stored and deleted, and their *names*
//! listed, but a stored secret is never returned to any response. Values are
//! AES-GCM encrypted at rest (CloudAgents.Crypto) and only ever decrypted
//! server-side when building a runner container's environment
//! (CloudAgents.Docker). Every route is scoped to the caller's identity
//! (CloudAgents.Auth.currentUserId()).
//!
//! NB: because these endpoints expose/accept secrets, they must never run on
//! an unauthenticated deployment. Enforcement uses CloudAgents.Auth's
//! authorizeSecret once Lyric.Web exposes request headers to handlers
//! (docs/BUILD.md "Dependencies"); the validation/storage logic is complete
//! and unit-tested now.
package CloudAgents.Credentials

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.Repository
import CloudAgents.Sqlite

val maxCredentialNameLen = 128
val maxCredentialValueLen = 65536

@generate(Json)
pub record PutCredentialRequest {
  pub name: String
  pub value: String
}

/// Env-var name rules: a leading letter or underscore, then letters, digits
/// or underscores. Keeps injected names shell- and Docker-safe.
func isValidCredentialName(name: in String): Bool {
  if name.length == 0 or name.length > maxCredentialNameLen {
    return false
  }
  var i = 0
  while i < name.length {
    val c = name.substring(i, 1)
    val isUpper = c >= "A" and c <= "Z"
    val isLower = c >= "a" and c <= "z"
    val isDigit = c >= "0" and c <= "9"
    val isUnderscore = c == "_"
    if i == 0 {
      if not (isUpper or isLower or isUnderscore) {
        return false
      }
    } else {
      if not (isUpper or isLower or isDigit or isUnderscore) {
        return false
      }
    }
    i = i + 1
  }
  return true
}

/// List the caller's stored credential names (never values).
@get("/api/credentials")
pub func listCredentialsHandler(): Result[CredentialNameList, Web.ApiError] {
  match listCredentialNames(CloudAgents.Auth.currentUserId()) {
    case Ok(names) -> return Ok(CredentialNameList(credentials = names))
    case Err(e) -> return Err(Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e)))
  }
}

/// Store or replace a credential.
@post("/api/credentials")
pub func putCredentialHandler(@body req: in PutCredentialRequest): Result[Unit, Web.ApiError] {
  if not isValidCredentialName(req.name) {
    return Err(Web.badRequest("name must be a valid environment variable name (letters, digits, underscore; no leading digit)"))
  }
  if req.value.length == 0 {
    return Err(Web.badRequest("value is required"))
  }
  if req.value.length > maxCredentialValueLen {
    return Err(Web.badRequest("value is too long (max 65536 characters)"))
  }
  match putCredential(CloudAgents.Auth.currentUserId(), req.name, req.value) {
    case Ok(_) -> return Ok(())
    case Err(e) -> return Err(Web.internalError("failed to store credential: " + credentialErrorMessage(e)))
  }
}

/// Delete a credential by name.
@delete("/api/credentials/{name}")
pub func deleteCredentialHandler(name: in String): Result[Unit, Web.ApiError] {
  if name.length == 0 {
    return Err(Web.badRequest("credential name is required"))
  }
  val affected = match deleteCredential(CloudAgents.Auth.currentUserId(), name) {
    case Ok(n) -> n
    case Err(e) -> return Err(Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e)))
  }
  if affected == 0 {
    return Err(Web.notFound("credential not found"))
  }
  return Ok(())
}
