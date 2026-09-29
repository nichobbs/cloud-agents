//! Offline tests for CloudAgents.Pg scope validation
//! (docs/phase11-postgres-tenancy.md §5.2, §10): an empty tenant or user id is
//! rejected before any SQL is sent. No database needed: the failing
//! validation happens before the connection is touched.
@test_module
package CloudAgents.PgScopeTests

import Std.Core
import Std.Testing
import CloudAgents.Pg

func invalid(r: in Result[Unit, PgError]): String {
  return match r {
    case Ok(_) -> ""
    case Err(e) -> pgErrorMessage(e)
  }
}

test "a complete tenant scope is valid" {
  assertEqual(invalid(checkTenantScope(TenantScope(tenantId = "personal:gh-1", userId = "gh-1"))), "", "valid scope")
}

test "an empty tenant id is rejected" {
  assertEqual(
    invalid(checkTenantScope(TenantScope(tenantId = "", userId = "gh-1"))),
    "invalid scope: empty tenant id",
    "empty tenant rejected"
  )
}

test "an empty user id is rejected in a tenant scope" {
  assertEqual(
    invalid(checkTenantScope(TenantScope(tenantId = "personal:gh-1", userId = ""))),
    "invalid scope: empty user id",
    "empty user rejected"
  )
}

test "an empty user scope is rejected" {
  assertEqual(invalid(checkUserScope(UserScope(userId = ""))), "invalid scope: empty user id", "empty user rejected")
  assertEqual(invalid(checkUserScope(UserScope(userId = "default"))), "", "operator user is a valid user scope")
}

test "the personal tenant id is derived from the user id" {
  assertEqual(personalTenantId("gh-42"), "personal:gh-42", "personal tenant of a GitHub user")
  assertEqual(personalTenantId("default"), "personal:default", "personal tenant of the operator user")
}
