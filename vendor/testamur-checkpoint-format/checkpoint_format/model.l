//! Testamur.CheckpointFormat.Model — the provenance data model
//! (docs/specs/checkpoint-format.md §2): Session, Step (a DAG node with the
//! five closed body kinds of §2.3), Checkpoint, and the Principal / Origin /
//! CaptureSource attribution records, plus strict decode from — and encode
//! to — Canon's `JsonValue`.
//!
//! Strictness rules implemented here, per the spec:
//!   - Step `kind` is a CLOSED set (§2.2): an unknown kind is a typed
//!     `UnknownStepKind` error, never coerced (the Ambienta-audit
//!     anti-pattern the spec calls out). `CaptureSource.adapter` is the
//!     deliberate opposite (§2.5): an OPEN set — any adapter string decodes,
//!     because it is provenance metadata, not a dispatch discriminator. The
//!     other enumerated wire strings (principal/origin `type`, `fidelity`,
//!     tool-use `permission`) are closed like `kind`.
//!   - Absent-vs-null is Canon's §3.5 rule: optional fields are omitted from
//!     the encoding when `None` and `null` never reaches this package at all
//!     (Canon's `JsonValue` cannot represent it; `Canon.parse` rejects it).
//!   - Checkpoint `steps` must arrive sorted strictly ascending (§3.6):
//!     the decoder REJECTS unsorted (or duplicated) ids rather than
//!     re-sorting — re-sorting would let two encodings of the same logical
//!     object hash differently.
//!   - Unknown object fields are rejected (`UnexpectedField`): a field the
//!     model does not carry cannot round-trip, so accepting it would break
//!     decode→encode→hash identity.
//!   - The checkpoint `signature` is excluded from the hashed body (§3.7)
//!     STRUCTURALLY: the `Checkpoint` record has no signature field, so
//!     `encodeCheckpoint` (the hash/signing body) cannot accidentally
//!     include one. The full wire object is the separate
//!     `CheckpointEnvelope` (checkpoint + optional `Sign.Signature`),
//!     encoded by `encodeCheckpointEnvelope`.
//!
//! Decode operates on `JsonValue` (any layout `Canon.parse` accepts);
//! canonical-layout enforcement is Canon's `decodeCanonical`. Values built
//! by `Canon.parse` are duplicate-key-free; for hand-built `JObject`s with
//! duplicate keys the first occurrence of a key wins here.
@runtime_checked
package Testamur.CheckpointFormat.Model

import Std.Char
import Std.Collections
import Std.Core
import Std.Encoding
import Testamur.CheckpointFormat.Canon
import Testamur.CheckpointFormat.Sign

// Schema identifiers (spec §2.1/§2.2/§2.6). Package-private on purpose:
// the facade package (Testamur.CheckpointFormat) exports the same literals
// as `sessionSchema()`/`stepSchema()`/`checkpointSchema()`, and exporting
// equally-named funcs here would make an unqualified call ambiguous for a
// file importing both (import-order-dependent resolution — see
// docs/lyric/gotchas.md "Ambiguous names"). Tests assert the two stay equal.
func sessionSchema(): String {
  return "testamur/session/v1"
}

func stepSchema(): String {
  return "testamur/step/v1"
}

func checkpointSchema(): String {
  return "testamur/checkpoint/v1"
}

// ─── Attribution records (spec §2.4) ───────────────────────────────────────
/// `Principal.type` (spec §2.4): who/what ran the session. CLOSED wire set
/// `human` | `agent` | `service`; unknown strings are a typed decode error.
/// Case names carry the `...Principal` suffix so they cannot collide with
/// `OriginKind`'s cases in the same namespace.
pub union PrincipalKind {
  case HumanPrincipal
  case AgentPrincipal
  case ServicePrincipal
}

/// Wire string for a `PrincipalKind`. Total.
pub func principalKindName(kind: in PrincipalKind): String {
  return match kind {
    case HumanPrincipal -> "human"
    case AgentPrincipal -> "agent"
    case ServicePrincipal -> "service"
  }
}

/// Who/what ran the session (spec §2.4). `display` is optional and omitted
/// from the encoding when `None` (never `null`, §3.5).
pub record Principal {
  pub kind: PrincipalKind
  pub id: String
  pub display: Option[String]
}

/// `Origin.type` (spec §2.4): attribution of one step. CLOSED wire set
/// `human` | `agent` | `skill` | `tool`.
pub union OriginKind {
  case HumanOrigin
  case AgentOrigin
  case SkillOrigin
  case ToolOrigin
}

/// Wire string for an `OriginKind`. Total.
pub func originKindName(kind: in OriginKind): String {
  return match kind {
    case HumanOrigin -> "human"
    case AgentOrigin -> "agent"
    case SkillOrigin -> "skill"
    case ToolOrigin -> "tool"
  }
}

/// A skill reference inside an `Origin` (spec §2.4).
pub record SkillRef {
  pub id: String
  pub version: String
}

/// Attribution of one step (spec §2.4): the unit the review plane weights
/// on. `model` and `skill` are optional; `sessionPrincipal` denormalises
/// the owning session's `Principal.id`.
pub record Origin {
  pub kind: OriginKind
  pub model: Option[String]
  pub skill: Option[SkillRef]
  pub sessionPrincipal: String
}

/// Capture fidelity (spec §2.5): CLOSED wire set `events` | `reconstructed`.
pub union Fidelity {
  case Events
  case Reconstructed
}

/// Wire string for a `Fidelity`. Total.
pub func fidelityName(fidelity: in Fidelity): String {
  return match fidelity { case Events -> "events"; case Reconstructed -> "reconstructed" }
}

