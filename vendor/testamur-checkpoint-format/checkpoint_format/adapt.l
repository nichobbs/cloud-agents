//! Testamur.CheckpointFormat.Adapt — the capture adapter interface and the
//! two fixture-scoped readers (docs/specs/checkpoint-format.md §6, §6.1,
//! §6.3-mapping; acceptance criteria §8.3 and §8.5).
//!
//! ## The `Stream[ProvenanceObject]` representation
//!
//! Spec §6 writes the adapter read operation as `read(): Stream[Provenance-
//! Object]`. Lyric has no lazy generator/stream type usable at an interface
//! boundary here, so the stream is represented as an ORDERED
//! `List[Model.ProvenanceObject]` (wrapped in `Result` for typed adapter
//! failures): the list's element order IS the stream order, and the
//! normative dependency-order rule below applies to it verbatim. This is a
//! representation choice only — a future pull-based stream can layer on the
//! same interface without changing the contract.
//!
//! ## Normative adapter requirements (spec §6 — these bind every adapter)
//!
//! 1. **Dependency order.** Objects are emitted parents-before-children: a
//!    session before its steps, a step after its session and its parent
//!    steps, a checkpoint after its session, its frontier steps, and its
//!    parent checkpoint. `ingest` REJECTS forward references with a typed
//!    `ForwardReference` error rather than buffering.
//! 2. **Honest origins.** Adapters never fabricate attribution: an origin is
//!    typed `human`/`agent` only where the captured record says so;
//!    adapter-injected steps (notes) carry `origin.type: "tool"` — the
//!    adapter itself — and no model claim.
//! 3. **Redact before encode.** The redaction hook point applies before
//!    hashing (spec §2.2 `redactions`). No redaction detectors exist yet
//!    (spec §9), so every step this package emits carries `redactions: 0` —
//!    honestly meaning "nothing was elided", never "nothing was scanned
//!    silently dropped".
//! 4. **Gaps become `note` steps, never silence.** Every captured record
//!    that cannot be mapped to `prompt`/`response`/`tool_use`/`file_change`
//!    becomes a `note` step carrying the raw payload's SHA-256; a
//!    `tool_use` with no captured `tool_result` is flushed with an
//!    all-zero-content output hash plus an explicit "capture gap" note.
//!    Mapping summaries report mapped vs note-wrapped counts, and the two
//!    MUST sum to the total event count (§8.5: no silent drops).
//!
//! ## Timestamp policy (explicit, per the fixture consumer notes)
//!
//! Timestamps are DATA: this package never reads the wall clock. All
//! emitted timestamps are RFC 3339 UTC truncated to second precision
//! (`truncateTimestamp`) — truncation is monotone, so the chain's
//! non-decreasing invariant survives it, and it normalises the mixed
//! precisions found in the wild (milliseconds in Claude Code transcripts,
//! nanoseconds in Entire metadata) to the spec's §2.1 precision. Events
//! that carry no timestamp (most stream-json system events) inherit the
//! last-seen event timestamp; events before any timestamped event inherit
//! the session's `startedAt` (from invocation context or the first
//! transcript event).
//!
//! ## Event → step mapping (shared by both readers)
//!
//! | Captured record                          | Step kind |
//! |------------------------------------------|-----------|
//! | `user` event with string content         | `prompt` (origin: human) |
//! | `assistant` `text` content block         | `response` (origin: agent + model; body hashes the text) |
//! | `assistant` `tool_use` block + its later `tool_result` | one `tool_use` step, emitted when the result arrives (input and output hashes) |
//! | `tool_result` with no matching `tool_use`| `note` |
//! | any other event / block / unparseable line | `note` with the raw payload hash |
//!
//! The cloud-agents runner's user prompt is NOT an event in `-p` mode — it
//! is synthesized from `InvocationContext` as the session's root step.
//!
//! Tool-use `permission` is taken from the invocation context for the
//! runner adapter (`auto` for auto-approved allowlists); the Entire reader
//! uses `auto` — the least-claiming closed-set value for a reconstructed
//! record that carries no permission evidence (claiming `granted` would
//! assert an explicit human grant the record does not show).
//!
//! ## FFI note
//!
//! Chain's SHA-256 helpers are package-private, so this package carries its
//! own two static BCL bindings (the cloud-agents `src/crypto/crypto.l`
//! pattern, same as chain.l); UTF-8 byte conversion reuses the public
//! `Sign.utf8Bytes`. Foreign-format JSON (stream-json lines, Claude Code
//! transcripts, Entire metadata) is parsed with `Std.Json` directly — NOT
//! with `Canon.parse`, which rightly rejects the `null`s and floats those
//! formats legitimately contain.
@runtime_checked
package Testamur.CheckpointFormat.Adapt

import Std.Char
import Std.Collections
import Std.Core
import Std.File
import Std.Json
import Testamur.CheckpointFormat.Chain
import Testamur.CheckpointFormat.Model
import Testamur.CheckpointFormat.Sign

@externTarget("System.Security.Cryptography.SHA256.HashData")
func sha256(data: in slice[Byte]): slice[Byte] = []

@externTarget("System.Convert.ToHexStringLower")
func toHexLower(b: in slice[Byte]): String = ""

// ─── Errors ────────────────────────────────────────────────────────────────
/// Typed adapter/ingest failures. Every case names the offending path or
/// object id; `MalformedInput.line` is 0 when the problem is not tied to a
/// specific line.
pub union AdaptError {
  case ReadFailed(path: String, message: String)
  case MalformedInput(path: String, line: Int, message: String)
  case ForwardReference(objectId: String, missing: String)
}

/// Human-readable rendering of an `AdaptError`.
pub func adaptErrorMessage(e: in AdaptError): String {
  return match e {
    case ReadFailed(path, message) -> "cannot read " + path + ": " + message
    case MalformedInput(path, line, message) -> "malformed input at " + path + (if line > 0 then " line " + toString(line) else "") + ": " + message
    case ForwardReference(objectId, missing) -> "object " + objectId + " references " + missing + " before it was emitted (adapters must emit parents before children, spec §6 rule 1)"
  }
}

// ─── Small shared helpers ──────────────────────────────────────────────────
/// Lowercase-hex SHA-256 of a string's UTF-8 bytes — the hash used for
/// response texts, tool inputs/outputs, and note payload hashes. Public so
/// tests can recompute expected body hashes without their own FFI binding.
pub func sha256Hex(text: in String): String {
  return toHexLower(sha256(utf8Bytes(text)))
}

/// Truncate an RFC 3339 UTC timestamp to second precision: everything from
/// the first `.` on is replaced by the trailing `Z` (assumes UTC `Z`
/// suffix, which every supported capture format uses). Truncation is
/// monotone, so it preserves the chain's non-decreasing timestamp
/// invariant. Timestamps without a fractional part pass through unchanged.
pub func truncateTimestamp(ts: in String): String {
  var i = 0
  while i < ts.length {
    if ts[i] == '.' {
      return ts.substring(0, i) + "Z"
    }
    i = i + 1
  }
  return ts
}

