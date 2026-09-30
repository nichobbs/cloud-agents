//! Live-Postgres tests for CloudAgents.PgStore.Library
//! (docs/phase11-postgres-tenancy.md §9 slices B/C): profiles, skills,
//! subagents and MCP servers behave like the SQLite store and are isolated by
//! tenant and user. Runs iff the Postgres DSNs are set (see
//! tests/pg_live_tests.l). Per-run unique user ids keep it re-runnable.
@test_module
package CloudAgents.PgStoreLibraryTests

import Std.Core
import Std.Environment
import Std.Testing
import Std.Uuid
import CloudAgents.Pg
import CloudAgents.Pg.Migrate
import CloudAgents.PgStore.Library
import CloudAgents.Repository
import CloudAgents.Sqlite

func live(): Bool {
  val ok = CloudAgents.Pg.serviceConfigured() and
    Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "").length.toInt() > 0
  if ok {
    return true
  }
  assertTrue(
    Std.Environment.getVarOrDefault("CLOUD_AGENTS_REQUIRE_LIVE_PG", "") != "1",
    "CLOUD_AGENTS_REQUIRE_LIVE_PG=1 but LYRIC_CONFIG_DB_CONNECTION_URL or CLOUD_AGENTS_MIGRATE_DATABASE_URL is not set"
  )
  println("SKIP: PgStore library tests need LYRIC_CONFIG_DB_CONNECTION_URL and CLOUD_AGENTS_MIGRATE_DATABASE_URL")
  return false
}

func migrate(): Unit {
  val conn = match CloudAgents.Pg.connectDsn(Std.Environment.getVarOrDefault(CloudAgents.Pg.migrateDsnVar(), "")) {
    case Ok(c) -> c
    case Err(e) -> panic(CloudAgents.Pg.pgErrorMessage(e))
  }
  defer {
    conn.close()
  }
  match CloudAgents.Pg.Migrate.migrate(conn) {
    case Ok(_) -> ()
    case Err(e) -> panic("migrate failed: " + CloudAgents.Pg.pgErrorMessage(e))
  }
}

func fresh(): CloudAgents.Pg.TenantScope {
  return personalScope("gh-pgl-" + Std.Uuid.uuidToString(Std.Uuid.newUuid()))
}

func joined(xs: in slice[String]): String {
  var acc = ""
  for x in xs {
    acc = acc + x + ","
  }
  return acc
}

