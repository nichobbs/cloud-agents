@test_module
package CloudAgents.ProfileTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Db
import CloudAgents.Profiles
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

// ── SQL builder tests (no database needed) ────────────────────────────────────

test "profile SQL builders are owner-scoped and escaped" {
  val ins = insertProfileSql("p1", "u1", "it's a name", "claude", "none", "selected", "1000")
  assertTrue(ins.startsWith("INSERT INTO profiles"), "insert target")
  assertTrue(ins.contains("'it''s a name'"), "name is escaped")
  assertTrue(selectProfilesSql("u1").contains("WHERE user_id = 'u1'"), "list scoped by owner")
  assertTrue(selectProfilesSql("u1").contains("ORDER BY name ASC"), "profiles alphabetical")
  assertTrue(selectProfileByIdSql("p1", "u1").contains("AND user_id = 'u1'"), "get scoped by owner")
  assertTrue(updateProfileSql("p1", "u1", "n", "codex", "full", "all", "2000").contains("AND user_id = 'u1'"), "update scoped by owner")
  assertTrue(deleteProfileSql("p1", "u1").endsWith("AND user_id = 'u1'"), "delete scoped by owner")
  assertTrue(profilesSchemaSql().contains("CREATE TABLE IF NOT EXISTS profiles"), "ddl idempotent")
  assertTrue(profileCredentialsSchemaSql().contains("UNIQUE(profile_id, credential_name)"), "grants unique per profile")
  val grant = insertProfileCredentialSql("g1", "p1", "u1", "GITHUB_TOKEN")
  assertTrue(grant.contains("ON CONFLICT(profile_id, credential_name) DO NOTHING"), "grant insert is idempotent")
  assertTrue(selectProfileCredentialsSql("p1", "u1").contains("WHERE profile_id = 'p1'"), "grants scoped to profile")
  assertTrue(deleteProfileCredentialsSql("p1", "u1").contains("AND user_id = 'u1'"), "grant delete scoped by owner")
}

test "handler validation rejects bad enums" {
  assertTrue(isValidNetworkPolicy("full"), "full is valid")
  assertTrue(isValidNetworkPolicy("none"), "none is valid")
  assertTrue(isValidNetworkPolicy("restricted"), "restricted is valid")
  assertTrue(not isValidNetworkPolicy("open"), "unknown policy rejected")
  assertTrue(isValidCredentialMode("all") and isValidCredentialMode("selected"), "credential modes")
  assertTrue(not isValidCredentialMode("some"), "unknown mode rejected")
  assertTrue(isValidProfileHarness("") and isValidProfileHarness("claude"), "empty and claude harness ok")
  assertTrue(not isValidProfileHarness("bogus"), "unknown harness rejected")
}

// ── Live-database tests ───────────────────────────────────────────────────────

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

