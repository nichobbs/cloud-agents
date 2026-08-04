//! src/handlers/open_pr.l — CloudAgents.OpenPr: opt-in, user-triggered
//! "Open PR" action for a session (docs/phase10-auto-open-pr.md). Entirely
//! server-side: the vaulted GITHUB_TOKEN never reaches the browser (same
//! never-return-the-raw-token precedent as CloudAgents.Proxy / ADR-006).
//!
//! Design: rather than having the platform peek inside a (possibly already
//! terminated) container to check for unpushed git changes — a capability
//! this codebase doesn't have (no `docker exec` wrapper in
//! CloudAgents.Docker) — this asks GitHub itself whether the session's
//! branch has any commits ahead of the repo's default branch, via GitHub's
//! own compare API. That's the same "ask the remote, don't inspect the
//! local checkout" idiom CloudAgents.Proxy already uses for CI status and
//! open-PR checks.
package CloudAgents.OpenPr

import Std.Core
import Web
import CloudAgents.Auth
import CloudAgents.GitHubApi
import CloudAgents.Highlights
import CloudAgents.OAuth
import CloudAgents.Proxy
import CloudAgents.RepoKey
import CloudAgents.SessionStore
import CloudAgents.Sqlite
import CloudAgents.Streaming
import CloudAgents.Text

val openPrUserAgent = "cloud-agents"

func sessionDbError(e: in CloudAgents.Sqlite.DbError): Web.ApiError {
  return Web.internalError(CloudAgents.Sqlite.dbErrorMessage(e))
}

/// Translate a github_api.l transport error into a Web.ApiError. A confirmed
/// 401/403 means GitHub itself rejected the vaulted token (revoked, or
/// expired with no usable refresh token) — surfaced plainly so the fix is
/// obviously "reconnect GitHub" rather than a server bug, same as
/// CloudAgents.Proxy.githubGet. Everything else is logged server-side only
/// (#422's precedent) and surfaced as a generic 500.
func githubApiError(e: in String): Web.ApiError {
  if CloudAgents.OAuth.isConfirmedAuthRejection(e) {
    return Web.unauthorized(CloudAgents.OAuth.reconnectGitHubMessage())
  }
  println("WARNING: open-PR GitHub API call failed: " + e)
  return Web.internalError("GitHub request failed")
}

/// A parsed GitHub owner/repo pair.
pub record OwnerRepo {
  pub owner: String
  pub repo: String
}

/// Parse a session's `repoUrl` into a GitHub owner/repo pair, or None if it
/// isn't a github.com repo. Built on CloudAgents.RepoKey.repoKeyOf (already
/// proven and unit-tested) rather than a fresh URL parser: repoKeyOf
/// normalizes to `host/owner/repo`, lowercased; this just checks the host is
/// exactly `github.com` and splits the remainder, then re-validates both
/// segments through CloudAgents.Proxy.isValidOwnerOrRepo before they ever
/// reach a GitHub API URL.
pub func githubOwnerRepoFromUrl(url: in String): Option[OwnerRepo] {
  val key = CloudAgents.RepoKey.repoKeyOf(url)
  if key.length == 0 {
    return None
  }
  val prefix = "github.com/"
  if not key.startsWith(prefix) {
    return None
  }
  val tail = key.substring(prefix.length, key.length - prefix.length)
  val slashPos = CloudAgents.Text.indexOfFrom(tail, "/", 0)
  if slashPos <= 0 {
    return None
  }
  val tailLen = tail.length.toInt()
  val owner = tail.substring(0, slashPos)
  val repo = tail.substring(slashPos + 1, tailLen - slashPos - 1)
  if not CloudAgents.Proxy.isValidOwnerOrRepo(owner) or not CloudAgents.Proxy.isValidOwnerOrRepo(repo) {
    return None
  }
  return Some(value = OwnerRepo(owner = owner, repo = repo))
}

