//! CloudAgents.Ledger.ToolArgs — decode the agent's raw ledger_* tool
//! arguments into the service's request records (docs/session-ledger.md §6).
//!
//! The in-container shim forwards each tool call's MCP `arguments` object
//! verbatim, so the argument contract lives in exactly one place (here) and
//! the shim carries no per-tool field logic. Decoding is deliberately
//! tolerant of how LLM tool-callers actually fill a JSON schema: absent
//! optional fields default to ""/[], a boolean may arrive as true or "true",
//! a string list may arrive as a single string, and a batch item may be a
//! bare ref string instead of {id, title, url}. It is strict about shape
//! errors that would silently lose meaning (a non-object body, an object
//! where a string was expected), naming the field so the agent can fix the
//! call.
package CloudAgents.Ledger.ToolArgs

import Std.Core
import Std.Json
import CloudAgents.Ledger.Service
import CloudAgents.Ledger.Reconcile

val kindObject = 1

val kindArray = 2

val kindString = 3

val kindNumber = 4

val kindTrue = 5

val kindFalse = 6

val kindNull = 7

func propOf(root: in JsonElement, key: in String): Option[JsonElement] {
  return Std.Json.tryGetProperty(root, key)
}

func kindOf(el: in JsonElement): Int {
  return Std.Json.valueKind(el)
}

func safeGetString(el: in JsonElement): String {
  return try {
    Std.Json.getString(el)
  } catch Bug as b {
    ""
  }
}

/// A string field: absent / null -> "", a string -> itself, a number or bool
/// -> its JSON text; anything else is an error.
func str(root: in JsonElement, key: in String): Result[String, String] {
  match propOf(root, key) {
    case None -> return Ok(value = "")
    case Some(el) -> {
      val k = kindOf(el)
      if k == kindNull {
        return Ok(value = "")
      }
      if k == kindString {
        return Ok(value = safeGetString(el))
      }
      if k == kindNumber {
        return Ok(value = Std.Json.getRawText(el))
      }
      if k == kindTrue {
        return Ok(value = "true")
      }
      if k == kindFalse {
        return Ok(value = "false")
      }
      return Err(error = "'" + key + "' must be a string")
    }
  }
}

/// A boolean field as "true" / "false" / "" (absent); accepts JSON booleans
/// and the strings "true" / "false".
func boolText(root: in JsonElement, key: in String): Result[String, String] {
  match propOf(root, key) {
    case None -> return Ok(value = "")
    case Some(el) -> {
      val k = kindOf(el)
      if k == kindTrue {
        return Ok(value = "true")
      }
      if k == kindFalse {
        return Ok(value = "false")
      }
      if k == kindNull {
        return Ok(value = "")
      }
      if k == kindString {
        val s = safeGetString(el).trim()
        if s == "true" or s == "True" or s == "TRUE" {
          return Ok(value = "true")
        }
        if s == "false" or s == "False" or s == "FALSE" or s == "" {
          if s == "" {
            return Ok(value = "")
          }
          return Ok(value = "false")
        }
      }
      return Err(error = "'" + key + "' must be true or false")
    }
  }
}

/// A string-list field: absent / null -> [], an array of strings, or a
/// single string -> [it].
func strList(root: in JsonElement, key: in String): Result[slice[String], String] {
  var acc: slice[String] = []
  match propOf(root, key) {
    case None -> return Ok(value = acc)
    case Some(el) -> {
      val k = kindOf(el)
      if k == kindNull {
        return Ok(value = acc)
      }
      if k == kindString {
        val s = safeGetString(el)
        if s.trim().length.toInt() > 0 {
          acc = acc.append(s)
        }
        return Ok(value = acc)
      }
      if k != kindArray {
        return Err(error = "'" + key + "' must be an array of strings")
      }
      var cur = Std.Json.enumerateArray(el)
      var n = 0
      while Std.Json.arrayMoveNext(cur) {
        val item = Std.Json.arrayCurrent(cur)
        if kindOf(item) != kindString {
          return Err(error = "'" + key + "' must be an array of strings")
        }
        n = n + 1
        if n > 200 {
          return Err(error = "'" + key + "' has too many entries")
        }
        acc = acc.append(safeGetString(item))
      }
      return Ok(value = acc)
    }
  }
}

/// Parse `json` (the forwarded MCP arguments; "" or "null" = no arguments)
/// and hand the root object to `f`'s caller. Errors if it is not an object.
func withRoot(json: in String): Result[JsonDoc, String] {
  var body = json.trim()
  if body.length.toInt() == 0 or body == "null" {
    body = "{}"
  }
  val doc = match Std.Json.tryParseJson(body) {
    case Ok(d) -> d
    case Err(_) -> return Err(error = "arguments are not valid JSON")
  }
  if kindOf(Std.Json.rootElement(doc)) != kindObject {
    Std.Json.disposeJson(doc)
    return Err(error = "arguments must be a JSON object")
  }
  return Ok(value = doc)
}

