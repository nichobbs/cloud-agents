//! CloudAgents.Ledger.ObserverWindow — the transcript window an observer pass
//! reads (docs/session-ledger.md §10). Renders captured stream-json events into
//! compact, seq-numbered lines that keep what matters for spotting undeclared
//! work: the agent's text, each tool call with its salient inputs (file paths,
//! commands, edits), and truncated tool results. Pure: it reads already-parsed
//! `CaptureEvent`s and does no I/O.
//!
//! Claude's stream-json is rendered in full detail. Other harnesses' events
//! fall back to their visible text, or a truncated raw line for tool events,
//! so an observer always sees something rather than nothing.
package CloudAgents.Ledger.ObserverWindow

import Std.Core
import Std.Json
import CloudAgents.Capture
import CloudAgents.Capture.Render

val kindObject = 1

val kindArray = 2

val kindString = 3

/// A rendered window: `text` covers events `firstSeq`..`lastSeq` (decimal;
/// "" when empty). `signal` counts lines that can show undeclared work (the
/// agent's own words, edits, non-read-only commands); a window without any is
/// not worth a pass. `truncated` says the window stopped at `maxChars` before
/// the last event given.
pub record RenderedWindow {
  pub text: String
  pub firstSeq: String
  pub lastSeq: String
  pub events: Int
  pub signal: Int
  pub truncated: Bool
}

/// One rendered event: its lines and whether they carry signal.
record EventLines {
  pub text: String
  pub signal: Bool
}

pub func renderWindow(events: in slice[CaptureEvent], maxChars: in Int): RenderedWindow {
  var text = ""
  var first = ""
  var last = ""
  var count = 0
  var signal = 0
  var truncated = false
  var i = 0
  while i < events.length.toInt() {
    val e = events[i]
    val rendered = renderEvent(e)
    if rendered.text.length.toInt() > 0 and count > 0 and text.length.toInt() + rendered.text.length.toInt() > maxChars {
      truncated = true
      i = events.length.toInt()
    } else {
      if rendered.text.length.toInt() > 0 {
        text = text + rendered.text
        if rendered.signal {
          signal = signal + 1
        }
      }
      if first.length.toInt() == 0 {
        first = toString(e.seq)
      }
      last = toString(e.seq)
      count = count + 1
      i = i + 1
    }
  }
  return RenderedWindow(
    text = text,
    firstSeq = first,
    lastSeq = last,
    events = count,
    signal = signal,
    truncated = truncated
  )
}

func line(seq: in Long, body: in String): String {
  return "[seq " + toString(seq) + "] " + body + "\n"
}

func clip(s: in String, max: in Int): String {
  var flat = ""
  var i = 0
  while i < s.length.toInt() {
    val c = s.substring(i, 1)
    if c == "\n" or c == "\r" or c == "\t" {
      flat = flat + " "
    } else {
      flat = flat + c
    }
    i = i + 1
  }
  if flat.length.toInt() <= max {
    return flat
  }
  return flat.substring(0, max) + "…"
}

func renderEvent(e: in CaptureEvent): EventLines {
  if e.eventType == "malformed" {
    return EventLines(text = line(e.seq, "raw: " + clip(e.payload, 300)), signal = false)
  }
  if e.eventType == "system" or e.eventType == "rate_limit_event" or e.eventType == "autocompact_state" or e.eventType == "active_goal" {
    return EventLines(text = "", signal = false)
  }
  val parsed = match Std.Json.tryParseJson(e.payload) {
    case Ok(doc) -> {
      defer {
        Std.Json.disposeJson(doc)
      }
      try {
        renderRoot(e, Std.Json.rootElement(doc))
      } catch Bug as b {
        EventLines(text = "", signal = false)
      }
    }
    case Err(_) -> EventLines(text = "", signal = false)
  }
  if parsed.text.length.toInt() > 0 {
    return parsed
  }
  // Another harness's schema: its visible text, or the raw line of a tool event.
  val visible = displayTextOf(e)
  if visible.trim().length.toInt() > 0 {
    return EventLines(text = line(e.seq, "agent: " + clip(visible, 1500)), signal = visible.trim().length.toInt() >= 40)
  }
  if e.eventType.contains("tool") or e.eventType.contains("item") or e.eventType.contains("command") {
    return EventLines(text = line(e.seq, e.eventType + ": " + clip(e.payload, 400)), signal = true)
  }
  return EventLines(text = "", signal = false)
}

func str(el: in JsonElement, name: in String): String {
  if Std.Json.valueKind(el) != kindObject {
    return ""
  }
  match Std.Json.tryGetProperty(el, name) {
    case Some(v) -> {
      if Std.Json.valueKind(v) == kindString {
        return Std.Json.getString(v)
      }
      return ""
    }
    case _ -> return ""
  }
}