/// Which adapter produced a session (spec §2.5). `adapter` is an OPEN set:
/// any string decodes — unknown adapters are permitted, unlike step kinds,
/// because this is provenance metadata, not a dispatch discriminator.
pub record CaptureSource {
  pub adapter: String
  pub adapterVersion: String
  pub fidelity: Fidelity
}

// ─── Session (spec §2.1) ───────────────────────────────────────────────────
/// One agent or human working session against one workspace (spec §2.1).
/// Open structure: carries no step list — steps point at their session.
/// `startedAt` is an RFC 3339 UTC timestamp string (second precision);
/// timestamps are data here, never wall-clock reads.
pub record Session {
  pub principal: Principal
  pub workspace: String
  pub taskRef: Option[String]
  pub startedAt: String
  pub capture: CaptureSource
}

// ─── Step (spec §2.2, §2.3) ────────────────────────────────────────────────
/// Tool-use permission outcome (spec §2.3 `tool_use.permission`): CLOSED
/// wire set `granted` | `denied` | `auto`.
pub union Permission {
  case Granted
  case Denied
  case Auto
}

/// Wire string for a `Permission`. Total.
pub func permissionName(permission: in Permission): String {
  return match permission { case Granted -> "granted"; case Denied -> "denied"; case Auto -> "auto" }
}

/// A prompt attachment (spec §2.3 `prompt`): name + content hash only —
/// attachment contents are never embedded.
pub record Attachment {
  pub name: String
  pub sha256: String
}

/// Token usage of a response (spec §2.3 `response.tokens`). Field names
/// avoid the wire keys `in`/`out`, which are Lyric keywords; the encoder
/// maps `tokensIn`/`tokensOut` to `"in"`/`"out"`.
pub record TokenUsage {
  pub tokensIn: Long
  pub tokensOut: Long
}

/// One hunk range of a file change (spec §2.3 `file_change.files[].hunks`).
pub record HunkRange {
  pub start: Long
  pub lines: Long
}

/// One changed file in a `file_change` body (spec §2.3). `beforeSha256` /
/// `afterSha256` are optional git blob hashes (absent for create/delete).
pub record FileDelta {
  pub path: String
  pub beforeSha256: Option[String]
  pub afterSha256: Option[String]
  pub hunks: List[HunkRange]
}

/// The kind-specific step payload (spec §2.3). The step's wire `kind`
/// string is DERIVED from the body case (`stepKindName`), so a `Step` can
/// never carry a body that contradicts its kind. The set is CLOSED: decode
/// rejects unknown kinds with `UnknownStepKind`, never coerces.
pub union StepBody {
  case PromptBody(text: String, attachments: List[Attachment])
  case ResponseBody(model: String, textSha256: String, tokens: TokenUsage)
  case ToolUseBody(tool: String, inputSha256: String, outputSha256: String, permission: Permission)
  case FileChangeBody(files: List[FileDelta])
  case NoteBody(text: String)
}

/// The wire `kind` string of a step body (spec §2.2). Total — every body
/// case has exactly one kind.
pub func stepKindName(body: in StepBody): String {
  return match body {
    case PromptBody(_, _) -> "prompt"
    case ResponseBody(_, _, _) -> "response"
    case ToolUseBody(_, _, _, _) -> "tool_use"
    case FileChangeBody(_) -> "file_change"
    case NoteBody(_) -> "note"
  }
}

/// One node in a session's step DAG (spec §2.2). `parents` order is
/// significant (§3: arrays keep declared order). `redactions` counts hits
/// removed from `body` before encoding (the hash covers the redacted form);
/// decode rejects negative counts.
pub record Step {
  pub session: String
  pub parents: List[String]
  pub origin: Origin
  pub at: String
  pub body: StepBody
  pub redactions: Long
}

// ─── Checkpoint (spec §2.6) ────────────────────────────────────────────────
/// The HASHED BODY of a checkpoint (spec §2.6 minus `signature`): binds a
/// step frontier to a git tree. Deliberately has NO signature field — spec
/// §3.7 excludes `signature` from the hashed/signed body, and omitting the
/// field from this record makes accidental inclusion unrepresentable. The
/// full wire object is `CheckpointEnvelope`. `steps` must be sorted
/// strictly ascending (UTF-8 byte order); the decoder rejects unsorted
/// input (§3.6).
pub record Checkpoint {
  pub session: String
  pub steps: List[String]
  pub tree: String
  pub parent: Option[String]
  pub at: String
}

/// The full wire form of a checkpoint (spec §2.6): the hashed body plus the
/// optional detached `signature`. Absent signature ⇒ unattributed-grade
/// (§4) — never an error.
pub record CheckpointEnvelope {
  pub checkpoint: Checkpoint
  pub signature: Option[Signature]
}

/// Any of the three content-addressed object types (spec §6's
/// `ProvenanceObject`), for stores and adapters that handle mixed streams.
pub union ProvenanceObject {
  case SessionObject(session: Session)
  case StepObject(step: Step)
  case CheckpointObject(envelope: CheckpointEnvelope)
}

// ─── Errors ────────────────────────────────────────────────────────────────
/// Typed decode failures. `at` fields carry the same informal `$`-rooted
/// path convention as Canon's errors (e.g. `$.body.files[0]`), naming where
/// in the document the offending value sits.
pub union ModelError {
  case NotAnObject(at: String)
  case MissingField(field: String, at: String)
  case UnexpectedField(field: String, at: String)
  case WrongFieldType(field: String, expected: String, at: String)
  case WrongSchema(expected: String, actual: String, at: String)
  case UnknownSchema(actual: String, at: String)
  case UnknownStepKind(kind: String, at: String)
  case InvalidValue(field: String, message: String, at: String)
  case UnsortedSteps(message: String, at: String)
  case MalformedTimestamp(field: String, at: String)
  case BadSignature(message: String, at: String)
}

