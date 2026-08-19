//! CloudAgents.Capture.Render — display-text reconstruction from stream-json
//! events (docs/capture-display-render.md; audit WP4 follow-up).
//!
//! The runner is moving from plain `claude -p --print` output (which the poll
//! loop byte-diffs straight to the PWA) to `--output-format stream-json` so the
//! provenance capture core (`CloudAgents.Capture`, ADR-0004) can parse it. That
//! turns the container log into NDJSON — this package reconstructs the SAME
//! human-readable assistant transcript the PWA used to get from `--print`, so
//! the flip does not regress the UI.
//!
//! Pure and offline: it reads already-parsed `CaptureEvent`s and does no Docker,
//! DB, or HTTP work. It is the reconstruction CONTRACT the entrypoint flip and
//! poll-loop rewrite (the deferred follow-up) depend on — grounded on real
//! harness output (`tests/fixtures/stream-json/`), not an assumed schema.
//!
//! Interpretation, deliberately: `CloudAgents.Capture` keeps fidelity (verbatim
//! payloads, open event-type set); this layer interprets them for DISPLAY. Only
//! the visible assistant `text` blocks are rendered — `thinking`, `tool_use`, and
//! `tool_result` blocks are excluded, matching what plain `--print` showed
//! (surfacing them is a later UI enhancement, not this contract). JSON is read
//! through the `Std.Json` DOM with the same guarded-`getString` idiom the
//! vendored `Adapt` mapper uses, so a lone-surrogate string cannot crash a render.
@runtime_checked
package CloudAgents.Capture.Render

import Std.Core
import Std.Collections
import Std.Json
import CloudAgents.Capture
import CloudAgents.Text

// System.Text.Json.JsonValueKind ordinals (Std.Json.valueKind): Object=1,
// Array=2, String=3.
val jsonKindObject = 1

val jsonKindArray = 2

val jsonKindString = 3

// A string element's value, or "" when it is not a JSON string OR materialising
// it throws (a lone/unpaired UTF-16 surrogate: System.Text.Json tokenises it but
// getString throws when decoding). Guarded so every render stays total — the
// same posture the vendored Adapt mapper takes before hashing.
func safeString(el: in JsonElement): String {
  if Std.Json.valueKind(el) != jsonKindString {
    return ""
  }
  return try {
    Std.Json.getString(el)
  } catch Bug as b {
    ""
  }
}

// The concatenated text of an assistant message's `content[]` text blocks, in
// array order. `content` that is absent or not an array contributes "".
func textOfContent(content: in JsonElement): String {
  if Std.Json.valueKind(content) != jsonKindArray {
    return ""
  }
  var acc = ""
  var cur = Std.Json.enumerateArray(content)
  while Std.Json.arrayMoveNext(cur) {
    val block = Std.Json.arrayCurrent(cur)
    if Std.Json.valueKind(block) == jsonKindObject {
      val blockType = match Std.Json.tryGetProperty(block, "type") { case None -> ""; case Some(t) -> safeString(t) }
      if blockType == "text" {
        acc = acc + match Std.Json.tryGetProperty(block, "text") { case None -> ""; case Some(txt) -> safeString(txt) }
      }
    }
  }
  return acc
}

// The visible-text contribution of one event's parsed root. Non-object roots
// (a payload whose top level is a JSON array/string/number — only reachable via
// a synthetically-mislabeled event, not real captured data) and assistant roots
// with no text blocks contribute "". Guarding on valueKind keeps this total:
// tryGetProperty on a non-object element throws.
func displayTextOfRoot(root: in JsonElement): String {
  if Std.Json.valueKind(root) != jsonKindObject {
    return ""
  }
  val msg = match Std.Json.tryGetProperty(root, "message") { case None -> return ""; case Some(m) -> m }
  if Std.Json.valueKind(msg) != jsonKindObject {
    return ""
  }
  return match Std.Json.tryGetProperty(msg, "content") { case None -> ""; case Some(content) -> textOfContent(content) }
}

/// The transcript text a single captured event contributes to the PWA — the
/// concatenation of its assistant `text` blocks, or "" for any other event
/// (control events, `tool_use`/`tool_result`/`thinking`-only assistant turns,
/// or a malformed payload). Total: never throws.
pub func displayTextOf(event: in CaptureEvent): String {
  if event.eventType != "assistant" {
    return ""
  }
  return match Std.Json.tryParseJson(event.payload) {
    case Err(_) -> ""
    case Ok(doc) -> {
      defer {
        Std.Json.disposeJson(doc)
      }
      displayTextOfRoot(Std.Json.rootElement(doc))
    }
  }
}

/// Reconstruct the visible assistant transcript of a captured turn: the non-empty
/// `displayTextOf` contributions in `seq` order, joined with a newline. Empty when
/// the batch carries no assistant text (e.g. a tool-only or still-running turn).
pub func renderDisplayText(events: in slice[CaptureEvent]): String {
  var acc = ""
  var wrote = false
  var i = 0
  while i < events.length.toInt() {
    val t = displayTextOf(events[i])
    if t.length.toInt() > 0 {
      if wrote {
        acc = acc + "\n"
      }
      acc = acc + t
      wrote = true
    }
    i = i + 1
  }
  return acc
}

