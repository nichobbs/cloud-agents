//! CloudAgents.PgStore.Credentials — the Postgres implementation of the
//! user-owned vault (`credentials`, `github_oauth_refresh`,
//! `model_listing_cache`), mirroring the SQLite-backed functions in
//! `CloudAgents.Repository` with the same signatures and semantics
//! (docs/phase11-postgres-tenancy.md §4.3a, §9 slices B/C).
//!
//! These tables belong to a person, not a tenant: they have no `tenant_id`,
//! and RLS matches `user_id` against `app.current_user`. Every function here
//! runs in a user-scoped unit, so it works at sign-in (before a tenant is
//! chosen) and returns the same rows whichever tenant is active. The one
//! exception is `decryptedCredentialsForProfile`, which reads a tenant-owned
//! profile first and then the creator's own credentials.
//!
//! Semantics carried over from the SQLite store:
//! - values are encrypted before they are written and decrypted only for
//!   injection or server-side use, never returned by the listing;
//! - names sort in byte order (`COLLATE "C"`, SQLite's BINARY);
//! - a re-put keeps the credential's id and `created_at`;
//! - bulk decryption skips an undecryptable row with a warning, while a single
//!   named lookup reports it as an error;
//! - deleting `GITHUB_TOKEN` also drops the refresh metadata, best-effort.
@runtime_checked
package CloudAgents.PgStore.Credentials

import Std.Core
import Std.Uuid
import Db
import CloudAgents.Crypto
import CloudAgents.Pg
import CloudAgents.PgStore
import CloudAgents.PgStore.Library
import CloudAgents.Repository
import CloudAgents.Scope
import CloudAgents.Sqlite

func newId(): String {
  return Std.Uuid.uuidToString(Std.Uuid.newUuid())
}

func dbErr(e: in CloudAgents.Sqlite.DbError): CloudAgents.Repository.CredentialError {
  return CloudAgents.Repository.Db(error = e)
}

func cryptoErr(e: in CloudAgents.Crypto.CryptoError): CloudAgents.Repository.CredentialError {
  return CloudAgents.Repository.Crypto(error = e)
}

/// The integer SQLite's `CAST(x AS INTEGER)` yields for `x`: optional leading
/// spaces and sign, then the leading digits; anything else (including "")
/// is 0. GitHub's `expires_in` fields go through this so a missing or
/// malformed value expires the token immediately, exactly as on SQLite.
/// Values beyond ten significant digits are clamped to 9999999999 seconds,
/// so the resulting timestamp is always in Postgres's range.
pub func sqliteIntPrefix(s: in String): String {
  var i = 0
  while i < s.length and s.substring(i, 1) == " " {
    i = i + 1
  }
  var sign = ""
  if i < s.length and (s.substring(i, 1) == "-" or s.substring(i, 1) == "+") {
    if s.substring(i, 1) == "-" {
      sign = "-"
    }
    i = i + 1
  }
  var digits = ""
  while i < s.length {
    val c = s.substring(i, 1)
    if not (c >= "0" and c <= "9") {
      break
    }
    digits = digits + c
    i = i + 1
  }
  if digits.length == 0 {
    return "0"
  }
  // SQLite saturates a huge value instead of failing; Postgres would raise
  // "timestamp out of range" adding it to now(). Clamp to ten digits (about
  // 317 years), which is a far-future expiry either way.
  var n = 0
  while n < digits.length and digits.substring(n, 1) == "0" {
    n = n + 1
  }
  if n == digits.length {
    return "0"
  }
  if digits.length - n > 10 {
    return sign + "9999999999"
  }
  return sign + digits.substring(n, digits.length - n)
}