/// Split text into lines on `\n`, stripping one trailing `\r` per line
/// (CRLF input) and dropping a final empty segment when the text ends with
/// a newline. Interior empty lines are KEPT (they are payload for
/// line-numbered formats).
pub func splitLines(text: in String): List[String] {
  val lines: List[String] = newList()
  val n = text.length
  var start = 0
  var i = 0
  while i < n {
    if text[i] == '\n' {
      lines.add(chopCr(text.substring(start, i - start)))
      start = i + 1
    }
    i = i + 1
  }
  if start < n {
    lines.add(chopCr(text.substring(start, n - start)))
  }
  return lines
}

func chopCr(s: in String): String {
  val n = s.length
  if n > 0 {
    if s[n - 1] == '\r' {
      return s.substring(0, n - 1)
    }
  }
  return s
}

func hasPrefix(s: in String, prefix: in String): Bool {
  val n = s.length.toInt()
  val m = prefix.length.toInt()
  if m > n {
    return false
  }
  return s.substring(0, m) == prefix
}

func suffixAfter(s: in String, prefix: in String): String {
  val n = s.length.toInt()
  val m = prefix.length.toInt()
  return s.substring(m, n - m)
}

func allDigits(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    val code = toInt(s[i])
    if code < 48 or code > 57 {
      return false
    }
    i = i + 1
  }
  return true
}

func baseName(path: in String): String {
  var i = path.length - 1
  while i >= 0 {
    if path[i] == '/' {
      return path.substring(i + 1, path.length - i - 1)
    }
    i = i - 1
  }
  return path
}

func indexOfString(items: in List[String], needle: in String): Int {
  var i = 0
  while i < items.count {
    if items[i] == needle {
      return i
    }
    i = i + 1
  }
  return -1
}

// Insertion sort on strings in strict UTF-8 byte order (Chain.idLess), the
// same rebuild-on-insert shape as Canon's key sorter.
func sortNames(names: in List[String]): List[String] {
  var sorted: List[String] = newList()
  var i = 0
  while i < names.count {
    val name = names[i]
    val next: List[String] = newList()
    var j = 0
    var inserted = false
    while j < sorted.count {
      if not inserted and idLess(name, sorted[j]) {
        next.add(name)
        inserted = true
      }
      next.add(sorted[j])
      j = j + 1
    }
    if not inserted {
      next.add(name)
    }
    sorted = next
    i = i + 1
  }
  return sorted
}

func readFileText(path: in String): Result[String, AdaptError] {
  return match Std.File.readText(path) {
    case Ok(text) -> Ok(value = text)
    case Err(_) -> Err(error = ReadFailed(path = path, message = "cannot read file"))
  }
}

func listDirNames(path: in String): Result[List[String], AdaptError] {
  val paths = match Std.File.listDirs(path) {
    case Ok(entries) -> entries
    case Err(_) -> return Err(error = ReadFailed(path = path, message = "cannot list directory"))
  }
  val names: List[String] = newList()
  var i = 0
  while i < paths.count {
    names.add(baseName(paths[i]))
    i = i + 1
  }
  return Ok(value = sortNames(names))
}

// ─── Capture adapter interface (spec §6) ───────────────────────────────────
/// A capture adapter (spec §6): declares its `CaptureSource` honestly and
/// yields provenance objects for the ingester. `read()` returns the spec's
/// `Stream[ProvenanceObject]` as an ORDERED list (see the module doc's
/// representation note); the list MUST satisfy the four normative adapter
/// requirements in the module doc — dependency order above all, since
/// `ingest` rejects forward references rather than reordering.
pub interface CaptureAdapter {
  /// Which adapter this is, its version, and its capture fidelity —
  /// honest metadata, never aspirational (spec §2.5).
  func source(): CaptureSource
  /// Produce the adapter's provenance objects in dependency order
  /// (parents before children). Failures are typed `AdaptError`s.
  func read(): Result[List[ProvenanceObject], AdaptError]
}

/// An adapter's `CaptureSource`, through the interface seam (the shape the
/// ingester and tests dispatch through).
pub func adapterSource(adapter: in CaptureAdapter): CaptureSource {
  return adapter.source()
}

/// An adapter's object stream, through the interface seam (see
/// `adapterSource`).
pub func adapterRead(adapter: in CaptureAdapter): Result[List[ProvenanceObject], AdaptError] {
  return adapter.read()
}

// ─── Ingester (spec §6 rule 1) ─────────────────────────────────────────────
/// What one `ingest` call did: the content addresses actually stored (in
/// ingest order, duplicates excluded), per-type counts, how many objects
/// were content-address duplicates of already-stored ones, and the
/// terminal checkpoints — checkpoints from this batch that no other
/// checkpoint in the batch names as `parent` (the chain heads to verify).
pub record IngestSummary {
  pub ids: List[String]
  pub sessions: Int
  pub steps: Int
  pub checkpoints: Int
  pub duplicates: Int
  pub terminalCheckpoints: List[String]
}

func requirePresent(store: in ObjectStore, refId: in String, objectId: in String): Result[Unit, AdaptError] {
  return match storeGet(store, refId) {
    case Some(_) -> Ok(value = ())
    case None -> Err(error = ForwardReference(objectId = objectId, missing = refId))
  }
}

