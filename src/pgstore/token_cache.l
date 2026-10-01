//! CloudAgents.PgStore.TokenCache — the Postgres implementation of the
//! GitHub token-validation cache (`github_token_cache`), mirroring the
//! SQLite-backed functions in `CloudAgents.Repository` with the same
//! signatures and semantics (docs/phase11-postgres-tenancy.md §4.2, §9).
//!
//! The cache is read before any tenant is known (it is how a bearer token
//! resolves to a user), so it is a global table and every function here runs
//! in an unscoped unit.
//!
//! Semantics carried over from the SQLite store:
//! - a validated token is cached for ten minutes, a denied token or a
//!   rejected OAuth code for one minute;
//! - a denial is a row with empty user and login, a rejected code a row with
//!   empty user and login "oauth-code";
//! - a "historical" lookup still finds a validated token up to two hours
//!   after it expired, and rows are swept only after those two hours;
//! - each write first sweeps swept-eligible rows, best-effort (its own unit,
//!   so a failed sweep cannot abort the write).
@runtime_checked
package CloudAgents.PgStore.TokenCache

import Std.Core
import Db
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.Repository
import CloudAgents.Db

func validTtlMillis(): String {
  return "600000"
}

func deniedTtlMillis(): String {
  return "60000"
}

/// How long past expiry a row is kept for historical lookups (2 hours).
func graceMillis(): String {
  return "7200000"
}

func now(): String {
  return CloudAgents.Repository.nowMillis()
}

func unscoped(sql: in String, params: in slice[String]): Result[slice[DbRow], CloudAgents.Db.DbError] {
  val u = CloudAgents.PgStore.openUnscoped()?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, sql, params)?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = rows)
}

func sweep(nowMs: in String): Unit {
  match unscoped("DELETE FROM github_token_cache WHERE expires_at <= " + CloudAgents.Pg.msIn(0) + " - @p1::bigint * interval '1 millisecond'", [nowMs, graceMillis()]) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func upsert(
  tokenHash: in String, userId: in String, login: in String, ttl: in String
): Result[Unit, CloudAgents.Db.DbError] {
  val nowMs = now()
  sweep(nowMs)
  unscoped("INSERT INTO github_token_cache (token_hash, user_id, login, expires_at) VALUES (@p0, @p1, @p2, " + CloudAgents.Pg.msIn(3) + " + @p4::bigint * interval '1 millisecond') " + "ON CONFLICT (token_hash) DO UPDATE SET user_id = EXCLUDED.user_id, login = EXCLUDED.login, expires_at = EXCLUDED.expires_at", [tokenHash, userId, login, nowMs, ttl])?
  return Ok(value = ())
}

pub func cacheGitHubToken(
  tokenHash: in String, userId: in String, login: in String
): Result[Unit, CloudAgents.Db.DbError] {
  return upsert(tokenHash, userId, login, validTtlMillis())
}

pub func cacheGitHubTokenDenied(tokenHash: in String): Result[Unit, CloudAgents.Db.DbError] {
  return upsert(tokenHash, "", "", deniedTtlMillis())
}

pub func cacheOAuthCodeRejected(codeHash: in String): Result[Unit, CloudAgents.Db.DbError] {
  return upsert(codeHash, "", "oauth-code", deniedTtlMillis())
}

func countActive(login: in String): Result[Int, CloudAgents.Db.DbError] {
  val rows = unscoped("SELECT count(*)::text AS n FROM github_token_cache WHERE user_id = '' AND login = @p0 AND expires_at > " + CloudAgents.Pg.msIn(1), [login, now()])?
  return Ok(value = CloudAgents.Repository.parseNatString(CloudAgents.PgStore.col(rows[0], "n")))
}

/// Unexpired denial rows (a rate-limit signal).
pub func activeNegativeGitHubTokens(): Result[Int, CloudAgents.Db.DbError] {
  return countActive("")
}

/// Unexpired rejected-OAuth-code rows.
pub func activeRejectedOAuthCodes(): Result[Int, CloudAgents.Db.DbError] {
  return countActive("oauth-code")
}

func entry(rows: in slice[DbRow]): Option[CloudAgents.Repository.GitHubTokenCacheEntry] {
  if rows.length == 0 {
    return None
  }
  return Some(
    value = CloudAgents.Repository.GitHubTokenCacheEntry(
      userId = CloudAgents.PgStore.col(rows[0], "user_id"),
      login = CloudAgents.PgStore.col(rows[0], "login")
    )
  )
}

/// An unexpired cache entry for a token hash (a denial reads as an entry
/// with empty user), or None.
pub func cachedGitHubToken(
  tokenHash: in String
): Result[Option[CloudAgents.Repository.GitHubTokenCacheEntry], CloudAgents.Db.DbError] {
  val rows = unscoped("SELECT user_id, login FROM github_token_cache WHERE token_hash = @p0 AND expires_at > " + CloudAgents.Pg.msIn(1), [tokenHash, now()])?
  return Ok(value = entry(rows))
}

/// A validated entry for a token hash that expired less than two hours ago
/// (or has not expired), or None.
pub func lookupHistoricalGitHubToken(
  tokenHash: in String
): Result[Option[CloudAgents.Repository.GitHubTokenCacheEntry], CloudAgents.Db.DbError] {
  val rows = unscoped("SELECT user_id, login FROM github_token_cache WHERE token_hash = @p0 AND user_id <> '' AND expires_at >= " + CloudAgents.Pg.msIn(1) + " - @p2::bigint * interval '1 millisecond'", [tokenHash, now(), graceMillis()])?
  return Ok(value = entry(rows))
}

/// Any cached GitHub login for a user, or "".
pub func lookupGitHubLoginForUser(userId: in String): Result[String, CloudAgents.Db.DbError] {
  val rows = unscoped("SELECT login FROM github_token_cache WHERE user_id = @p0 AND login <> '' LIMIT 1", [userId])?
  if rows.length == 0 {
    return Ok(value = "")
  }
  return Ok(value = CloudAgents.PgStore.col(rows[0], "login"))
}

pub func invalidateGitHubToken(tokenHash: in String): Result[Unit, CloudAgents.Db.DbError] {
  unscoped("DELETE FROM github_token_cache WHERE token_hash = @p0", [tokenHash])?
  return Ok(value = ())
}