/// Store (or replace) a credential, encrypting the value at rest.
pub func putCredential(
  sc: in CloudAgents.Pg.UserScope, name: in String, value: in String
): Result[Unit, CloudAgents.Repository.CredentialError] {
  val encrypted = match CloudAgents.Crypto.encrypt(value) {
    case Ok(blob) -> blob
    case Err(e) -> return Err(error = cryptoErr(e))
  }
  val u = match CloudAgents.PgStore.openUser(sc) { case Ok(x) -> x; case Err(e) -> return Err(error = dbErr(e)) }
  defer {
    CloudAgents.PgStore.release(u)
  }
  val ts = CloudAgents.Repository.nowMillis()
  val sql = "INSERT INTO credentials (user_id, id, name, value_encrypted, created_at, updated_at) VALUES (@p0, @p1, @p2, @p3, " +
    CloudAgents.Pg.msIn(4) +
    ", " +
    CloudAgents.Pg.msIn(4) +
    ") ON CONFLICT (user_id, name) DO UPDATE SET value_encrypted = EXCLUDED.value_encrypted, updated_at = EXCLUDED.updated_at"
  match CloudAgents.PgStore.ex(u, sql, [sc.userId, newId(), name, encrypted, ts]) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = dbErr(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> return Ok(value = ())
    case Err(e) -> return Err(error = dbErr(e))
  }
}

/// The user's credential names and last-update times (never values).
pub func listCredentialNames(
  sc: in CloudAgents.Pg.UserScope
): Result[slice[CloudAgents.Repository.CredentialName], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.openUser(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT name, " + CloudAgents.Pg.msOut("updated_at") + " AS updated_at FROM credentials " + "WHERE user_id = @p0 ORDER BY name COLLATE \"C\"", [sc.userId])?
  var acc: slice[CloudAgents.Repository.CredentialName] = []
  for r in rows {
    acc = acc.append(
      CloudAgents.Repository.CredentialName(
        name = CloudAgents.PgStore.col(r, "name"),
        updatedAt = CloudAgents.PgStore.col(r, "updated_at")
      )
    )
  }
  CloudAgents.PgStore.commit(u)?
  return Ok(value = acc)
}