/// Human-readable rendering of a `ModelError`.
pub func modelErrorMessage(e: in ModelError): String {
  return match e {
    case NotAnObject(p) -> "expected a JSON object at " + p
    case MissingField(f, p) -> "missing required field '" + f + "' at " + p
    case UnexpectedField(f, p) -> "unexpected field '" + f + "' at " + p + " (unknown fields cannot round-trip and are rejected)"
    case WrongFieldType(f, t, p) -> "field '" + f + "' at " + p + " must be a " + t
    case WrongSchema(want, got, p) -> "wrong schema at " + p + ": expected \"" + want + "\", got \"" + got + "\""
    case UnknownSchema(got, p) -> "unknown schema \"" + got + "\" at " + p
    case UnknownStepKind(k, p) -> "unknown step kind \"" + k + "\" at " + p + " (expected prompt | response | tool_use | file_change | note; unknown kinds are rejected, never coerced — spec §2.2)"
    case InvalidValue(f, m, p) -> "invalid value for field '" + f + "' at " + p + ": " + m
    case UnsortedSteps(m, p) -> "checkpoint steps at " + p + " are not sorted strictly ascending: " + m + " (decoders reject unsorted input rather than re-sort, spec §3.6)"
    case MalformedTimestamp(f, p) -> "field '" + f + "' at " + p + " is not a strict RFC 3339 UTC second-precision timestamp (expected YYYY-MM-DDTHH:MM:SSZ, spec §2.1; decoders reject other forms rather than coerce)"
    case BadSignature(m, p) -> "invalid signature at " + p + ": " + m
  }
}

// ─── Decode helpers ────────────────────────────────────────────────────────
func entriesOf(v: in JsonValue, at: in String): Result[List[JsonEntry], ModelError] {
  return match v { case JObject(entries) -> Ok(value = entries); case _ -> Err(error = NotAnObject(at = at)) }
}

// First occurrence wins; `Canon.parse`-derived values are duplicate-free.
func fieldOf(entries: in List[JsonEntry], key: in String): Option[JsonValue] {
  var i = 0
  while i < entries.count {
    if entries[i].key == key {
      return Some(value = entries[i].value)
    }
    i = i + 1
  }
  return None
}

func rejectUnknownKeys(entries: in List[JsonEntry], allowed: in slice[String], at: in String): Result[Unit, ModelError] {
  var i = 0
  while i < entries.count {
    val key = entries[i].key
    var found = false
    var j = 0
    while j < allowed.length {
      if allowed[j] == key {
        found = true
      }
      j = j + 1
    }
    if not found {
      return Err(error = UnexpectedField(field = key, at = at))
    }
    i = i + 1
  }
  return Ok(value = ())
}

func requireField(entries: in List[JsonEntry], key: in String, at: in String): Result[JsonValue, ModelError] {
  return match fieldOf(entries, key) {
    case Some(v) -> Ok(value = v)
    case None -> Err(error = MissingField(field = key, at = at))
  }
}

func requireString(entries: in List[JsonEntry], key: in String, at: in String): Result[String, ModelError] {
  return match requireField(entries, key, at)? {
    case JString(s) -> Ok(value = s)
    case _ -> Err(error = WrongFieldType(field = key, expected = "string", at = at))
  }
}

func optionalString(entries: in List[JsonEntry], key: in String, at: in String): Result[Option[String], ModelError] {
  return match fieldOf(entries, key) {
    case None -> Ok(value = None)
    case Some(v) -> match v { case JString(s) -> Ok(value = Some(value = s)); case _ -> Err(error = WrongFieldType(field = key, expected = "string", at = at)) }
  }
}

func requireLong(entries: in List[JsonEntry], key: in String, at: in String): Result[Long, ModelError] {
  return match requireField(entries, key, at)? {
    case JInt(n) -> Ok(value = n)
    case _ -> Err(error = WrongFieldType(field = key, expected = "integer", at = at))
  }
}

func requireArray(entries: in List[JsonEntry], key: in String, at: in String): Result[List[JsonValue], ModelError] {
  return match requireField(entries, key, at)? {
    case JArray(items) -> Ok(value = items)
    case _ -> Err(error = WrongFieldType(field = key, expected = "array", at = at))
  }
}

func requireSchema(entries: in List[JsonEntry], expected: in String, at: in String): Result[Unit, ModelError] {
  val schema = requireString(entries, "schema", at)?
  if schema != expected {
    return Err(error = WrongSchema(expected = expected, actual = schema, at = at + ".schema"))
  }
  return Ok(value = ())
}

func stringItems(items: in List[JsonValue], field: in String, at: in String): Result[List[String], ModelError] {
  val strings: List[String] = newList()
  var i = 0
  while i < items.count {
    match items[i] {
      case JString(s) -> strings.add(s)
      case _ -> return Err(error = WrongFieldType(field = field, expected = "array of strings", at = at + "[" + toString(i) + "]"))
    }
    i = i + 1
  }
  return Ok(value = strings)
}

// Spec §3.1's key order is UTF-8 byte order; step/checkpoint ids and
// RFC 3339 UTC timestamps are ASCII, where this coincides with ordinal
// order, but the comparison is byte-exact for any string (same approach as
// Canon's private key comparator).
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