func optProfile(r: in Result[Option[Profile], DbError]): Option[Profile] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func optSkill(r: in Result[Option[Skill], DbError]): Option[Skill] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func skillList(r: in Result[slice[Skill], DbError]): slice[Skill] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func subagentList(r: in Result[slice[Subagent], DbError]): slice[Subagent] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func serverList(r: in Result[slice[McpServer], DbError]): slice[McpServer] {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func str(r: in Result[String, DbError]): String {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func int(r: in Result[Int, DbError]): Int {
  return match r { case Ok(v) -> v; case Err(e) -> panic("store call failed: " + dbErrorMessage(e)) }
}

func mkProfile(
  sc: in CloudAgents.Pg.TenantScope, name: in String, skills: in slice[String], servers: in slice[String]
): Profile {
  val creds: slice[String] = ["ZETA_TOKEN", "API_KEY"]
  val subs: slice[String] = []
  val tools: slice[String] = ["ledger_note"]
  return match CloudAgents.PgStore.Library.addProfile(sc, name, "claude", "restricted", "selected", creds, skills, subs, servers, "selected", tools) {
    case Ok(p) -> p
    case Err(e) -> panic("addProfile failed: " + dbErrorMessage(e))
  }
}

func mkSkill(sc: in CloudAgents.Pg.TenantScope, name: in String): Skill {
  return match CloudAgents.PgStore.Library.addSkill(sc, name, "desc", "body") {
    case Ok(s) -> s
    case Err(e) -> panic("addSkill failed: " + dbErrorMessage(e))
  }
}

func mkServer(sc: in CloudAgents.Pg.TenantScope, name: in String, enabled: in String): McpServer {
  val args: slice[String] = ["--b", "--a", "--c"]
  val env: slice[String] = ["Z=1", "A=2"]
  val headers: slice[String] = ["X-One=1"]
  return match CloudAgents.PgStore.Library.addMcpServer(sc, name, "stdio", "run", args, "", env, enabled, headers) {
    case Ok(s) -> s
    case Err(e) -> panic("addMcpServer failed: " + dbErrorMessage(e))
  }
}

test "a profile round-trips with every grant set, sorted" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val sc = fresh()
  val s = mkSkill(sc, "s1")
  val m = mkServer(sc, "m1", "1")
  val skills: slice[String] = [s.id]
  val servers: slice[String] = [m.id]
  val created = mkProfile(sc, "prof", skills, servers)
  match CloudAgents.PgStore.Library.getProfile(created.id, sc) {
    case Ok(Some(p)) -> {
      assertEqual(p.networkPolicy, "restricted", "network policy")
      assertEqual(joined(p.credentials), "API_KEY,ZETA_TOKEN,", "credential grants sorted")
      assertEqual(joined(p.skillIds), s.id + ",", "skill grant")
      assertEqual(joined(p.mcpServerIds), m.id + ",", "mcp grant")
      assertEqual(joined(p.tools), "ledger_note,", "tool grant")
      assertEqual(p.createdAt, created.createdAt, "timestamp round-trips")
    }
    case Ok(None) -> assertTrue(false, "profile must exist")
    case Err(e) -> assertTrue(false, dbErrorMessage(e))
  }
  match CloudAgents.PgStore.Library.profileIdByName(sc, "prof") {
    case Ok(Some(id)) -> assertEqual(id, created.id, "found by name")
    case _ -> assertTrue(false, "profileIdByName must find it")
  }
}

test "network policy fails closed for a missing profile and tools fail open" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val sc = fresh()
  assertEqual(str(CloudAgents.PgStore.Library.profileNetworkPolicy(sc, "")), "full", "no profile means full")
  assertEqual(str(CloudAgents.PgStore.Library.profileNetworkPolicy(sc, "gone")), "none", "missing profile fails closed")
  assertEqual(
    str(CloudAgents.PgStore.Library.enabledToolsForProfile(sc, "gone")),
    "",
    "missing profile fails open for tools"
  )
  val none: slice[String] = []
  val p = mkProfile(sc, "p", none, none)
  assertEqual(str(CloudAgents.PgStore.Library.profileNetworkPolicy(sc, p.id)), "restricted", "the profile's own policy")
  assertTrue(
    str(CloudAgents.PgStore.Library.enabledToolsForProfile(sc, p.id)).contains("ledger_note"),
    "selected tools are listed"
  )
}

test "update replaces grants; another user's update and delete match nothing" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val sc = fresh()
  val none: slice[String] = []
  val p = mkProfile(sc, "p", none, none)
  val creds: slice[String] = ["ONLY"]
  val tools: slice[String] = []
  assertEqualInt(
    int(
      CloudAgents.PgStore.Library.updateProfile(
        p.id,
        sc,
        "p2",
        "",
        "full",
        "selected",
        creds,
        none,
        none,
        none,
        "all",
        tools
      )
    ),
    1,
    "owner updates"
  )
  val intruder = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-other-" + sc.userId)
  val hijack: slice[String] = ["STOLEN"]
  assertEqualInt(
    int(
      CloudAgents.PgStore.Library.updateProfile(
        p.id,
        intruder,
        "x",
        "",
        "full",
        "all",
        hijack,
        none,
        none,
        none,
        "all",
        tools
      )
    ),
    0,
    "other user updates nothing"
  )
  assertEqualInt(int(CloudAgents.PgStore.Library.deleteProfile(p.id, intruder)), 0, "other user deletes nothing")
  match CloudAgents.PgStore.Library.getProfile(p.id, sc) {
    case Ok(Some(got)) -> {
      assertEqual(got.name, "p2", "owner's update applied")
      assertEqual(joined(got.credentials), "ONLY,", "grants replaced, and none added by the intruder")
      assertEqual(joined(got.tools), "", "tool grants cleared")
    }
    case _ -> assertTrue(false, "profile must survive")
  }
  assertEqualInt(int(CloudAgents.PgStore.Library.deleteProfile(p.id, sc)), 1, "owner deletes")
  assertTrue(isNone(optProfile(CloudAgents.PgStore.Library.getProfile(p.id, sc))), "gone")
}

