//! CloudAgents.Ledger.RepoPolicy — fetch a repository's `.agent-ledger.json`
//! severity policy (docs/session-ledger.md §5).
//!
//! Read from the repository's DEFAULT branch through the GitHub contents API
//! with the session owner's vaulted GitHub token — never from the session's
//! own workspace or working branch, which the agent can edit: the policy is
//! a repository owner's statement of what needs review, so the copy the
//! agent cannot rewrite is the one that counts. (Policy is raise-only, so
//! the only thing an agent-edited copy could do is drop the repo's extra
//! floors; reading the default branch closes that.)
package CloudAgents.Ledger.RepoPolicy

import Std.Core
import Std.Json
import Web
import CloudAgents.GitHubApi
import CloudAgents.OAuth
import CloudAgents.Ledger.Model
import CloudAgents.Ledger.Policy

extern type Encoding = "System.Text.Encoding"

@externTarget("System.Text.Encoding.get_UTF8")
func utf8Encoding(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func bytesToUtf8(enc: in Encoding, bytes: in slice[Byte]): String = ()

@externTarget("System.Convert.FromBase64String")
func fromBase64(s: in String): slice[Byte] = []

val policyUserAgent = "cloud-agents-ledger"

/// The outcome of one fetch. `status` is:
///   loaded       the file exists and parsed; `json` holds it
///   absent       the repository has no .agent-ledger.json (defaults apply)
///   invalid      the file exists but does not parse; `error` says why
///   unavailable  it could not be read (no GitHub token, network, auth);
///                `error` says why (defaults apply)
pub record PolicyFetch {
  pub status: String
  pub json: String
  pub error: String
}

func fetchResult(status: in String, json: in String, error: in String): PolicyFetch {
  return PolicyFetch(status = status, json = json, error = error)
}

/// Fetch and validate `ownerRepo`'s policy file as `ownerUserId`.
pub func fetchRepoPolicy(ownerUserId: in String, ownerRepo: in String): PolicyFetch {
  if ownerRepo.length.toInt() == 0 {
    return fetchResult("absent", "", "")
  }
  val token = match CloudAgents.OAuth.ensureFreshGitHubToken(ownerUserId) {
    case Ok(t) -> t
    case Err(_) -> return fetchResult("unavailable", "", "no usable GitHub token for the session owner")
  }
  val url = "https://api.github.com/repos/" + ownerRepo + "/contents/.agent-ledger.json"
  val names: slice[String] = ["Authorization"]
  val values: slice[String] = ["Bearer " + token]
  val body = match CloudAgents.GitHubApi.httpGetWithHeaders(url, names, values, policyUserAgent) {
    case Ok(b) -> b
    case Err(e) -> {
      if e.contains("(404)") {
        // GitHub answers 404 both for a missing file and for a repository
        // the token cannot see. Only a readable repository makes the file
        // genuinely absent; otherwise it's a scope problem, retried on the
        // next entry rather than cached as "no policy".
        if repoReadable(ownerRepo, names, values) {
          return fetchResult("absent", "", "")
        }
        println(
          "WARNING: .agent-ledger.json for " + ownerRepo +
            " is unreadable: the session owner's token cannot see the repository"
        )
        return fetchResult("unavailable", "", "the session owner's GitHub token cannot read this repository")
      }
      println("WARNING: fetching .agent-ledger.json for " + ownerRepo + " failed: " + e)
      if CloudAgents.OAuth.isConfirmedAuthRejection(e) {
        return fetchResult("unavailable", "", "GitHub rejected the session owner's token")
      }
      return fetchResult("unavailable", "", "GitHub request failed")
    }
  }
  val content = match decodeContentsBody(body) {
    case Ok(c) -> c
    case Err(msg) -> return fetchResult("invalid", "", msg)
  }
  match parseRepoPolicy(content) {
    case Ok(_) -> return fetchResult("loaded", content, "")
    case Err(msg) -> return fetchResult("invalid", "", msg)
  }
}

func repoReadable(ownerRepo: in String, names: in slice[String], values: in slice[String]): Bool {
  val url = "https://api.github.com/repos/" + ownerRepo
  match CloudAgents.GitHubApi.httpGetWithHeaders(url, names, values, policyUserAgent) {
    case Ok(_) -> return true
    case Err(_) -> return false
  }
}

/// The file text out of a GitHub contents-API response
/// (`{"encoding":"base64","content":"<base64 with newlines>"}`), capped at
/// 64 KiB.
pub func decodeContentsBody(body: in String): Result[String, String] {
  val doc = match Std.Json.tryParseJson(body) {
    case Ok(d) -> d
    case Err(_) -> return Err(error = "unexpected GitHub response")
  }
  defer {
    Std.Json.disposeJson(doc)
  }
  return try {
    val root = Std.Json.rootElement(doc)
    if Std.Json.valueKind(root) != 1 {
      Err(error = ".agent-ledger.json is not a file")
    } else {
      val encoding = match Std.Json.tryGetProperty(root, "encoding") {
        case Some(e) -> if Std.Json.valueKind(e) == 3 { Std.Json.getString(e) } else { "" }
        case None -> ""
      }
      val raw = match Std.Json.tryGetProperty(root, "content") {
        case Some(c) -> if Std.Json.valueKind(c) == 3 { Std.Json.getString(c) } else { "" }
        case None -> ""
      }
      if encoding != "base64" {
        Err(error = ".agent-ledger.json could not be read (encoding '" + encoding + "')")
      } else {
        if raw.length.toInt() > 92000 {
          Err(error = ".agent-ledger.json is too large (max 64 KiB)")
        } else {
          Ok(value = bytesToUtf8(utf8Encoding(), fromBase64(stripWhitespace(raw))))
        }
      }
    }
  } catch Bug as b {
    Err(error = ".agent-ledger.json could not be decoded")
  }
}

// GitHub wraps the base64 at 60 columns with "\n"; join the lines back.
func stripWhitespace(s: in String): String {
  val lines = CloudAgents.Ledger.Model.splitOn(s, "\n")
  var acc = ""
  var i = 0
  while i < lines.length.toInt() {
    acc = acc + lines[i].trim()
    i = i + 1
  }
  return acc
}
