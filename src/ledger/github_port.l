//! CloudAgents.Ledger.GitHubPort — the GitHub operations ledger sync needs
//! (docs/session-ledger.md §9, Phase 3), as an interface so the sync logic
//! is tested against an in-memory fake, and its REST implementation over the
//! session owner's vaulted GitHub token.
//!
//! Errors are the platform's message text, which names the HTTP status as
//! "(404)" etc; the few statuses that mean "already so" (a label that
//! exists, a label already removed) are treated as success here.
package CloudAgents.Ledger.GitHubPort

import Std.Core
import Std.Json
import CloudAgents.Streaming
import CloudAgents.GitHubApi
import CloudAgents.Ledger.GitHubSync

pub interface GitHubPort {
  /// The issue's state ("open" / "closed") and label names.
  func getIssue(ownerRepo: in String, number: in String): Result[IssueFacts, String]

  /// Whether the pull request has been merged.
  func pullMerged(ownerRepo: in String, number: in String): Result[Bool, String]

  /// Create the managed label in the repository if it doesn't exist yet.
  func ensureLabel(ownerRepo: in String, label: in String): Result[Unit, String]

  func addLabel(ownerRepo: in String, number: in String, label: in String): Result[Unit, String]

  func removeLabel(ownerRepo: in String, number: in String, label: in String): Result[Unit, String]

  /// The id of the issue comment containing `marker`, or "" when none does.
  func findComment(ownerRepo: in String, number: in String, marker: in String): Result[String, String]

  /// Post a comment; returns its id.
  func createComment(ownerRepo: in String, number: in String, body: in String): Result[String, String]

  /// Edit a comment in place. An error containing "(404)" means it is gone.
  func updateComment(ownerRepo: in String, commentId: in String, body: in String): Result[Unit, String]
}

val userAgent = "cloud-agents-ledger-sync"

val timeoutMillis = 15000

val api = "https://api.github.com/repos/"

/// GitHub REST over the session owner's token.
pub record HttpGitHubPort {
  pub token: String
}

impl GitHubPort for HttpGitHubPort {
  func getIssue(ownerRepo: in String, number: in String): Result[IssueFacts, String] {
    val body = call(self.token, "GET", api + ownerRepo + "/issues/" + number, "")?
    return parseIssue(body)
  }

  func pullMerged(ownerRepo: in String, number: in String): Result[Bool, String] {
    val body = call(self.token, "GET", api + ownerRepo + "/pulls/" + number, "")?
    return parsePullMerged(body)
  }

  func ensureLabel(ownerRepo: in String, label: in String): Result[Unit, String] {
    val payload = "{\"name\":\"" + jsonEscape(label) + "\",\"color\":\"" + labelColor(label) + "\",\"description\":\"" +
      jsonEscape(labelDescription(label)) +
      "\"}"
    match call(self.token, "POST", api + ownerRepo + "/labels", payload) {
      case Ok(_) -> return Ok(())
      // 422: the label already exists, which is what we want.
      case Err(e) -> if e.contains("(422)") { return Ok(()) } else { return Err(error = e) }
    }
  }

  func addLabel(ownerRepo: in String, number: in String, label: in String): Result[Unit, String] {
    val _ = call(self.token, "POST", api + ownerRepo + "/issues/" + number + "/labels", "{\"labels\":[\"" + jsonEscape(label) + "\"]}")?
    return Ok(())
  }

  func removeLabel(ownerRepo: in String, number: in String, label: in String): Result[Unit, String] {
    match call(self.token, "DELETE", api + ownerRepo + "/issues/" + number + "/labels/" + urlEncodeLabel(label), "") {
      case Ok(_) -> return Ok(())
      // 404: the label is already off the issue.
      case Err(e) -> if e.contains("(404)") { return Ok(()) } else { return Err(error = e) }
    }
  }

  func findComment(ownerRepo: in String, number: in String, marker: in String): Result[String, String] {
    // The ledger's comment is posted by the owner and edited in place, so a
    // few pages of 100 cover any real issue.
    var page = 1
    while page <= 5 {
      val url = api + ownerRepo + "/issues/" + number + "/comments?per_page=100&page=" + toString(page)
      val body = call(self.token, "GET", url, "")?
      val found = commentWithMarker(body, marker)
      if found.id.length.toInt() > 0 {
        return Ok(value = found.id)
      }
      if found.count < 100 {
        return Ok(value = "")
      }
      page = page + 1
    }
    return Ok(value = "")
  }

  func createComment(ownerRepo: in String, number: in String, body: in String): Result[String, String] {
    val resp = call(self.token, "POST", api + ownerRepo + "/issues/" + number + "/comments", "{\"body\":\"" + jsonEscape(body) + "\"}")?
    return idOf(resp)
  }

  func updateComment(ownerRepo: in String, commentId: in String, body: in String): Result[Unit, String] {
    val _ = call(self.token, "PATCH", api + ownerRepo + "/issues/comments/" + commentId, "{\"body\":\"" + jsonEscape(body) + "\"}")?
    return Ok(())
  }
}

