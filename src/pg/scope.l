//! CloudAgents.Scope — the tenant and user scope values (docs/phase11-postgres-tenancy.md
//! §5.2). A leaf package with no database dependency, so request-handling code
//! (`CloudAgents.Auth`) can build a scope without linking the Postgres driver.
//! `CloudAgents.Pg` re-exports these under its own name.
@runtime_checked
package CloudAgents.Scope

import Std.Core

/// The tenant and user a unit of work acts for. Constructed only by the auth
/// middleware (from a validated membership), the callback-token resolver, or a
/// maintenance claim (spec §5.2).
pub record TenantScope {
  pub tenantId: String
  pub userId: String
}

/// The user a unit of work acts for when it touches only user-owned data
/// (spec §4.3a): no tenant is set, so tenant-owned tables stay invisible.
pub record UserScope {
  pub userId: String
}

/// The implicit personal tenant of a user (spec §6.1, §9 slice B): every user
/// has exactly one, and its id is derived from the user id so every path that
/// needs it (auth, callbacks, organisations) derives the same id.
pub func personalTenantId(userId: in String): String {
  return "personal:" + userId
}

/// The scope of a user acting in their personal tenant. Until organisations
/// ship (spec §9 slice F) this is every request's scope.
pub func personalScope(userId: in String): TenantScope {
  return TenantScope(tenantId = personalTenantId(userId), userId = userId)
}

/// The scope of a user acting on their own user-owned data (spec §4.3a).
pub func userScope(userId: in String): UserScope {
  return UserScope(userId = userId)
}
