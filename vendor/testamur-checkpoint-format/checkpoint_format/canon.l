//! Canonical JSON encoder/decoder for content-addressing
//! (docs/specs/checkpoint-format.md §3).
//!
//! One byte-exact encoding per logical value: object keys sorted by UTF-8
//! byte order recursively, no insignificant whitespace, strings NFC-normalised
//! with only the escapes JSON requires (lowercase `\uXXXX` where an escape has
//! no short form), integers only (no floats, no exponents, no `-0`), and no
//! `null` anywhere (absent fields are omitted, spec §3.5).
//!
//! The value model (`JsonValue`) deliberately has no null and no float case:
//! a value that cannot be canonically encoded cannot be represented. `parse`
//! rejects such documents with a typed `CanonError` instead — it sees nulls
//! and floats through `Std.Json` (the `System.Text.Json`-backed low-level
//! cursor) and refuses them at the boundary.
//!
//! Ecosystem-extraction candidate (ADR-0003 / spec §3): no imports beyond
//! `Std.*` plus one BCL `String.Normalize` binding, no Testamur-specific
//! names or behaviour.
//!
//! Known toolchain caveat: `List[T]` is used for container payloads (the
//! pattern proven by lyric-jsonrpc's `JsonRpc.Json` model at this compiler
//! version) rather than `slice[T]`, whose record-append-in-hot-loop
//! miscompile (lyric-lang#6322) makes slice accumulation unsafe on large
//! documents.
@runtime_checked
package Testamur.CheckpointFormat.Canon

import Std.Char
import Std.Collections
import Std.Core
import Std.Encoding
import Std.Json
import Std.JsonHost

// NFC normalisation via the BCL: the parameterless `String.Normalize()`
// overload defaults to `NormalizationForm.FormC`, so no enum argument needs
// to cross the FFI boundary (enums marshal poorly — see cloud-agents'
// crypto.l notes on `PaddingMode`).
@externInstance
@externTarget("System.String.Normalize")
func nfcNormalize(s: in String): String = ""

// ── Well-formed UTF-16 (spec §3) ─────────────────────────────────────────────
// Ill-formed UTF-16 (a lone/unpaired surrogate) is rejected centrally, before
// any NFC normalisation or UTF-8 encoding, at every boundary untrusted input
// can enter: `parse` (string values and object keys), where a lone surrogate
// is surfaced as a typed `IllFormedUtf16` error, and `encodeCanonical`, where
// a lone surrogate in a HAND-BUILT `JsonValue` is a caller bug and panics.
// This is NOT swallowed by falling back to the un-normalised string: `Std.
// Encoding.encodeUtf8` is documented to diverge on lone surrogates (.NET emits
// U+FFFD, the JVM emits WTF-8), so tolerating one would silently break spec
// §3's "one byte-exact encoding per logical value" guarantee across runtimes.
//
// The scan works on UTF-16 code units (`String` indexing yields them): a high
// surrogate (U+D800..U+DBFF) is well-formed only immediately followed by a low
// surrogate (U+DC00..U+DFFF); a low surrogate with no preceding high one is
// lone. Surrogate code-unit ranges as decimals to avoid relying on hex
// literals.
func hasLoneSurrogate(s: in String): Bool {
  val len = s.length.toInt()
  var i = 0
  while i < len {
    val code = toInt(s[i])
    if code >= 55296 and code <= 56319 {
      // High surrogate: must be immediately followed by a low surrogate.
      if i + 1 >= len {
        return true
      }
      val next = toInt(s[i + 1])
      if next < 56320 or next > 57343 {
        return true
      }
      i = i + 2
    } else if code >= 56320 and code <= 57343 {
      // Low surrogate with no preceding high surrogate.
      return true
    } else {
      i = i + 1
    }
  }
  return false
}

// Encode-side guard: NFC-normalise `s`, but treat a lone surrogate as a caller
// bug (a hand-built `JsonValue` — `parse`/`decodeCanonical` never yield one, as
// they reject it up front). `System.String.Normalize` itself throws on
// ill-formed UTF-16; we panic with an actionable message rather than let that
// surface as an opaque runtime fault or, worse, be papered over in a way that
// diverges .NET vs JVM (see `hasLoneSurrogate`'s note).
func nfcNormalizeChecked(s: in String): String {
  if hasLoneSurrogate(s) {
    panic(
      "Canon.encodeCanonical received ill-formed UTF-16 (a lone or unpaired UTF-16 surrogate) in a hand-built JsonValue; untrusted input must enter through Canon.parse / Model.decode* / Adapt, which reject it as a typed error"
    )
  }
  return nfcNormalize(s)
}