/// Walk adapter output in stream order, storing each object under its
/// computed content address (`Chain.objectIdOf`). Enforces spec §6 rule 1:
/// every reference an object carries (a step's session and parents; a
/// checkpoint's session, frontier steps, and parent) must already resolve
/// in the store — earlier in this stream, or from a previous ingest into
/// the same store — else the walk stops with a typed `ForwardReference`.
/// An object whose id is already present is counted as a duplicate and not
/// re-stored (content-addressed: same id ⇒ same object).
pub func ingest(objects: in List[ProvenanceObject], store: in ObjectStore): Result[IngestSummary, AdaptError] {
  val ids: List[String] = newList()
  val ckptIds: List[String] = newList()
  val ckptParents: List[String] = newList()
  var sessions = 0
  var steps = 0
  var checkpoints = 0
  var duplicates = 0
  var i = 0
  while i < objects.count {
    val obj = objects[i]
    val id = objectIdOf(obj)
    match obj {
      case SessionObject(_) -> ()
      case StepObject(step) -> {
        requirePresent(store, step.session, id)?
        var p = 0
        while p < step.parents.count {
          requirePresent(store, step.parents[p], id)?
          p = p + 1
        }
      }
      case CheckpointObject(envelope) -> {
        requirePresent(store, envelope.checkpoint.session, id)?
        var s = 0
        while s < envelope.checkpoint.steps.count {
          requirePresent(store, envelope.checkpoint.steps[s], id)?
          s = s + 1
        }
        match envelope.checkpoint.parent {
          case Some(parentId) -> requirePresent(store, parentId, id)?
          case None -> ()
        }
      }
    }
    match storeGet(store, id) {
      case Some(_) -> {
        duplicates = duplicates + 1
      }
      case None -> {
        storePut(store, id, obj)
        ids.add(id)
        match obj {
          case SessionObject(_) -> {
            sessions = sessions + 1
          }
          case StepObject(_) -> {
            steps = steps + 1
          }
          case CheckpointObject(envelope) -> {
            checkpoints = checkpoints + 1
            ckptIds.add(id)
            match envelope.checkpoint.parent {
              case Some(parentId) -> ckptParents.add(parentId)
              case None -> ()
            }
          }
        }
      }
    }
    i = i + 1
  }
  val terminal: List[String] = newList()
  var t = 0
  while t < ckptIds.count {
    if indexOfString(ckptParents, ckptIds[t]) < 0 {
      terminal.add(ckptIds[t])
    }
    t = t + 1
  }
  return Ok(
    value = IngestSummary(
      ids = ids,
      sessions = sessions,
      steps = steps,
      checkpoints = checkpoints,
      duplicates = duplicates,
      terminalCheckpoints = terminal
    )
  )
}

/// `adapterRead` + `ingest` in one seam: pull the adapter's stream and
/// ingest it into `store`.
pub func ingestFrom(adapter: in CaptureAdapter, store: in ObjectStore): Result[IngestSummary, AdaptError] {
  val objects = adapterRead(adapter)?
  return ingest(objects, store)
}

// ─── In-memory adapter (interface conformance vehicle) ─────────────────────
/// A trivial in-memory `CaptureAdapter` over a pre-built object list.
/// Lives here (not in a test module) because interface `impl` blocks must
/// be declared in the interface's own package on the current MSIL backend
/// (see sign.l's `Signer` note). Fields are package-private — construct
/// with `newListAdapter`.
pub record ListAdapter {
  src: CaptureSource
  objects: List[ProvenanceObject]
}

/// Construct a `ListAdapter` that declares `src` and yields `objects`
/// verbatim. The caller is responsible for the list being in dependency
/// order — the ingester will reject it otherwise, which is exactly what
/// the forward-reference tests exercise.
pub func newListAdapter(src: in CaptureSource, objects: in List[ProvenanceObject]): ListAdapter {
  return ListAdapter(src = src, objects = objects)
}

impl CaptureAdapter for ListAdapter {
  func source(): CaptureSource {
    return self.src
  }

  func read(): Result[List[ProvenanceObject], AdaptError] {
    return Ok(value = self.objects)
  }
}

// ─── Adapter identity constants ────────────────────────────────────────────
/// This package's adapter implementation version (the `adapter_version` it
/// stamps into every `CaptureSource` it emits).
pub func adaptVersion(): String {
  return "0.1.0"
}

/// The Entire ingestion adapter's `CaptureSource` (spec §6.1):
/// `adapter: "entire"`, `fidelity: reconstructed` — the record is derived
/// after the fact from an existing branch, and says so.
pub func entireSource(): CaptureSource {
  return CaptureSource(adapter = "entire", adapterVersion = adaptVersion(), fidelity = Reconstructed)
}

/// The cloud-agents runner adapter's `CaptureSource` (spec §6.3):
/// `adapter: "cloud-agents-runner"`, `fidelity: events` — the runner saw
/// structured stream-json events as they happened.
pub func runnerSource(): CaptureSource {
  return CaptureSource(adapter = "cloud-agents-runner", adapterVersion = adaptVersion(), fidelity = Events)
}

// ─── Shared transcript-event model ─────────────────────────────────────────
// One parsed line of a Claude Code-format event stream (`claude -p`
// stream-json or an Entire-captured session transcript). Parsing NEVER
// fails: an unparseable line becomes a `RawEvent` with kind
// "!unparseable", which the mapper turns into a note step — degraded but
// present beats absent (spec §6 rule 4).
union RawBlock {
  case TextBlock(text: String)
  case ToolUseBlock(toolUseId: String, tool: String, inputSha256: String)
  case ToolResultBlock(toolUseId: String, outputSha256: String)
  case UnknownBlock(payloadSha256: String, blockType: String)
}

record RawEvent {
  kind: String
  label: String
  timestamp: String
  cwd: String
  model: String
  tokensIn: Long
  tokensOut: Long
  hasPrompt: Bool
  promptText: String
  blocks: List[RawBlock]
  payloadSha256: String
}

func stringProp(elem: in JsonElement, name: in String): String {
  return match Std.Json.tryGetProperty(elem, name) {
    case Some(v) -> if Std.Json.valueKind(v) == 3 then Std.Json.getString(v) else ""
    case None -> ""
  }
}

func longProp(elem: in JsonElement, name: in String): Long {
  return match Std.Json.tryGetProperty(elem, name) {
    case Some(v) -> match Std.Json.tryGetLong(v) { case Some(n) -> n; case None -> 0.toLong() }
    case None -> 0.toLong()
  }
}

func rawProp(elem: in JsonElement, name: in String): String {
  return match Std.Json.tryGetProperty(elem, name) { case Some(v) -> Std.Json.getRawText(v); case None -> "" }
}

func unparseableEvent(payloadSha: in String): RawEvent {
  val blocks: List[RawBlock] = newList()
  return RawEvent(
    kind = "!unparseable",
    label = "unparseable-line",
    timestamp = "",
    cwd = "",
    model = "",
    tokensIn = 0.toLong(),
    tokensOut = 0.toLong(),
    hasPrompt = false,
    promptText = "",
    blocks = blocks,
    payloadSha256 = payloadSha
  )
}

