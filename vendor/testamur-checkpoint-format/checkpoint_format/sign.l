//! Testamur.CheckpointFormat.Sign — signing hooks for the checkpoint format
//! (docs/specs/checkpoint-format.md §4, §7 "sign").
//!
//! This package is deliberately leaf-level: it operates on raw bytes and
//! strings only and imports no other Testamur.CheckpointFormat.* sub-package
//! (in particular NOT Canon — the tiny JSON fragment codec here is
//! hand-rolled and strict, see the codec section below).
//!
//! What lives here, per the spec:
//!   - the `Signature` model: `{ keyid, scheme, sig }`, with `scheme` a
//!     CLOSED variant (`sigstore` | `x509` | `ssh` on the wire; unknown
//!     scheme strings are a typed decode error, never coerced);
//!   - the `Signer` / `Verifier` interfaces — hooks only; real Sigstore /
//!     X.509 / SSH implementations are later packages (spec §9);
//!   - a TEST-ONLY in-memory HMAC-SHA256 signer for exercising the hooks.
//!
//! Trust assumptions and design notes (for the adversarial review pass):
//!   - Verification failure is `None`, NEVER an exception; success is
//!     `Some(verifiedKeyid)` carrying the keyid THIS verifier matched (derived
//!     from its own key, not echoed from the untrusted `Signature.keyid`), so
//!     the Chain package attributes to what was verified, not what was
//!     claimed. The Chain package degrades unsigned/verify-failing checkpoints
//!     to "unattributed" (spec §4, §8.6). Every path through `verify` on the
//!     test signer is total for arbitrary attacker-supplied `Signature` values
//!     (any scheme, any keyid, any sig string, valid base64 or not).
//!   - The test signer must not masquerade as a real scheme. The wire set of
//!     schemes is closed to the three real values, so the internal
//!     representation carries a FOURTH variant, `TestHmacSha256`, which is
//!     distinguishable everywhere in memory and is REFUSED a wire encoding:
//!     `encodeSignature` returns a typed error for it, and `decodeSignature`
//!     accepts only the three real scheme strings — a test signature can
//!     therefore neither be emitted onto the wire nor smuggled in from it.
//!   - HMAC-SHA256 is a MAC, not a signature: verification requires the
//!     symmetric key, so "verifies" here attests nothing to third parties.
//!     That is acceptable ONLY because the scheme is unmistakably test-only.
//!   - Tag comparison in the test verifier is constant-time over the
//!     trusted expected tag's length (same hardened shape as cloud-agents'
//!     CloudAgents.Text.constantTimeEquals, see its #212 history). The
//!     keyid comparison is NOT constant-time — keyids are public metadata
//!     derived from the key by a one-way hash, not secrets.
//!   - The JSON fragment codec is intentionally minimal and strict: exact
//!     canonical form only (sorted keys `keyid` < `scheme` < `sig`, no
//!     whitespace — spec §3), values restricted to escape-free strings
//!     (no `"`, `\`, newline, carriage return, or tab; other C0 controls in
//!     adversarial input are not rejected here — full string
//!     canonicalisation is the Canon package's job, and keyids/base64 sigs
//!     never legitimately contain them). `sig` must be canonical base64
//!     (decode→re-encode byte-identical). Anything else is a typed
//!     `MalformedSignature` error — reject, never repair (spec §3 rule 6's
//!     philosophy).
@runtime_checked
package Testamur.CheckpointFormat.Sign

import Std.Core

// ─── BCL bindings (slice[Byte] ⇄ byte[]; pattern from cloud-agents
//     src/crypto/crypto.l) ─────────────────────────────────────────────────
extern type Encoding = "System.Text.Encoding"

@externTarget("System.Convert.FromBase64String")
func fromBase64(s: in String): slice[Byte] = []

@externTarget("System.Convert.ToBase64String")
func toBase64(b: in slice[Byte]): String = ""

@externTarget("System.Convert.ToHexStringLower")
func toHexLower(b: in slice[Byte]): String = ""