/// A JSON value that is representable in canonical form. There is no null
/// case (spec §3.5: optional fields are omitted, never null) and no float
/// case (spec §3.4: integers only) — invalid documents are rejected by
/// `parse`/`decodeCanonical` rather than represented.
pub union JsonValue {
  case JBool(value: Bool)
  case JInt(value: Long)
  case JString(value: String)
  case JArray(items: List[JsonValue])
  case JObject(entries: List[JsonEntry])
}

/// One key/value pair of a `JObject`. Entry order in the list is
/// insignificant: `encodeCanonical` sorts by the NFC-normalised key's UTF-8
/// byte order (spec §3.1).
pub record JsonEntry {
  pub key: String
  pub value: JsonValue
}

/// Typed decode/verification failures. `at` fields carry an informal
/// `$`-rooted path (e.g. `$.body.files[2].path`) naming where in the
/// document the offending value sits.
pub union CanonError {
  case ParseFailed(message: String)
  case FloatRejected(literal: String, at: String)
  case NegativeZeroRejected(at: String)
  case IntOutOfRange(literal: String, at: String)
  case NullRejected(at: String)
  case DuplicateKey(key: String, at: String)
  case IllFormedUtf16(at: String)
  case NotCanonical(reason: String)
}

/// Human-readable rendering of a `CanonError`.
pub func canonErrorMessage(e: in CanonError): String {
  return match e {
    case ParseFailed(m) -> "not valid JSON: " + m
    case FloatRejected(l, p) -> "non-integer number '" + l + "' at " + p + " (canonical documents carry integers only, spec §3.4)"
    case NegativeZeroRejected(p) -> "negative zero at " + p + " (canonical documents forbid -0, spec §3.4)"
    case IntOutOfRange(l, p) -> "integer '" + l + "' at " + p + " does not fit in a 64-bit signed integer"
    case NullRejected(p) -> "null value at " + p + " (optional fields are omitted, never null, spec §3.5)"
    case DuplicateKey(k, p) -> "duplicate object key '" + k + "' at " + p + " (keys are compared after NFC normalisation)"
    case IllFormedUtf16(p) -> "ill-formed UTF-16 at " + p + " (a lone or unpaired surrogate; canonical encoding requires well-formed Unicode so .NET and JVM produce byte-identical output, spec §3)"
    case NotCanonical(r) -> "input is not in canonical form: " + r
  }
}

// ── Parsing ─────────────────────────────────────────────────────────────────
/// Parse arbitrary JSON text into a `JsonValue`, rejecting anything the
/// canonical form cannot represent: non-integer numbers (floats, exponents,
/// `-0`), integers outside 64-bit signed range, `null` values, and duplicate
/// object keys (compared after NFC normalisation, which is also applied to
/// every string). Accepts non-canonical *layout* — whitespace, unsorted
/// keys, non-preferred escapes — use `decodeCanonical` to additionally
/// verify layout.
pub func parse(text: in String): Result[JsonValue, CanonError] {
  val doc = match Std.Json.tryParseJson(text) {
    case Ok(d) -> d
    case Err(m) -> return Err(error = ParseFailed(message = m))
  }
  defer {
    Std.Json.disposeJson(doc)
  }
  return valueOfElement(Std.Json.rootElement(doc), "$")
}

// JsonValueKind ordinals per Std.Json.valueKind:
// 0=Undefined, 1=Object, 2=Array, 3=String, 4=Number, 5=True, 6=False, 7=Null.
func valueOfElement(elem: in JsonElement, path: in String): Result[JsonValue, CanonError] {
  val kind = Std.Json.valueKind(elem)
  if kind == 7 {
    return Err(error = NullRejected(at = path))
  }
  if kind == 5 {
    return Ok(value = JBool(value = true))
  }
  if kind == 6 {
    return Ok(value = JBool(value = false))
  }
  if kind == 3 {
    return stringValueOfElement(elem, path)
  }
  if kind == 4 {
    return intOfElement(elem, path)
  }
  if kind == 2 {
    return arrayOfElement(elem, path)
  }
  if kind == 1 {
    return objectOfElement(elem, path)
  }
  return Err(error = ParseFailed(message = "unsupported JSON value kind " + toString(kind) + " at " + path))
}

// A JSON string value. `System.Text.Json` accepts a lone/unpaired UTF-16
// surrogate escape (e.g. `"\ud800"`) at tokenise time, then THROWS from
// `getString` when it materialises the string ("Cannot read incomplete UTF-16
// JSON text ... missing low surrogate"). We catch that here and surface it as a
// typed `IllFormedUtf16` rather than letting it crash `parse`. A string that
// materialises cleanly is well-formed UTF-16, so the following `nfcNormalize`
// (which would also throw on a lone surrogate) cannot fault.
func stringValueOfElement(elem: in JsonElement, path: in String): Result[JsonValue, CanonError] {
  return try {
    Ok(value = JString(value = nfcNormalize(Std.Json.getString(elem))))
  } catch Bug as b {
    Err(error = IllFormedUtf16(at = path))
  }
}