/// Delete a credential by name; rows affected (0 = not found). Deleting
/// `GITHUB_TOKEN` also drops the refresh metadata (#668), best-effort: a
/// cleanup failure never blocks the deletion itself.
pub func deleteCredential(sc: in CloudAgents.Pg.UserScope, name: in String): Result[Int, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.openUser(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val n = CloudAgents.PgStore.ex(u, "DELETE FROM credentials WHERE user_id = @p0 AND name = @p1", [sc.userId, name])?
  CloudAgents.PgStore.commit(u)?
  if name == "GITHUB_TOKEN" {
    match deleteGitHubOAuthRefresh(sc) {
      case Ok(_) -> ()
      case Err(e) -> println(
        "NOTE: could not drop GitHub OAuth refresh metadata after deleting GITHUB_TOKEN: " +
          CloudAgents.Repository.credentialErrorMessage(e)
      )
    }
  }
  return Ok(value = n)
}

/// Whether the user has a credential stored under exactly `name`.
pub func credentialNameExists(
  sc: in CloudAgents.Pg.UserScope, name: in String
): Result[Bool, CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.openUser(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT 1 AS one FROM credentials WHERE user_id = @p0 AND name = @p1 LIMIT 1", [sc.userId, name])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = rows.length > 0)
}

/// Encrypted (name, value) rows of the user, byte-ordered by name.
func encryptedRows(sc: in CloudAgents.Pg.UserScope): Result[slice[DbRow], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.openUser(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = CloudAgents.PgStore.q(u, "SELECT name, value_encrypted FROM credentials WHERE user_id = @p0 ORDER BY name COLLATE \"C\"", [sc.userId])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = rows)
}

/// Decrypt `rows` whose name is in `only` (every row when `all`), skipping an
/// undecryptable value with a warning.
func decryptRows(
  rows: in slice[DbRow], all: in Bool, only: in slice[String]
): slice[CloudAgents.Repository.CredentialValue] {
  var acc: slice[CloudAgents.Repository.CredentialValue] = []
  for r in rows {
    val name = CloudAgents.PgStore.col(r, "name")
    var wanted = all
    if not all {
      for g in only {
        if g == name {
          wanted = true
        }
      }
    }
    if wanted {
      match CloudAgents.Crypto.decrypt(CloudAgents.PgStore.col(r, "value_encrypted")) {
        case Ok(p) -> {
          acc = acc.append(CloudAgents.Repository.CredentialValue(name = name, value = p))
        }
        case Err(e) -> {
          println("WARNING: skipping undecryptable credential '" + name + "': " + CloudAgents.Crypto.cryptoErrorMessage(e))
        }
      }
    }
  }
  return acc
}

/// Decrypt every credential of the user for container injection. A single
/// undecryptable row is skipped with a warning; a read failure is fatal.
pub func decryptedCredentials(
  sc: in CloudAgents.Pg.UserScope
): Result[slice[CloudAgents.Repository.CredentialValue], CloudAgents.Repository.CredentialError] {
  val rows = match encryptedRows(sc) { case Ok(r) -> r; case Err(e) -> return Err(error = dbErr(e)) }
  val none: slice[String] = []
  return Ok(value = decryptRows(rows, true, none))
}

/// Decrypt one named credential for server-side use. `Ok(None)` when absent,
/// decided before any decryption; a present but undecryptable value is an
/// error, not a skip.
pub func decryptedCredentialValue(
  sc: in CloudAgents.Pg.UserScope, name: in String
): Result[Option[String], CloudAgents.Repository.CredentialError] {
  val u = match CloudAgents.PgStore.openUser(sc) { case Ok(x) -> x; case Err(e) -> return Err(error = dbErr(e)) }
  defer {
    CloudAgents.PgStore.release(u)
  }
  val rows = match CloudAgents.PgStore.q(u, "SELECT value_encrypted FROM credentials WHERE user_id = @p0 AND name = @p1", [sc.userId, name]) {
    case Ok(r) -> r
    case Err(e) -> return Err(error = dbErr(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = dbErr(e))
  }
  if rows.length == 0 {
    return Ok(value = None)
  }
  return match CloudAgents.Crypto.decrypt(CloudAgents.PgStore.col(rows[0], "value_encrypted")) {
    case Ok(p) -> Ok(value = Some(value = p))
    case Err(e) -> Err(error = cryptoErr(e))
  }
}

/// The creator's credentials a session under `profileId` receives. An empty
/// profile id means no profile (every credential); a profile that no longer
/// resolves injects nothing (fail closed, #231); in "selected" mode only the
/// granted credentials are decrypted (#267).
pub func decryptedCredentialsForProfile(
  sc: in CloudAgents.Pg.TenantScope, profileId: in String
): Result[slice[CloudAgents.Repository.CredentialValue], CloudAgents.Repository.CredentialError] {
  val user = CloudAgents.Scope.userScope(sc.userId)
  if profileId.length == 0 {
    return decryptedCredentials(user)
  }
  val profile = match CloudAgents.PgStore.Library.getProfile(profileId, sc) {
    case Ok(p) -> p
    case Err(e) -> return Err(error = dbErr(e))
  }
  match profile {
    case None -> {
      val empty: slice[CloudAgents.Repository.CredentialValue] = []
      return Ok(value = empty)
    }
    case Some(p) -> {
      if p.credentialMode != "selected" {
        return decryptedCredentials(user)
      }
      val rows = match encryptedRows(user) { case Ok(r) -> r; case Err(e) -> return Err(error = dbErr(e)) }
      return Ok(value = decryptRows(rows, false, p.credentials))
    }
  }
}

// ─── GitHub OAuth token refresh ─────────────────────────────────────────────
/// Store (or replace) the user's refresh-token metadata, encrypting the
/// refresh token. The expiry inputs are GitHub's `expires_in` /
/// `refresh_token_expires_in` seconds, verbatim.
pub func upsertGitHubOAuthRefresh(
  sc: in CloudAgents.Pg.UserScope,
  refreshToken: in String,
  accessExpiresInSeconds: in String,
  refreshExpiresInSeconds: in String,
): Result[Unit, CloudAgents.Repository.CredentialError] {
  val encrypted = match CloudAgents.Crypto.encrypt(refreshToken) {
    case Ok(blob) -> blob
    case Err(e) -> return Err(error = cryptoErr(e))
  }
  val u = match CloudAgents.PgStore.openUser(sc) { case Ok(x) -> x; case Err(e) -> return Err(error = dbErr(e)) }
  defer {
    CloudAgents.PgStore.release(u)
  }
  val now = "(timestamptz 'epoch' + @p2::bigint * interval '1 millisecond')"
  val sql = "INSERT INTO github_oauth_refresh (user_id, refresh_token, access_expires_at, refresh_expires_at, updated_at) " +
    "VALUES (@p0, @p1, " +
    now +
    " + @p3::bigint * interval '1 second', " +
    now +
    " + @p4::bigint * interval '1 second', " +
    now +
    ") ON CONFLICT (user_id) DO UPDATE SET refresh_token = EXCLUDED.refresh_token, " +
    "access_expires_at = EXCLUDED.access_expires_at, refresh_expires_at = EXCLUDED.refresh_expires_at, " +
    "updated_at = EXCLUDED.updated_at"
  val params = [
    sc.userId,
    encrypted,
    CloudAgents.Repository.nowMillis(),
    sqliteIntPrefix(accessExpiresInSeconds),
    sqliteIntPrefix(refreshExpiresInSeconds)
  ]
  match CloudAgents.PgStore.ex(u, sql, params) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = dbErr(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> return Ok(value = ())
    case Err(e) -> return Err(error = dbErr(e))
  }
}

/// The user's refresh-token status, or `Ok(None)` for a non-expiring token.
/// The access token counts as expired five minutes early, as on SQLite.
pub func githubOAuthRefreshStatus(
  sc: in CloudAgents.Pg.UserScope
): Result[Option[CloudAgents.Repository.GitHubOAuthRefreshStatus], CloudAgents.Repository.CredentialError] {
  val u = match CloudAgents.PgStore.openUser(sc) { case Ok(x) -> x; case Err(e) -> return Err(error = dbErr(e)) }
  defer {
    CloudAgents.PgStore.release(u)
  }
  val now = CloudAgents.Pg.msIn(1)
  val sql = "SELECT refresh_token, " + "CASE WHEN access_expires_at - interval '300000 milliseconds' <= " + now +
    " THEN '1' ELSE '0' END AS access_expired, " +
    "CASE WHEN refresh_expires_at <= " +
    now +
    " THEN '1' ELSE '0' END AS refresh_expired " +
    "FROM github_oauth_refresh WHERE user_id = @p0"
  val rows = match CloudAgents.PgStore.q(u, sql, [sc.userId, CloudAgents.Repository.nowMillis()]) {
    case Ok(r) -> r
    case Err(e) -> return Err(error = dbErr(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = dbErr(e))
  }
  if rows.length == 0 {
    return Ok(value = None)
  }
  val r0 = rows[0]
  return match CloudAgents.Crypto.decrypt(CloudAgents.PgStore.col(r0, "refresh_token")) {
    case Ok(token) -> Ok(
      value = Some(
        value = CloudAgents.Repository.GitHubOAuthRefreshStatus(
          refreshToken = token,
          accessTokenExpired = CloudAgents.PgStore.col(r0, "access_expired") ==
            "1",
          refreshTokenExpired = CloudAgents.PgStore.col(r0, "refresh_expired") ==
            "1"
        )
      )
    )
    case Err(e) -> Err(error = cryptoErr(e))
  }
}

/// Drop the user's refresh-token metadata.
pub func deleteGitHubOAuthRefresh(sc: in CloudAgents.Pg.UserScope): Result[Unit, CloudAgents.Repository.CredentialError] {
  val u = match CloudAgents.PgStore.openUser(sc) { case Ok(x) -> x; case Err(e) -> return Err(error = dbErr(e)) }
  defer {
    CloudAgents.PgStore.release(u)
  }
  match CloudAgents.PgStore.ex(u, "DELETE FROM github_oauth_refresh WHERE user_id = @p0", [sc.userId]) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = dbErr(e))
  }
  match CloudAgents.PgStore.commit(u) {
    case Ok(_) -> return Ok(value = ())
    case Err(e) -> return Err(error = dbErr(e))
  }
}

// ─── Provider model-listing cache ───────────────────────────────────────────
func modelListingTtlMillis(): String {
  return "3600000"
}

/// A still-fresh cached listing body for (user, provider), or None. Fresh
/// means fetched less than the TTL (one hour) ago.
pub func cachedModelListing(
  sc: in CloudAgents.Pg.UserScope, provider: in String
): Result[Option[String], CloudAgents.Sqlite.DbError] {
  val u = CloudAgents.PgStore.openUser(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val sql = "SELECT body FROM model_listing_cache WHERE user_id = @p0 AND provider = @p1 AND " + CloudAgents.Pg.msIn(2) +
    " - fetched_at < @p3::bigint * interval '1 millisecond'"
  val rows = CloudAgents.PgStore.q(u, sql, [sc.userId, provider, CloudAgents.Repository.nowMillis(), modelListingTtlMillis()])?
  CloudAgents.PgStore.commit(u)?
  if rows.length == 0 {
    return Ok(value = None)
  }
  return Ok(value = Some(value = CloudAgents.PgStore.col(rows[0], "body")))
}

/// Sweep the user's expired listings, ignoring failure: it is housekeeping,
/// and runs in its own unit because a failed statement would abort the write's.
func sweepExpiredModelListings(sc: in CloudAgents.Pg.UserScope, now: in String): Unit {
  match CloudAgents.PgStore.openUser(sc) {
    case Ok(u) -> {
      match CloudAgents.PgStore.ex(u, "DELETE FROM model_listing_cache WHERE " + CloudAgents.Pg.msIn(0) + " - fetched_at >= @p1::bigint * interval '1 millisecond'", [now, modelListingTtlMillis()]) {
        case Ok(_) -> {
          match CloudAgents.PgStore.commit(u) {
            case Ok(_) -> ()
            case Err(_) -> ()
          }
        }
        case Err(_) -> ()
      }
      CloudAgents.PgStore.release(u)
    }
    case Err(_) -> ()
  }
}

/// Cache a freshly-fetched listing body. Expired rows are swept first,
/// best-effort. Under RLS the sweep reaches only this user's rows; other
/// users' expired rows are swept on their own next write.
pub func cacheModelListing(
  sc: in CloudAgents.Pg.UserScope, provider: in String, body: in String
): Result[Unit, CloudAgents.Sqlite.DbError] {
  val now = CloudAgents.Repository.nowMillis()
  sweepExpiredModelListings(sc, now)
  val u = CloudAgents.PgStore.openUser(sc)?
  defer {
    CloudAgents.PgStore.release(u)
  }
  val sql = "INSERT INTO model_listing_cache (user_id, provider, body, fetched_at) VALUES (@p0, @p1, @p2, " +
    CloudAgents.Pg.msIn(3) +
    ") ON CONFLICT (user_id, provider) DO UPDATE SET body = EXCLUDED.body, fetched_at = EXCLUDED.fetched_at"
  CloudAgents.PgStore.ex(u, sql, [sc.userId, provider, body, now])?
  CloudAgents.PgStore.commit(u)?
  return Ok(value = ())
}