// ── Ill-formed UTF-16 rejection (spec §3 / §6) ───────────────────────────────
// Untrusted transcript/metadata JSON can carry a lone/unpaired UTF-16
// surrogate escape (e.g. `"\ud800"`). `System.Text.Json` tokenises it but
// `getString`/`propertyName` THROW when materialising it — which, left
// unguarded, would crash the adapter mid-map (this package reads strings with
// `Std.Json.getString` directly, then feeds them to `Chain.*Id` /
// `encodeCanonical`, where a lone surrogate would hash to divergent bytes on
// .NET vs JVM). We probe every string of a document here, inside `try`/`catch`,
// so ingestion can reject the input as a typed `AdaptError` instead. Scanning
// the raw line string cannot catch this: a `\ud800` ESCAPE is plain ASCII in
// the line and only becomes a surrogate when JSON-decoded, so the probe must go
// through `getString` exactly as the real map would.
func jsonStringsWellFormed(elem: in JsonElement): Bool {
  val kind = Std.Json.valueKind(elem)
  if kind == 3 {
    return try {
      Std.Json.getString(elem).length.toInt() >= 0
    } catch Bug as b {
      false
    }
  }
  if kind == 2 {
    var cur = Std.Json.enumerateArray(elem)
    while Std.Json.arrayMoveNext(cur) {
      if not jsonStringsWellFormed(Std.Json.arrayCurrent(cur)) {
        return false
      }
    }
    return true
  }
  if kind == 1 {
    var cur = Std.Json.enumerateObject(elem)
    while Std.Json.objectMoveNext(cur) {
      val prop = Std.Json.objectCurrent(cur)
      val nameOk = try {
        Std.Json.propertyName(prop).length.toInt() >= 0
      } catch Bug as b {
        false
      }
      if not nameOk {
        return false
      }
      if not jsonStringsWellFormed(Std.Json.propertyValue(prop)) {
        return false
      }
    }
    return true
  }
  return true
}

// True when `text` is either not a single JSON document (a non-JSON line is
// mapped to a note later — no strings materialised, nothing to fault) or a JSON
// document all of whose string values and keys are well-formed UTF-16.
func jsonTextWellFormed(text: in String): Bool {
  val doc = match Std.Json.tryParseJson(text) { case Ok(d) -> d; case Err(_) -> return true }
  defer {
    Std.Json.disposeJson(doc)
  }
  return jsonStringsWellFormed(Std.Json.rootElement(doc))
}

// Reject the first line carrying ill-formed UTF-16 with a typed AdaptError.
func rejectIllFormedLines(lines: in List[String], path: in String): Result[Unit, AdaptError] {
  var i = 0
  while i < lines.count {
    if not jsonTextWellFormed(lines[i]) {
      return Err(
        error = MalformedInput(
          path = path,
          line = i + 1,
          message = "ill-formed UTF-16 (a lone or unpaired surrogate) in a JSON string; rejected before hashing so .NET and JVM stay byte-exact (spec §3)"
        )
      )
    }
    i = i + 1
  }
  return Ok(value = ())
}

func parseEvent(text: in String): RawEvent {
  val payloadSha = sha256Hex(text)
  val doc = match Std.Json.tryParseJson(text) { case Ok(d) -> d; case Err(_) -> return unparseableEvent(payloadSha) }
  defer {
    Std.Json.disposeJson(doc)
  }
  return eventOfRoot(Std.Json.rootElement(doc), payloadSha)
}

func eventOfRoot(root: in JsonElement, payloadSha: in String): RawEvent {
  val eventType = stringProp(root, "type")
  val subtype = stringProp(root, "subtype")
  val typeLabel = if eventType == "" then "untyped" else eventType
  val label = if subtype == "" then typeLabel else typeLabel + "/" + subtype
  val timestamp = stringProp(root, "timestamp")
  val cwd = stringProp(root, "cwd")
  var model = ""
  var tokensIn = 0.toLong()
  var tokensOut = 0.toLong()
  var hasPrompt = false
  var promptText = ""
  val blocks: List[RawBlock] = newList()
  match Std.Json.tryGetProperty(root, "message") {
    case None -> ()
    case Some(msg) -> {
      model = stringProp(msg, "model")
      match Std.Json.tryGetProperty(msg, "usage") {
        case Some(usage) -> {
          tokensIn = longProp(usage, "input_tokens")
          tokensOut = longProp(usage, "output_tokens")
        }
        case None -> ()
      }
      match Std.Json.tryGetProperty(msg, "content") {
        case None -> ()
        case Some(content) -> {
          val contentKind = Std.Json.valueKind(content)
          if contentKind == 3 {
            hasPrompt = true
            promptText = Std.Json.getString(content)
          }
          if contentKind == 2 {
            var cur = Std.Json.enumerateArray(content)
            while Std.Json.arrayMoveNext(cur) {
              blocks.add(blockOfElement(Std.Json.arrayCurrent(cur)))
            }
          }
        }
      }
    }
  }
  return RawEvent(
    kind = eventType,
    label = label,
    timestamp = timestamp,
    cwd = cwd,
    model = model,
    tokensIn = tokensIn,
    tokensOut = tokensOut,
    hasPrompt = hasPrompt,
    promptText = promptText,
    blocks = blocks,
    payloadSha256 = payloadSha
  )
}

// Tool inputs/outputs are hashed over the bytes actually captured: a
// string result hashes the string, anything structured hashes its raw JSON
// source text verbatim (`Std.Json.getRawText`) — deterministic for a given
// capture, no re-encoding of formats Canon cannot represent.
func blockOfElement(elem: in JsonElement): RawBlock {
  val blockType = stringProp(elem, "type")
  if blockType == "text" {
    return TextBlock(text = stringProp(elem, "text"))
  }
  if blockType == "tool_use" {
    return ToolUseBlock(
      toolUseId = stringProp(elem, "id"),
      tool = stringProp(elem, "name"),
      inputSha256 = sha256Hex(rawProp(elem, "input"))
    )
  }
  if blockType == "tool_result" {
    var outputSha = sha256Hex("")
    match Std.Json.tryGetProperty(elem, "content") {
      case Some(c) -> {
        outputSha = if Std.Json.valueKind(c) == 3 then sha256Hex(Std.Json.getString(c)) else sha256Hex(Std.Json.getRawText(c))
      }
      case None -> ()
    }
    return ToolResultBlock(toolUseId = stringProp(elem, "tool_use_id"), outputSha256 = outputSha)
  }
  return UnknownBlock(
    payloadSha256 = sha256Hex(Std.Json.getRawText(elem)),
    blockType = if blockType == "" then "unknown" else blockType
  )
}

func parseEventLines(lines: in List[String], from: in Int): List[RawEvent] {
  val events: List[RawEvent] = newList()
  var i = from
  while i < lines.count {
    events.add(parseEvent(lines[i]))
    i = i + 1
  }
  return events
}

// ─── Shared event → step mapper ────────────────────────────────────────────
record MapSettings {
  sessionId: String
  principalId: String
  fallbackModel: String
  permission: Permission
}

record MapCursor {
  lastStepId: String
  lastTs: String
  mapped: Int
  notes: Int
}

record PendingTool {
  sessionKey: String
  toolUseId: String
  tool: String
  inputSha256: String
  model: String
}

func emptyAttachments(): List[Attachment] {
  val attachments: List[Attachment] = newList()
  return attachments
}

func humanOrigin(principalId: in String): Origin {
  return Origin(kind = HumanOrigin, model = None, skill = None, sessionPrincipal = principalId)
}