func renderRoot(e: in CaptureEvent, root: in JsonElement): EventLines {
  if Std.Json.valueKind(root) != kindObject {
    return EventLines(text = "", signal = false)
  }
  val t = str(root, "type")
  if t == "result" {
    return EventLines(text = line(e.seq, "result: " + clip(str(root, "result"), 600)), signal = false)
  }
  if t != "assistant" and t != "user" {
    return EventLines(text = "", signal = false)
  }
  val content = match Std.Json.tryGetProperty(root, "message") {
    case Some(m) -> {
      if Std.Json.valueKind(m) == kindObject {
        Std.Json.tryGetProperty(m, "content")
      } else {
        None
      }
    }
    case _ -> None
  }
  var acc = ""
  var signal = false
  match content {
    case Some(blocks) -> {
      if Std.Json.valueKind(blocks) == kindArray {
        var cur = Std.Json.enumerateArray(blocks)
        while Std.Json.arrayMoveNext(cur) {
          val b = Std.Json.arrayCurrent(cur)
          val bt = str(b, "type")
          if bt == "text" and t == "assistant" {
            val txt = str(b, "text")
            if txt.trim().length.toInt() > 0 {
              acc = acc + line(e.seq, "agent: " + clip(txt, 1500))
              if txt.trim().length.toInt() >= 40 {
                signal = true
              }
            }
          } else if bt == "tool_use" {
            val name = str(b, "name")
            val input = match Std.Json.tryGetProperty(b, "input") { case Some(i) -> toolInput(i); case _ -> "" }
            acc = acc + line(e.seq, "tool " + name + ": " + input)
            if toolCarriesSignal(name, input) {
              signal = true
            }
          } else if bt == "tool_result" {
            var label = "result"
            match Std.Json.tryGetProperty(b, "is_error") {
              case Some(flag) -> {
                if Std.Json.valueKind(flag) == 5 {
                  label = "error"
                }
              }
              case _ -> ()
            }
            val body = match Std.Json.tryGetProperty(b, "content") { case Some(c) -> resultText(c); case _ -> "" }
            acc = acc + line(e.seq, label + ": " + clip(body, 400))
          }
        }
      } else if Std.Json.valueKind(blocks) == kindString and t == "user" {
        // A plain user message: the person's instruction, which defines scope.
        acc = acc + line(e.seq, "user: " + clip(Std.Json.getString(blocks), 1500))
      }
    }
    case _ -> ()
  }
  return EventLines(text = acc, signal = signal)
}

// The salient inputs of a tool call, in a stable order, then anything else.
func toolInput(input: in JsonElement): String {
  if Std.Json.valueKind(input) != kindObject {
    return clip(Std.Json.getRawText(input), 300)
  }
  val keys: slice[String] = ["file_path", "path", "notebook_path", "command", "pattern", "description"]
  var acc = ""
  var i = 0
  while i < keys.length.toInt() {
    val v = str(input, keys[i])
    if v.length.toInt() > 0 {
      acc = acc + keys[i] + "=" + clip(v, 300) + " "
    }
    i = i + 1
  }
  val oldText = str(input, "old_string")
  val newText = str(input, "new_string")
  if oldText.length.toInt() > 0 or newText.length.toInt() > 0 {
    acc = acc + "replace [" + clip(oldText, 300) + "] with [" + clip(newText, 300) + "] "
  }
  val body = str(input, "content")
  if body.length.toInt() > 0 {
    acc = acc + "content=[" + clip(body, 300) + "] "
  }
  if acc.length.toInt() == 0 {
    return clip(Std.Json.getRawText(input), 300)
  }
  return acc.trim()
}

func resultText(c: in JsonElement): String {
  if Std.Json.valueKind(c) == kindString {
    return Std.Json.getString(c)
  }
  if Std.Json.valueKind(c) == kindArray {
    var acc = ""
    var cur = Std.Json.enumerateArray(c)
    while Std.Json.arrayMoveNext(cur) {
      acc = acc + str(Std.Json.arrayCurrent(cur), "text") + " "
    }
    return acc
  }
  return ""
}

/// Whether a tool call can be undeclared work: anything but reading, listing
/// and searching. A shell command counts unless it only reads.
pub func toolCarriesSignal(name: in String, input: in String): Bool {
  val readOnly: slice[String] = ["Read", "Glob", "Grep", "LS", "WebSearch", "WebFetch", "TodoRead", "NotebookRead"]
  var i = 0
  while i < readOnly.length.toInt() {
    if name == readOnly[i] {
      return false
    }
    i = i + 1
  }
  if name == "Bash" {
    return not isReadOnlyCommand(input)
  }
  return true
}

func isReadOnlyCommand(input: in String): Bool {
  val prefixes: slice[String] = [
    "command=ls",
    "command=cat ",
    "command=head ",
    "command=tail ",
    "command=grep ",
    "command=rg ",
    "command=find ",
    "command=pwd",
    "command=wc ",
    "command=git status",
    "command=git diff",
    "command=git log",
    "command=git show"
  ]
  var i = 0
  while i < prefixes.length.toInt() {
    if input.startsWith(prefixes[i]) and not input.contains("&&") and not input.contains(";") and not input.contains("|") and not input.contains(">") {
      return true
    }
    i = i + 1
  }
  return false
}
