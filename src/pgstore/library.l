//! CloudAgents.PgStore.Library — the Postgres store for profiles and
//! the per-user library (skills, subagents, MCP servers) and the grants that
//! link them, behind the `CloudAgents.Repository` facade
//! (docs/phase11-postgres-tenancy.md §9 slices B/C).
//!
//! Semantics:
//! - every read and write is also filtered by the caller's user id (creator-
//!   only visibility within the tenant, spec §5.4);
//! - names and grant ids sort in byte order (`COLLATE "C"`); MCP server
//!   args/env/headers keep their stored position order;
//! - a record and all its child rows (grants, args/env/headers) are written
//!   in one transaction, and grant inserts ignore duplicates;
//! - update/delete return the rows affected on the parent row (0 = not found
//!   or not owned) and touch no child rows when the parent did not match;
//! - deleting a skill, subagent or MCP server also removes it from every
//!   profile that granted it;
//! - `profileNetworkPolicy` fails closed ("none") for a profile id that no
//!   longer resolves, `enabledToolsForProfile` fails open ("") for one, and
//!   `mcpServersForProfile` returns only enabled servers.
//!
//! `decryptedCredentialsForProfile` reads the user-owned credential vault and
//! lives with the credentials domain.
@runtime_checked
package CloudAgents.PgStore.Library

import Std.Core
import Std.Uuid
import Db
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Repository
import CloudAgents.Db
import CloudAgents.ToolPolicy

alias PgUnit = CloudAgents.PgStore.PgUnit

func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func col(r: in DbRow, name: in String): String {
  return CloudAgents.PgStore.col(r, name)
}

func stamps(prefix: in String): String {
  return CloudAgents.Pg.msOut(prefix + "created_at") + " AS created_at, " + CloudAgents.Pg.msOut(prefix + "updated_at") +
    " AS updated_at"
}

func values(u: in PgUnit, sql: in String, params: in slice[String]): Result[slice[String], CloudAgents.Db.DbError] {
  val rows = CloudAgents.PgStore.q(u, sql, params)?
  var acc: slice[String] = []
  for r in rows {
    acc = acc.append(col(r, "v"))
  }
  return Ok(value = acc)
}

// ─── Profiles ───────────────────────────────────────────────────────────────
/// The five grant sets of a profile: table, value column.
func grantTables(): slice[String] {
  return ["profile_credentials", "profile_skills", "profile_subagents", "profile_mcp_servers", "profile_tools"]
}

func grantColumn(table: in String): String {
  return match table {
    case "profile_credentials" -> "credential_name"
    case "profile_skills" -> "skill_id"
    case "profile_subagents" -> "subagent_id"
    case "profile_mcp_servers" -> "mcp_server_id"
    case _ -> "tool_name"
  }
}

func grantValues(
  u: in PgUnit, table: in String, profileId: in String, userId: in String
): Result[slice[String], CloudAgents.Db.DbError] {
  val c = grantColumn(table)
  return values(
    u,
    "SELECT " + c + " AS v FROM " + table + " WHERE profile_id = @p0 AND user_id = @p1 ORDER BY " + c +
      " COLLATE \"C\"",
    [profileId, userId]
  )
}

func replaceGrants(
  u: in PgUnit, table: in String, profileId: in String, userId: in String, items: in slice[String]
): Result[Unit, CloudAgents.Db.DbError] {
  CloudAgents.PgStore.ex(u, "DELETE FROM " + table + " WHERE profile_id = @p0 AND user_id = @p1", [profileId, userId])?
  for item in items {
    CloudAgents.PgStore.ex(u, "INSERT INTO " + table + " (id, profile_id, user_id, " + grantColumn(table) + ") VALUES (@p0, @p1, @p2, @p3) " + "ON CONFLICT (tenant_id, profile_id, " + grantColumn(table) + ") DO NOTHING", [newId(), profileId, userId, item])?
  }
  return Ok(value = ())
}