// The `result` string of a `result`-typed event's parsed root, or None. A
// non-object root (only reachable via a synthetically-mislabeled event) yields
// None — the valueKind guard keeps this total, since tryGetProperty on a
// non-object throws.
func resultTextOfRoot(root: in JsonElement): Option[String] {
  if Std.Json.valueKind(root) != jsonKindObject {
    return None
  }
  return match Std.Json.tryGetProperty(root, "result") {
    case None -> None
    case Some(r) -> if Std.Json.valueKind(r) == jsonKindString { Some(safeString(r)) } else { None }
  }
}

/// The terminal result text of a captured turn — the `result` field of the LAST
/// `result`-typed event whose `result` is a string, or `None` when the turn
/// carries no such event (still running, or errored before a result). Useful for
/// persisting the agent message / anchoring the checkpoint. Total: never throws.
pub func finalResultText(events: in slice[CaptureEvent]): Option[String] {
  var found: Option[String] = None
  var i = 0
  while i < events.length.toInt() {
    val e = events[i]
    if e.eventType == "result" {
      match Std.Json.tryParseJson(e.payload) {
        case Err(_) -> ()
        case Ok(doc) -> {
          // defer the dispose (matching displayTextOf's Ok branch) so the doc is
          // released even if the read throws, not only on the normal path.
          defer {
            Std.Json.disposeJson(doc)
          }
          match resultTextOfRoot(Std.Json.rootElement(doc)) {
            case Some(s) -> {
              found = Some(s)
            }
            case None -> ()
          }
        }
      }
    }
    i = i + 1
  }
  return found
}

// ─── Incremental log→(display + capture) delta ──────────────────────────────
/// The result of rendering a container-log delta for one poll tick: the visible
/// text to stream to the PWA, the `CaptureEvent`s to persist, how many characters
/// of the delta were CONSUMED (advance the log offset by this — only complete
/// NDJSON lines are consumed; a partial trailing line is left for the next tick),
/// and the carried-forward chain state (`nextSeq`/`lastHash`) so one hash chain
/// spans the whole run.
pub record RenderedDelta {
  pub displayText: String
  pub events: slice[CaptureEvent]
  pub consumed: Int
  pub nextSeq: Long
  pub lastHash: String
}

func emptyEvents(): slice[CaptureEvent] {
  val e: List[CaptureEvent] = newList()
  return e.toArray()
}

// The index of the LAST "\n" in `s`, or -1 if there is none. Uses the proven
// forward `indexOfFrom` char-scan (as `parseStreamJson` does) rather than
// backward `substring` indexing.
func lastNewlineIndex(s: in String): Int {
  var last = -1
  var from = 0
  val n = s.length.toInt()
  while from < n {
    val idx = CloudAgents.Text.indexOfFrom(s, "\n", from)
    if idx < 0 {
      return last
    }
    last = idx
    from = idx + 1
  }
  return last
}

/// Render the portion of an NDJSON container log past `offset`. Parses from
/// `startSeq`/`prevHash` so the hash chain continues across ticks. Pure and total.
///
/// `atEnd` decides what counts as a COMPLETE line at the tail:
/// - `false` (a live poll tick, the run is still producing output): only whole
///   "\n"-terminated lines are consumed; a partial trailing line is NOT consumed,
///   so `offset + consumed` lands on a line boundary and the partial line is
///   re-read next tick — the buffering `parseStreamJson`'s doc describes. When the
///   delta has no complete line yet, nothing is consumed and the chain is unchanged.
/// - `true` (the final flush / whole-log render, the log is finished and
///   authoritative): the ENTIRE remaining delta is consumed, INCLUDING a trailing
///   line with no "\n". The terminal `result` event is frequently emitted without a
///   trailing newline, so truncating at the last "\n" here would silently drop it —
///   and that final line is exactly what becomes the persisted agent message
///   (#973). At end-of-stream there is no "next tick" to re-read it, so it must be
///   rendered now.
pub func renderLogDelta(fullLog: in String, offset: in Int, startSeq: in Long, prevHash: in String, atEnd: in Bool): RenderedDelta {
  val total = fullLog.length.toInt()
  val safeOffset = if offset > total { total } else { offset }
  if safeOffset >= total {
    return RenderedDelta(displayText = "", events = emptyEvents(), consumed = 0, nextSeq = startSeq, lastHash = prevHash)
  }
  val delta = fullLog.substring(safeOffset, total - safeOffset)
  // How much of the delta is safe to consume (see `atEnd` above).
  val completeLen = if atEnd {
    delta.length.toInt()
  } else {
    val lastNl = lastNewlineIndex(delta)
    if lastNl < 0 { -1 } else { lastNl + 1 }
  }
  if completeLen <= 0 {
    return RenderedDelta(displayText = "", events = emptyEvents(), consumed = 0, nextSeq = startSeq, lastHash = prevHash)
  }
  val complete = delta.substring(0, completeLen)
  val batch = parseStreamJson(complete, startSeq, prevHash)
  val text = renderDisplayText(batch.events)
  return RenderedDelta(
    displayText = text,
    events = batch.events,
    consumed = completeLen,
    nextSeq = batch.nextSeq,
    lastHash = batch.lastHash
  )
}

/// Render an ENTIRE NDJSON container log to its visible transcript — the read-back
/// path (`getRunOutput`) that returns the whole log at once. The log is complete,
/// so the final line is rendered even without a trailing newline (`atEnd = true`),
/// so the terminal `result` text is never dropped (#973).
pub func renderFullLog(fullLog: in String): String {
  return renderLogDelta(fullLog, 0, 0.toLong(), "", true).displayText
}
