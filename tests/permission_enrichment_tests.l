//! Tests for CloudAgents.PermissionEnrichment
//! (docs/capture-permission-enrichment.md §6). Two tiers, matching the repo:
//!
//! - **Offline** (no DB, no network, no clock): the pure status mappers, the
//!   conservative fold precedence, the `permissionForTool` accessor, and the
//!   `request_secret:<name>` key convention — over hand-built `ToolPermission`
//!   lists.
//! - **Live-SQLite** (same fresh-temp-DB harness as tests/session_events_tests.l,
//!   gated on the native SQLite lib): create + answer real
//!   `permission_requests` / `secret_requests` rows through the repository, then
//!   `permissionsForSession` derives the expected per-tool map.
@test_module
package CloudAgents.PermissionEnrichmentTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.Uuid
import CloudAgents.PermissionEnrichment
import CloudAgents.Repository
import CloudAgents.Sqlite
import Testamur.CheckpointFormat.Model
import extern System.Environment as Env

@externTarget("System.IO.File.Delete")
func fileDelete(path: in String): Unit = ()

// ── Small helpers ────────────────────────────────────────────────────────────
// Build ToolPermission through the home-package constructor func, not by
// constructing the imported record directly here — the latter can crash with a
// cross-package InvalidProgramException (docs/lyric/gotchas.md).
func tp(tool: in String, permission: in Permission): ToolPermission {
  return CloudAgents.PermissionEnrichment.toolPermission(tool, permission)
}

func permName(p: in Permission): String {
  return permissionName(p)
}

func lookup(perms: in List[ToolPermission], tool: in String): String {
  return permName(permissionForTool(perms, tool))
}

// ── Offline: status mappers ──────────────────────────────────────────────────
test "permission-request status maps to the checkpoint permission" {
  assertEqual(permName(permissionOfStatus("allowed")), "granted", "allowed → granted")
  assertEqual(permName(permissionOfStatus("denied")), "denied", "denied → denied (incl. timed-out-to-denied)")
  assertEqual(permName(permissionOfStatus("pending")), "auto", "pending → auto (no explicit decision)")
  assertEqual(permName(permissionOfStatus("weird")), "auto", "unknown status → auto")
}

test "secret-request status maps to the checkpoint permission" {
  assertEqual(permName(permissionOfSecretStatus("approved")), "granted", "approved → granted")
  assertEqual(permName(permissionOfSecretStatus("denied")), "denied", "denied → denied")
  assertEqual(permName(permissionOfSecretStatus("timed_out")), "auto", "timed_out → auto (no explicit decision)")
  assertEqual(permName(permissionOfSecretStatus("pending")), "auto", "pending → auto")
}

test "secret tool key namespaces the credential name" {
  assertEqual(secretToolKey("GITHUB_TOKEN"), "request_secret:GITHUB_TOKEN", "secret keyed under request_secret:<name>")
}

// ── Offline: the conservative fold ───────────────────────────────────────────
test "distinct tools fold to one entry each, sorted by tool key" {
  val rows: List[ToolPermission] = newList()
  rows.add(tp("Write", Granted))
  rows.add(tp("Bash", Denied))
  rows.add(tp("Read", Auto))
  val derived = derivePermissions(rows)
  assertEqualInt(derived.count, 3, "three distinct tools")
  // Sorted ascending by tool key: Bash, Read, Write.
  assertEqual(derived[0].tool, "Bash", "first is Bash")
  assertEqual(derived[1].tool, "Read", "second is Read")
  assertEqual(derived[2].tool, "Write", "third is Write")
  assertEqual(permName(derived[0].permission), "denied", "Bash denied")
  assertEqual(permName(derived[1].permission), "auto", "Read auto")
  assertEqual(permName(derived[2].permission), "granted", "Write granted")
}

test "a tool denied even once folds to denied (Denied > Granted > Auto)" {
  val rows: List[ToolPermission] = newList()
  // Same tool, three rows, different outcomes and orderings.
  rows.add(tp("Bash", Granted))
  rows.add(tp("Bash", Denied))
  rows.add(tp("Bash", Auto))
  val derived = derivePermissions(rows)
  assertEqualInt(derived.count, 1, "one folded entry for Bash")
  assertEqual(permName(derived[0].permission), "denied", "any denial wins")
}