func replaceAllGrants(
  u: in PgUnit,
  profileId: in String,
  userId: in String,
  credentials: in slice[String],
  skillIds: in slice[String],
  subagentIds: in slice[String],
  mcpServerIds: in slice[String],
  tools: in slice[String],
): Result[Unit, CloudAgents.Db.DbError] {
  replaceGrants(u, "profile_credentials", profileId, userId, credentials)?
  replaceGrants(u, "profile_skills", profileId, userId, skillIds)?
  replaceGrants(u, "profile_subagents", profileId, userId, subagentIds)?
  replaceGrants(u, "profile_mcp_servers", profileId, userId, mcpServerIds)?
  replaceGrants(u, "profile_tools", profileId, userId, tools)?
  return Ok(value = ())
}

func profileCols(): String {
  return "id, user_id, name, harness, network_policy, credential_mode, tool_mode, " + stamps("")
}

func toProfile(u: in PgUnit, r: in DbRow): Result[CloudAgents.Repository.Profile, CloudAgents.Db.DbError] {
  val pid = col(r, "id")
  val uid = col(r, "user_id")
  // Hoisted: `?` inside a call argument can emit invalid IL (lyric-lang#6448).
  val creds = grantValues(u, "profile_credentials", pid, uid)?
  val skills = grantValues(u, "profile_skills", pid, uid)?
  val subagents = grantValues(u, "profile_subagents", pid, uid)?
  val servers = grantValues(u, "profile_mcp_servers", pid, uid)?
  val tools = grantValues(u, "profile_tools", pid, uid)?
  return Ok(
    value = CloudAgents.Repository.Profile(
      id = pid,
      userId = uid,
      name = col(r, "name"),
      harness = col(r, "harness"),
      networkPolicy = col(r, "network_policy"),
      credentialMode = col(r, "credential_mode"),
      credentials = creds,
      skillIds = skills,
      subagentIds = subagents,
      mcpServerIds = servers,
      toolMode = col(r, "tool_mode"),
      tools = tools,
      createdAt = col(r, "created_at"),
      updatedAt = col(r, "updated_at")
    )
  )
}

func getProfileIn(
  u: in PgUnit, id: in String, userId: in String
): Result[Option[CloudAgents.Repository.Profile], CloudAgents.Db.DbError] {
  val rows = CloudAgents.PgStore.q(u, "SELECT " + profileCols() + " FROM profiles WHERE id = @p0 AND user_id = @p1", [id, userId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  val p = toProfile(u, rows[0])?
  return Ok(value = Some(value = p))
}

/// The network policy a profile pins: "full" for no profile, "none" (fail
/// closed) for a profile id that no longer resolves.
pub func profileNetworkPolicy(
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[String, CloudAgents.Db.DbError] {
  if profileId.length == 0 {
    return Ok(value = "full")
  }
  match getProfile(profileId, sc)? {
    case None -> return Ok(value = "none")
    case Some(p) -> return Ok(value = if p.networkPolicy.length == 0 then "full" else p.networkPolicy)
  }
}

pub func addProfile(
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  harness: in String,
  networkPolicy: in String,
  credentialMode: in String,
  credentials: in slice[String],
  skillIds: in slice[String],
  subagentIds: in slice[String],
  mcpServerIds: in slice[String],
  toolMode: in String,
  tools: in slice[String],
): Result[CloudAgents.Repository.Profile, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, "INSERT INTO profiles (id, user_id, name, harness, network_policy, credential_mode, tool_mode, created_at, updated_at) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6, " + CloudAgents.Pg.msIn(7) + ", " + CloudAgents.Pg.msIn(7) + ")", [id, sc.userId, name, harness, networkPolicy, credentialMode, toolMode, ts])?
  replaceAllGrants(u, id, sc.userId, credentials, skillIds, subagentIds, mcpServerIds, tools)?
  CloudAgents.PgStore.commit(u)?
  return Ok(
    value = CloudAgents.Repository.Profile(
      id = id,
      userId = sc.userId,
      name = name,
      harness = harness,
      networkPolicy = networkPolicy,
      credentialMode = credentialMode,
      credentials = credentials,
      skillIds = skillIds,
      subagentIds = subagentIds,
      mcpServerIds = mcpServerIds,
      toolMode = toolMode,
      tools = tools,
      createdAt = ts,
      updatedAt = ts
    )
  )
}

pub func listProfiles(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Profile], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + profileCols() + " FROM profiles WHERE user_id = @p0 ORDER BY name COLLATE \"C\"", [sc.userId])?
  var acc: slice[CloudAgents.Repository.Profile] = []
  for r in rows {
    val p = toProfile(u, r)?
    acc = acc.append(p)
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = acc)
}

