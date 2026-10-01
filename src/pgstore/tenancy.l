//! CloudAgents.PgStore.Tenancy — personal-tenant provisioning
//! (docs/phase11-postgres-tenancy.md §6.1).
//!
//! Every user has exactly one `personal` tenant, `personal:<user id>`, with
//! the user as its `owner`. Tenant-owned rows reference their tenant (for
//! example `session_routes.tenant_id`), so the tenant must exist before the
//! user's first write. `ensurePersonalTenant` creates the `users` row, the
//! tenant and the membership in one transaction, idempotently, and the auth
//! middleware calls it for every authenticated request. A process-wide cache
//! of users already provisioned keeps that to one round trip per user per
//! process; the inserts are `ON CONFLICT DO NOTHING`, so a second instance or
//! a race within this one is harmless.
//!
//! A `gh-<id>` user id also records the GitHub numeric id. The GitHub login
//! and organisation memberships are filled in by the membership sync
//! (slice F); the tenant's name is the user id until then.
@runtime_checked
package CloudAgents.PgStore.Tenancy

import Std.Core
import Db
import CloudAgents.Auth
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Sqlite

/// User ids whose personal tenant this process has already provisioned.
/// Bounded by the number of distinct users who sign in during the process's
/// lifetime.
protected type ProvisionedUsers {
  var ids: slice[String] = []
  entry contains(userId: in String): Bool {
    for id in ids {
      if id == userId {
        return true
      }
    }
    return false
  }
  entry add(userId: in String): Unit {
    for id in ids {
      if id == userId {
        return
      }
    }
    ids = ids.append(userId)
  }
}

val provisioned = ProvisionedUsers()

/// Make sure `userId` has a `users` row, a personal tenant and an owner
/// membership of it. Idempotent; after the first success in this process it
/// returns without touching the database.
pub func ensurePersonalTenant(userId: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  if userId.length == 0 {
    return Err(error = CloudAgents.Sqlite.ValidationFailed(message = "cannot provision a tenant for an empty user id"))
  }
  if provisioned.contains(userId) {
    return Ok(value = ())
  }
  provisionPersonalTenant(userId)?
  provisioned.add(userId)
  return Ok(value = ())
}

/// The database half of `ensurePersonalTenant`, without the cache. Tests use
/// it directly to check the rows it writes.
pub func provisionPersonalTenant(userId: in String): Result[Unit, CloudAgents.Sqlite.DbError] {
  val sc = CloudAgents.Pg.personalScope(userId)
  val githubId = CloudAgents.Auth.githubIdFromUserId(userId)
  val u = CloudAgents.PgStore.open(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  if githubId.length > 0 {
    CloudAgents.PgStore.ex(u, "INSERT INTO users (id, github_id) VALUES (@p0, @p1::bigint) ON CONFLICT (id) DO NOTHING", [userId, githubId])?
  } else {
    CloudAgents.PgStore.ex(u, "INSERT INTO users (id) VALUES (@p0) ON CONFLICT (id) DO NOTHING", [userId])?
  }
  CloudAgents.PgStore.ex(u, "INSERT INTO tenants (id, name, kind) VALUES (@p0, @p1, 'personal') ON CONFLICT (id) DO NOTHING", [sc.tenantId, userId])?
  CloudAgents.PgStore.ex(u, "INSERT INTO memberships (tenant_id, user_id, role, source) VALUES (@p0, @p1, 'owner', 'native') " + "ON CONFLICT (tenant_id, user_id) DO NOTHING", [sc.tenantId, userId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}