pub func decodeRegisterItems(json: in String): Result[RegisterItemsRequest, String] {
  val doc = withRoot(json)?
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  val itemsEl = match propOf(root, "items") {
    case Some(el) -> el
    case None -> return Err(error = "'items' is required: an array of {id, title?, url?} (id like #12, owner/repo#12 or local:slug)")
  }
  if kindOf(itemsEl) != kindArray {
    return Err(error = "'items' must be an array")
  }
  var ids: slice[String] = []
  var titles: slice[String] = []
  var urls: slice[String] = []
  var cur = Std.Json.enumerateArray(itemsEl)
  var n = 0
  while Std.Json.arrayMoveNext(cur) {
    val el = Std.Json.arrayCurrent(cur)
    n = n + 1
    if n > 200 {
      return Err(error = "too many items in one call (max 200)")
    }
    val k = kindOf(el)
    if k == kindString {
      ids = ids.append(safeGetString(el))
      titles = titles.append("")
      urls = urls.append("")
    } else if k == kindObject {
      val id = str(el, "id")?
      val title = str(el, "title")?
      val url = str(el, "url")?
      ids = ids.append(id)
      titles = titles.append(title)
      urls = urls.append(url)
    } else {
      return Err(error = "each entry of 'items' must be an object {id, title?, url?} or an id string")
    }
  }
  return Ok(value = RegisterItemsRequest(items = zipItems(ids, titles, urls)))
}

// Built outside the enumeration loop from parallel string slices
// (docs/lyric/gotchas.md: record appends in a hot loop can miscompile).
func zipItems(ids: in slice[String], titles: in slice[String], urls: in slice[String]): slice[RegisterItemInput] {
  var acc: slice[RegisterItemInput] = []
  var i = 0
  while i < ids.length.toInt() {
    acc = acc.append(RegisterItemInput(id = ids[i], title = titles[i], url = urls[i]))
    i = i + 1
  }
  return acc
}

pub func decodeSetItemStatus(json: in String): Result[SetItemStatusRequest, String] {
  val doc = withRoot(json)?
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  val itemArg = str(root, "item")?
  val stateArg = str(root, "state")?
  val reasonArg = str(root, "reason")?
  val blockedByArg = strList(root, "blockedBy")?
  val prerequisiteProposalArg = str(root, "prerequisiteProposal")?
  val recommendationArg = str(root, "recommendation")?
  val prUrlArg = str(root, "prUrl")?
  return Ok(
    value = SetItemStatusRequest(
      item = itemArg,
      state = stateArg,
      reason = reasonArg,
      blockedBy = blockedByArg,
      prerequisiteProposal = prerequisiteProposalArg,
      recommendation = recommendationArg,
      prUrl = prUrlArg
    )
  )
}

pub func decodeDecision(json: in String): Result[RecordDecisionRequest, String] {
  val doc = withRoot(json)?
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  val summaryArg = str(root, "summary")?
  val detailArg = str(root, "detail")?
  val optionsConsideredArg = strList(root, "optionsConsidered")?
  val chosenArg = str(root, "chosen")?
  val rationaleArg = str(root, "rationale")?
  val recommendationArg = str(root, "recommendation")?
  val reversibleArg = boolText(root, "reversible")?
  val itemArg = str(root, "item")?
  val tagsArg = strList(root, "tags")?
  val filesArg = strList(root, "files")?
  val severityArg = str(root, "severity")?
  val supersedesArg = str(root, "supersedes")?
  return Ok(
    value = RecordDecisionRequest(
      summary = summaryArg,
      detail = detailArg,
      optionsConsidered = optionsConsideredArg,
      chosen = chosenArg,
      rationale = rationaleArg,
      recommendation = recommendationArg,
      reversible = reversibleArg,
      item = itemArg,
      tags = tagsArg,
      files = filesArg,
      severity = severityArg,
      supersedes = supersedesArg
    )
  )
}

pub func decodeDeviation(json: in String): Result[RecordDeviationRequest, String] {
  val doc = withRoot(json)?
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  val kindArg = str(root, "kind")?
  val summaryArg = str(root, "summary")?
  val detailArg = str(root, "detail")?
  val recommendationArg = str(root, "recommendation")?
  val reversibleArg = boolText(root, "reversible")?
  val itemArg = str(root, "item")?
  val tagsArg = strList(root, "tags")?
  val filesArg = strList(root, "files")?
  val severityArg = str(root, "severity")?
  val supersedesArg = str(root, "supersedes")?
  return Ok(
    value = RecordDeviationRequest(
      kind = kindArg,
      summary = summaryArg,
      detail = detailArg,
      recommendation = recommendationArg,
      reversible = reversibleArg,
      item = itemArg,
      tags = tagsArg,
      files = filesArg,
      severity = severityArg,
      supersedes = supersedesArg
    )
  )
}

