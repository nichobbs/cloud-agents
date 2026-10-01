//! CloudAgents.PgStore.Tenancy — personal-tenant provisioning
//! (docs/phase11-postgres-tenancy.md §6.1).
//!
//! Every user has exactly one `personal` tenant, `personal:<user id>`, with
//! the user as its `owner`. Tenant-owned rows reference their tenant (for
//! example `session_routes.tenant_id`), so the tenant must exist before the
//! user's first write. `ensurePersonalTenant` creates the `users` row, the
//! tenant and the membership in one transaction, idempotently, and the auth
//! middleware calls it for every authenticated request. A process-wide cache
//! of users already provisioned (an O(1) `CloudAgents.KeyCache`) keeps that to
//! one round trip per user per process; the inserts are `ON CONFLICT DO NOTHING`, so a second instance or
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
import CloudAgents.Db
import CloudAgents.KeyCache

/// User ids whose personal tenant this process has already provisioned.
/// Bounded by `CloudAgents.KeyCache`; an entry never expires on its own,
/// since a provisioned tenant stays provisioned.
protected type ProvisionedUsers {
  var table: CloudAgents.KeyCache.Hashtable = CloudAgents.KeyCache.newTable()
  entry isLive(key: in String, nowMs: in Long): Bool {
    return CloudAgents.KeyCache.liveIn(table, key, nowMs)
  }
  entry remember(key: in String, expiresAtMs: in Long): Unit {
    CloudAgents.KeyCache.rememberIn(table, key, expiresAtMs, 10000)
  }
  entry forget(key: in String): Unit {
    CloudAgents.KeyCache.forgetIn(table, key)
  }
}

val provisioned = ProvisionedUsers()

/// An expiry far enough ahead to mean "for the life of the process".
func forever(): Long {
  return CloudAgents.KeyCache.nowMillis() + 3153600000000.toLong()
}

/// Make sure `userId` has a `users` row, a personal tenant and an owner
/// membership of it. Idempotent; after the first success in this process it
/// returns without touching the database.
pub func ensurePersonalTenant(userId: in String): Result[Unit, CloudAgents.Db.DbError] {
  if userId.length == 0 {
    return Err(error = CloudAgents.Db.ValidationFailed(message = "cannot provision a tenant for an empty user id"))
  }
  if provisioned.isLive(userId, CloudAgents.KeyCache.nowMillis()) {
    return Ok(value = ())
  }
  provisionPersonalTenant(userId)?
  provisioned.remember(userId, forever())
  return Ok(value = ())
}

/// The database half of `ensurePersonalTenant`, without the cache. Tests use
/// it directly to check the rows it writes.
pub func provisionPersonalTenant(userId: in String): Result[Unit, CloudAgents.Db.DbError] {
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