// Strict RFC 3339 UTC second-precision timestamp validation (spec §2.1:
// `started_at`/`at` are "RFC 3339 UTC, second precision"). The layout is
// EXACTLY `YYYY-MM-DDTHH:MM:SSZ` — 20 chars, fixed-width digit fields with the
// literal `-`/`T`/`:` separators and a trailing `Z`. This is a structural
// check (digit positions + separators), not a calendar check: it is what
// chain.l's timestamp-ordering invariant needs, which byte-compares these
// strings on the documented assumption that they are UTC, same-precision, same
// width (so lexicographic order coincides with temporal order). Model accepts
// timestamps only through `requireString`, so without this, constant/empty
// (`""`, all-identical) or mixed-precision timestamps would silently neutralise
// or corrupt that ordering guarantee. Reject, never coerce (Model's philosophy).
func isAsciiDigitAt(s: in String, i: in Int): Bool {
  val code = toInt(s[i])
  return code >= 48 and code <= 57
}

// The two-digit decimal value at [i, i+1]. Caller must have confirmed both
// positions are ASCII digits (isAsciiDigitAt); otherwise the result is
// meaningless.
func twoDigitValue(s: in String, i: in Int): Int {
  return (toInt(s[i]) - 48) * 10 + (toInt(s[i + 1]) - 48)
}

func isRfc3339UtcSeconds(s: in String): Bool {
  if s.length.toInt() != 20 {
    return false
  }
  // Structural: exactly YYYY-MM-DDTHH:MM:SSZ, all digit positions ASCII digits.
  val structural = isAsciiDigitAt(s, 0) and isAsciiDigitAt(s, 1) and isAsciiDigitAt(s, 2) and isAsciiDigitAt(s, 3) and
    s[4] == '-' and
    isAsciiDigitAt(s, 5) and
    isAsciiDigitAt(s, 6) and
    s[7] == '-' and
    isAsciiDigitAt(s, 8) and
    isAsciiDigitAt(s, 9) and
    s[10] == 'T' and
    isAsciiDigitAt(s, 11) and
    isAsciiDigitAt(s, 12) and
    s[13] == ':' and
    isAsciiDigitAt(s, 14) and
    isAsciiDigitAt(s, 15) and
    s[16] == ':' and
    isAsciiDigitAt(s, 17) and
    isAsciiDigitAt(s, 18) and
    s[19] == 'Z'
  if not structural {
    return false
  }
  // Value ranges, so a structurally-shaped nonsense like "9999-99-99T99:99:99Z"
  // is rejected rather than silently accepted. Calendar-exact validation
  // (per-month day counts, leap years) is intentionally NOT done — it is not
  // needed for the byte-comparison ordering guarantee and would add a table
  // for no security benefit. Second allows 60 for RFC 3339 leap seconds.
  val month = twoDigitValue(s, 5)
  val day = twoDigitValue(s, 8)
  val hour = twoDigitValue(s, 11)
  val minute = twoDigitValue(s, 14)
  val second = twoDigitValue(s, 17)
  return month >= 1 and month <= 12 and day >= 1 and day <= 31 and hour <= 23 and minute <= 59 and second <= 60
}

// Read a required string field AND enforce the strict RFC 3339 UTC
// second-precision timestamp format on it.
func requireTimestamp(entries: in List[JsonEntry], key: in String, at: in String): Result[String, ModelError] {
  val value = requireString(entries, key, at)?
  if not isRfc3339UtcSeconds(value) {
    return Err(error = MalformedTimestamp(field = key, at = at + "." + key))
  }
  return Ok(value = value)
}

// ─── Decoding (strict, spec §2) ────────────────────────────────────────────
func decodePrincipal(v: in JsonValue, at: in String): Result[Principal, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["display", "id", "type"], at)?
  val kindRaw = requireString(entries, "type", at)?
  val kind = if kindRaw == "human" {
    HumanPrincipal
  } else if kindRaw == "agent" {
    AgentPrincipal
  } else if kindRaw == "service" {
    ServicePrincipal
  } else {
    return Err(
      error = InvalidValue(
        field = "type",
        message = "unknown principal type \"" + kindRaw + "\" (expected human | agent | service)",
        at = at
      )
    )
  }
  val id = requireString(entries, "id", at)?
  val display = optionalString(entries, "display", at)?
  return Ok(value = Principal(kind = kind, id = id, display = display))
}

func decodeSkillRef(v: in JsonValue, at: in String): Result[SkillRef, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["id", "version"], at)?
  val id = requireString(entries, "id", at)?
  val version = requireString(entries, "version", at)?
  return Ok(value = SkillRef(id = id, version = version))
}

func decodeOrigin(v: in JsonValue, at: in String): Result[Origin, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["model", "session_principal", "skill", "type"], at)?
  val kindRaw = requireString(entries, "type", at)?
  val kind = if kindRaw == "human" {
    HumanOrigin
  } else if kindRaw == "agent" {
    AgentOrigin
  } else if kindRaw == "skill" {
    SkillOrigin
  } else if kindRaw == "tool" {
    ToolOrigin
  } else {
    return Err(
      error = InvalidValue(
        field = "type",
        message = "unknown origin type \"" + kindRaw + "\" (expected human | agent | skill | tool)",
        at = at
      )
    )
  }
  val model = optionalString(entries, "model", at)?
  // Explicitly-typed accumulator, not a match EXPRESSION mixing a bare
  // `None` arm with a `Some[SkillRef]` arm: the bare None would infer the
  // scrutinee's Option[JsonValue] type and mis-type the codegen (W0004).
  var skill: Option[SkillRef] = None
  match fieldOf(entries, "skill") {
    case Some(sv) -> {
      val skillRef = decodeSkillRef(sv, at + ".skill")?
      skill = Some(value = skillRef)
    }
    case None -> ()
  }
  val sessionPrincipal = requireString(entries, "session_principal", at)?
  return Ok(value = Origin(kind = kind, model = model, skill = skill, sessionPrincipal = sessionPrincipal))
}