func agentOrigin(model: in String, principalId: in String): Origin {
  // Explicitly-typed accumulator (W0004 — see model.l's decodeOrigin).
  var m: Option[String] = None
  if model != "" {
    m = Some(value = model)
  }
  return Origin(kind = AgentOrigin, model = m, skill = None, sessionPrincipal = principalId)
}

// Adapter-injected steps are the adapter's own words, and the adapter is a
// tool — origin type "tool", no model claim (spec §6 rule 2).
func noteOrigin(principalId: in String): Origin {
  return Origin(kind = ToolOrigin, model = None, skill = None, sessionPrincipal = principalId)
}

func chainStep(
  objects: in List[ProvenanceObject],
  sessionId: in String,
  parentId: in String,
  origin: in Origin,
  at: in String,
  body: in StepBody,
): String {
  val parents: List[String] = newList()
  if parentId != "" {
    parents.add(parentId)
  }
  val step = Step(
    session = sessionId,
    parents = parents,
    origin = origin,
    at = at,
    body = body,
    redactions = 0.toLong()
  )
  val id = stepIdOf(step)
  objects.add(StepObject(step = step))
  return id
}

func chainNote(
  objects: in List[ProvenanceObject],
  settings: in MapSettings,
  parentId: in String,
  at: in String,
  text: in String,
): String {
  return chainStep(objects, settings.sessionId, parentId, noteOrigin(settings.principalId), at, NoteBody(text = text))
}

func appendKind(current: in String, kind: in String): String {
  return if current == "" then kind else current + "+" + kind
}

func findPendingIndex(
  pending: in List[PendingTool],
  resolved: in List[String],
  sessionKey: in String,
  toolUseId: in String,
): Int {
  var i = 0
  while i < pending.count {
    if pending[i].sessionKey == sessionKey and pending[i].toolUseId == toolUseId and not listContains(resolved, toolUseId) {
      return i
    }
    i = i + 1
  }
  return -1
}

// The shared event mapper: appends steps to `objects` (linearly chained —
// each step's parent is the previously emitted step of the same session)
// and one kind label per event to `eventKinds`. Every event lands in
// exactly one summary bucket: `mapped` if it produced or registered at
// least one prompt/response/tool_use, else `notes` — so mapped + notes
// always equals the number of events processed (spec §8.5's accounting).
func mapEvents(
  events: in List[RawEvent],
  settings: in MapSettings,
  cursorIn: in MapCursor,
  pending: in List[PendingTool],
  resolved: in List[String],
  sessionKey: in String,
  objects: in List[ProvenanceObject],
  eventKinds: in List[String],
): MapCursor {
  var lastStepId = cursorIn.lastStepId
  var lastTs = cursorIn.lastTs
  var mapped = cursorIn.mapped
  var notes = cursorIn.notes
  var i = 0
  while i < events.count {
    val e = events[i]
    var ts = lastTs
    if e.timestamp != "" {
      ts = truncateTimestamp(e.timestamp)
    }
    var kindsLabel = ""
    var producedMapped = false
    if e.kind == "user" and e.hasPrompt {
      lastStepId = chainStep(
        objects,
        settings.sessionId,
        lastStepId,
        humanOrigin(settings.principalId),
        ts,
        PromptBody(text = e.promptText, attachments = emptyAttachments())
      )
      kindsLabel = "prompt"
      producedMapped = true
    } else if e.blocks.count > 0 {
      var b = 0
      while b < e.blocks.count {
        match e.blocks[b] {
          case TextBlock(text) -> {
            val eventModel = if e.model != "" then e.model else settings.fallbackModel
            lastStepId = chainStep(
              objects,
              settings.sessionId,
              lastStepId,
              agentOrigin(eventModel, settings.principalId),
              ts,
              ResponseBody(
                model = eventModel,
                textSha256 = sha256Hex(text),
                tokens = TokenUsage(tokensIn = e.tokensIn, tokensOut = e.tokensOut)
              )
            )
            kindsLabel = appendKind(kindsLabel, "response")
            producedMapped = true
          }
          case ToolUseBlock(toolUseId, tool, inputSha256) -> {
            pending.add(
              PendingTool(
                sessionKey = sessionKey,
                toolUseId = toolUseId,
                tool = tool,
                inputSha256 = inputSha256,
                model = if e.model != "" then e.model else settings.fallbackModel
              )
            )
            kindsLabel = appendKind(kindsLabel, "tool_use")
            producedMapped = true
          }
          case ToolResultBlock(toolUseId, outputSha256) -> {
            val idx = findPendingIndex(pending, resolved, sessionKey, toolUseId)
            if idx >= 0 {
              val p = pending[idx]
              lastStepId = chainStep(
                objects,
                settings.sessionId,
                lastStepId,
                agentOrigin(p.model, settings.principalId),
                ts,
                ToolUseBody(
                  tool = p.tool,
                  inputSha256 = p.inputSha256,
                  outputSha256 = outputSha256,
                  permission = settings.permission
                )
              )
              resolved.add(toolUseId)
              kindsLabel = appendKind(kindsLabel, "tool_use")
              producedMapped = true
            } else {
              lastStepId = chainNote(
                objects,
                settings,
                lastStepId,
                ts,
                "unmatched tool_result for tool_use \"" + toolUseId + "\" (payload sha256:" + e.payloadSha256 + ")"
              )
              kindsLabel = appendKind(kindsLabel, "note")
            }
          }
          case UnknownBlock(payloadSha256, blockType) -> {
            lastStepId = chainNote(
              objects,
              settings,
              lastStepId,
              ts,
              "unmappable \"" + blockType + "\" content block (payload sha256:" + payloadSha256 + ")"
            )
            kindsLabel = appendKind(kindsLabel, "note")
          }
        }
        b = b + 1
      }
    } else {
      lastStepId = chainNote(
        objects,
        settings,
        lastStepId,
        ts,
        "unmappable \"" + e.label + "\" event (payload sha256:" + e.payloadSha256 + ")"
      )
      kindsLabel = "note"
    }
    if producedMapped {
      mapped = mapped + 1
    } else {
      notes = notes + 1
    }
    eventKinds.add(kindsLabel)
    if e.timestamp != "" {
      lastTs = ts
    }
    i = i + 1
  }
  return MapCursor(lastStepId = lastStepId, lastTs = lastTs, mapped = mapped, notes = notes)
}