// An object key's raw (pre-NFC) text, or `None` if `propertyName` throws on a
// lone/unpaired UTF-16 surrogate (same materialisation trap as
// `stringValueOfElement`).
func propertyNameOrNone(prop: in JsonProperty): Option[String] {
  return try {
    Some(value = Std.Json.propertyName(prop))
  } catch Bug as b {
    None
  }
}

// The number's raw source text distinguishes what the parsed double/long
// cannot: `1.0`, `1e0`, and `-0` all need rejecting even though they
// round-trip numerically. JSON's number grammar guarantees the raw text is
// an integer literal exactly when it contains no '.', 'e', or 'E'.
func intOfElement(elem: in JsonElement, path: in String): Result[JsonValue, CanonError] {
  val raw = Std.Json.getRawText(elem)
  if raw.contains(".") or raw.contains("e") or raw.contains("E") {
    return Err(error = FloatRejected(literal = raw, at = path))
  }
  if raw == "-0" {
    return Err(error = NegativeZeroRejected(at = path))
  }
  return match Std.Json.tryGetLong(elem) {
    case Some(n) -> Ok(value = JInt(value = n))
    case None -> Err(error = IntOutOfRange(literal = raw, at = path))
  }
}

func arrayOfElement(elem: in JsonElement, path: in String): Result[JsonValue, CanonError] {
  val items: List[JsonValue] = newList()
  var cur = Std.Json.enumerateArray(elem)
  var idx = 0
  while Std.Json.arrayMoveNext(cur) {
    val child = valueOfElement(Std.Json.arrayCurrent(cur), path + "[" + toString(idx) + "]")?
    items.add(child)
    idx = idx + 1
  }
  return Ok(value = JArray(items = items))
}

// Duplicate keys are checked on the NFC-normalised form: two raw keys that
// normalise identically would encode as the same canonical key, so they are
// the same key for content-addressing purposes and must be rejected here —
// System.Text.Json itself permits duplicates and simply yields both.
func objectOfElement(elem: in JsonElement, path: in String): Result[JsonValue, CanonError] {
  val entries: List[JsonEntry] = newList()
  val seen: List[String] = newList()
  var cur = Std.Json.enumerateObject(elem)
  while Std.Json.objectMoveNext(cur) {
    val prop = Std.Json.objectCurrent(cur)
    val rawKey = match propertyNameOrNone(prop) {
      case Some(k) -> k
      case None -> return Err(error = IllFormedUtf16(at = path))
    }
    val key = nfcNormalize(rawKey)
    if listContains(seen, key) {
      return Err(error = DuplicateKey(key = key, at = path))
    }
    seen.add(key)
    val child = valueOfElement(Std.Json.propertyValue(prop), path + "." + key)?
    entries.add(JsonEntry(key = key, value = child))
  }
  return Ok(value = JObject(entries = entries))
}

// ── Canonical encoding ──────────────────────────────────────────────────────
/// Encode a `JsonValue` to its canonical byte-exact form (spec §3): object
/// keys NFC-normalised and sorted by UTF-8 byte order recursively, arrays in
/// given order, no whitespace, strings NFC-normalised with minimal escaping
/// (lowercase `\uXXXX` for control characters without a short escape).
///
/// Values built by `parse`/`decodeCanonical` are already normalised and
/// duplicate-free; for hand-built values the normalisation is re-applied
/// here, but a hand-built object carrying two keys that NFC-normalise
/// identically is a caller bug this function cannot report (it emits both).
pub func encodeCanonical(value: in JsonValue): String {
  return match value {
    case JBool(b) -> if b { "true" } else { "false" }
    case JInt(n) -> toString(n)
    case JString(s) -> encodeCanonicalString(s)
    case JArray(items) -> encodeArrayItems(items)
    case JObject(entries) -> encodeObjectEntries(entries)
  }
}

func encodeArrayItems(items: in List[JsonValue]): String {
  var buf = "["
  var i = 0
  while i < items.count {
    if i > 0 {
      buf = buf + ","
    }
    buf = buf + encodeCanonical(items[i])
    i = i + 1
  }
  return buf + "]"
}

func encodeObjectEntries(entries: in List[JsonEntry]): String {
  val sorted = sortEntriesByKeyUtf8(entries)
  var buf = "{"
  var i = 0
  while i < sorted.count {
    if i > 0 {
      buf = buf + ","
    }
    buf = buf + encodeCanonicalString(sorted[i].key) + ":" + encodeCanonical(sorted[i].value)
    i = i + 1
  }
  return buf + "}"
}