func decodeCapture(v: in JsonValue, at: in String): Result[CaptureSource, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["adapter", "adapter_version", "fidelity"], at)?
  // OPEN set (spec §2.5): any adapter string is accepted, including ones
  // this package has never heard of — the deliberate asymmetry with the
  // CLOSED step `kind` set.
  val adapter = requireString(entries, "adapter", at)?
  val adapterVersion = requireString(entries, "adapter_version", at)?
  val fidelityRaw = requireString(entries, "fidelity", at)?
  val fidelity = if fidelityRaw == "events" {
    Events
  } else if fidelityRaw == "reconstructed" {
    Reconstructed
  } else {
    return Err(
      error = InvalidValue(
        field = "fidelity",
        message = "unknown fidelity \"" + fidelityRaw + "\" (expected events | reconstructed)",
        at = at
      )
    )
  }
  return Ok(value = CaptureSource(adapter = adapter, adapterVersion = adapterVersion, fidelity = fidelity))
}

/// Strictly decode a `Session` (spec §2.1) from a `JsonValue`. Rejections
/// are typed `ModelError`s naming the offending field and path; unknown
/// fields are rejected; absent optionals decode to `None` (`null` never
/// reaches this package — Canon rejects it at parse).
pub func decodeSession(v: in JsonValue): Result[Session, ModelError] {
  val at = "$"
  val entries = entriesOf(v, at)?
  // Schema first, unknown keys second: a wrong-schema object reports
  // WrongSchema, not a confusing UnexpectedField about the other schema's
  // legitimate fields.
  requireSchema(entries, sessionSchema(), at)?
  rejectUnknownKeys(entries, ["capture", "principal", "schema", "started_at", "task_ref", "workspace"], at)?
  // `?` expressions are hoisted out of argument positions throughout this
  // package: `f(g(...)?, ...)` produced a method the CLR JIT rejected with
  // InvalidProgramException (no compile-time diagnostic) at decodeStep's
  // body dispatch — see decodeBody's note. Filed upstream with a minimal
  // repro as lyric-lang#6448 (method-call arguments specifically; plain
  // function arguments are unaffected).
  val principalValue = requireField(entries, "principal", at)?
  val principal = decodePrincipal(principalValue, at + ".principal")?
  val workspace = requireString(entries, "workspace", at)?
  val taskRef = optionalString(entries, "task_ref", at)?
  val captureValue = requireField(entries, "capture", at)?
  val startedAt = requireTimestamp(entries, "started_at", at)?
  val capture = decodeCapture(captureValue, at + ".capture")?
  return Ok(
    value = Session(
      principal = principal,
      workspace = workspace,
      taskRef = taskRef,
      startedAt = startedAt,
      capture = capture
    )
  )
}

func decodeAttachment(v: in JsonValue, at: in String): Result[Attachment, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["name", "sha256"], at)?
  val name = requireString(entries, "name", at)?
  val sha256 = requireString(entries, "sha256", at)?
  return Ok(value = Attachment(name = name, sha256 = sha256))
}

func decodeTokens(v: in JsonValue, at: in String): Result[TokenUsage, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["in", "out"], at)?
  val tokensIn = requireLong(entries, "in", at)?
  val tokensOut = requireLong(entries, "out", at)?
  return Ok(value = TokenUsage(tokensIn = tokensIn, tokensOut = tokensOut))
}

func decodeHunk(v: in JsonValue, at: in String): Result[HunkRange, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["lines", "start"], at)?
  val start = requireLong(entries, "start", at)?
  val lines = requireLong(entries, "lines", at)?
  return Ok(value = HunkRange(start = start, lines = lines))
}

func decodeFileDelta(v: in JsonValue, at: in String): Result[FileDelta, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["after_sha256", "before_sha256", "hunks", "path"], at)?
  val path = requireString(entries, "path", at)?
  val beforeSha256 = optionalString(entries, "before_sha256", at)?
  val afterSha256 = optionalString(entries, "after_sha256", at)?
  val hunkItems = requireArray(entries, "hunks", at)?
  val hunks: List[HunkRange] = newList()
  var i = 0
  while i < hunkItems.count {
    val hunk = decodeHunk(hunkItems[i], at + ".hunks[" + toString(i) + "]")?
    hunks.add(hunk)
    i = i + 1
  }
  return Ok(value = FileDelta(path = path, beforeSha256 = beforeSha256, afterSha256 = afterSha256, hunks = hunks))
}

// CLOSED kind dispatch (spec §2.2): the kind string selects exactly one
// body shape; anything else is `UnknownStepKind`. One helper per kind —
// besides readability, folding all five decoders into one function
// produced a method the CLR JIT rejected outright (InvalidProgramException
// on first call, no compile-time diagnostic; same silently-miscompiled
// family as cloud-agents docs/lyric/gotchas.md's InvalidProgramException
// entries — the argument-position `?` trigger is filed upstream as
// lyric-lang#6448). Keep them separate.
func decodeBody(kind: in String, v: in JsonValue, at: in String): Result[StepBody, ModelError] {
  if kind == "prompt" {
    return decodePromptBody(v, at)
  }
  if kind == "response" {
    return decodeResponseBody(v, at)
  }
  if kind == "tool_use" {
    return decodeToolUseBody(v, at)
  }
  if kind == "file_change" {
    return decodeFileChangeBody(v, at)
  }
  if kind == "note" {
    return decodeNoteBody(v, at)
  }
  return Err(error = UnknownStepKind(kind = kind, at = "$.kind"))
}