pub func profileIdByName(
  sc: in CloudAgents.Pg.TenantScope, name: in String
): Result[Option[String], CloudAgents.Db.DbError] {
  return idByName(sc, "profiles", name)
}

pub func getProfile(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.Profile], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val p = getProfileIn(u, id, sc.userId)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = p)
}

pub func updateProfile(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  harness: in String,
  networkPolicy: in String,
  credentialMode: in String,
  credentials: in slice[String],
  skillIds: in slice[String],
  subagentIds: in slice[String],
  mcpServerIds: in slice[String],
  toolMode: in String,
  tools: in slice[String],
): Result[Int, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "UPDATE profiles SET name = @p2, harness = @p3, network_policy = @p4, credential_mode = @p5, tool_mode = @p6, " + "updated_at = " + CloudAgents.Pg.msIn(7) + " WHERE id = @p0 AND user_id = @p1", [id, sc.userId, name, harness, networkPolicy, credentialMode, toolMode, CloudAgents.Repository.nowMillis()])?
  if n > 0 {
    replaceAllGrants(u, id, sc.userId, credentials, skillIds, subagentIds, mcpServerIds, tools)?
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

pub func deleteProfile(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "DELETE FROM profiles WHERE id = @p0 AND user_id = @p1", [id, sc.userId])?
  if n > 0 {
    for t in grantTables() {
      CloudAgents.PgStore.ex(u, "DELETE FROM " + t + " WHERE profile_id = @p0 AND user_id = @p1", [id, sc.userId])?
    }
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

/// CLOUD_AGENTS_ENABLED_TOOLS for a profile's session. Fails open ("") for
/// no profile or one that no longer resolves.
pub func enabledToolsForProfile(
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[String, CloudAgents.Db.DbError] {
  if profileId.length == 0 {
    return Ok(value = "")
  }
  match getProfile(profileId, sc)? {
    case None -> return Ok(value = "")
    case Some(p) -> return Ok(value = CloudAgents.ToolPolicy.enabledToolsEnvValue(p.toolMode, p.tools))
  }
}

// ─── Shared library helpers ─────────────────────────────────────────────────
func idByName(
  sc: in CloudAgents.Pg.TenantScope, table: in String, name: in String
): Result[Option[String], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ids = values(u, "SELECT id AS v FROM " + table + " WHERE user_id = @p0 AND name = @p1", [sc.userId, name])?
  CloudAgents.PgStore.commit(u)?
  if ids.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = ids[0]))
}

/// Delete a library item and ungrant it from every profile, in one unit.
func deleteLibraryItem(
  sc: in CloudAgents.Pg.TenantScope,
  table: in String,
  grantTable: in String,
  grantCol: in String,
  id: in String,
  children: in slice[String],
): Result[Int, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "DELETE FROM " + table + " WHERE id = @p0 AND user_id = @p1", [id, sc.userId])?
  if n > 0 {
    CloudAgents.PgStore.ex(u, "DELETE FROM " + grantTable + " WHERE " + grantCol + " = @p0 AND user_id = @p1", [id, sc.userId])?
    for child in children {
      CloudAgents.PgStore.ex(u, "DELETE FROM " + child + " WHERE mcp_server_id = @p0 AND user_id = @p1", [id, sc.userId])?
    }
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

// ─── Skills ─────────────────────────────────────────────────────────────────
func skillCols(): String {
  return "id, user_id, name, description, body, " + stamps("")
}

func toSkill(r: in DbRow): CloudAgents.Repository.Skill {
  return CloudAgents.Repository.Skill(
    id = col(r, "id"),
    userId = col(r, "user_id"),
    name = col(r, "name"),
    description = col(r, "description"),
    body = col(r, "body"),
    createdAt = col(r, "created_at"),
    updatedAt = col(r, "updated_at")
  )
}

func getSkillIn(
  u: in PgUnit, id: in String, userId: in String
): Result[Option[CloudAgents.Repository.Skill], CloudAgents.Db.DbError] {
  val rows = CloudAgents.PgStore.q(u, "SELECT " + skillCols() + " FROM skills WHERE id = @p0 AND user_id = @p1", [id, userId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toSkill(rows[0])))
}

pub func addSkill(
  sc: in CloudAgents.Pg.TenantScope, name: in String, description: in String, body: in String
): Result[CloudAgents.Repository.Skill, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, "INSERT INTO skills (id, user_id, name, description, body, created_at, updated_at) VALUES (@p0, @p1, @p2, @p3, @p4, " + CloudAgents.Pg.msIn(5) + ", " + CloudAgents.Pg.msIn(5) + ")", [id, sc.userId, name, description, body, ts])?
  CloudAgents.PgStore.commit(u)?
  return Ok(
    value = CloudAgents.Repository.Skill(
      id = id,
      userId = sc.userId,
      name = name,
      description = description,
      body = body,
      createdAt = ts,
      updatedAt = ts
    )
  )
}

pub func listSkills(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Skill], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + skillCols() + " FROM skills WHERE user_id = @p0 ORDER BY name COLLATE \"C\"", [sc.userId])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.Skill] = []
  for r in rows {
    acc = acc.append(toSkill(r))
  }
  return Ok(value = acc)
}

