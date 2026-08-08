@test_module
package CloudAgents.GroupsTests

import Std.Core
import Std.Testing
import Std.Uuid
import CloudAgents.Auth
import CloudAgents.Db
import CloudAgents.Groups
import CloudAgents.Repository
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import extern System.Environment as Env

// ── Live-DB plumbing (same pattern as tests/highlights_tests.l) ──────────────
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
  CloudAgents.Auth.setCurrentUserId("default")
}

func mkSession(id: in String): Unit {
  val s = makeAgentSession(
    sessionId = id,
    repoUrl = "https://github.com/nic/repo",
    branch = "main",
    containerId = "",
    harness = "claude",
    model = "claude-opus-4-8",
    nativeSessionId = id
  )
  match addSession(s) {
    case Ok(_) -> ()
    case Err(e) -> panic("addSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustCreateGroup(name: in String, parentId: in String): CloudAgents.Repository.SessionGroup {
  return match createGroupHandler(SaveGroupRequest(name = name, parentId = parentId)) {
    case Ok(g) -> g
    case Err(e) -> panic("createGroupHandler failed with status " + toString(e.status))
  }
}

func mustGetSession(id: in String): AgentSession {
  return match CloudAgents.SessionStore.getSession(id) {
    case Ok(Some(s)) -> s
    case Ok(None) -> panic("session " + id + " should exist")
    case Err(e) -> panic("getSession failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

func mustGetGroup(id: in String, userId: in String): CloudAgents.Repository.SessionGroup {
  return match CloudAgents.Repository.getSessionGroup(id, userId) {
    case Ok(Some(g)) -> g
    case Ok(None) -> panic("group " + id + " should exist")
    case Err(e) -> panic("getSessionGroup failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}

// ── Migration 0029 ───────────────────────────────────────────────────────────
test "migration 0029 applies: fresh sessions carry group/viewed defaults" {
  val dbPath = useFreshTestDb("groups-migration")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  mkSession("sess-g-0")
  val s = mustGetSession("sess-g-0")
  assertEqual(s.groupId, "", "fresh session is ungrouped")
  assertEqual(s.lastViewedAt, "0", "fresh session was never viewed")
}

// ── Group CRUD ───────────────────────────────────────────────────────────────
test "group CRUD round-trips and lists alphabetically" {
  val dbPath = useFreshTestDb("groups-crud")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")

  val beta = mustCreateGroup("Beta", "")
  val alpha = mustCreateGroup("Alpha", "")
  val gamma = mustCreateGroup("Gamma", beta.id)
  assertEqual(gamma.parentId, beta.id, "child stores its parent")
  assertTrue(alpha.createdAt.length > 0, "createdAt is stamped")

  match listGroupsHandler() {
    case Ok(l) -> {
      assertEqualInt(l.groups.length.toInt(), 3, "three groups listed")
      assertEqual(l.groups[0].name, "Alpha", "alphabetical: Alpha first")
      assertEqual(l.groups[1].name, "Beta", "alphabetical: Beta second")
      assertEqual(l.groups[2].name, "Gamma", "alphabetical: Gamma last")
    }
    case Err(e) -> assertTrue(false, "listGroupsHandler failed: " + toString(e.status))
  }

  // Full update: rename AND reparent to root in one call.
  match updateGroupHandler(gamma.id, SaveGroupRequest(name = "Zed", parentId = "")) {
    case Ok(g) -> {
      assertEqual(g.name, "Zed", "rename applied")
      assertEqual(g.parentId, "", "reparent to root applied")
    }
    case Err(e) -> assertTrue(false, "updateGroupHandler failed: " + toString(e.status))
  }

  match deleteGroupHandler(alpha.id) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "deleteGroupHandler failed: " + toString(e.status))
  }
  match listGroupsHandler() {
    case Ok(l) -> assertEqualInt(l.groups.length.toInt(), 2, "two groups remain after delete")
    case Err(e) -> assertTrue(false, "listGroupsHandler after delete failed: " + toString(e.status))
  }
}

test "group validation: empty name 400, unknown parent 404, unknown id 404" {
  val dbPath = useFreshTestDb("groups-validation")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")

  match createGroupHandler(SaveGroupRequest(name = "", parentId = "")) {
    case Ok(_) -> assertTrue(false, "empty name must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "empty name -> 400")
  }
  match createGroupHandler(SaveGroupRequest(name = "   ", parentId = "")) {
    case Ok(_) -> assertTrue(false, "whitespace-only name must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "whitespace name -> 400")
  }
  match createGroupHandler(SaveGroupRequest(name = "Orphan", parentId = "no-such-group")) {
    case Ok(_) -> assertTrue(false, "unknown parent must be rejected")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown parent -> 404")
  }
  match updateGroupHandler("no-such-group", SaveGroupRequest(name = "X", parentId = "")) {
    case Ok(_) -> assertTrue(false, "updating an unknown group must fail")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown group update -> 404")
  }
  match deleteGroupHandler("no-such-group") {
    case Ok(_) -> assertTrue(false, "deleting an unknown group must fail")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown group delete -> 404")
  }
}

// ── Cycle / depth rejection ──────────────────────────────────────────────────
test "update rejects self and descendant parents (cycle guard)" {
  val dbPath = useFreshTestDb("groups-cycles")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")

  val a = mustCreateGroup("a", "")
  val b = mustCreateGroup("b", a.id)
  val c = mustCreateGroup("c", b.id)

  match updateGroupHandler(a.id, SaveGroupRequest(name = "a", parentId = a.id)) {
    case Ok(_) -> assertTrue(false, "a group must not be its own parent")
    case Err(e) -> assertEqualInt(e.status, 400, "self parent -> 400")
  }
  match updateGroupHandler(a.id, SaveGroupRequest(name = "a", parentId = c.id)) {
    case Ok(_) -> assertTrue(false, "a group must not be parented under its own descendant")
    case Err(e) -> assertEqualInt(e.status, 400, "descendant parent -> 400")
  }
  // A sibling-ish legal reparent still works: c moves directly under a.
  match updateGroupHandler(c.id, SaveGroupRequest(name = "c", parentId = a.id)) {
    case Ok(g) -> assertEqual(g.parentId, a.id, "legal reparent applies")
    case Err(e) -> assertTrue(false, "legal reparent failed: " + toString(e.status))
  }
}

test "create rejects a parent chain deeper than 10 levels" {
  val dbPath = useFreshTestDb("groups-depth")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")

  // Build an 11-deep chain g1 <- g2 <- ... <- g11: every creation walks a
  // parent chain of at most 10 nodes, so all succeed.
  var prev = ""
  var i = 1
  while i <= 11 {
    val g = mustCreateGroup("level-" + toString(i), prev)
    prev = g.id
    i = i + 1
  }
  // A 12th level would walk an 11-node parent chain — beyond the cap.
  match createGroupHandler(SaveGroupRequest(name = "level-12", parentId = prev)) {
    case Ok(_) -> assertTrue(false, "a 12th level must be rejected")
    case Err(e) -> assertEqualInt(e.status, 400, "parent chain too deep -> 400")
  }
}

// ── Delete reparents children and reassigns sessions ─────────────────────────
test "deleting a group reparents child groups and reassigns sessions to its parent" {
  val dbPath = useFreshTestDb("groups-reparent")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")

  val a = mustCreateGroup("a", "")
  val b = mustCreateGroup("b", a.id)
  val c = mustCreateGroup("c", b.id)
  mkSession("sess-in-b")
  mkSession("sess-in-a")
  match setSessionGroupHandler("sess-in-b", SetSessionGroupRequest(groupId = b.id)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "assign to b failed: " + toString(e.status))
  }
  match setSessionGroupHandler("sess-in-a", SetSessionGroupRequest(groupId = a.id)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "assign to a failed: " + toString(e.status))
  }

  // Delete the middle group: c moves under a, and b's session moves to a.
  match deleteGroupHandler(b.id) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "delete b failed: " + toString(e.status))
  }
  assertEqual(mustGetGroup(c.id, "default").parentId, a.id, "child group reparented to grandparent")
  assertEqual(mustGetSession("sess-in-b").groupId, a.id, "session reassigned to grandparent")

  // Delete the root: c and both sessions become ungrouped.
  match deleteGroupHandler(a.id) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "delete a failed: " + toString(e.status))
  }
  assertEqual(mustGetGroup(c.id, "default").parentId, "", "child of a deleted root becomes a root")
  assertEqual(mustGetSession("sess-in-b").groupId, "", "session of a deleted root becomes ungrouped")
  assertEqual(mustGetSession("sess-in-a").groupId, "", "session directly in the deleted root becomes ungrouped")
}

// ── Owner scoping ────────────────────────────────────────────────────────────
test "groups are owner-scoped: another user cannot see or mutate them" {
  val dbPath = useFreshTestDb("groups-ownership")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val g = mustCreateGroup("mine", "")

  CloudAgents.Auth.setCurrentUserId("intruder")
  match listGroupsHandler() {
    case Ok(l) -> assertEqualInt(l.groups.length.toInt(), 0, "another user's listing is empty")
    case Err(e) -> assertTrue(false, "intruder list failed: " + toString(e.status))
  }
  match updateGroupHandler(g.id, SaveGroupRequest(name = "stolen", parentId = "")) {
    case Ok(_) -> assertTrue(false, "another user must not rename this group")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign update -> 404, indistinguishable from absent")
  }
  match deleteGroupHandler(g.id) {
    case Ok(_) -> assertTrue(false, "another user must not delete this group")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign delete -> 404")
  }
  // Another user's parentId reference to a foreign group 404s too.
  match createGroupHandler(SaveGroupRequest(name = "child-of-foreign", parentId = g.id)) {
    case Ok(_) -> assertTrue(false, "another user must not parent under a foreign group")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign parent -> 404")
  }

  CloudAgents.Auth.setCurrentUserId("default")
  assertEqual(mustGetGroup(g.id, "default").name, "mine", "owner's group is untouched")
}

// ── Session-group assignment ─────────────────────────────────────────────────
test "setSessionGroupHandler assigns, clears, and 404s unknown/foreign refs" {
  val dbPath = useFreshTestDb("groups-assign")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  val g = mustCreateGroup("folder", "")
  mkSession("sess-assign")

  match setSessionGroupHandler("no-such-session", SetSessionGroupRequest(groupId = g.id)) {
    case Ok(_) -> assertTrue(false, "unknown session must 404")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown session -> 404")
  }
  match setSessionGroupHandler("sess-assign", SetSessionGroupRequest(groupId = "no-such-group")) {
    case Ok(_) -> assertTrue(false, "unknown group must 404")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown group -> 404")
  }
  match setSessionGroupHandler("sess-assign", SetSessionGroupRequest(groupId = g.id)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "assign failed: " + toString(e.status))
  }
  assertEqual(mustGetSession("sess-assign").groupId, g.id, "session filed under the group")

  // Another user cannot file a foreign session.
  CloudAgents.Auth.setCurrentUserId("intruder")
  match setSessionGroupHandler("sess-assign", SetSessionGroupRequest(groupId = "")) {
    case Ok(_) -> assertTrue(false, "another user must not touch this session's group")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign session -> 404")
  }

  CloudAgents.Auth.setCurrentUserId("default")
  match setSessionGroupHandler("sess-assign", SetSessionGroupRequest(groupId = "")) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "clear failed: " + toString(e.status))
  }
  assertEqual(mustGetSession("sess-assign").groupId, "", "empty groupId clears the association")
}