func call(token: in String, method: in String, url: in String, body: in String): Result[String, String] {
  return CloudAgents.GitHubApi.httpJsonWithBearer(method, url, body, token, userAgent, timeoutMillis)
}

// "agent:blocked" -> "agent%3Ablocked" (the managed labels are a-z, '-' and ':').
func urlEncodeLabel(label: in String): String {
  var acc = ""
  var i = 0
  while i < label.length.toInt() {
    val c = label.substring(i, 1)
    if c == ":" {
      acc = acc + "%3A"
    } else if c == " " {
      acc = acc + "%20"
    } else {
      acc = acc + c
    }
    i = i + 1
  }
  return acc
}

// ── Response parsing (pure; tested on recorded GitHub bodies) ─────────────────
val kindObject = 1

val kindArray = 2

val kindString = 3

val kindTrue = 5

/// An issue body's state and label names.
pub func parseIssue(body: in String): Result[IssueFacts, String] {
  val doc = match Std.Json.tryParseJson(body) {
    case Ok(d) -> d
    case Err(_) -> return Err(error = "unexpected GitHub issue response")
  }
  defer {
    Std.Json.disposeJson(doc)
  }
  return try {
    val root = Std.Json.rootElement(doc)
    if Std.Json.valueKind(root) != kindObject {
      Err(error = "unexpected GitHub issue response")
    } else {
      val state = match Std.Json.tryGetProperty(root, "state") {
        case Some(s) -> if Std.Json.valueKind(s) == kindString { Std.Json.getString(s) } else { "" }
        case _ -> ""
      }
      Ok(value = IssueFacts(state = state, labels = labelNames(root)))
    }
  } catch Bug as b {
    Err(error = "unreadable GitHub issue response")
  }
}

func labelNames(root: in JsonElement): slice[String] {
  var acc: slice[String] = []
  match Std.Json.tryGetProperty(root, "labels") {
    case Some(arr) -> {
      if Std.Json.valueKind(arr) == kindArray {
        var cur = Std.Json.enumerateArray(arr)
        while Std.Json.arrayMoveNext(cur) {
          val el = Std.Json.arrayCurrent(cur)
          if Std.Json.valueKind(el) == kindObject {
            match Std.Json.tryGetProperty(el, "name") {
              case Some(n) -> if Std.Json.valueKind(n) == kindString { acc = acc.append(Std.Json.getString(n)) }
              case _ -> ()
            }
          }
        }
      }
    }
    case _ -> ()
  }
  return acc
}

/// A pull request body's `merged` flag.
pub func parsePullMerged(body: in String): Result[Bool, String] {
  val doc = match Std.Json.tryParseJson(body) {
    case Ok(d) -> d
    case Err(_) -> return Err(error = "unexpected GitHub pull request response")
  }
  defer {
    Std.Json.disposeJson(doc)
  }
  return try {
    val root = Std.Json.rootElement(doc)
    match Std.Json.tryGetProperty(root, "merged") {
      case Some(m) -> Ok(value = Std.Json.valueKind(m) == kindTrue)
      case _ -> Ok(value = false)
    }
  } catch Bug as b {
    Err(error = "unreadable GitHub pull request response")
  }
}

/// A created comment's (or any object's) numeric `id`, as text.
pub func idOf(body: in String): Result[String, String] {
  val doc = match Std.Json.tryParseJson(body) {
    case Ok(d) -> d
    case Err(_) -> return Err(error = "unexpected GitHub response")
  }
  defer {
    Std.Json.disposeJson(doc)
  }
  return try {
    match Std.Json.tryGetProperty(Std.Json.rootElement(doc), "id") {
      case Some(i) -> Ok(value = Std.Json.getRawText(i))
      case _ -> Err(error = "GitHub response has no id")
    }
  } catch Bug as b {
    Err(error = "unreadable GitHub response")
  }
}

/// A page of issue comments: the id of the first whose body contains
/// `marker` ("" if none) and how many comments the page held.
pub record CommentSearch {
  pub id: String
  pub count: Int
}

pub func commentWithMarker(body: in String, marker: in String): CommentSearch {
  val doc = match Std.Json.tryParseJson(body) {
    case Ok(d) -> d
    case Err(_) -> return CommentSearch(id = "", count = 0)
  }
  defer {
    Std.Json.disposeJson(doc)
  }
  return try {
    val root = Std.Json.rootElement(doc)
    var found = ""
    var n = 0
    if Std.Json.valueKind(root) == kindArray {
      var cur = Std.Json.enumerateArray(root)
      while Std.Json.arrayMoveNext(cur) {
        val el = Std.Json.arrayCurrent(cur)
        n = n + 1
        if found.length.toInt() == 0 {
          val text = match Std.Json.tryGetProperty(el, "body") {
            case Some(b) -> if Std.Json.valueKind(b) == kindString { Std.Json.getString(b) } else { "" }
            case _ -> ""
          }
          if text.contains(marker) {
            found = match Std.Json.tryGetProperty(el, "id") { case Some(i) -> Std.Json.getRawText(i); case _ -> "" }
          }
        }
      }
    }
    CommentSearch(id = found, count = n)
  } catch Bug as b {
    CommentSearch(id = "", count = 0)
  }
}
