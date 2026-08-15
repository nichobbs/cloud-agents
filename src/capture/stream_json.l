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
@runtime_checked
package CloudAgents.Capture

import Std.Core
import Std.Collections
import Std.Json
import Std.Encoding

@externTarget("System.Security.Cryptography.SHA256.HashData")
func sha256(data: in slice[Byte]): slice[Byte] = []

@externTarget("System.Convert.ToHexStringLower")
func toHexLower(b: in slice[Byte]): String = ""

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
  pub events: List[CaptureEvent]
  pub nextSeq: Long
  pub lastHash: String
}

/// The `eventType` given to a line that is not valid JSON, or is JSON with no
/// string `"type"` — captured, never dropped.
pub func malformedType(): String {
  return "malformed"
}

// ─── Hashing (spec §4) ───────────────────────────────────────────────────────
// hash = sha256_hex(prevHash + "\n" + payload). Lowercase hex, UTF-8 bytes.
func hashHex(prev: in String, payload: in String): String {
  return toHexLower(sha256(Std.Encoding.encodeUtf8(prev + "\n" + payload)))
}

// The line's "type" field as a string, or malformedType() when absent, not a
// string, or the line is not valid JSON. Total — never throws on bad input.
func eventTypeOf(line: in String): String {
  return match Std.Json.tryParseJson(line) {
    case Err(_) -> malformedType()
    case Ok(doc) -> {
      defer {
        Std.Json.disposeJson(doc)
      }
      var t: String = ""
      if Std.Json.lyricJsonGetString(line, "type", t) {
        t
      } else {
        malformedType()
      }
    }
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
    val line = lines[i]
    if line.length.toInt() > 0 {
      val etype = eventTypeOf(line)
      val h = hashHex(prev, line)
      events.add(CaptureEvent(seq = seq, eventType = etype, payload = line, prevHash = prev, hash = h))
      seq = seq + 1
      prev = h
    }
    i = i + 1
  }
  return CaptureBatch(events = events, nextSeq = seq, lastHash = prev)
}

// ─── verifyChain (spec §4) ───────────────────────────────────────────────────
/// Recompute the chain from `genesisPrevHash` and return `false` on the first
/// `prevHash` discontinuity or `hash` mismatch — the tamper check a consumer
/// runs before trusting a captured stream. Detects payload mutation, reordering,
/// and dropped events.
pub func verifyChain(events: in List[CaptureEvent], genesisPrevHash: in String): Bool {
  var prev = genesisPrevHash
  var i = 0
  while i < events.count {
    val e = events[i]
    if e.prevHash != prev {
      return false
    }
    val h = hashHex(prev, e.payload)
    if e.hash != h {
      return false
    }
    prev = h
    i = i + 1
  }
  return true
}