// ── Viewed tracking ──────────────────────────────────────────────────────────
test "markSessionViewedHandler stamps last_viewed_at and is owner-scoped" {
  val dbPath = useFreshTestDb("groups-viewed")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  mkSession("sess-viewed")
  assertEqual(mustGetSession("sess-viewed").lastViewedAt, "0", "never viewed initially")

  match markSessionViewedHandler("no-such-session") {
    case Ok(_) -> assertTrue(false, "unknown session must 404")
    case Err(e) -> assertEqualInt(e.status, 404, "unknown session -> 404")
  }

  CloudAgents.Auth.setCurrentUserId("intruder")
  match markSessionViewedHandler("sess-viewed") {
    case Ok(_) -> assertTrue(false, "another user must not stamp this session")
    case Err(e) -> assertEqualInt(e.status, 404, "foreign session -> 404")
  }
  CloudAgents.Auth.setCurrentUserId("default")
  assertEqual(mustGetSession("sess-viewed").lastViewedAt, "0", "foreign attempt left the stamp untouched")

  match markSessionViewedHandler("sess-viewed") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "viewed stamp failed: " + toString(e.status))
  }
  val stamped = mustGetSession("sess-viewed").lastViewedAt
  assertTrue(stamped != "0", "last_viewed_at updated")
  assertTrue(stamped.length >= 13, "epoch-millis magnitude: " + stamped)
}

