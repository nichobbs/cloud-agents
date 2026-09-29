//! CloudAgents.PgStore.Prompts — the Postgres implementation of the prompt
//! library (`prompts`, `prompt_tags`), mirroring the SQLite-backed functions
//! in `CloudAgents.Repository` with the same signatures and semantics
//! (docs/phase11-postgres-tenancy.md §9 slices B/C).
//!
//! Semantics carried over from the SQLite store:
//! - every read and write is additionally filtered by the caller's user id,
//!   so a user sees only their own prompts within the tenant (spec §5.4);
//! - names sort in byte order (`COLLATE "C"`, SQLite's BINARY), tags
//!   alphabetically within a prompt;
//! - a prompt and its tag set are written in one transaction;
//! - update/delete return the rows affected on the prompt row (0 = not found
//!   or not owned), taken from the prompt statement itself.
@runtime_checked
package CloudAgents.PgStore.Prompts

import Std.Core
import Std.Uuid
import Db
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Repository
import CloudAgents.Sqlite

func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func promptCols(prefix: in String): String {
  return prefix + "id AS id, " + prefix + "user_id AS user_id, " + prefix + "name AS name, " + prefix + "body AS body, " +
    prefix +
    "use_count::text AS use_count, " +
    CloudAgents.Pg.msOut(prefix + "created_at") +
    " AS created_at, " +
    CloudAgents.Pg.msOut(prefix + "updated_at") +
    " AS updated_at"
}

func toPrompt(r: in DbRow, tags: in slice[String]): CloudAgents.Repository.Prompt {
  return CloudAgents.Repository.Prompt(
    id = CloudAgents.PgStore.col(r, "id"),
    userId = CloudAgents.PgStore.col(r, "user_id"),
    name = CloudAgents.PgStore.col(r, "name"),
    body = CloudAgents.PgStore.col(r, "body"),
    useCount = CloudAgents.PgStore.col(r, "use_count"),
    createdAt = CloudAgents.PgStore.col(r, "created_at"),
    updatedAt = CloudAgents.PgStore.col(r, "updated_at"),
    tags = tags
  )
}

func insertTags(
  u: in CloudAgents.PgStore.PgUnit, promptId: in String, userId: in String, tags: in slice[String]
): Result[Unit, CloudAgents.Sqlite.DbError] {
  for t in tags {
    CloudAgents.PgStore.ex(u, "INSERT INTO prompt_tags (id, prompt_id, user_id, tag) VALUES (@p0, @p1, @p2, @p3) " + "ON CONFLICT (tenant_id, prompt_id, tag) DO NOTHING", [newId(), promptId, userId, t])?
  }
  return Ok(value = ())
}

func deleteTagsSql(): String {
  return "DELETE FROM prompt_tags WHERE prompt_id = @p0 AND user_id = @p1"
}

/// Every (prompt_id, tag) pair of the user, tag-ordered within each prompt.
func tagPairs(
  u: in CloudAgents.PgStore.PgUnit, userId: in String
): Result[slice[CloudAgents.Repository.PromptTag], CloudAgents.Sqlite.DbError] {
  val rows = CloudAgents.PgStore.q(u, "SELECT prompt_id, tag FROM prompt_tags WHERE user_id = @p0 ORDER BY prompt_id COLLATE \"C\", tag COLLATE \"C\"", [userId])?
  var acc: slice[CloudAgents.Repository.PromptTag] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.Repository.PromptTag(
        promptId = CloudAgents.PgStore.col(r, "prompt_id"),
        tag = CloudAgents.PgStore.col(r, "tag")
      )
    )
  }
  return Ok(value = acc)
}

func tagsFor(pairs: in slice[CloudAgents.Repository.PromptTag], promptId: in String): slice[String] {
  var acc: slice[String] = []
  for p in pairs {
    if p.promptId == promptId {
      acc = acc.append(p.tag)
    }
  }
  return acc
}

func listWith(
  sc: in CloudAgents.Pg.TenantScope, sql: in String, params: in slice[String]
): Result[slice[CloudAgents.Repository.Prompt], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, sql, params)?
  val pairs = tagPairs(u, sc.userId)?
  CloudAgents.PgStore.commit(u)?
  var acc: slice[CloudAgents.Repository.Prompt] = []
  for r in rows {
    acc = acc.append(toPrompt(r, tagsFor(pairs, CloudAgents.PgStore.col(r, "id"))))
  }
  return Ok(value = acc)
}

/// Replace a prompt's tag set atomically.
pub func setPromptTags(
  promptId: in String, sc: in CloudAgents.Pg.TenantScope, tags: in slice[String]
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, deleteTagsSql(), [promptId, sc.userId])?
  insertTags(u, promptId, sc.userId, tags)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}

pub func addPrompt(
  sc: in CloudAgents.Pg.TenantScope, name: in String, body: in String
): Result[CloudAgents.Repository.Prompt, CloudAgents.Sqlite.DbError] {
  val noTags: slice[String] = []
  return addPromptWithTags(sc, name, body, noTags)
}