// End-of-stream flush (spec §6 rule 4): every registered tool_use that
// never saw its tool_result is emitted anyway — output hash of the empty
// string, `permission` as configured — followed by an explicit "capture
// gap" note step, so the gap is a record, not silence.
func flushPending(
  pending: in List[PendingTool],
  resolved: in List[String],
  settings: in MapSettings,
  cursorIn: in MapCursor,
  sessionKey: in String,
  objects: in List[ProvenanceObject],
): MapCursor {
  var lastStepId = cursorIn.lastStepId
  var i = 0
  while i < pending.count {
    val p = pending[i]
    if p.sessionKey == sessionKey and not listContains(resolved, p.toolUseId) {
      lastStepId = chainStep(
        objects,
        settings.sessionId,
        lastStepId,
        agentOrigin(p.model, settings.principalId),
        cursorIn.lastTs,
        ToolUseBody(
          tool = p.tool,
          inputSha256 = p.inputSha256,
          outputSha256 = sha256Hex(""),
          permission = settings.permission
        )
      )
      lastStepId = chainNote(
        objects,
        settings,
        lastStepId,
        cursorIn.lastTs,
        "capture gap: tool_use \"" + p.toolUseId + "\" has no tool_result in the captured stream"
      )
      resolved.add(p.toolUseId)
    }
    i = i + 1
  }
  return MapCursor(lastStepId = lastStepId, lastTs = cursorIn.lastTs, mapped = cursorIn.mapped, notes = cursorIn.notes)
}

// ─── Entire ingestion reader (spec §6.1) ───────────────────────────────────
/// The result of one `readEntire` walk: the full object stream in
/// dependency order plus the derived session and checkpoint content
/// addresses (in emission order) and the event accounting.
pub record EntireIngestion {
  pub objects: List[ProvenanceObject]
  pub sessionIds: List[String]
  pub checkpointIds: List[String]
  pub mappedEvents: Int
  pub noteEvents: Int
}

record EntireSessionMeta {
  sessionKey: String
  createdAt: String
  agent: String
  model: String
  transcriptStart: Int
}

record CkptWork {
  entireId: String
  meta: EntireSessionMeta
  cwd: String
  firstEventTs: String
  newEvents: List[RawEvent]
}

record EntireScan {
  works: List[CkptWork]
  trailerIds: List[String]
  workTrees: List[String]
}

func parseEntireSessionMeta(text: in String, path: in String): Result[EntireSessionMeta, AdaptError] {
  val doc = match Std.Json.tryParseJson(text) {
    case Ok(d) -> d
    case Err(m) -> return Err(error = MalformedInput(path = path, line = 0, message = "not valid JSON: " + m))
  }
  defer {
    Std.Json.disposeJson(doc)
  }
  val root = Std.Json.rootElement(doc)
  val sessionKey = stringProp(root, "session_id")
  if sessionKey == "" {
    return Err(error = MalformedInput(path = path, line = 0, message = "missing session_id"))
  }
  val createdAt = stringProp(root, "created_at")
  if createdAt == "" {
    return Err(error = MalformedInput(path = path, line = 0, message = "missing created_at"))
  }
  val agent = stringProp(root, "agent")
  val model = stringProp(root, "model")
  // `omitempty` upstream: an absent checkpoint_transcript_start means 0
  // (the checkpoint owns the transcript from its beginning).
  var start = 0
  match Std.Json.tryGetProperty(root, "checkpoint_transcript_start") {
    case Some(v) -> match Std.Json.tryGetInt(v) { case Some(n) -> { start = n }; case None -> return Err(error = MalformedInput(path = path, line = 0, message = "checkpoint_transcript_start is not an integer")) }
    case None -> ()
  }
  if start < 0 {
    return Err(error = MalformedInput(path = path, line = 0, message = "checkpoint_transcript_start is negative"))
  }
  return Ok(
    value = EntireSessionMeta(
      sessionKey = sessionKey,
      createdAt = createdAt,
      agent = agent,
      model = model,
      transcriptStart = start
    )
  )
}

func commitTreeHash(lines: in List[String]): String {
  if lines.count > 0 {
    if hasPrefix(lines[0], "tree ") {
      return suffixAfter(lines[0], "tree ")
    }
  }
  return ""
}

func commitSubject(lines: in List[String]): String {
  var i = 0
  while i < lines.count {
    if lines[i] == "" {
      if i + 1 < lines.count {
        return lines[i + 1]
      }
      return ""
    }
    i = i + 1
  }
  return ""
}

func trailerValue(lines: in List[String], key: in String): String {
  val prefix = key + ": "
  var i = 0
  while i < lines.count {
    if hasPrefix(lines[i], prefix) {
      return suffixAfter(lines[i], prefix)
    }
    i = i + 1
  }
  return ""
}

// Pass A: walk the unpacked tree, collecting per-checkpoint work items
// (metadata-branch order) and the work-commit trailer → tree-hash links.
// Checkpoint ids are treated as opaque strings sharded `<id[:2]>/<id[2:]>`
// — both legacy 12-hex and 26-char ULID ids satisfy that (never hard-code
// 12-hex, per the fixture consumer notes).
func scanEntire(root: in String): Result[EntireScan, AdaptError] {
  val works: List[CkptWork] = newList()
  val trailerIds: List[String] = newList()
  val workTrees: List[String] = newList()

  val workRoot = root + "/main"
  val workNames = listDirNames(workRoot)?
  var w = 0
  while w < workNames.count {
    val commitPath = workRoot + "/" + workNames[w] + "/COMMIT.txt"
    val commitText = readFileText(commitPath)?
    val commitLines = splitLines(commitText)
    val ckptId = trailerValue(commitLines, "Entire-Checkpoint")
    if ckptId != "" {
      val tree = commitTreeHash(commitLines)
      if tree == "" {
        return Err(error = MalformedInput(path = commitPath, line = 1, message = "missing tree header"))
      }
      trailerIds.add(ckptId)
      workTrees.add(tree)
    }
    w = w + 1
  }

  val metaRoot = root + "/entire-checkpoints-v1"
  val commitNames = listDirNames(metaRoot)?
  var c = 0
  while c < commitNames.count {
    val commitDir = metaRoot + "/" + commitNames[c]
    val commitPath = commitDir + "/COMMIT.txt"
    val commitText = readFileText(commitPath)?
    val subject = commitSubject(splitLines(commitText))
    if hasPrefix(subject, "Checkpoint: ") {
      val entireId = suffixAfter(subject, "Checkpoint: ")
      if entireId.length.toInt() <= 2 {
        return Err(
          error = MalformedInput(
            path = commitPath,
            line = 0,
            message = "checkpoint id \"" + entireId + "\" is too short to shard"
          )
        )
      }
      val shard = entireId.substring(0, 2)
      val rest = entireId.substring(2, entireId.length.toInt() - 2)
      val base = commitDir + "/tree/" + shard + "/" + rest
      val sessionDirs = listDirNames(base)?
      var d = 0
      while d < sessionDirs.count {
        if allDigits(sessionDirs[d]) and sessionDirs[d] != "0" {
          return Err(
            error = MalformedInput(
              path = base,
              line = 0,
              message = "multi-session checkpoints are not supported by this reader (found session dir \"" +
                sessionDirs[d] +
                "\")"
            )
          )
        }
        d = d + 1
      }
      val metaPath = base + "/0/metadata.json"
      val metaText = readFileText(metaPath)?
      // Reject ill-formed UTF-16 in the metadata and transcript before any
      // string is materialised into the model (spec §3; see
      // `jsonStringsWellFormed`).
      if not jsonTextWellFormed(metaText) {
        return Err(
          error = MalformedInput(
            path = metaPath,
            line = 0,
            message = "ill-formed UTF-16 (a lone or unpaired surrogate) in the session metadata (spec §3)"
          )
        )
      }
      val meta = parseEntireSessionMeta(metaText, metaPath)?
      val fullPath = base + "/0/full.jsonl"
      val fullText = readFileText(fullPath)?
      val transcriptLines = splitLines(fullText)
      rejectIllFormedLines(transcriptLines, fullPath)?
      if meta.transcriptStart > transcriptLines.count {
        return Err(
          error = MalformedInput(
            path = fullPath,
            line = meta.transcriptStart,
            message = "checkpoint_transcript_start is beyond the transcript's " +
              toString(transcriptLines.count) +
              " lines"
          )
        )
      }
      val newEvents = parseEventLines(transcriptLines, meta.transcriptStart)
      var cwd = ""
      var firstEventTs = ""
      if newEvents.count > 0 {
        cwd = newEvents[0].cwd
        if newEvents[0].timestamp != "" {
          firstEventTs = truncateTimestamp(newEvents[0].timestamp)
        }
      }
      works.add(CkptWork(entireId = entireId, meta = meta, cwd = cwd, firstEventTs = firstEventTs, newEvents = newEvents))
    }
    c = c + 1
  }
  return Ok(value = EntireScan(works = works, trailerIds = trailerIds, workTrees = workTrees))
}