/// The repository's default branch (e.g. "main"), from GitHub's own repo
/// metadata — never assumed/hardcoded, since plenty of repos don't use
/// "main"/"master".
func repoDefaultBranch(ownerRepo: in OwnerRepo, token: in String): Result[String, Web.ApiError] {
  match CloudAgents.GitHubApi.httpGetWithBearer(
    "https://api.github.com/repos/" + ownerRepo.owner + "/" + ownerRepo.repo, token, openPrUserAgent
  ) {
    case Ok(body) -> {
      val branch = CloudAgents.Highlights.jsonStringValueOf(body, "default_branch")
      if branch.length == 0 {
        return Err(Web.internalError("could not determine the repository's default branch"))
      }
      return Ok(value = branch)
    }
    case Err(e) -> return Err(githubApiError(e))
  }
}

/// GitHub's compare status for base...head ("identical" | "ahead" |
/// "behind" | "diverged"), or "" if either ref doesn't exist on the remote
/// yet (a 404 from GitHub — most commonly, the session's branch was never
/// pushed). "" is a safe empty-status sentinel here since GitHub's real
/// status values are always non-empty, and decidePrAction treats anything
/// other than "ahead"/"diverged" as "nothing to open a PR for".
func compareBranchStatus(ownerRepo: in OwnerRepo, base: in String, head: in String, token: in String): Result[String, Web.ApiError] {
  val url = "https://api.github.com/repos/" + ownerRepo.owner + "/" + ownerRepo.repo + "/compare/" + base + "..." +
    head
  match CloudAgents.GitHubApi.httpGetWithBearer(url, token, openPrUserAgent) {
    case Ok(body) -> return Ok(value = CloudAgents.Highlights.jsonStringValueOf(body, "status"))
    case Err(e) -> {
      if e.contains("(404)") {
        return Ok(value = "")
      }
      return Err(githubApiError(e))
    }
  }
}

/// The html_url of an already-open PR for `head` (owner:branch), or "" if
/// none. per_page=1 since only presence/absence and one URL are needed.
func existingOpenPrUrl(ownerRepo: in OwnerRepo, head: in String, token: in String): Result[String, Web.ApiError] {
  val url = "https://api.github.com/repos/" + ownerRepo.owner + "/" + ownerRepo.repo +
    "/pulls?state=open&per_page=1&head=" + ownerRepo.owner + ":" + head
  match CloudAgents.GitHubApi.httpGetWithBearer(url, token, openPrUserAgent) {
    case Ok(body) -> return Ok(value = CloudAgents.Highlights.jsonStringValueOf(body, "html_url"))
    case Err(e) -> return Err(githubApiError(e))
  }
}

/// Create the PR and return its html_url.
func createPr(ownerRepo: in OwnerRepo, base: in String, head: in String, token: in String): Result[String, Web.ApiError] {
  val title = "Cloud Agents: " + head
  val body = "Opened automatically from a Cloud Agents session on branch `" + head + "`."
  val bodyJson = "{\"title\":\"" + CloudAgents.Streaming.jsonEscape(title) + "\",\"head\":\"" +
    CloudAgents.Streaming.jsonEscape(head) +
    "\",\"base\":\"" +
    CloudAgents.Streaming.jsonEscape(base) +
    "\",\"body\":\"" +
    CloudAgents.Streaming.jsonEscape(body) +
    "\"}"
  match CloudAgents.GitHubApi.httpPostJsonWithBearer(
    "https://api.github.com/repos/" + ownerRepo.owner + "/" + ownerRepo.repo + "/pulls", bodyJson, token, openPrUserAgent
  ) {
    case Ok(respBody) -> {
      val url = CloudAgents.Highlights.jsonStringValueOf(respBody, "html_url")
      if url.length == 0 {
        println("WARNING: PR create call succeeded but no html_url was found in the response")
        return Err(Web.internalError("GitHub did not return a PR URL"))
      }
      return Ok(value = url)
    }
    case Err(e) -> return Err(githubApiError(e))
  }
}