pub func skillIdByName(
  sc: in CloudAgents.Pg.TenantScope, name: in String
): Result[Option[String], CloudAgents.Db.DbError] {
  return idByName(sc, "skills", name)
}

pub func getSkill(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.Skill], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val s = getSkillIn(u, id, sc.userId)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = s)
}

pub func updateSkill(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  description: in String,
  body: in String,
): Result[Int, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "UPDATE skills SET name = @p2, description = @p3, body = @p4, updated_at = " + CloudAgents.Pg.msIn(5) + " WHERE id = @p0 AND user_id = @p1", [id, sc.userId, name, description, body, CloudAgents.Repository.nowMillis()])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

pub func deleteSkill(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  val none: slice[String] = []
  return deleteLibraryItem(sc, "skills", "profile_skills", "skill_id", id, none)
}

// ─── Subagents ──────────────────────────────────────────────────────────────
func subagentCols(): String {
  return "id, user_id, name, description, system_prompt, model, " + stamps("")
}

func toSubagent(r: in DbRow): CloudAgents.Repository.Subagent {
  return CloudAgents.Repository.Subagent(
    id = col(r, "id"),
    userId = col(r, "user_id"),
    name = col(r, "name"),
    description = col(r, "description"),
    systemPrompt = col(r, "system_prompt"),
    model = col(r, "model"),
    createdAt = col(r, "created_at"),
    updatedAt = col(r, "updated_at")
  )
}

func getSubagentIn(
  u: in PgUnit, id: in String, userId: in String
): Result[Option[CloudAgents.Repository.Subagent], CloudAgents.Db.DbError] {
  val rows = CloudAgents.PgStore.q(u, "SELECT " + subagentCols() + " FROM subagents WHERE id = @p0 AND user_id = @p1", [id, userId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = toSubagent(rows[0])))
}

pub func addSubagent(
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  description: in String,
  systemPrompt: in String,
  model: in String,
): Result[CloudAgents.Repository.Subagent, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, "INSERT INTO subagents (id, user_id, name, description, system_prompt, model, created_at, updated_at) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, " + CloudAgents.Pg.msIn(6) + ", " + CloudAgents.Pg.msIn(6) + ")", [id, sc.userId, name, description, systemPrompt, model, ts])?
  CloudAgents.PgStore.commit(u)?
  return Ok(
    value = CloudAgents.Repository.Subagent(
      id = id,
      userId = sc.userId,
      name = name,
      description = description,
      systemPrompt = systemPrompt,
      model = model,
      createdAt = ts,
      updatedAt = ts
    )
  )
}

pub func listSubagents(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Subagent], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + subagentCols() + " FROM subagents WHERE user_id = @p0 ORDER BY name COLLATE \"C\"", [sc.userId])?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.Subagent] = []
  for r in rows {
    acc = acc.append(toSubagent(r))
  }
  return Ok(value = acc)
}

pub func subagentIdByName(
  sc: in CloudAgents.Pg.TenantScope, name: in String
): Result[Option[String], CloudAgents.Db.DbError] {
  return idByName(sc, "subagents", name)
}

pub func getSubagent(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.Subagent], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val s = getSubagentIn(u, id, sc.userId)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = s)
}