/// Read a `fixtures/entire-v1/unpacked/`-shaped directory tree (plain
/// files, no git invocation — spec §6.1 fixture scope) and map it to the
/// provenance model, in dependency order:
///
/// - each `Checkpoint: <id>` commit on the metadata branch becomes a spec
///   `Checkpoint`, its `parent` the previous metadata-branch checkpoint of
///   the same session, its `at` the session metadata's `created_at`
///   (truncated), and its `tree` the WORK commit's tree hash — found via
///   the `Entire-Checkpoint` trailer in `main/<NN>-*/COMMIT.txt`, never
///   the metadata-branch tree;
/// - one `Session` is synthesized per Entire session (`session_id`),
///   `fidelity: reconstructed`, `adapter: "entire"`, principal derived
///   from the `agent` field, workspace from the transcript's `cwd`,
///   `started_at` from the first transcript event;
/// - steps come from each checkpoint's `full.jsonl` slice
///   (`checkpoint_transcript_start` onward — the branch is append-only, so
///   earlier lines belong to earlier checkpoints), mapped per the module
///   doc's table; each checkpoint's frontier is its last emitted step.
///
/// Unmappable records become note steps with the raw payload hash; nothing
/// is silently dropped (spec §6 rule 4).
pub func readEntire(root: in String): Result[EntireIngestion, AdaptError] {
  val scan = scanEntire(root)?
  val objects: List[ProvenanceObject] = newList()
  val sessionIds: List[String] = newList()
  val checkpointIds: List[String] = newList()
  val kindsScratch: List[String] = newList()
  val pending: List[PendingTool] = newList()
  val resolved: List[String] = newList()
  var totalMapped = 0
  var totalNotes = 0

  // Distinct sessions in first-seen (metadata-branch) order.
  val sessionKeys: List[String] = newList()
  var s = 0
  while s < scan.works.count {
    if indexOfString(sessionKeys, scan.works[s].meta.sessionKey) < 0 {
      sessionKeys.add(scan.works[s].meta.sessionKey)
    }
    s = s + 1
  }

  var k = 0
  while k < sessionKeys.count {
    val key = sessionKeys[k]
    // The session's first checkpoint provides the synthesis inputs.
    var firstIdx = -1
    var w = 0
    while w < scan.works.count {
      if firstIdx < 0 and scan.works[w].meta.sessionKey == key {
        firstIdx = w
      }
      w = w + 1
    }
    val first = scan.works[firstIdx]
    val agent = if first.meta.agent != "" then first.meta.agent else "unknown"
    val principalId = "agent:" + agent
    var display: Option[String] = None
    if first.meta.agent != "" {
      display = Some(value = first.meta.agent)
    }
    val startedAt = if first.firstEventTs != "" then first.firstEventTs else truncateTimestamp(first.meta.createdAt)
    val workspace = if first.cwd != "" then first.cwd else "entire:unknown-workspace"
    val session = Session(
      principal = Principal(kind = AgentPrincipal, id = principalId, display = display),
      workspace = workspace,
      taskRef = None,
      startedAt = startedAt,
      capture = entireSource()
    )
    val sessionId = sessionIdOf(session)
    objects.add(SessionObject(session = session))
    sessionIds.add(sessionId)

    val settings = MapSettings(
      sessionId = sessionId,
      principalId = principalId,
      fallbackModel = first.meta.model,
      permission = Auto
    )
    var cursor = MapCursor(lastStepId = "", lastTs = startedAt, mapped = 0, notes = 0)
    var prevCkptId = ""
    var i = 0
    while i < scan.works.count {
      val work = scan.works[i]
      if work.meta.sessionKey == key {
        cursor = mapEvents(work.newEvents, settings, cursor, pending, resolved, key, objects, kindsScratch)
        val frontier: List[String] = newList()
        if cursor.lastStepId != "" {
          frontier.add(cursor.lastStepId)
        }
        val treeIdx = indexOfString(scan.trailerIds, work.entireId)
        if treeIdx < 0 {
          return Err(
            error = MalformedInput(
              path = root + "/main",
              line = 0,
              message = "no work commit carries trailer Entire-Checkpoint: " + work.entireId
            )
          )
        }
        var parent: Option[String] = None
        if prevCkptId != "" {
          parent = Some(value = prevCkptId)
        }
        val checkpoint = Checkpoint(
          session = sessionId,
          steps = frontier,
          tree = scan.workTrees[treeIdx],
          parent = parent,
          at = truncateTimestamp(work.meta.createdAt)
        )
        val ckptId = checkpointIdOf(checkpoint)
        objects.add(CheckpointObject(envelope = CheckpointEnvelope(checkpoint = checkpoint, signature = None)))
        checkpointIds.add(ckptId)
        prevCkptId = ckptId
      }
      i = i + 1
    }
    cursor = flushPending(pending, resolved, settings, cursor, key, objects)
    totalMapped = totalMapped + cursor.mapped
    totalNotes = totalNotes + cursor.notes
    k = k + 1
  }

  return Ok(
    value = EntireIngestion(
      objects = objects,
      sessionIds = sessionIds,
      checkpointIds = checkpointIds,
      mappedEvents = totalMapped,
      noteEvents = totalNotes
    )
  )
}