@externTarget("System.Text.Encoding.get_UTF8")
func utf8(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetBytes")
func encGetBytes(enc: in Encoding, s: in String): slice[Byte] = []

@externTarget("System.Security.Cryptography.SHA256.HashData")
func sha256(data: in slice[Byte]): slice[Byte] = []

// Static one-shot HMAC (byte[] key, byte[] source) -> byte[]; the
// HMACSHA256 constructor binding does not resolve in this toolchain (see
// cloud-agents crypto.l), the static HashData does.
@externTarget("System.Security.Cryptography.HMACSHA256.HashData")
func hmacHashData(key: in slice[Byte], source: in slice[Byte]): slice[Byte] = []

/// UTF-8 bytes of a string. Public so callers (and tests) can build payload
/// and key byte slices without their own FFI bindings; Sign itself stays the
/// only crypto/FFI surface of the checkpoint format.
pub func utf8Bytes(s: in String): slice[Byte] {
  return encGetBytes(utf8(), s)
}

// ─── Signature model (spec §4) ─────────────────────────────────────────────
/// Signature scheme, as a closed variant. The wire set (spec §4) is exactly
/// `sigstore` | `x509` | `ssh`; `schemeFromWire` rejects everything else
/// with a typed error. `TestHmacSha256` is an internal-only fourth variant
/// for the in-memory test signer: it is deliberately DISTINGUISHABLE from
/// every real scheme and has NO wire form — `schemeToWire`/`encodeSignature`
/// refuse it — so a test signature can never masquerade as, or be confused
/// with, a real one (spec §7 "NOT a real scheme").
pub union SignatureScheme {
  case Sigstore
  case X509
  case Ssh
  case TestHmacSha256
}

/// A detached signature over some canonical byte body (spec §4):
/// `{ "keyid": string, "scheme": "sigstore" | "x509" | "ssh", "sig": base64 }`.
/// `keyid` identifies the key within the scheme's namespace; `sig` is the
/// base64 signature bytes. The signed body itself is NOT part of this
/// record — per spec §3 rule 7 the `signature` field is excluded from the
/// hashed/signed body, so a `Signature` always travels alongside the object
/// it covers, never inside its hash.
pub record Signature {
  pub keyid: String
  pub scheme: SignatureScheme
  pub sig: String
}

/// Typed errors for the signature codec. Per the spec's strictness
/// philosophy these are decode/encode-time REJECTIONS — they are never used
/// to report a verification failure (that is `verify(...) == false`, spec
/// §4: unsigned or verify-failing degrades to unattributed, it does not
/// error).
pub union SignatureError {
  case UnknownScheme(raw: String)
  case MalformedSignature(message: String)
  case NotWireEncodable(message: String)
}

/// Human-readable rendering of a `SignatureError`, for logs and test
/// diagnostics.
pub func signatureErrorMessage(e: in SignatureError): String {
  return match e {
    case UnknownScheme(raw) -> "unknown signature scheme \"" + raw + "\" (expected sigstore | x509 | ssh)"
    case MalformedSignature(m) -> "malformed signature fragment: " + m
    case NotWireEncodable(m) -> "signature is not wire-encodable: " + m
  }
}

/// Parse a wire scheme string. Strict: exactly `sigstore`, `x509`, or `ssh`
/// (spec §4's closed set); anything else — including the test scheme's own
/// debug name — is a typed `UnknownScheme` error, mirroring the spec's
/// unknown-step-`kind` rule (§2.2): reject, never coerce.
pub func schemeFromWire(raw: in String): Result[SignatureScheme, SignatureError] {
  if raw == "sigstore" {
    return Ok(value = Sigstore)
  }
  if raw == "x509" {
    return Ok(value = X509)
  }
  if raw == "ssh" {
    return Ok(value = Ssh)
  }
  return Err(error = UnknownScheme(raw = raw))
}

/// Wire string for a scheme. Total for the three real schemes; the
/// test-only `TestHmacSha256` is refused with `NotWireEncodable` — it has no
/// legitimate wire form by design (see the module doc's trust notes).
pub func schemeToWire(scheme: in SignatureScheme): Result[String, SignatureError] {
  return match scheme {
    case Sigstore -> Ok(value = "sigstore")
    case X509 -> Ok(value = "x509")
    case Ssh -> Ok(value = "ssh")
    case TestHmacSha256 -> Err(error = NotWireEncodable(message = "test-hmac-sha256 is test-only and has no wire form"))
  }
}

/// Debug/display name of a scheme. Total (covers the test scheme too) and
/// for diagnostics ONLY — never a wire encoding; use `schemeToWire` for
/// that, which correctly refuses the test scheme.
pub func schemeName(scheme: in SignatureScheme): String {
  return match scheme {
    case Sigstore -> "sigstore"
    case X509 -> "x509"
    case Ssh -> "ssh"
    case TestHmacSha256 -> "test-hmac-sha256"
  }
}

// ─── Signer / Verifier hooks (spec §4) ─────────────────────────────────────
/// Produces signatures over canonical byte bodies. Interface only — key
/// management and real scheme implementations (Sigstore-keyless,
/// platform-CA X.509, SSH) are later packages (spec §9). Implementations
/// MUST set `Signature.keyid` to their own `keyid()` and declare their
/// `scheme` honestly.
///
/// Note: `impl Signer for ...` blocks must live in THIS package —
/// implementing an interface imported from another package fails on the
/// current self-hosted MSIL backend (see cloud-agents
/// shim/src/callbacks_client.l's module note). Real scheme implementations
/// will land here (or behind a re-export) when they arrive.
@stubbable
pub interface Signer {
  /// Stable identifier of the signing key, scheme-namespaced.
  func keyid(): String
  /// Sign a canonical byte body, returning a detached `Signature`.
  func sign(payload: in slice[Byte]): Signature
}

/// Checks a detached `Signature` over a canonical byte body. MUST be total:
/// verification failure — wrong scheme, wrong key, tampered payload,
/// malformed sig, anything — is `None`, never an exception; the caller
/// (Chain, spec §4/§8.6) degrades a failing checkpoint to "unattributed"
/// rather than erroring.
///
/// On success it returns `Some(verifiedKeyid)` — the keyid the verifier
/// ACTUALLY matched, derived from its own key material, not echoed from the
/// attacker-controlled `Signature.keyid`. The caller attributes to this value,
/// so a multi-key verifier can never be tricked into attributing a checkpoint
/// to a keyid it did not verify against.
@stubbable
pub interface Verifier {
  /// `Some(verifiedKeyid)` iff `signature` is a valid signature by this
  /// verifier's key over exactly `payload`; `None` otherwise.
  func verify(payload: in slice[Byte], signature: in Signature): Option[String]
}

/// Sign `payload` with `signer` — the interface-typed seam the Chain
/// package will call through; tests exercise dispatch through this too.
pub func signWith(signer: in Signer, payload: in slice[Byte]): Signature {
  return signer.sign(payload)
}

/// Verify `signature` over `payload` with `verifier` (see `signWith`):
/// `Some(verifiedKeyid)` on success, `None` on failure. Total — never throws.
pub func verifyWith(verifier: in Verifier, payload: in slice[Byte], signature: in Signature): Option[String] {
  return verifier.verify(payload, signature)
}

/// The `keyid()` of a signer, through the interface seam.
pub func keyidOf(signer: in Signer): String {
  return signer.keyid()
}

// ─── TEST-ONLY in-memory signer (spec §7 "sign") ───────────────────────────
/// ⚠ TEST-ONLY. An in-memory HMAC-SHA256 signer/verifier for exercising the
/// signing hooks in unit tests and fixtures — NOT a real signature scheme
/// (spec §7). HMAC is symmetric: anyone who can verify can also sign, so
/// this attests nothing to a third party. It declares itself honestly as
/// `TestHmacSha256`, a variant with no wire encoding — `encodeSignature`
/// refuses it — so nothing this signer produces can leave the process
/// disguised as a real signature (see the module doc's trust notes).
///
/// `keyid` is the first 8 lowercase-hex chars of SHA-256(key): stable for a
/// given key, one-way (does not reveal key bytes), and collision-irrelevant
/// at test scale.
///
/// The key field is package-private, so this record cannot be constructed
/// outside the package — use `newHmacTestSigner`.
pub record HmacTestSigner {
  keyBytes: slice[Byte]
}

/// Construct a `HmacTestSigner` (⚠ TEST-ONLY — see `HmacTestSigner`) over
/// the given in-memory key bytes.
pub func newHmacTestSigner(key: in slice[Byte]): HmacTestSigner {
  return HmacTestSigner(keyBytes = key)
}

/// keyid derivation for the test signer: first 8 lowercase-hex chars of
/// SHA-256(key).
func hmacKeyid(key: in slice[Byte]): String {
  return toHexLower(sha256(key)).substring(0, 8)
}

func isTestHmacScheme(scheme: in SignatureScheme): Bool {
  return match scheme { case Sigstore -> false; case X509 -> false; case Ssh -> false; case TestHmacSha256 -> true }
}

/// Constant-time string equality for MAC-tag comparison, bounded by the
/// TRUSTED `expected` value's length only (never the candidate's), so
/// comparison count does not depend on attacker-controlled input — the
/// hardened shape from cloud-agents CloudAgents.Text.constantTimeEquals
/// (its #212 fix); see that function's doc for why a max-length bound leaks
/// the secret's length. A length mismatch is folded into `diff` up front.
func constantTimeEquals(candidate: in String, expected: in String): Bool {
  val candLen = candidate.length.toInt()
  val expectedLen = expected.length.toInt()
  var diff = if candLen == expectedLen then 0 else 1
  var i = 0
  while i < expectedLen {
    val ce = expected.substring(i, 1)
    // Past the candidate's end, compare `ce` to itself: the mismatch is
    // already in `diff`, and per-iteration work stays uniform.
    val cc = if i < candLen then candidate.substring(i, 1) else ce
    if cc != ce {
      diff = 1
    }
    i = i + 1
  }
  return diff == 0
}

/// Total verification for the test signer. Fails closed (`None`) on: any
/// non-test scheme (a real-scheme signature is never accepted by the test
/// verifier), a keyid not derived from this key, or a tag mismatch. On success
/// returns `Some(keyid)` where the keyid is derived from THIS verifier's key
/// (not echoed from the untrusted `signature.keyid`). The expected tag is
/// recomputed and base64-compared — no decoding of the untrusted `sig` string,
/// so no exception path exists for malformed input.
func hmacVerify(key: in slice[Byte], payload: in slice[Byte], signature: in Signature): Option[String] {
  if not isTestHmacScheme(signature.scheme) {
    return None
  }
  val verifiedKeyid = hmacKeyid(key)
  if signature.keyid != verifiedKeyid {
    return None
  }
  val expected = toBase64(hmacHashData(key, payload))
  if constantTimeEquals(signature.sig, expected) {
    return Some(value = verifiedKeyid)
  }
  return None
}

impl Signer for HmacTestSigner {
  func keyid(): String {
    return hmacKeyid(self.keyBytes)
  }

  func sign(payload: in slice[Byte]): Signature {
    return Signature(
      keyid = hmacKeyid(self.keyBytes),
      scheme = TestHmacSha256,
      sig = toBase64(hmacHashData(self.keyBytes, payload))
    )
  }
}

impl Verifier for HmacTestSigner {
  func verify(payload: in slice[Byte], signature: in Signature): Option[String] {
    return hmacVerify(self.keyBytes, payload, signature)
  }
}

// ─── JSON fragment codec ───────────────────────────────────────────────────
//
// The canonical wire shape (spec §3 rules applied to the §4 Signature):
//   {"keyid":"<keyid>","scheme":"<scheme>","sig":"<base64>"}
// Keys in sorted order (keyid < scheme < sig lexicographically — sorted by
// construction), no whitespace, values escape-free. The decoder requires
// EXACTLY this byte shape: field order, absence of whitespace, and closing
// brace are all checked, so decode(x) succeeding implies encode(decode(x))
// == x byte-for-byte. Plain string building/parsing on purpose — this
// package must not depend on Canon (leaf-level; see module doc).
/// True when `s` can appear verbatim between JSON quotes with no escaping:
/// rejects `"`, `\`, newline, carriage return, and tab. (Remaining C0
/// controls are not scanned for here — see the module doc's trust notes.)
func isPlainJsonValue(s: in String): Bool {
  if s.contains("\"") or s.contains("\\") {
    return false
  }
  if s.contains("\n") or s.contains("\r") or s.contains("\t") {
    return false
  }
  return true
}

/// True when `s` is canonical base64: decodes, and re-encodes to the
/// byte-identical string (rejects whitespace-padded or otherwise
/// non-canonical encodings that .NET's decoder would tolerate).
func isCanonicalBase64(s: in String): Bool {
  return try {
    toBase64(fromBase64(s)) == s
  } catch Bug as b {
    false
  }
}

/// True when `expected` occurs in `s` exactly at `pos`.
func hasAt(s: in String, pos: in Int, expected: in String): Bool {
  val n = s.length.toInt()
  val m = expected.length.toInt()
  if pos < 0 or pos + m > n {
    return false
  }
  return s.substring(pos, m) == expected
}

/// Index of the closing `"` of a string value starting at `start`, or -1 if
/// the value is unterminated or contains a character the codec refuses
/// (`\`, newline, carriage return, tab — escape sequences are not part of
/// this codec's accepted grammar).
func valueEnd(s: in String, start: in Int): Int {
  val n = s.length.toInt()
  var i = start
  while i < n {
    val c = s.substring(i, 1)
    if c == "\"" {
      return i
    }
    if c == "\\" or c == "\n" or c == "\r" or c == "\t" {
      return -1
    }
    i = i + 1
  }
  return -1
}

/// Encode a `Signature` to its canonical JSON-fragment form. Typed errors:
/// `NotWireEncodable` for the test-only scheme (it must never reach the
/// wire), `MalformedSignature` for a keyid/sig that is empty, needs JSON
/// escaping, or (sig) is not canonical base64 — encode is exactly as strict
/// as decode, so every encodable Signature round-trips byte-identically.
pub func encodeSignature(signature: in Signature): Result[String, SignatureError] {
  val wire = schemeToWire(signature.scheme)?
  if signature.keyid.length.toInt() == 0 {
    return Err(error = MalformedSignature(message = "keyid must not be empty"))
  }
  if not isPlainJsonValue(signature.keyid) {
    return Err(
      error = MalformedSignature(
        message = "keyid contains characters this codec refuses (quote, backslash, or control)"
      )
    )
  }
  if signature.sig.length.toInt() == 0 {
    return Err(error = MalformedSignature(message = "sig must not be empty"))
  }
  if not isPlainJsonValue(signature.sig) {
    return Err(
      error = MalformedSignature(
        message = "sig contains characters this codec refuses (quote, backslash, or control)"
      )
    )
  }
  if not isCanonicalBase64(signature.sig) {
    return Err(error = MalformedSignature(message = "sig is not canonical base64"))
  }
  return Ok(
    value = "{\"keyid\":\"" + signature.keyid + "\",\"scheme\":\"" + wire + "\",\"sig\":\"" + signature.sig +
      "\"}"
  )
}

/// Decode a canonical JSON-fragment `Signature`. Strict (spec §3): exact
/// key order (`keyid`, `scheme`, `sig`), no whitespace, no trailing bytes,
/// escape-free non-empty values, canonical base64 `sig`, and a scheme from
/// the closed wire set — an unknown scheme string is a typed
/// `UnknownScheme` error (never coerced, mirroring the spec's unknown
/// step-`kind` rule); every other deviation is `MalformedSignature`.
pub func decodeSignature(json: in String): Result[Signature, SignatureError] {
  val n = json.length.toInt()

  val keyidPrefix = "{\"keyid\":\""
  if not hasAt(json, 0, keyidPrefix) {
    return Err(error = MalformedSignature(message = "expected canonical fragment starting {\"keyid\":\""))
  }
  val keyidStart = keyidPrefix.length.toInt()
  val keyidEnd = valueEnd(json, keyidStart)
  if keyidEnd < 0 {
    return Err(error = MalformedSignature(message = "unterminated or escape-bearing keyid value"))
  }
  val keyid = json.substring(keyidStart, keyidEnd - keyidStart)

  val schemePrefix = "\",\"scheme\":\""
  if not hasAt(json, keyidEnd, schemePrefix) {
    return Err(error = MalformedSignature(message = "expected \",\"scheme\":\" after keyid"))
  }
  val schemeStart = keyidEnd + schemePrefix.length.toInt()
  val schemeEnd = valueEnd(json, schemeStart)
  if schemeEnd < 0 {
    return Err(error = MalformedSignature(message = "unterminated or escape-bearing scheme value"))
  }
  val schemeRaw = json.substring(schemeStart, schemeEnd - schemeStart)

  val sigPrefix = "\",\"sig\":\""
  if not hasAt(json, schemeEnd, sigPrefix) {
    return Err(error = MalformedSignature(message = "expected \",\"sig\":\" after scheme"))
  }
  val sigStart = schemeEnd + sigPrefix.length.toInt()
  val sigEnd = valueEnd(json, sigStart)
  if sigEnd < 0 {
    return Err(error = MalformedSignature(message = "unterminated or escape-bearing sig value"))
  }
  val sigValue = json.substring(sigStart, sigEnd - sigStart)

  if not hasAt(json, sigEnd, "\"}") or sigEnd + 2 != n {
    return Err(error = MalformedSignature(message = "expected \"} at end of fragment with no trailing bytes"))
  }

  if keyid.length.toInt() == 0 {
    return Err(error = MalformedSignature(message = "keyid must not be empty"))
  }
  val scheme = schemeFromWire(schemeRaw)?
  if sigValue.length.toInt() == 0 {
    return Err(error = MalformedSignature(message = "sig must not be empty"))
  }
  if not isCanonicalBase64(sigValue) {
    return Err(error = MalformedSignature(message = "sig is not canonical base64"))
  }

  return Ok(value = Signature(keyid = keyid, scheme = scheme, sig = sigValue))
}