pub func updateSubagent(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  description: in String,
  systemPrompt: in String,
  model: in String,
): Result[Int, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "UPDATE subagents SET name = @p2, description = @p3, system_prompt = @p4, model = @p5, updated_at = " + CloudAgents.Pg.msIn(6) + " WHERE id = @p0 AND user_id = @p1", [id, sc.userId, name, description, systemPrompt, model, CloudAgents.Repository.nowMillis()])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

pub func deleteSubagent(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  val none: slice[String] = []
  return deleteLibraryItem(sc, "subagents", "profile_subagents", "subagent_id", id, none)
}

// ─── MCP servers ────────────────────────────────────────────────────────────
func mcpChildTables(): slice[String] {
  return ["mcp_server_args", "mcp_server_env", "mcp_server_headers"]
}

func mcpChildValues(
  u: in PgUnit, table: in String, serverId: in String, userId: in String
): Result[slice[String], CloudAgents.Db.DbError] {
  return values(
    u,
    "SELECT value AS v FROM " + table + " WHERE mcp_server_id = @p0 AND user_id = @p1 ORDER BY position",
    [serverId, userId]
  )
}

func replaceMcpChildren(
  u: in PgUnit,
  serverId: in String,
  userId: in String,
  args: in slice[String],
  env: in slice[String],
  headers: in slice[String],
): Result[Unit, CloudAgents.Db.DbError] {
  for t in mcpChildTables() {
    CloudAgents.PgStore.ex(u, "DELETE FROM " + t + " WHERE mcp_server_id = @p0 AND user_id = @p1", [serverId, userId])?
  }
  insertMcpChildren(u, "mcp_server_args", serverId, userId, args)?
  insertMcpChildren(u, "mcp_server_env", serverId, userId, env)?
  insertMcpChildren(u, "mcp_server_headers", serverId, userId, headers)?
  return Ok(value = ())
}

func insertMcpChildren(
  u: in PgUnit, table: in String, serverId: in String, userId: in String, items: in slice[String]
): Result[Unit, CloudAgents.Db.DbError] {
  var i = 0
  while i < items.length {
    CloudAgents.PgStore.ex(u, "INSERT INTO " + table + " (id, mcp_server_id, user_id, position, value) VALUES (@p0, @p1, @p2, @p3::integer, @p4)", [newId(), serverId, userId, i.toString(), items[i]])?
    i = i + 1
  }
  return Ok(value = ())
}

func mcpCols(): String {
  return "id, user_id, name, transport, command, url, CASE WHEN enabled THEN '1' ELSE '0' END AS enabled, " + stamps("")
}

func toMcpServer(u: in PgUnit, r: in DbRow): Result[CloudAgents.Repository.McpServer, CloudAgents.Db.DbError] {
  val id = col(r, "id")
  val uid = col(r, "user_id")
  val args = mcpChildValues(u, "mcp_server_args", id, uid)?
  val env = mcpChildValues(u, "mcp_server_env", id, uid)?
  val headers = mcpChildValues(u, "mcp_server_headers", id, uid)?
  return Ok(
    value = CloudAgents.Repository.McpServer(
      id = id,
      userId = uid,
      name = col(r, "name"),
      transport = col(r, "transport"),
      command = col(r, "command"),
      args = args,
      url = col(r, "url"),
      env = env,
      createdAt = col(r, "created_at"),
      updatedAt = col(r, "updated_at"),
      enabled = col(r, "enabled"),
      headers = headers
    )
  )
}

func getMcpServerIn(
  u: in PgUnit, id: in String, userId: in String
): Result[Option[CloudAgents.Repository.McpServer], CloudAgents.Db.DbError] {
  val rows = CloudAgents.PgStore.q(u, "SELECT " + mcpCols() + " FROM mcp_servers WHERE id = @p0 AND user_id = @p1", [id, userId])?
  if rows.length == 0 {
    return Ok(value = None)
  }
  val m = toMcpServer(u, rows[0])?
  return Ok(value = Some(value = m))
}