pub func decodeAsk(json: in String): Result[AskRequest, String] {
  val doc = withRoot(json)?
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  val questionArg = str(root, "question")?
  val detailArg = str(root, "detail")?
  val optionsArg = strList(root, "options")?
  val proceedingWithArg = str(root, "proceedingWith")?
  val itemArg = str(root, "item")?
  val severityArg = str(root, "severity")?
  return Ok(
    value = AskRequest(
      question = questionArg,
      detail = detailArg,
      options = optionsArg,
      proceedingWith = proceedingWithArg,
      item = itemArg,
      severity = severityArg
    )
  )
}

pub func decodeNote(json: in String): Result[NoteRequest, String] {
  val doc = withRoot(json)?
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  val summaryArg = str(root, "summary")?
  val detailArg = str(root, "detail")?
  val recommendationArg = str(root, "recommendation")?
  val needsReviewArg = boolText(root, "needsReview")?
  val itemArg = str(root, "item")?
  val tagsArg = strList(root, "tags")?
  val filesArg = strList(root, "files")?
  return Ok(
    value = NoteRequest(
      summary = summaryArg,
      detail = detailArg,
      recommendation = recommendationArg,
      needsReview = needsReviewArg,
      item = itemArg,
      tags = tagsArg,
      files = filesArg
    )
  )
}

/// The most candidates one observer report may carry.
pub val maxReportCandidates: Int = 50

/// observer_report: `{candidates: [...]}`, each candidate an object with
/// kind, summary, detail, item, seqStart, seqEnd, tags, files, reversible,
/// confidence, evidence. Numbers are accepted where text is expected, and a
/// candidates array sent as a JSON string is unwrapped. Field values are
/// validated by the caller; this only fixes the shape.
pub func decodeObserverReport(json: in String): Result[slice[Candidate], String] {
  val doc = withRoot(json)?
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  match propOf(root, "candidates") {
    case None -> {
      val none: slice[Candidate] = []
      return Ok(value = none)
    }
    case Some(el) -> {
      if kindOf(el) == kindNull {
        val none: slice[Candidate] = []
        return Ok(value = none)
      }
      if kindOf(el) == kindString {
        val inner = safeGetString(el).trim()
        if inner.length.toInt() == 0 {
          val none: slice[Candidate] = []
          return Ok(value = none)
        }
        return decodeObserverReport("{\"candidates\":" + inner + "}")
      }
      if kindOf(el) != kindArray {
        return Err(error = "'candidates' must be an array of objects")
      }
      return candidatesOf(el)
    }
  }
}

func candidatesOf(arr: in JsonElement): Result[slice[Candidate], String] {
  var acc: slice[Candidate] = []
  var cur = Std.Json.enumerateArray(arr)
  var n = 0
  while Std.Json.arrayMoveNext(cur) {
    val c = Std.Json.arrayCurrent(cur)
    n = n + 1
    if n > maxReportCandidates {
      return Err(error = "at most " + toString(maxReportCandidates) + " candidates per report")
    }
    if kindOf(c) != kindObject {
      return Err(error = "candidates[" + toString(n - 1) + "] must be an object")
    }
    val cand = candidateOf(c)
    match cand {
      case Ok(x) -> {
        acc = acc.append(x)
      }
      case Err(e) -> return Err(error = "candidates[" + toString(n - 1) + "]: " + e)
    }
  }
  return Ok(value = acc)
}

func candidateOf(c: in JsonElement): Result[Candidate, String] {
  val kind = str(c, "kind")?
  val summary = str(c, "summary")?
  val detail = str(c, "detail")?
  val item = str(c, "item")?
  val seqStart = str(c, "seqStart")?
  val seqEnd = str(c, "seqEnd")?
  val tags = strList(c, "tags")?
  val files = strList(c, "files")?
  val reversible = boolText(c, "reversible")?
  val confidence = str(c, "confidence")?
  val evidence = str(c, "evidence")?
  return Ok(
    value = Candidate(
      kind = kind.trim(),
      summary = summary,
      detail = detail,
      itemId = item.trim(),
      seqStart = seqStart.trim(),
      seqEnd = seqEnd.trim(),
      tags = tags,
      files = files,
      reversible = reversible,
      confidence = confidence.trim(),
      evidence = evidence
    )
  )
}
