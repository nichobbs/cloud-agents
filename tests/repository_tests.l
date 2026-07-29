@test_module
package CloudAgents.RepositoryTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Repository
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/session_tests.l) ──────────────────

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

func useFreshTestDb(tag: in String): String {
  val path = "/tmp/cloud-agents-tests-" + tag + "-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()) + ".db"
  Env.SetEnvironmentVariable("CLOUD_AGENTS_DB_PATH", path)
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
    // locked or already gone — fine for a temp file
  }
}

func mustOptStr(r: in Result[Option[String], CloudAgents.Sqlite.DbError]): Option[String] {
  return match r {
    case Ok(o) -> o
    case Err(e) -> panic("model-listing cache read failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustCacheWrite(r: in Result[Unit, CloudAgents.Sqlite.DbError]): Unit {
  return match r {
    case Ok(_) -> ()
    case Err(e) -> panic("cacheModelListing failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── Model-listing cache (#446/#466) ───────────────────────────────────────────

test "model-listing cache round-trips and is scoped by (user, provider)" {
  val dbPath = useFreshTestDb("model-cache")
  defer {
    cleanupTestDb(dbPath)
  }

  // Absent before any write.
  match mustOptStr(CloudAgents.Repository.cachedModelListing("gh-1", "anthropic")) {
    case Some(_) -> assertTrue(false, "no cached listing before a write")
    case None -> ()
  }

  // Write, then read back the exact body.
  mustCacheWrite(CloudAgents.Repository.cacheModelListing("gh-1", "anthropic", "{\"data\":[1]}"))
  match mustOptStr(CloudAgents.Repository.cachedModelListing("gh-1", "anthropic")) {
    case Some(body) -> assertEqual(body, "{\"data\":[1]}", "freshly-cached body reads back")
    case None -> assertTrue(false, "freshly-cached listing should be present")
  }

  // Scoped by provider: a different provider for the same user is independent.
  match mustOptStr(CloudAgents.Repository.cachedModelListing("gh-1", "openai")) {
    case Some(_) -> assertTrue(false, "a different provider is a separate cache entry")
    case None -> ()
  }
  // Scoped by user: another user never sees gh-1's entry.
  match mustOptStr(CloudAgents.Repository.cachedModelListing("gh-2", "anthropic")) {
    case Some(_) -> assertTrue(false, "a different user is a separate cache entry")
    case None -> ()
  }

  // Upsert replaces the body for the same (user, provider) key.
  mustCacheWrite(CloudAgents.Repository.cacheModelListing("gh-1", "anthropic", "{\"data\":[2]}"))
  match mustOptStr(CloudAgents.Repository.cachedModelListing("gh-1", "anthropic")) {
    case Some(body) -> assertEqual(body, "{\"data\":[2]}", "upsert replaces the cached body")
    case None -> assertTrue(false, "upserted listing should be present")
  }
}