func mustProfile(r: in Result[Profile, CloudAgents.Sqlite.DbError]): Profile {
  return match r {
    case Ok(p) -> p
    case Err(e) -> panic("profile op failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustProfiles(r: in Result[slice[Profile], CloudAgents.Sqlite.DbError]): slice[Profile] {
  return match r {
    case Ok(ps) -> ps
    case Err(e) -> panic("profile list failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustRows(r: in Result[Int, CloudAgents.Sqlite.DbError]): Int {
  return match r {
    case Ok(n) -> n
    case Err(e) -> panic("profile write failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustPutCredential(userId: in String, name: in String, value: in String): Unit {
  match putCredential(userId, name, value) {
    case Ok(_) -> ()
    case Err(e) -> panic("putCredential failed: " + credentialErrorMessage(e))
  }
}

func mustProfileCreds(r: in Result[slice[CredentialValue], CredentialError]): slice[CredentialValue] {
  return match r {
    case Ok(cs) -> cs
    case Err(e) -> panic("profile creds failed: " + credentialErrorMessage(e))
  }
}

func hasCred(creds: in slice[CredentialValue], name: in String): Bool {
  var i = 0
  while i < creds.length {
    if creds[i].name == name {
      return true
    }
    i = i + 1
  }
  return false
}

test "Profile CRUD round-trips with its credential grants" {
  val dbPath = useFreshTestDb("profile-crud")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"

  val created = mustProfile(addProfile(userId, "locked-down", "claude", "none", "selected", ["GITHUB_TOKEN"]))
  assertTrue(created.id.length > 0, "created profile has an id")
  assertEqual(created.networkPolicy, "none", "network policy stored")
  assertEqualInt(created.credentials.length.toInt(), 1, "one credential granted")

  val listed = mustProfiles(listProfiles(userId))
  assertEqualInt(listed.length.toInt(), 1, "one profile listed")
  assertEqual(listed[0].name, "locked-down", "listed profile name matches")
  assertEqualInt(listed[0].credentials.length.toInt(), 1, "grants come back with the profile")

  // Update: switch to full network + all credentials (grants should clear).
  val updated = mustRows(updateProfile(created.id, userId, "opened-up", "", "full", "all", []))
  assertEqualInt(updated, 1, "update touches one row")
  match getProfile(created.id, userId) {
    case Ok(Some(p)) -> {
      assertEqual(p.networkPolicy, "full", "network policy updated")
      assertEqual(p.credentialMode, "all", "credential mode updated")
      assertEqualInt(p.credentials.length.toInt(), 0, "grants cleared on switch to all")
    }
    case Ok(None) -> assertTrue(false, "updated profile should exist")
    case Err(e) -> assertTrue(false, "getProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  val deleted = mustRows(deleteProfile(created.id, userId))
  assertEqualInt(deleted, 1, "delete touches one row")
  assertEqualInt(mustProfiles(listProfiles(userId)).length.toInt(), 0, "empty after delete")
}

test "Profile ownership scoping hides other users' profiles" {
  val dbPath = useFreshTestDb("profile-scope")
  defer {
    cleanupTestDb(dbPath)
  }
  val mine = mustProfile(addProfile("default", "mine", "", "full", "all", []))
  val theirs = mustProfile(addProfile("someone-else", "theirs", "", "full", "all", []))

  val myList = mustProfiles(listProfiles("default"))
  assertEqualInt(myList.length.toInt(), 1, "only my profile listed")
  assertEqual(myList[0].id, mine.id, "listed profile is mine")

  match getProfile(theirs.id, "default") {
    case Ok(Some(_)) -> assertTrue(false, "cannot read another user's profile")
    case Ok(None) -> ()
    case Err(e) -> assertTrue(false, "getProfile failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  assertEqualInt(mustRows(updateProfile(theirs.id, "default", "x", "", "full", "all", [])), 0, "cannot update another user's profile")
  assertEqualInt(mustRows(deleteProfile(theirs.id, "default")), 0, "cannot delete another user's profile")
}

test "Selected-mode profile injects only its granted credentials" {
  val dbPath = useFreshTestDb("profile-inject")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"
  mustPutCredential(userId, "GITHUB_TOKEN", "ghp_secret")
  mustPutCredential(userId, "AWS_KEY", "aws_secret")
  mustPutCredential(userId, "OPENAI_KEY", "oai_secret")

  // 'selected' profile grants only GITHUB_TOKEN.
  val locked = mustProfile(addProfile(userId, "gh-only", "", "none", "selected", ["GITHUB_TOKEN"]))
  val injected = mustProfileCreds(decryptedCredentialsForProfile(userId, locked.id))
  assertEqualInt(injected.length.toInt(), 1, "only the granted credential is injected")
  assertTrue(hasCred(injected, "GITHUB_TOKEN"), "granted credential present")
  assertTrue(not hasCred(injected, "AWS_KEY"), "ungranted credential withheld")

  // 'all' profile injects every credential.
  val open = mustProfile(addProfile(userId, "all-creds", "", "full", "all", []))
  val allInjected = mustProfileCreds(decryptedCredentialsForProfile(userId, open.id))
  assertEqualInt(allInjected.length.toInt(), 3, "all mode injects every credential")

  // No profile (empty id) falls open to all credentials (legacy behaviour).
  val legacy = mustProfileCreds(decryptedCredentialsForProfile(userId, ""))
  assertEqualInt(legacy.length.toInt(), 3, "empty profile id -> all credentials")

  // Fail closed (#231): a NON-EMPTY profile id that can't be resolved (deleted
  // profile) injects nothing rather than escalating to every credential.
  val orphaned = mustProfileCreds(decryptedCredentialsForProfile(userId, "does-not-exist"))
  assertEqualInt(orphaned.length.toInt(), 0, "unknown profile id -> no credentials (fail closed)")
}

test "Network policy resolves and fails closed for unknown profiles" {
  val dbPath = useFreshTestDb("profile-network")
  defer {
    cleanupTestDb(dbPath)
  }
  val userId = "default"
  val isolated = mustProfile(addProfile(userId, "isolated", "", "none", "all", []))

  match profileNetworkPolicy(userId, isolated.id) {
    case Ok(p) -> assertEqual(p, "none", "profile network policy read back")
    case Err(e) -> assertTrue(false, "policy read failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  // Empty profile -> full (legacy default); unknown non-empty -> none (closed).
  match profileNetworkPolicy(userId, "") {
    case Ok(p) -> assertEqual(p, "full", "no profile -> full network")
    case Err(e) -> assertTrue(false, "policy read failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match profileNetworkPolicy(userId, "does-not-exist") {
    case Ok(p) -> assertEqual(p, "none", "unknown profile -> isolated (fail closed)")
    case Err(e) -> assertTrue(false, "policy read failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}
