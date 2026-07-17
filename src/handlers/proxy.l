//! Server-side provider proxies (ADR-006's end state): GitHub listings and
//! model discovery performed with credential-vault keys, so the browser needs
//! no locally-held provider keys for these UI features.
//!
//! Every handler scopes its vault lookups by CloudAgents.Auth.currentUserId()
//! (stamped by the middleware) and returns a complete JSON body as a String —
//! a pure passthrough of the provider's own response (the frontend already
//! parses GitHub's/each provider's raw shapes), mapped to a Response by
//! main.l's jsonStringResp. Missing vault keys are a 404, which the frontend
//! treats as "fall back to direct browser calls"; upstream failures are
//! logged server-side and surface as a generic 500 (never raw transport text
//! — the #422 precedent in oauth.l).
//!
//! Network calls go through CloudAgents.GitHubApi.httpGetWithHeaders, whose
//! UTF-8 reader is safe for passthrough bodies (repo descriptions, model
//! display names) — NOT httpGetWithBearer, whose byte-per-char reader mangles
//! non-ASCII by design.
package CloudAgents.Proxy

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.GitHubApi
import CloudAgents.Repository
import CloudAgents.SessionStore

/// User-Agent for proxied calls — api.github.com rejects requests without one.
val proxyUserAgent = "cloud-agents"

val maxOwnerRepoLen = 100
val maxProxyBranchLen = 255

// ─── Pure validators (unit-tested in tests/proxy_tests.l) ────────────────────

func isAsciiLetter(c: in String): Bool {
  return (c >= "A" and c <= "Z") or (c >= "a" and c <= "z")
}

func isAsciiDigit(c: in String): Bool {
  return c >= "0" and c <= "9"
}

// Same digit-mapping shape as main.l's / repository.l's digitValue.
func digitValue(c: in String): Int {
  if c == "0" {
    return 0
  }
  if c == "1" {
    return 1
  }
  if c == "2" {
    return 2
  }
  if c == "3" {
    return 3
  }
  if c == "4" {
    return 4
  }
  if c == "5" {
    return 5
  }
  if c == "6" {
    return 6
  }
  if c == "7" {
    return 7
  }
  if c == "8" {
    return 8
  }
  if c == "9" {
    return 9
  }
  return -1
}

/// A proxy page number: digits only, 1..10 (the direct browser path also
/// stops at 5 pages of 100; 10 leaves headroom without letting a caller
/// drive unbounded outbound requests).
pub func isValidProxyPage(page: in String): Bool {
  if page.length == 0 or page.length > 2 {
    return false
  }
  var n = 0
  var i = 0
  while i < page.length {
    val d = digitValue(page.substring(i, 1))
    if d < 0 {
      return false
    }
    n = n * 10 + d
    i = i + 1
  }
  return n >= 1 and n <= 10
}

/// A GitHub owner or repository name as this proxy will place it in a URL
/// path: 1..100 chars of [A-Za-z0-9_.-], no leading '-' or '.'. (GitHub's own
/// rules are stricter still; anything this rejects could not name a real
/// repo, and the charset keeps the assembled URL unambiguous.)
pub func isValidOwnerOrRepo(s: in String): Bool {
  if s.length == 0 or s.length > maxOwnerRepoLen {
    return false
  }
  if s.startsWith("-") or s.startsWith(".") {
    return false
  }
  var i = 0
  while i < s.length {
    val c = s.substring(i, 1)
    if not (isAsciiLetter(c) or isAsciiDigit(c) or c == "_" or c == "." or c == "-") {
      return false
    }
    i = i + 1
  }
  return true
}

/// A branch name as this proxy will place it in a GitHub URL (query value or
/// path segment): the owner/repo charset plus '/', no leading '-' or '.', and
/// no "..". Charset-only, so '#', '?', '%', spaces, quotes and backslashes
/// are all rejected — mirroring the spirit of sessions.l's isSafeBranchName
/// but strict enough for URL assembly without encoding.
pub func isValidProxyBranch(branch: in String): Bool {
  if branch.length == 0 or branch.length > maxProxyBranchLen {
    return false
  }
  if branch.startsWith("-") or branch.startsWith(".") {
    return false
  }
  if branch.contains("..") {
    return false
  }
  var i = 0
  while i < branch.length {
    val c = branch.substring(i, 1)
    if not (isAsciiLetter(c) or isAsciiDigit(c) or c == "_" or c == "." or c == "/" or c == "-") {
      return false
    }
    i = i + 1
  }
  return true
}

/// The harnesses the models proxy knows provider mappings for.
pub func isKnownProxyHarness(harness: in String): Bool {
  return harness == "claude" or harness == "codex" or harness == "opencode" or harness == "gemini"
}

// ─── Vault lookups ────────────────────────────────────────────────────────────