/// The Entire ingestion adapter as a `CaptureAdapter` over an unpacked
/// branch directory (see `readEntire`). Construct with `newEntireReader`.
pub record EntireReader {
  root: String
}

/// Construct an `EntireReader` rooted at an unpacked
/// `entire/checkpoints/v1` tree (the `fixtures/entire-v1/unpacked` shape).
pub func newEntireReader(root: in String): EntireReader {
  return EntireReader(root = root)
}

impl CaptureAdapter for EntireReader {
  func source(): CaptureSource {
    return entireSource()
  }

  func read(): Result[List[ProvenanceObject], AdaptError] {
    val ingestion = readEntire(self.root)?
    return Ok(value = ingestion.objects)
  }
}

// ─── cloud-agents runner stream-json mapper (spec §6.3, mapping only) ──────
/// What the runner knew when it invoked `claude -p` — everything the
/// stream itself cannot honestly provide. The user's prompt is NOT a
/// stream event in `-p` mode, so the `prompt` step is synthesized from
/// `promptText`; `startedAt` doubles as the timestamp floor for events
/// that precede the first timestamped event (see the module doc's
/// timestamp policy); `permission` is the runner's tool-permission mode
/// (`Auto` for auto-approved allowlists); `tree` is the workspace's git
/// tree hash if the runner snapshotted one — when present a terminal
/// `Checkpoint` is emitted, when absent the mapping stops at steps.
pub record InvocationContext {
  pub principal: Principal
  pub workspace: String
  pub taskRef: Option[String]
  pub startedAt: String
  pub promptText: String
  pub model: String
  pub permission: Permission
  pub tree: Option[String]
}

/// One stream-json mapping outcome. `eventKinds` carries one label per
/// input line ("prompt" | "response" | "tool_use" | "note", "+"-joined for
/// multi-block events) so callers can audit exactly what each event
/// became; `mappedEvents + noteEvents == totalEvents` always holds (§8.5:
/// no silent drops). `checkpointId` is present iff the context carried a
/// workspace tree.
pub record StreamJsonMapping {
  pub objects: List[ProvenanceObject]
  pub eventKinds: List[String]
  pub totalEvents: Int
  pub mappedEvents: Int
  pub noteEvents: Int
  pub sessionId: String
  pub checkpointId: Option[String]
}

/// Map a `claude -p --output-format stream-json` transcript (one JSON
/// event per line) to the provenance model (spec §6.3's mapping concern):
///
/// - a `Session` from the invocation context (`adapter:
///   "cloud-agents-runner"`, `fidelity: events`);
/// - a synthesized `prompt` root step from `context.promptText` (the
///   prompt is CLI input, not an event);
/// - assistant `text` blocks → `response` steps (text hashed, tokens from
///   `message.usage`); assistant `tool_use` blocks + their `tool_result`
///   events → single `tool_use` steps; everything else → `note` steps with
///   the raw payload hash — never silently dropped;
/// - a terminal `Checkpoint` over the final step iff `context.tree` is
///   present.
///
/// Unparseable lines become note steps, not errors (degraded but present);
/// the `Result` is reserved for structural failures of future strict
/// modes, so current input always maps.
pub func mapStreamJson(lines: in List[String], context: in InvocationContext): Result[StreamJsonMapping, AdaptError] {
  // Reject ill-formed UTF-16 up front (spec §3): a lone surrogate anywhere in
  // the transcript would otherwise crash at `getString` during mapping, or
  // hash to divergent bytes across runtimes.
  rejectIllFormedLines(lines, "<stream-json>")?
  val objects: List[ProvenanceObject] = newList()
  val eventKinds: List[String] = newList()
  val startedAt = truncateTimestamp(context.startedAt)
  val session = Session(
    principal = context.principal,
    workspace = context.workspace,
    taskRef = context.taskRef,
    startedAt = startedAt,
    capture = runnerSource()
  )
  val sessionId = sessionIdOf(session)
  objects.add(SessionObject(session = session))

  val settings = MapSettings(
    sessionId = sessionId,
    principalId = context.principal.id,
    fallbackModel = context.model,
    permission = context.permission
  )
  val promptStepId = chainStep(
    objects,
    sessionId,
    "",
    humanOrigin(context.principal.id),
    startedAt,
    PromptBody(text = context.promptText, attachments = emptyAttachments())
  )

  val events = parseEventLines(lines, 0)
  val pending: List[PendingTool] = newList()
  val resolved: List[String] = newList()
  val cursor0 = MapCursor(lastStepId = promptStepId, lastTs = startedAt, mapped = 0, notes = 0)
  val cursor1 = mapEvents(events, settings, cursor0, pending, resolved, "", objects, eventKinds)
  val cursor = flushPending(pending, resolved, settings, cursor1, "", objects)

  var checkpointId: Option[String] = None
  match context.tree {
    case Some(tree) -> {
      val frontier: List[String] = newList()
      if cursor.lastStepId != "" {
        frontier.add(cursor.lastStepId)
      }
      val checkpoint = Checkpoint(session = sessionId, steps = frontier, tree = tree, parent = None, at = cursor.lastTs)
      val ckptId = checkpointIdOf(checkpoint)
      objects.add(CheckpointObject(envelope = CheckpointEnvelope(checkpoint = checkpoint, signature = None)))
      checkpointId = Some(value = ckptId)
    }
    case None -> ()
  }

  return Ok(
    value = StreamJsonMapping(
      objects = objects,
      eventKinds = eventKinds,
      totalEvents = lines.count,
      mappedEvents = cursor.mapped,
      noteEvents = cursor.notes,
      sessionId = sessionId,
      checkpointId = checkpointId
    )
  )
}

/// The cloud-agents runner adapter as a `CaptureAdapter` over a stream-json
/// transcript file plus its invocation context (see `mapStreamJson`).
/// Construct with `newStreamJsonAdapter`.
pub record StreamJsonAdapter {
  path: String
  context: InvocationContext
}

/// Construct a `StreamJsonAdapter` for the transcript at `path`, mapped
/// under `context`.
pub func newStreamJsonAdapter(path: in String, context: in InvocationContext): StreamJsonAdapter {
  return StreamJsonAdapter(path = path, context = context)
}

impl CaptureAdapter for StreamJsonAdapter {
  func source(): CaptureSource {
    return runnerSource()
  }

  func read(): Result[List[ProvenanceObject], AdaptError] {
    val text = readFileText(self.path)?
    val mapping = mapStreamJson(splitLines(text), self.context)?
    return Ok(value = mapping.objects)
  }
}