func decodePromptBody(v: in JsonValue, at: in String): Result[StepBody, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["attachments", "text"], at)?
  val text = requireString(entries, "text", at)?
  val attachmentItems = requireArray(entries, "attachments", at)?
  val attachments: List[Attachment] = newList()
  var i = 0
  while i < attachmentItems.count {
    val attachment = decodeAttachment(attachmentItems[i], at + ".attachments[" + toString(i) + "]")?
    attachments.add(attachment)
    i = i + 1
  }
  return Ok(value = PromptBody(text = text, attachments = attachments))
}

func decodeResponseBody(v: in JsonValue, at: in String): Result[StepBody, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["model", "text_sha256", "tokens"], at)?
  val model = requireString(entries, "model", at)?
  val textSha256 = requireString(entries, "text_sha256", at)?
  val tokensValue = requireField(entries, "tokens", at)?
  val tokens = decodeTokens(tokensValue, at + ".tokens")?
  return Ok(value = ResponseBody(model = model, textSha256 = textSha256, tokens = tokens))
}

func decodeToolUseBody(v: in JsonValue, at: in String): Result[StepBody, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["input_sha256", "output_sha256", "permission", "tool"], at)?
  val tool = requireString(entries, "tool", at)?
  val inputSha256 = requireString(entries, "input_sha256", at)?
  val outputSha256 = requireString(entries, "output_sha256", at)?
  val permissionRaw = requireString(entries, "permission", at)?
  val permission = if permissionRaw == "granted" {
    Granted
  } else if permissionRaw == "denied" {
    Denied
  } else if permissionRaw == "auto" {
    Auto
  } else {
    return Err(
      error = InvalidValue(
        field = "permission",
        message = "unknown permission \"" + permissionRaw + "\" (expected granted | denied | auto)",
        at = at
      )
    )
  }
  return Ok(
    value = ToolUseBody(
      tool = tool,
      inputSha256 = inputSha256,
      outputSha256 = outputSha256,
      permission = permission
    )
  )
}

func decodeFileChangeBody(v: in JsonValue, at: in String): Result[StepBody, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["files"], at)?
  val fileItems = requireArray(entries, "files", at)?
  val files: List[FileDelta] = newList()
  var i = 0
  while i < fileItems.count {
    val file = decodeFileDelta(fileItems[i], at + ".files[" + toString(i) + "]")?
    files.add(file)
    i = i + 1
  }
  return Ok(value = FileChangeBody(files = files))
}

func decodeNoteBody(v: in JsonValue, at: in String): Result[StepBody, ModelError] {
  val entries = entriesOf(v, at)?
  rejectUnknownKeys(entries, ["text"], at)?
  val text = requireString(entries, "text", at)?
  return Ok(value = NoteBody(text = text))
}

/// Strictly decode a `Step` (spec §2.2) from a `JsonValue`. Unknown `kind`
/// is a typed `UnknownStepKind` rejection — never coerced; the body must
/// match the kind's shape exactly; negative `redactions` are rejected.
pub func decodeStep(v: in JsonValue): Result[Step, ModelError] {
  val at = "$"
  val entries = entriesOf(v, at)?
  requireSchema(entries, stepSchema(), at)?
  rejectUnknownKeys(entries, ["at", "body", "kind", "origin", "parents", "redactions", "schema", "session"], at)?
  val session = requireString(entries, "session", at)?
  val parentItems = requireArray(entries, "parents", at)?
  val parents = stringItems(parentItems, "parents", at + ".parents")?
  val kind = requireString(entries, "kind", at)?
  val originValue = requireField(entries, "origin", at)?
  val origin = decodeOrigin(originValue, at + ".origin")?
  val atField = requireTimestamp(entries, "at", at)?
  val bodyValue = requireField(entries, "body", at)?
  val body = decodeBody(kind, bodyValue, at + ".body")?
  val redactions = requireLong(entries, "redactions", at)?
  if redactions < 0.toLong() {
    return Err(
      error = InvalidValue(field = "redactions", message = "must be a non-negative count", at = at + ".redactions")
    )
  }
  return Ok(
    value = Step(
      session = session,
      parents = parents,
      origin = origin,
      at = atField,
      body = body,
      redactions = redactions
    )
  )
}

/// Strictly decode a checkpoint wire object (spec §2.6) into a
/// `CheckpointEnvelope`. `steps` must be sorted strictly ascending (UTF-8
/// byte order) — unsorted or duplicated ids are rejected with
/// `UnsortedSteps`, never re-sorted (§3.6). A present `signature` is
/// decoded through `Sign.decodeSignature` (its canonical fragment codec),
/// so unknown schemes, non-canonical base64, and extra signature fields are
/// all typed `BadSignature` rejections.
pub func decodeCheckpoint(v: in JsonValue): Result[CheckpointEnvelope, ModelError] {
  val at = "$"
  val entries = entriesOf(v, at)?
  requireSchema(entries, checkpointSchema(), at)?
  rejectUnknownKeys(entries, ["at", "parent", "schema", "session", "signature", "steps", "tree"], at)?
  val session = requireString(entries, "session", at)?
  val stepItems = requireArray(entries, "steps", at)?
  val steps = stringItems(stepItems, "steps", at + ".steps")?
  var i = 0
  while i + 1 < steps.count {
    if not utf8Less(steps[i], steps[i + 1]) {
      return Err(
        error = UnsortedSteps(
          message = "\"" + steps[i + 1] + "\" at index " + toString(i + 1) +
            " does not sort strictly after \"" +
            steps[i] +
            "\"",
          at = at + ".steps"
        )
      )
    }
    i = i + 1
  }
  val tree = requireString(entries, "tree", at)?
  val parent = optionalString(entries, "parent", at)?
  val atField = requireTimestamp(entries, "at", at)?
  // Same explicitly-typed-accumulator shape as decodeOrigin's `skill` (a
  // match expression with a bare `None` arm mis-types codegen, W0004).
  var signature: Option[Signature] = None
  match fieldOf(entries, "signature") {
    case Some(sv) -> match decodeSignature(encodeCanonical(sv)) { case Ok(sig) -> { signature = Some(value = sig) }; case Err(e) -> return Err(error = BadSignature(message = signatureErrorMessage(e), at = at + ".signature")) }
    case None -> ()
  }
  val checkpoint = Checkpoint(session = session, steps = steps, tree = tree, parent = parent, at = atField)
  return Ok(value = CheckpointEnvelope(checkpoint = checkpoint, signature = signature))
}