test "deleting a skill or server ungrants it from profiles" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val sc = fresh()
  val s = mkSkill(sc, "s")
  val m = mkServer(sc, "m", "1")
  val skills: slice[String] = [s.id]
  val servers: slice[String] = [m.id]
  val p = mkProfile(sc, "p", skills, servers)
  assertEqualInt(
    skillList(CloudAgents.PgStore.Library.skillsForProfile(sc, p.id)).length.toInt(),
    1,
    "granted skill resolves"
  )
  assertEqualInt(int(CloudAgents.PgStore.Library.deleteSkill(s.id, sc)), 1, "skill deleted")
  assertEqualInt(int(CloudAgents.PgStore.Library.deleteMcpServer(m.id, sc)), 1, "server deleted")
  match CloudAgents.PgStore.Library.getProfile(p.id, sc) {
    case Ok(Some(got)) -> {
      assertEqual(joined(got.skillIds), "", "skill grant removed")
      assertEqual(joined(got.mcpServerIds), "", "server grant removed")
    }
    case _ -> assertTrue(false, "profile must remain")
  }
}

test "MCP servers keep argument order, and only enabled ones are granted to runs" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val sc = fresh()
  val on = mkServer(sc, "on", "1")
  val off = mkServer(sc, "off", "0")
  match CloudAgents.PgStore.Library.getMcpServer(on.id, sc) {
    case Ok(Some(got)) -> {
      assertEqual(joined(got.args), "--b,--a,--c,", "args keep their stored order")
      assertEqual(joined(got.env), "Z=1,A=2,", "env keeps its order")
      assertEqual(joined(got.headers), "X-One=1,", "headers")
      assertEqual(got.enabled, "1", "enabled flag round-trips")
    }
    case _ -> assertTrue(false, "server must exist")
  }
  val servers: slice[String] = [on.id, off.id]
  val none: slice[String] = []
  val p = mkProfile(sc, "p", none, servers)
  val granted = serverList(CloudAgents.PgStore.Library.mcpServersForProfile(sc, p.id))
  assertEqualInt(granted.length.toInt(), 1, "the disabled server is excluded")
  assertEqual(granted[0].name, "on", "only the enabled server")
  val list = serverList(CloudAgents.PgStore.Library.listMcpServers(sc))
  assertEqual(list[0].name + "," + list[1].name, "off,on", "listed by name")
}

test "library items are private to their user and tenant" {
  if not live() {
    assertTrue(true, "skipped")
    return
  }
  migrate()
  val sc = fresh()
  val s = mkSkill(sc, "private")
  match CloudAgents.PgStore.Library.addSubagent(sc, "sub", "d", "prompt", "") {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, dbErrorMessage(e))
  }
  val sameTenantOtherUser = CloudAgents.Pg.TenantScope(tenantId = sc.tenantId, userId = "gh-x-" + sc.userId)
  val otherTenantSameUser = CloudAgents.Pg.TenantScope(tenantId = "org-" + sc.userId, userId = sc.userId)
  assertTrue(
    isNone(optSkill(CloudAgents.PgStore.Library.getSkill(s.id, sameTenantOtherUser))),
    "other user cannot read"
  )
  assertEqualInt(
    skillList(CloudAgents.PgStore.Library.listSkills(otherTenantSameUser)).length.toInt(),
    0,
    "other tenant sees none"
  )
  assertEqualInt(
    subagentList(CloudAgents.PgStore.Library.listSubagents(otherTenantSameUser)).length.toInt(),
    0,
    "no subagents either"
  )
  assertEqualInt(int(CloudAgents.PgStore.Library.updateSkill(s.id, sameTenantOtherUser, "x", "y", "z")), 0, "no update")
}
