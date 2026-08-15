//! CloudAgents.Capture — stream-json event capture core
//! (docs/capture-stream-json.md; docs/CAPABILITY_AUDIT.md WP4). Pure and
//! offline: turn `claude -p --output-format stream-json` NDJSON into typed,
//! sequence-numbered, hash-chained `CaptureEvent` records, incrementally and
//! losslessly. This is the structured input the checkpoint-format emitter (WP6)
//! later normalises; it does no Docker, DB, or HTTP work.
//!
//! Fidelity over interpretation: the `"type"` discriminator is recorded
//! verbatim (an open set), the whole line is kept as the payload, a malformed
//! line is captured as `"malformed"` (never dropped), and every event is linked
//! into a SHA-256 hash chain so any edit/insert/reorder/drop is detectable
//! (`verifyChain`) — the same tamper-evidence posture as the platform's
//! checkpoint chain.
//!
//! In-repo idioms: hashing reuses `CloudAgents.Crypto.sha256Base64` (the same
//! proven SHA-256 binding used for the token cache); JSON is read through the
//! `Std.Json` DOM (`tryParseJson`/`rootElement`/`tryGetProperty`, as in
//! `handlers/profiles.l` and `handlers/library.l`); event lists are exposed as
//! `slice[CaptureEvent]` (built with `newList()`/`.add`, then `.toArray()`).
@runtime_checked
package CloudAgents.Capture

import Std.Core
import Std.Collections
import Std.Json
import CloudAgents.Crypto

// ─── Model (spec §3) ─────────────────────────────────────────────────────────
/// One captured stream-json event. `payload` is the raw NDJSON line verbatim;
/// `eventType` is the line's `"type"` (verbatim) or `"malformed"`. `prevHash`/
/// `hash` link the event into the capture's tamper-evident chain.
pub record CaptureEvent {
  pub seq: Long
  pub eventType: String
  pub payload: String
  pub prevHash: String
  pub hash: String
}

/// The result of parsing one stream-json chunk: the events it produced plus the
/// `nextSeq`/`lastHash` to feed into the next chunk so one chain spans the whole
/// session capture.
pub record CaptureBatch {
  pub events: slice[CaptureEvent]
  pub nextSeq: Long
  pub lastHash: String
}

/// The `eventType` given to a line that is not valid JSON, or is JSON with no
/// string `"type"` — captured, never dropped.
pub func malformedType(): String {
  return "malformed"
}

// ─── Hashing (spec §4) ───────────────────────────────────────────────────────
// hash = base64(sha256(prevHash + "\n" + seq + "\n" + eventType + "\n" + payload)).
// Every stored field is covered, so a tamper that mutates only `seq` or
// `eventType` (not just `payload`) also breaks the chain. Reuses the proven
// `CloudAgents.Crypto.sha256Base64` (base64 SHA-256 of a UTF-8 string).
func chainHash(prev: in String, seq: in Long, eventType: in String, payload: in String): String {
  val material = prev + "\n" + toString(seq) + "\n" + eventType + "\n" + payload
  return CloudAgents.Crypto.sha256Base64(material)
}

// Strip a single trailing carriage return so CRLF-framed NDJSON parses the same
// as LF-framed (a bare "\r" blank line collapses to "" and is skipped; a real
// line's trailing "\r" is dropped before it becomes the payload).
func stripCr(line: in String): String {
  if line.endsWith("\r") {
    return line.substring(0, line.length.toInt() - 1)
  }
  return line
}

// System.Text.Json.JsonValueKind.String — guard `getString` (which throws on a
// non-string element) so `eventTypeOf` stays total.
val jsonKindString = 3

// A present "type" element's string value, or malformedType() if it is not a
// JSON string. Guards getString on valueKind so a `{"type":123}` cannot throw.
func stringOrMalformed(el: in JsonElement): String {
  if Std.Json.valueKind(el) == jsonKindString {
    return Std.Json.getString(el)
  }
  return malformedType()
}

// The line's "type" as a string, via the Std.Json DOM — or malformedType() when
// the line is not valid JSON, has no "type", or "type" is not a string. Total:
// never throws on bad input.
func eventTypeOf(line: in String): String {
  return match Std.Json.tryParseJson(line) { case Err(_) -> malformedType(); case Ok(doc) -> typeFromDoc(doc) }
}

func typeFromDoc(doc: in JsonDoc): String {
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  return match Std.Json.tryGetProperty(root, "type") {
    case None -> malformedType()
    case Some(el) -> stringOrMalformed(el)
  }
}

// ─── parseStreamJson (spec §4) ───────────────────────────────────────────────
/// Parse one stream-json chunk (NDJSON) into hash-chained `CaptureEvent`s,
/// continuing from `startSeq` / `prevHash`. Blank lines are skipped; every other
/// line becomes one event (a malformed line is captured as `malformedType()`).
/// Total: returns a batch, never an error. The caller (runner) buffers any
/// partial trailing line so chunks split on line boundaries.
pub func parseStreamJson(ndjson: in String, startSeq: in Long, prevHash: in String): CaptureBatch {
  val events: List[CaptureEvent] = newList()
  var seq = startSeq
  var prev = prevHash
  val lines = ndjson.split("\n")
  var i = 0
  while i < lines.length.toInt() {
    val line = stripCr(lines[i])
    if line.length.toInt() > 0 {
      val etype = eventTypeOf(line)
      val h = chainHash(prev, seq, etype, line)
      events.add(CaptureEvent(seq = seq, eventType = etype, payload = line, prevHash = prev, hash = h))
      seq = seq + 1
      prev = h
    }
    i = i + 1
  }
  return CaptureBatch(events = events.toArray(), nextSeq = seq, lastHash = prev)
}

// ─── verifyChain (spec §4) ───────────────────────────────────────────────────
/// Recompute the chain from `genesisPrevHash` and return `false` on the first
/// `prevHash` discontinuity or `hash` mismatch — the tamper check a consumer
/// runs before trusting a captured stream. Detects payload/seq/eventType
/// mutation, reordering, and dropped events.
pub func verifyChain(events: in slice[CaptureEvent], genesisPrevHash: in String): Bool {
  var prev = genesisPrevHash
  var i = 0
  while i < events.length.toInt() {
    val e = events[i]
    if e.prevHash != prev {
      return false
    }
    val h = chainHash(prev, e.seq, e.eventType, e.payload)
    if e.hash != h {
      return false
    }
    prev = h
    i = i + 1
  }
  return true
}