pub func addMcpServer(
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  transport: in String,
  command: in String,
  args: in slice[String],
  url: in String,
  env: in slice[String],
  enabled: in String = "1",
  headers: in slice[String] = [],
): Result[CloudAgents.Repository.McpServer, CloudAgents.Db.DbError] {
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, "INSERT INTO mcp_servers (id, user_id, name, transport, command, url, enabled, created_at, updated_at) " + "VALUES (@p0, @p1, @p2, @p3, @p4, @p5, @p6 = '1', " + CloudAgents.Pg.msIn(7) + ", " + CloudAgents.Pg.msIn(7) + ")", [id, sc.userId, name, transport, command, url, enabled, ts])?
  replaceMcpChildren(u, id, sc.userId, args, env, headers)?
  CloudAgents.PgStore.commit(u)?
  return Ok(
    value = CloudAgents.Repository.McpServer(
      id = id,
      userId = sc.userId,
      name = name,
      transport = transport,
      command = command,
      args = args,
      url = url,
      env = env,
      createdAt = ts,
      updatedAt = ts,
      enabled = enabled,
      headers = headers
    )
  )
}

pub func listMcpServers(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.McpServer], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + mcpCols() + " FROM mcp_servers WHERE user_id = @p0 ORDER BY name COLLATE \"C\"", [sc.userId])?
  var acc: slice[CloudAgents.Repository.McpServer] = []
  for r in rows {
    val m = toMcpServer(u, r)?
    acc = acc.append(m)
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = acc)
}

pub func mcpServerIdByName(
  sc: in CloudAgents.Pg.TenantScope, name: in String
): Result[Option[String], CloudAgents.Db.DbError] {
  return idByName(sc, "mcp_servers", name)
}

pub func getMcpServer(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.McpServer], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val s = getMcpServerIn(u, id, sc.userId)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = s)
}

pub func updateMcpServer(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  transport: in String,
  command: in String,
  args: in slice[String],
  url: in String,
  env: in slice[String],
  enabled: in String = "1",
  headers: in slice[String] = [],
): Result[Int, CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "UPDATE mcp_servers SET name = @p2, transport = @p3, command = @p4, url = @p5, enabled = (@p6 = '1'), updated_at = " + CloudAgents.Pg.msIn(7) + " WHERE id = @p0 AND user_id = @p1", [id, sc.userId, name, transport, command, url, enabled, CloudAgents.Repository.nowMillis()])?
  if n > 0 {
    replaceMcpChildren(u, id, sc.userId, args, env, headers)?
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

pub func deleteMcpServer(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Db.DbError] {
  return deleteLibraryItem(sc, "mcp_servers", "profile_mcp_servers", "mcp_server_id", id, mcpChildTables())
}

// ─── A profile's granted library items ──────────────────────────────────────
pub func skillsForProfile(
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[slice[CloudAgents.Repository.Skill], CloudAgents.Db.DbError] {
  var acc: slice[CloudAgents.Repository.Skill] = []
  if profileId.length == 0 {
    return Ok(value = acc)
  }
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ids = grantValues(u, "profile_skills", profileId, sc.userId)?
  for id in ids {
    match getSkillIn(u, id, sc.userId)? {
      case Some(s) -> {
        acc = acc.append(s)
      }
      case None -> ()
    }
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = acc)
}

pub func subagentsForProfile(
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[slice[CloudAgents.Repository.Subagent], CloudAgents.Db.DbError] {
  var acc: slice[CloudAgents.Repository.Subagent] = []
  if profileId.length == 0 {
    return Ok(value = acc)
  }
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ids = grantValues(u, "profile_subagents", profileId, sc.userId)?
  for id in ids {
    match getSubagentIn(u, id, sc.userId)? {
      case Some(s) -> {
        acc = acc.append(s)
      }
      case None -> ()
    }
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = acc)
}

/// The profile's granted MCP servers, enabled ones only.
pub func mcpServersForProfile(
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[slice[CloudAgents.Repository.McpServer], CloudAgents.Db.DbError] {
  var acc: slice[CloudAgents.Repository.McpServer] = []
  if profileId.length == 0 {
    return Ok(value = acc)
  }
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ids = grantValues(u, "profile_mcp_servers", profileId, sc.userId)?
  for id in ids {
    match getMcpServerIn(u, id, sc.userId)? {
      case Some(s) -> {
        if s.enabled == "1" {
          acc = acc.append(s)
        }
      }
      case None -> ()
    }
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = acc)
}