/// Decode any provenance object by its `schema` field: dispatches to
/// `decodeSession` / `decodeStep` / `decodeCheckpoint`; an unrecognised
/// schema is a typed `UnknownSchema` error.
pub func decodeObject(v: in JsonValue): Result[ProvenanceObject, ModelError] {
  val entries = entriesOf(v, "$")?
  val schema = requireString(entries, "schema", "$")?
  if schema == sessionSchema() {
    val session = decodeSession(v)?
    return Ok(value = SessionObject(session = session))
  }
  if schema == stepSchema() {
    val step = decodeStep(v)?
    return Ok(value = StepObject(step = step))
  }
  if schema == checkpointSchema() {
    val envelope = decodeCheckpoint(v)?
    return Ok(value = CheckpointObject(envelope = envelope))
  }
  return Err(error = UnknownSchema(actual = schema, at = "$.schema"))
}

// ─── Encoding (to Canon JsonValue; canonical bytes via encodeCanonical) ────
func jstr(key: in String, s: in String): JsonEntry {
  return JsonEntry(key = key, value = JString(value = s))
}

func encodePrincipal(principal: in Principal): JsonValue {
  val entries: List[JsonEntry] = newList()
  entries.add(jstr("type", principalKindName(principal.kind)))
  entries.add(jstr("id", principal.id))
  match principal.display {
    case Some(d) -> entries.add(jstr("display", d))
    case None -> ()
  }
  return JObject(entries = entries)
}

func encodeOrigin(origin: in Origin): JsonValue {
  val entries: List[JsonEntry] = newList()
  entries.add(jstr("type", originKindName(origin.kind)))
  match origin.model {
    case Some(m) -> entries.add(jstr("model", m))
    case None -> ()
  }
  match origin.skill {
    case Some(skill) -> {
      val skillEntries: List[JsonEntry] = newList()
      skillEntries.add(jstr("id", skill.id))
      skillEntries.add(jstr("version", skill.version))
      entries.add(JsonEntry(key = "skill", value = JObject(entries = skillEntries)))
    }
    case None -> ()
  }
  entries.add(jstr("session_principal", origin.sessionPrincipal))
  return JObject(entries = entries)
}

func encodeCapture(capture: in CaptureSource): JsonValue {
  val entries: List[JsonEntry] = newList()
  entries.add(jstr("adapter", capture.adapter))
  entries.add(jstr("adapter_version", capture.adapterVersion))
  entries.add(jstr("fidelity", fidelityName(capture.fidelity)))
  return JObject(entries = entries)
}

/// Encode a `Session` to its `JsonValue` form (spec §2.1). Canonical bytes
/// — the hashed body — come from `Canon.encodeCanonical` of this value.
/// Absent optionals are omitted, never `null` (§3.5).
pub func encodeSession(session: in Session): JsonValue {
  val entries: List[JsonEntry] = newList()
  entries.add(jstr("schema", sessionSchema()))
  entries.add(JsonEntry(key = "principal", value = encodePrincipal(session.principal)))
  entries.add(jstr("workspace", session.workspace))
  match session.taskRef {
    case Some(t) -> entries.add(jstr("task_ref", t))
    case None -> ()
  }
  entries.add(jstr("started_at", session.startedAt))
  entries.add(JsonEntry(key = "capture", value = encodeCapture(session.capture)))
  return JObject(entries = entries)
}

func encodeBody(body: in StepBody): JsonValue {
  return match body {
    case PromptBody(text, attachments) -> {
      val entries: List[JsonEntry] = newList()
      entries.add(jstr("text", text))
      val items: List[JsonValue] = newList()
      var i = 0
      while i < attachments.count {
        val attachmentEntries: List[JsonEntry] = newList()
        attachmentEntries.add(jstr("name", attachments[i].name))
        attachmentEntries.add(jstr("sha256", attachments[i].sha256))
        items.add(JObject(entries = attachmentEntries))
        i = i + 1
      }
      entries.add(JsonEntry(key = "attachments", value = JArray(items = items)))
      JObject(entries = entries)
    }
    case ResponseBody(model, textSha256, tokens) -> {
      val entries: List[JsonEntry] = newList()
      entries.add(jstr("model", model))
      entries.add(jstr("text_sha256", textSha256))
      val tokenEntries: List[JsonEntry] = newList()
      tokenEntries.add(JsonEntry(key = "in", value = JInt(value = tokens.tokensIn)))
      tokenEntries.add(JsonEntry(key = "out", value = JInt(value = tokens.tokensOut)))
      entries.add(JsonEntry(key = "tokens", value = JObject(entries = tokenEntries)))
      JObject(entries = entries)
    }
    case ToolUseBody(tool, inputSha256, outputSha256, permission) -> {
      val entries: List[JsonEntry] = newList()
      entries.add(jstr("tool", tool))
      entries.add(jstr("input_sha256", inputSha256))
      entries.add(jstr("output_sha256", outputSha256))
      entries.add(jstr("permission", permissionName(permission)))
      JObject(entries = entries)
    }
    case FileChangeBody(files) -> {
      val items: List[JsonValue] = newList()
      var i = 0
      while i < files.count {
        items.add(encodeFileDelta(files[i]))
        i = i + 1
      }
      val entries: List[JsonEntry] = newList()
      entries.add(JsonEntry(key = "files", value = JArray(items = items)))
      JObject(entries = entries)
    }
    case NoteBody(text) -> {
      val entries: List[JsonEntry] = newList()
      entries.add(jstr("text", text))
      JObject(entries = entries)
    }
  }
}