/// The caller's GITHUB_TOKEN from the vault, or the 404 the frontend treats
/// as "use the direct path". A vault/crypto failure is a 500 with the detail
/// logged server-side only (#422).
func vaultGitHubToken(): Result[String, Web.ApiError] {
  match CloudAgents.Repository.decryptedCredentialValue(CloudAgents.Auth.currentUserId(), "GITHUB_TOKEN") {
    case Ok(Some(t)) -> return Ok(value = t)
    case Ok(None) -> return Err(Web.notFound("no GITHUB_TOKEN in the credential vault"))
    case Err(e) -> {
      println("WARNING: reading GITHUB_TOKEN from the credential vault failed: " + CloudAgents.Repository.credentialErrorMessage(e))
      return Err(Web.internalError("could not read the credential vault"))
    }
  }
}

/// A named vault credential for the models proxy, where absence (and any
/// read/decrypt failure, logged) just means "skip this provider".
func vaultKeyOrNone(name: in String): Option[String] {
  match CloudAgents.Repository.decryptedCredentialValue(CloudAgents.Auth.currentUserId(), name) {
    case Ok(Some(v)) -> return Some(value = v)
    case Ok(None) -> return None
    case Err(e) -> {
      println("WARNING: reading " + name + " from the credential vault failed: " + CloudAgents.Repository.credentialErrorMessage(e))
      return None
    }
  }
}

// ─── GitHub proxy endpoints ───────────────────────────────────────────────────

/// GET `url` from GitHub with the vault bearer, passing the body through.
/// Upstream detail is logged, never surfaced (#422).
func githubGet(url: in String, token: in String): Result[String, Web.ApiError] {
  val names: slice[String] = ["Authorization"]
  val values: slice[String] = ["Bearer " + token]
  match CloudAgents.GitHubApi.httpGetWithHeaders(url, names, values, proxyUserAgent) {
    case Ok(body) -> return Ok(value = body)
    case Err(e) -> {
      println("WARNING: GitHub proxy request failed: " + e)
      return Err(Web.internalError("GitHub request failed"))
    }
  }
}

/// GET /api/github/repos/{page}: one page (100 repos, most recently pushed
/// first) of the vault token's accessible repositories — GitHub's raw JSON.
pub func githubReposHandler(page: in String): Result[String, Web.ApiError] {
  if not isValidProxyPage(page) {
    return Err(Web.badRequest("page must be a whole number from 1 to 10"))
  }
  val token = vaultGitHubToken()?
  return githubGet(
    "https://api.github.com/user/repos?per_page=100&sort=pushed&direction=desc&page=" + page,
    token
  )
}

/// GET /api/github/repos/{owner}/{repo}: a single repository, raw JSON.
pub func githubRepoHandler(owner: in String, repo: in String): Result[String, Web.ApiError] {
  if not isValidOwnerOrRepo(owner) or not isValidOwnerOrRepo(repo) {
    return Err(Web.badRequest("owner and repo must be valid GitHub names"))
  }
  val token = vaultGitHubToken()?
  return githubGet("https://api.github.com/repos/" + owner + "/" + repo, token)
}

/// GET /api/github/pulls/{owner}/{repo}/{branch}: open PRs whose head is
/// owner:branch, raw JSON. The validated branch charset contains no '&', '=',
/// '#' or '%', so it embeds in the query string without encoding.
pub func githubPullsHandler(owner: in String, repo: in String, branch: in String): Result[String, Web.ApiError] {
  if not isValidOwnerOrRepo(owner) or not isValidOwnerOrRepo(repo) {
    return Err(Web.badRequest("owner and repo must be valid GitHub names"))
  }
  if not isValidProxyBranch(branch) {
    return Err(Web.badRequest("branch is not a valid git branch name"))
  }
  val token = vaultGitHubToken()?
  return githubGet(
    "https://api.github.com/repos/" + owner + "/" + repo +
      "/pulls?state=open&per_page=20&head=" + owner + ":" + branch,
    token
  )
}

/// GET /api/github/checks/{owner}/{repo}/{branch}: check runs for the tip of
/// a branch, raw JSON. GitHub accepts a branch name as the ref, so this is
/// one upstream call — no separate sha lookup. Here the branch lands in the
/// URL *path*; isValidProxyBranch's charset already rejects '#', '?', '%',
/// spaces and backslashes, so it embeds without encoding.
pub func githubChecksHandler(owner: in String, repo: in String, branch: in String): Result[String, Web.ApiError] {
  if not isValidOwnerOrRepo(owner) or not isValidOwnerOrRepo(repo) {
    return Err(Web.badRequest("owner and repo must be valid GitHub names"))
  }
  if not isValidProxyBranch(branch) {
    return Err(Web.badRequest("branch is not a valid git branch name"))
  }
  val token = vaultGitHubToken()?
  return githubGet(
    "https://api.github.com/repos/" + owner + "/" + repo + "/commits/" + branch + "/check-runs?per_page=50",
    token
  )
}

// ─── Model-discovery proxy ────────────────────────────────────────────────────