test "granted beats auto but not denied; order-independent" {
  val a: List[ToolPermission] = newList()
  a.add(tp("Edit", Auto))
  a.add(tp("Edit", Granted))
  assertEqual(permName(derivePermissions(a)[0].permission), "granted", "granted beats auto")

  // Reversed input order yields the same fold.
  val b: List[ToolPermission] = newList()
  b.add(tp("Edit", Granted))
  b.add(tp("Edit", Auto))
  assertEqual(permName(derivePermissions(b)[0].permission), "granted", "fold is order-independent")
}

test "empty input derives an empty map" {
  val rows: List[ToolPermission] = newList()
  assertEqualInt(derivePermissions(rows).count, 0, "no rows → no entries")
}

// ── Offline: the accessor ────────────────────────────────────────────────────
test "permissionForTool returns the folded outcome, Auto for unknown tools" {
  val rows: List[ToolPermission] = newList()
  rows.add(tp("Bash", Denied))
  rows.add(tp("Write", Granted))
  val derived = derivePermissions(rows)
  assertEqual(lookup(derived, "Bash"), "denied", "Bash → denied")
  assertEqual(lookup(derived, "Write"), "granted", "Write → granted")
  // A tool with no request row was never prompted → Auto (the mapper default).
  assertEqual(lookup(derived, "Read"), "auto", "unprompted tool → auto")
}

// ── Live-SQLite: fresh-temp-DB harness (as session_events_tests.l) ───────────
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

func mustCreatePerm(sessionId: in String, tool: in String): String {
  return match CloudAgents.Repository.createPermissionRequest(sessionId, tool, "{}", false) {
    case Ok(r) -> r.id
    case Err(e) -> panic("createPermissionRequest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustAnswerPerm(id: in String, status: in String): Unit {
  match CloudAgents.Repository.answerPermissionRequest(id, status, "", "") {
    case Ok(_) -> ()
    case Err(e) -> panic("answerPermissionRequest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustCreateSecret(sessionId: in String, name: in String): String {
  return match CloudAgents.Repository.createSecretRequest(sessionId, name, "why") {
    case Ok(r) -> r.id
    case Err(e) -> panic("createSecretRequest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustAnswerSecret(id: in String, status: in String): Unit {
  match CloudAgents.Repository.answerSecretRequest(id, status) {
    case Ok(_) -> ()
    case Err(e) -> panic("answerSecretRequest failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustDerive(sessionId: in String): List[ToolPermission] {
  return match CloudAgents.PermissionEnrichment.permissionsForSession(sessionId) {
    case Ok(perms) -> perms
    case Err(e) -> panic("permissionsForSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

test "permissionsForSession folds real permission and secret rows per tool" {
  val path = useFreshTestDb("permenrich-live")

  // Bash: allowed. Write: denied. Read: prompted but still pending → auto.
  mustAnswerPerm(mustCreatePerm("sess-P", "Bash"), "allowed")
  mustAnswerPerm(mustCreatePerm("sess-P", "Write"), "denied")
  val _read = mustCreatePerm("sess-P", "Read")
  // A secret ask, approved → request_secret:GITHUB_TOKEN granted.
  mustAnswerSecret(mustCreateSecret("sess-P", "GITHUB_TOKEN"), "approved")

  val derived = mustDerive("sess-P")
  assertEqualInt(derived.count, 4, "Bash, Read, Write, request_secret:GITHUB_TOKEN")
  assertEqual(permName(permissionForTool(derived, "Bash")), "granted", "Bash granted")
  assertEqual(permName(permissionForTool(derived, "Write")), "denied", "Write denied")
  assertEqual(permName(permissionForTool(derived, "Read")), "auto", "Read pending → auto")
  assertEqual(
    permName(permissionForTool(derived, "request_secret:GITHUB_TOKEN")),
    "granted",
    "approved secret → granted under request_secret:<name>"
  )

  // A different session is isolated.
  assertEqualInt(mustDerive("sess-other").count, 0, "unknown session → empty map")

  cleanupTestDb(path)
}

test "permissionsForSession folds repeated tool prompts conservatively" {
  val path = useFreshTestDb("permenrich-fold")

  // Two Bash prompts for the session: one allowed, one denied → denied wins.
  mustAnswerPerm(mustCreatePerm("sess-F", "Bash"), "allowed")
  mustAnswerPerm(mustCreatePerm("sess-F", "Bash"), "denied")

  val derived = mustDerive("sess-F")
  assertEqualInt(derived.count, 1, "one folded Bash entry")
  assertEqual(permName(permissionForTool(derived, "Bash")), "denied", "any denial wins the fold")

  cleanupTestDb(path)
}