/// Save a new prompt and its tag set in one transaction.
pub func addPromptWithTags(
  sc: in CloudAgents.Pg.TenantScope, name: in String, body: in String, tags: in slice[String]
): Result[CloudAgents.Repository.Prompt, CloudAgents.Sqlite.DbError] {
  val id = newId()
  val ts = CloudAgents.Repository.nowMillis()
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  CloudAgents.PgStore.ex(u, "INSERT INTO prompts (id, user_id, name, body, use_count, created_at, updated_at) " + "VALUES (@p0, @p1, @p2, @p3, 0, " + CloudAgents.Pg.msIn(4) + ", " + CloudAgents.Pg.msIn(4) + ")", [id, sc.userId, name, body, ts])?
  insertTags(u, id, sc.userId, tags)?
  CloudAgents.PgStore.commit(u)?
  return Ok(
    value = CloudAgents.Repository.Prompt(
      id = id,
      userId = sc.userId,
      name = name,
      body = body,
      useCount = "0",
      createdAt = ts,
      updatedAt = ts,
      tags = tags
    )
  )
}

/// All of the user's prompts, by name.
pub func listPrompts(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Prompt], CloudAgents.Sqlite.DbError] {
  return listWith(
    sc,
    "SELECT " + promptCols("") + " FROM prompts WHERE user_id = @p0 ORDER BY name COLLATE \"C\"",
    [sc.userId]
  )
}

/// The user's prompts, most used first (ties by name).
pub func listPromptsByUsage(
  sc: in CloudAgents.Pg.TenantScope
): Result[slice[CloudAgents.Repository.Prompt], CloudAgents.Sqlite.DbError] {
  return listWith(
    sc,
    "SELECT " + promptCols("") + " FROM prompts WHERE user_id = @p0 ORDER BY use_count DESC, name COLLATE \"C\"",
    [sc.userId]
  )
}

/// The user's prompts carrying `tag`, by name, each with its full tag set.
pub func listPromptsByTag(
  sc: in CloudAgents.Pg.TenantScope, tag: in String
): Result[slice[CloudAgents.Repository.Prompt], CloudAgents.Sqlite.DbError] {
  return listWith(
    sc,
    "SELECT " + promptCols("p.") + " FROM prompts p JOIN prompt_tags pt " +
      "ON pt.tenant_id = p.tenant_id AND pt.prompt_id = p.id " +
      "WHERE p.user_id = @p0 AND pt.user_id = @p0 AND pt.tag = @p1 ORDER BY p.name COLLATE \"C\"",
    [sc.userId, tag]
  )
}

/// One of the user's prompts (with tags), or None.
pub func getPrompt(
  id: in String, sc: in CloudAgents.Pg.TenantScope
): Result[Option[CloudAgents.Repository.Prompt], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT " + promptCols("") + " FROM prompts WHERE id = @p0 AND user_id = @p1", [id, sc.userId])?
  if rows.length == 0 {
    CloudAgents.PgStore.commit(u)?
    return Ok(value = None)
  }
  val tagRows = CloudAgents.PgStore.q(u, "SELECT tag FROM prompt_tags WHERE prompt_id = @p0 AND user_id = @p1 ORDER BY tag COLLATE \"C\"", [id, sc.userId])?
  CloudAgents.PgStore.commit(u)?
  var tags: slice[String] = []
  for r in tagRows {
    tags = tags.append(CloudAgents.PgStore.col(r, "tag"))
  }
  return Ok(value = Some(value = toPrompt(rows[0], tags)))
}

func updateSql(): String {
  return "UPDATE prompts SET name = @p2, body = @p3, updated_at = " + CloudAgents.Pg.msIn(4) +
    " WHERE id = @p0 AND user_id = @p1"
}

/// Update name/body. Rows affected (0 = not found or not owned).
pub func updatePrompt(
  id: in String, sc: in CloudAgents.Pg.TenantScope, name: in String, body: in String
): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, updateSql(), [id, sc.userId, name, body, CloudAgents.Repository.nowMillis()])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

/// Update name/body and replace the tag set in one transaction. The tag
/// writes only happen when the prompt row matched, so a missing or foreign
/// prompt gets no orphan tags.
pub func updatePromptWithTags(
  id: in String,
  sc: in CloudAgents.Pg.TenantScope,
  name: in String,
  body: in String,
  tags: in slice[String],
): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, updateSql(), [id, sc.userId, name, body, CloudAgents.Repository.nowMillis()])?
  if n > 0 {
    CloudAgents.PgStore.ex(u, deleteTagsSql(), [id, sc.userId])?
    insertTags(u, id, sc.userId, tags)?
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

/// Record one use. Rows affected (0 = not found).
pub func markPromptUsed(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "UPDATE prompts SET use_count = use_count + 1, updated_at = " + CloudAgents.Pg.msIn(2) + " WHERE id = @p0 AND user_id = @p1", [id, sc.userId, CloudAgents.Repository.nowMillis()])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}

/// Delete a prompt and its tags in one transaction. Rows affected on the
/// prompt (0 = not found or not owned).
pub func deletePrompt(id: in String, sc: in CloudAgents.Pg.TenantScope): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "DELETE FROM prompts WHERE id = @p0 AND user_id = @p1", [id, sc.userId])?
  if n > 0 {
    CloudAgents.PgStore.ex(u, deleteTagsSql(), [id, sc.userId])?
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = n)
}