/// The providers whose model listings apply to a harness — must stay in sync
/// with the frontend's lib/harnesses.ts provider mapping.
func providersForHarness(harness: in String): slice[String] {
  if harness == "claude" {
    return ["anthropic"]
  }
  if harness == "codex" {
    return ["openai"]
  }
  if harness == "gemini" {
    return ["google"]
  }
  return ["anthropic", "openai", "google"]
}

/// The vault key for a provider (GOOGLE_API_KEY is accepted as a fallback
/// alias for google's canonical GEMINI_API_KEY).
func keyForProvider(provider: in String): Option[String] {
  if provider == "anthropic" {
    return vaultKeyOrNone("ANTHROPIC_API_KEY")
  }
  if provider == "openai" {
    return vaultKeyOrNone("OPENAI_API_KEY")
  }
  if provider == "google" {
    match vaultKeyOrNone("GEMINI_API_KEY") {
      case Some(v) -> return Some(value = v)
      case None -> return vaultKeyOrNone("GOOGLE_API_KEY")
    }
  }
  return None
}

/// A provider's listing body for a user: the still-fresh server-cached copy if
/// present, otherwise a live upstream fetch which is then cached (#446). Cache
/// read/write failures are non-fatal (logged) and simply fall back to a live
/// fetch, so a broken cache never breaks discovery.
func cachedOrFetchedModelsBody(userId: in String, provider: in String, key: in String): Result[String, String] {
  match CloudAgents.Repository.cachedModelListing(userId, provider) {
    case Ok(Some(body)) -> return Ok(value = body)
    case Ok(None) -> ()
    case Err(_) -> println("WARNING: model-listing cache read failed for " + provider)
  }
  match providerModelsBody(provider, key) {
    case Ok(body) -> {
      match CloudAgents.Repository.cacheModelListing(userId, provider, body) {
        case Ok(_) -> ()
        case Err(_) -> println("WARNING: model-listing cache write failed for " + provider)
      }
      return Ok(value = body)
    }
    case Err(e) -> return Err(error = e)
  }
}

/// One provider's models listing, raw. Keys travel in headers, never URLs
/// (URLs end up in proxy logs).
func providerModelsBody(provider: in String, key: in String): Result[String, String] {
  if provider == "anthropic" {
    val names: slice[String] = ["x-api-key", "anthropic-version"]
    val values: slice[String] = [key, "2023-06-01"]
    return CloudAgents.GitHubApi.httpGetWithHeaders(
      "https://api.anthropic.com/v1/models?limit=100", names, values, proxyUserAgent
    )
  }
  if provider == "openai" {
    val names: slice[String] = ["Authorization"]
    val values: slice[String] = ["Bearer " + key]
    return CloudAgents.GitHubApi.httpGetWithHeaders(
      "https://api.openai.com/v1/models", names, values, proxyUserAgent
    )
  }
  val names: slice[String] = ["x-goog-api-key"]
  val values: slice[String] = [key]
  return CloudAgents.GitHubApi.httpGetWithHeaders(
    "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200", names, values, proxyUserAgent
  )
}

/// GET /api/models/{harness}: call each mapped provider's models API with its
/// vault key and return {"providers":[{"provider":"...","body":"<raw JSON,
/// escaped>"}...]}. The frontend JSON-parses each body with its existing
/// filter functions, so this stays parsing-free. Providers without a vault
/// key — or whose upstream call fails (logged) — are skipped, not fatal; only
/// zero usable providers is the 404 the frontend falls back on.
pub func modelsHandler(harness: in String): Result[String, Web.ApiError] {
  if not isKnownProxyHarness(harness) {
    return Err(Web.badRequest("harness must be one of: claude, codex, opencode, gemini"))
  }
  // Providers are queried SEQUENTIALLY by design (#446): making this
  // concurrent would require async funcs, and an async func anywhere in this
  // package makes the whole package uninvokable from @test_module suites
  // (docs/lyric/gotchas.md) — the validators and no-credential paths below
  // are only testable because the package stays sync. A per-(user,provider)
  // server-side cache (cachedOrFetchedModelsBody, 1h TTL) now amortises the
  // fetch cost to at most once per window, so the sequential worst case (3
  // providers x the 15s HTTP timeout on a dark network) is only paid on a cold
  // cache; the frontend also caches for an hour, so the latency trade is taken
  // knowingly.
  val userId = CloudAgents.Auth.currentUserId()
  var entries = ""
  var count = 0
  for p in providersForHarness(harness) {
    match keyForProvider(p) {
      case None -> ()
      case Some(key) -> {
        match cachedOrFetchedModelsBody(userId, p, key) {
          case Ok(body) -> {
            if count > 0 {
              entries = entries + ","
            }
            entries = entries + "{\"provider\":\"" + p + "\",\"body\":\"" +
              CloudAgents.SessionStore.jsonEscapeField(body) +
              "\"}"
            count = count + 1
          }
          case Err(e) -> {
            println("WARNING: " + p + " models request failed: " + e)
          }
        }
      }
    }
  }
  if count == 0 {
    return Err(Web.notFound("no provider API keys in the credential vault"))
  }
  return Ok(value = "{\"providers\":[" + entries + "]}")
}