// ── Extended session-list payload ────────────────────────────────────────────
test "sessionSummariesJson carries groupId/lastViewedAt/pendingCount/attention" {
  val dbPath = useFreshTestDb("groups-summaries")
  defer {
    cleanupTestDb(dbPath)
  }
  CloudAgents.Auth.setCurrentUserId("default")
  mkSession("sess-summary")

  // Fresh session: last_message_at = created_at > 0 and never viewed, so the
  // attention model reports 'pending' (activity the user hasn't seen).
  match CloudAgents.SessionStore.sessionSummariesJson() {
    case Ok(json) -> {
      assertTrue(json.contains("\"groupId\":\"\""), "groupId present (ungrouped): " + json)
      assertTrue(json.contains("\"lastViewedAt\":\"0\""), "lastViewedAt present (never viewed)")
      assertTrue(json.contains("\"pendingCount\":\"0\""), "pendingCount present (no callbacks)")
      assertTrue(json.contains("\"attention\":\"pending\""), "unviewed activity -> pending")
    }
    case Err(e) -> assertTrue(false, "sessionSummariesJson failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // After viewing, everything is seen: attention flips to 'viewed'.
  match markSessionViewedHandler("sess-summary") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "viewed stamp failed: " + toString(e.status))
  }
  match CloudAgents.SessionStore.sessionSummariesJson() {
    case Ok(json) -> assertTrue(json.contains("\"attention\":\"viewed\""), "viewed after stamp: " + json)
    case Err(e) -> assertTrue(false, "sessionSummariesJson failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // A pending permission request bumps pendingCount and wins the priority.
  match CloudAgents.Sqlite.execute(
    CloudAgents.Db.insertPermissionRequestSql(
      "pr-1",
      "sess-summary",
      "Bash",
      "{}",
      "pending",
      "",
      CloudAgents.Repository.nowMillis(),
      ""
    )
  ) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "insert permission request failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
  match CloudAgents.SessionStore.sessionSummariesJson() {
    case Ok(json) -> {
      assertTrue(json.contains("\"pendingCount\":\"1\""), "pending callback counted: " + json)
      assertTrue(json.contains("\"attention\":\"pending\""), "pending callback -> pending")
    }
    case Err(e) -> assertTrue(false, "sessionSummariesJson failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }

  // Grouping shows up in the projection too.
  val g = mustCreateGroup("folder", "")
  match setSessionGroupHandler("sess-summary", SetSessionGroupRequest(groupId = g.id)) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, "assign failed: " + toString(e.status))
  }
  match CloudAgents.SessionStore.sessionSummariesJson() {
    case Ok(json) -> assertTrue(json.contains("\"groupId\":\"" + g.id + "\""), "assigned group id projected")
    case Err(e) -> assertTrue(false, "sessionSummariesJson failed: " + CloudAgents.Sqlite.dbErrorMessage(e))
  }
}