/// What openPrHandler should do, given the three pieces of state it must
/// gather first — the repo's default branch, the compare status of
/// default...session branch, and any already-open PR's URL ("" for none).
/// Pure and unit-tested (tests/open_pr_tests.l) so the actual decision
/// logic — the part most worth getting right — doesn't require a real
/// GitHub API round trip to exercise.
pub union PrDecision {
  case Reject(reason: String)
  case Reuse(url: String)
  case Create
}

pub func decidePrAction(defaultBranch: in String, sessionBranch: in String, compareStatus: in String, existingPrUrl: in String): PrDecision {
  if sessionBranch == defaultBranch {
    return Reject(reason = "this session's branch is the repository's default branch; nothing to open a PR against")
  }
  if not (compareStatus == "ahead" or compareStatus == "diverged") {
    return Reject(
      reason = "no commits found on '" + sessionBranch + "' ahead of '" + defaultBranch +
        "' — push your changes first"
    )
  }
  if existingPrUrl.length > 0 {
    return Reuse(url = existingPrUrl)
  }
  return Create
}

/// The result of a successful open-PR call: the PR's URL, and whether it was
/// just created (false = an already-open PR for this branch was found and
/// reused instead of opening a duplicate).
pub record OpenPrResult {
  pub url: String
  pub created: Bool
}

/// POST /api/sessions/{id}/open-pr — opt-in, user-triggered. Never fires
/// automatically on run completion (a deliberate scope decision: see
/// docs/phase10-auto-open-pr.md).
pub func openPrHandler(sessionId: in String): Result[OpenPrResult, Web.ApiError] {
  if sessionId.length == 0 {
    return Err(Web.badRequest("session id is required"))
  }
  val session = match CloudAgents.SessionStore.getSession(sessionId) {
    case Ok(Some(s)) -> s
    case Ok(None) -> return Err(Web.notFound("session not found"))
    case Err(e) -> return Err(sessionDbError(e))
  }
  val ownerRepo = match githubOwnerRepoFromUrl(session.repoUrl) {
    case Some(v) -> v
    case None -> return Err(Web.badRequest("this session's repository is not a github.com HTTPS repo"))
  }
  // session.branch is embedded directly into raw GitHub API URLs below (a
  // path segment in the compare call, a query value in the pulls lookup) —
  // isSafeBranchName at session-creation time allows characters like '#'/'&'
  // that are valid in a git branch name but would corrupt or inject into
  // those URLs, so it's re-validated here through the same charset
  // CloudAgents.Proxy's own GitHub-URL-embedding endpoints already require.
  if not CloudAgents.Proxy.isValidProxyBranch(session.branch) {
    return Err(Web.badRequest("this session's branch name is not safe to embed in a GitHub API URL"))
  }
  val token = CloudAgents.OAuth.ensureFreshGitHubToken(CloudAgents.Auth.currentUserId())?
  val defaultBranch = repoDefaultBranch(ownerRepo, token)?
  // Short-circuit before the compare/existing-PR calls in the common case of
  // a session still sitting on the repo's default branch — decidePrAction
  // below would reject this too, but there's no reason to spend two more
  // GitHub round trips to reach the same answer.
  if session.branch == defaultBranch {
    return Err(
      Web.badRequest("this session's branch is the repository's default branch; nothing to open a PR against")
    )
  }
  val compareStatus = compareBranchStatus(ownerRepo, defaultBranch, session.branch, token)?
  val existingPrUrl = existingOpenPrUrl(ownerRepo, session.branch, token)?
  match decidePrAction(defaultBranch, session.branch, compareStatus, existingPrUrl) {
    case Reject(reason) -> return Err(Web.badRequest(reason))
    case Reuse(url) -> return Ok(value = OpenPrResult(url = url, created = false))
    case Create -> {
      val url = createPr(ownerRepo, defaultBranch, session.branch, token)?
      return Ok(value = OpenPrResult(url = url, created = true))
    }
  }
}