// Insertion sort (rebuild-on-insert: only List.add/index/count are relied
// on). Strict-less comparison keeps it stable. Keys are compared in their
// NFC-normalised form, matching what encodeCanonicalString will emit.
func sortEntriesByKeyUtf8(entries: in List[JsonEntry]): List[JsonEntry] {
  var sorted: List[JsonEntry] = newList()
  var i = 0
  while i < entries.count {
    val e = entries[i]
    val eKey = nfcNormalizeChecked(e.key)
    val next: List[JsonEntry] = newList()
    var j = 0
    var inserted = false
    while j < sorted.count {
      if not inserted and utf8Less(eKey, nfcNormalizeChecked(sorted[j].key)) {
        next.add(e)
        inserted = true
      }
      next.add(sorted[j])
      j = j + 1
    }
    if not inserted {
      next.add(e)
    }
    sorted = next
    i = i + 1
  }
  return sorted
}

// Spec §3.1 orders keys by *UTF-8 byte* order, which is Unicode code-point
// order — NOT the same as .NET ordinal (UTF-16 unit) order: supplementary
// characters (whose UTF-16 forms start with a surrogate in 0xD800..0xDBFF)
// sort below U+E000..U+FFFF under ordinal comparison but above them in
// UTF-8. Comparing the actual UTF-8 encodings sidesteps that trap.
func utf8Less(a: in String, b: in String): Bool {
  val ab = Std.Encoding.encodeUtf8(a)
  val bb = Std.Encoding.encodeUtf8(b)
  val alen = ab.length.toInt()
  val blen = bb.length.toInt()
  var i = 0
  while i < alen and i < blen {
    val x = ab[i].toInt()
    val y = bb[i].toInt()
    if x != y {
      return x < y
    }
    i = i + 1
  }
  return alen < blen
}

// Minimal escaping (spec §3.3): only what JSON requires — '"', '\\', and
// control characters below U+0020. Short escapes where JSON defines them
// (\b \t \n \f \r), lowercase \u00xx otherwise, everything else emitted
// raw (UTF-8 handles it). '/' is never escaped.
func encodeCanonicalString(s: in String): String {
  val n = nfcNormalizeChecked(s)
  var buf = "\""
  var i = 0
  while i < n.length {
    val c = n[i]
    val code = toInt(c)
    if c == '"' {
      buf = buf + "\\\""
    } else if c == '\\' {
      buf = buf + "\\\\"
    } else if c == '\n' {
      buf = buf + "\\n"
    } else if c == '\r' {
      buf = buf + "\\r"
    } else if c == '\t' {
      buf = buf + "\\t"
    } else if code == 8 {
      buf = buf + "\\b"
    } else if code == 12 {
      buf = buf + "\\f"
    } else if code < 32 {
      buf = buf + "\\u" + hex4Lower(code)
    } else {
      buf = buf + "" + c
    }
    i = i + 1
  }
  return buf + "\""
}

func hex4Lower(code: in Int): String {
  val digits = "0123456789abcdef"
  var buf = ""
  var shift = 12
  while shift >= 0 {
    val d = code.shr(shift).and(15)
    buf = buf + "" + digits[d]
    shift = shift - 4
  }
  return buf
}

// ── Canonical decoding ──────────────────────────────────────────────────────
/// Parse `text` AND verify it is already in canonical form: the value is
/// re-encoded and compared byte-for-byte against the input, so any
/// non-canonical layout — unsorted keys, insignificant whitespace,
/// non-minimal or uppercase escapes, non-NFC strings — is rejected with
/// `NotCanonical` naming the first divergence. All `parse`-level rejections
/// (floats, nulls, duplicate keys, ...) apply too.
pub func decodeCanonical(text: in String): Result[JsonValue, CanonError] {
  val value = parse(text)?
  val canonical = encodeCanonical(value)
  if canonical != text {
    return Err(error = NotCanonical(reason = divergenceReason(text, canonical)))
  }
  return Ok(value = value)
}

// Both strings are well-formed UTF-16 here, so char-by-char equality is
// equivalent to byte equality of the UTF-8 encodings.
func divergenceReason(input: in String, canonical: in String): String {
  val ilen = input.length
  val clen = canonical.length
  var i = 0
  while i < ilen and i < clen and input[i] == canonical[i] {
    i = i + 1
  }
  if i >= ilen {
    return "input stops at index " + toString(i) + " where canonical form continues with '" + snippetAt(canonical, i) +
      "'"
  }
  if i >= clen {
    return "input has trailing content at index " + toString(i) + ": '" + snippetAt(input, i) +
      "' beyond the canonical form"
  }
  return "diverges at index " + toString(i) + ": input has '" + snippetAt(input, i) + "' where canonical form has '" +
    snippetAt(canonical, i) +
    "'"
}

func snippetAt(s: in String, from: in Int): String {
  val len = s.length
  val remaining = len - from
  val take = if remaining < 12 { remaining } else { 12 }
  return s.substring(from, take)
}
