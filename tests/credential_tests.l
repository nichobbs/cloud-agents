@test_module
package CloudAgents.CredentialTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Credentials
import CloudAgents.Db
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
  match CloudAgents.Repository.initSchema() {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "initSchema failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  return path
}

func cleanupTestDb(path: in String): Unit {
  try {
    fileDelete(path)
  } catch Bug as b {
    // fine
  }
}

func mustPut(userId: in String, name: in String, value: in String): Unit {
  match putCredential(userId, name, value) {
    case Ok(_) -> ()
    case Err(e) -> panic("putCredential failed: " + credentialErrorMessage(e))
  }
}

func mustNames(userId: in String): slice[CredentialName] {
  return match listCredentialNames(userId) {
    case Ok(ns) -> ns
    case Err(e) -> panic("listCredentialNames failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustDecrypted(userId: in String): slice[CredentialValue] {
  return match decryptedCredentials(userId) {
    case Ok(cs) -> cs
    case Err(e) -> panic("decryptedCredentials failed: " + credentialErrorMessage(e))
  }
}

func findValue(creds: in slice[CredentialValue], name: in String): String {
  var i = 0
  while i < creds.length {
    if creds[i].name == name {
      return creds[i].value
    }
    i = i + 1
  }
  return "<missing>"
}

test "Credentials store, list names, and decrypt for injection" {
  val dbPath = useFreshTestDb("cred-crud")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"

  mustPut(userId, "GITHUB_TOKEN", "ghp_secret_value")
  mustPut(userId, "GOOGLE_PROJECT", "my-project-123")

  val names = mustNames(userId)
  assertEqualInt(names.length.toInt(), 2, "two credential names listed")
  // Alphabetical: GITHUB_TOKEN before GOOGLE_PROJECT.
  assertEqual(names[0].name, "GITHUB_TOKEN", "first name")
  assertEqual(names[1].name, "GOOGLE_PROJECT", "second name")

  // Values decrypt back for container injection.
  val decrypted = mustDecrypted(userId)
  assertEqual(findValue(decrypted, "GITHUB_TOKEN"), "ghp_secret_value", "github token decrypts")
  assertEqual(findValue(decrypted, "GOOGLE_PROJECT"), "my-project-123", "google project decrypts")
}

test "Upsert replaces a credential value in place" {
  val dbPath = useFreshTestDb("cred-upsert")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"
  mustPut(userId, "API_KEY", "old-value")
  mustPut(userId, "API_KEY", "new-value")

  assertEqualInt(mustNames(userId).length.toInt(), 1, "upsert does not duplicate the name")
  assertEqual(findValue(mustDecrypted(userId), "API_KEY"), "new-value", "value was replaced")
}

test "Credential handler rejects invalid and reserved names" {
  val dbPath = useFreshTestDb("cred-validate")
  defer {
    cleanupTestDb(dbPath)
  }
  // Reserved runner env-var names must not be storable (would override the
  // runner's own value on injection).
  match putCredentialHandler(PutCredentialRequest(name = "MODEL", value = "x")) {
    case Ok(_) -> assertTrue(false, "reserved name MODEL must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "reserved name -> 400")
  }
  match putCredentialHandler(PutCredentialRequest(name = "NATIVE_SESSION_ID", value = "x")) {
    case Ok(_) -> assertTrue(false, "reserved name NATIVE_SESSION_ID must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "reserved name -> 400")
  }
  // Malformed env-var names rejected too.
  match putCredentialHandler(PutCredentialRequest(name = "1BAD", value = "x")) {
    case Ok(_) -> assertTrue(false, "leading digit must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "bad name -> 400")
  }
  match putCredentialHandler(PutCredentialRequest(name = "has space", value = "x")) {
    case Ok(_) -> assertTrue(false, "space must be rejected")
    case Err(err) -> assertEqualInt(err.status, 400, "bad name -> 400")
  }
  // A valid, non-reserved name succeeds.
  match putCredentialHandler(PutCredentialRequest(name = "GITHUB_TOKEN", value = "ok")) {
    case Ok(_) -> assertTrue(true, "valid name accepted")
    case Err(_) -> assertTrue(false, "valid credential should store")
  }
}

test "Credentials are per-user isolated and deletable" {
  val dbPath = useFreshTestDb("cred-scope")
  defer {
    cleanupTestDb(dbPath)
  }
  mustPut("default", "SECRET", "mine")
  mustPut("someone-else", "SECRET", "theirs")

  assertEqualInt(mustNames("default").length.toInt(), 1, "only my credential listed")
  assertEqual(findValue(mustDecrypted("default"), "SECRET"), "mine", "I see my own value")

  // Deleting another user's credential touches nothing.
  match deleteCredential("default", "SECRET") {
    case Ok(n) -> assertEqualInt(n, 1, "delete my own credential")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match deleteCredential("default", "SECRET") {
    case Ok(n) -> assertEqualInt(n, 0, "second delete finds nothing")
    case Err(e) -> assertTrue(false, CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertEqualInt(mustNames("someone-else").length.toInt(), 1, "other user's credential untouched")
}