func encodeFileDelta(file: in FileDelta): JsonValue {
  val entries: List[JsonEntry] = newList()
  entries.add(jstr("path", file.path))
  match file.beforeSha256 {
    case Some(h) -> entries.add(jstr("before_sha256", h))
    case None -> ()
  }
  match file.afterSha256 {
    case Some(h) -> entries.add(jstr("after_sha256", h))
    case None -> ()
  }
  val hunkItems: List[JsonValue] = newList()
  var i = 0
  while i < file.hunks.count {
    val hunkEntries: List[JsonEntry] = newList()
    hunkEntries.add(JsonEntry(key = "start", value = JInt(value = file.hunks[i].start)))
    hunkEntries.add(JsonEntry(key = "lines", value = JInt(value = file.hunks[i].lines)))
    hunkItems.add(JObject(entries = hunkEntries))
    i = i + 1
  }
  entries.add(JsonEntry(key = "hunks", value = JArray(items = hunkItems)))
  return JObject(entries = entries)
}

/// Encode a `Step` to its `JsonValue` form (spec §2.2). The wire `kind` is
/// derived from the body case, so kind and body can never disagree.
pub func encodeStep(step: in Step): JsonValue {
  val entries: List[JsonEntry] = newList()
  entries.add(jstr("schema", stepSchema()))
  entries.add(jstr("session", step.session))
  val parentItems: List[JsonValue] = newList()
  var i = 0
  while i < step.parents.count {
    parentItems.add(JString(value = step.parents[i]))
    i = i + 1
  }
  entries.add(JsonEntry(key = "parents", value = JArray(items = parentItems)))
  entries.add(jstr("kind", stepKindName(step.body)))
  entries.add(JsonEntry(key = "origin", value = encodeOrigin(step.origin)))
  entries.add(jstr("at", step.at))
  entries.add(JsonEntry(key = "body", value = encodeBody(step.body)))
  entries.add(JsonEntry(key = "redactions", value = JInt(value = step.redactions)))
  return JObject(entries = entries)
}

/// Encode a checkpoint's HASHED BODY (spec §2.6 minus `signature`, per
/// §3.7). This is the value whose canonical bytes are hashed for the
/// checkpoint's ID and signed by a `Signer` — the `Checkpoint` record has
/// no signature field, so one cannot leak in. For the full wire object use
/// `encodeCheckpointEnvelope`.
pub func encodeCheckpoint(checkpoint: in Checkpoint): JsonValue {
  val entries: List[JsonEntry] = newList()
  entries.add(jstr("schema", checkpointSchema()))
  entries.add(jstr("session", checkpoint.session))
  val stepItems: List[JsonValue] = newList()
  var i = 0
  while i < checkpoint.steps.count {
    stepItems.add(JString(value = checkpoint.steps[i]))
    i = i + 1
  }
  entries.add(JsonEntry(key = "steps", value = JArray(items = stepItems)))
  entries.add(jstr("tree", checkpoint.tree))
  match checkpoint.parent {
    case Some(p) -> entries.add(jstr("parent", p))
    case None -> ()
  }
  entries.add(jstr("at", checkpoint.at))
  return JObject(entries = entries)
}

/// Encode the full checkpoint wire object: the hashed body plus, when
/// present, the `signature` field. Signature encoding goes through
/// `Sign.encodeSignature`, so a signature that has no wire form — the
/// test-only scheme, non-canonical base64 — is a typed `BadSignature`
/// error here rather than silently emitted.
pub func encodeCheckpointEnvelope(envelope: in CheckpointEnvelope): Result[JsonValue, ModelError] {
  val body = encodeCheckpoint(envelope.checkpoint)
  return match envelope.signature {
    case None -> Ok(value = body)
    case Some(sig) -> {
      val fragment = match encodeSignature(sig) {
        case Ok(f) -> f
        case Err(e) -> return Err(error = BadSignature(message = signatureErrorMessage(e), at = "$.signature"))
      }
      val sigValue = match parse(fragment) {
        case Ok(sv) -> sv
        case Err(e) -> return Err(
          error = BadSignature(
            message = "signature fragment did not re-parse: " + canonErrorMessage(e),
            at = "$.signature"
          )
        )
      }
      match body {
        case JObject(entries) -> {
          entries.add(JsonEntry(key = "signature", value = sigValue))
          Ok(value = JObject(entries = entries))
        }
        case _ -> panic("encodeCheckpoint always returns an object")
      }
    }
  }
}

/// Encode any `ProvenanceObject` to its full wire `JsonValue`. Sessions and
/// steps always encode; a checkpoint envelope inherits
/// `encodeCheckpointEnvelope`'s signature strictness.
pub func encodeObject(obj: in ProvenanceObject): Result[JsonValue, ModelError] {
  return match obj {
    case SessionObject(session) -> Ok(value = encodeSession(session))
    case StepObject(step) -> Ok(value = encodeStep(step))
    case CheckpointObject(envelope) -> encodeCheckpointEnvelope(envelope)
  }
}
