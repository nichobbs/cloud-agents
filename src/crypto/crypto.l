//! Authenticated encryption at rest for stored credentials.
//!
//! AES-256-CBC then HMAC-SHA256 (encrypt-then-MAC): a random 16-byte IV per
//! encryption, AES-256-CBC/PKCS7 ciphertext, and a 32-byte HMAC-SHA256 tag
//! over `IV ‖ ciphertext`. The stored blob is base64(IV ‖ ciphertext ‖ tag).
//! Decryption verifies the tag in constant time before decrypting, so
//! tampering or a wrong key fails cleanly rather than returning garbage.
//!
//! Byte buffers are Lyric-native `slice[Byte]`, which the FFI boundary
//! marshals to/from .NET `byte[]` (docs/lyric/reference.md §"Cross-boundary
//! marshalling": "Slices → arrays"). This is what lets the BCL crypto
//! primitives — whose parameters are typed `byte[]` — actually bind: an
//! `extern type = "System.Byte[]"` value instead marshals as `System.Object`
//! and only matches `System.Array`-typed methods (confirmed in CI:
//! `Method not found: ...Aes.set_Key(System.Object)`).
//!
//! AES-GCM is avoided deliberately: `AesGcm`/`RandomNumberGenerator.Fill` are
//! `Span<byte>`-only, which the boundary cannot express. Every call here uses
//! a `byte[]`-shaped overload.
@runtime_checked
package CloudAgents.Crypto

import Std.Core
import CloudAgents.Text
import extern System.Environment as Env
import extern System.String as DotNetString

extern type Encoding = "System.Text.Encoding"
extern type Aes = "System.Security.Cryptography.Aes"
extern type CryptoTransform = "System.Security.Cryptography.ICryptoTransform"

pub union CryptoError {
  case NotConfigured
  case BadKey(message: String)
  case DecryptFailed(message: String)
}

pub func cryptoErrorMessage(e: in CryptoError): String {
  return match e {
    case NotConfigured -> "ENCRYPTION_KEY is not set — credential storage is disabled"
    case BadKey(m) -> "ENCRYPTION_KEY is invalid: " + m
    case DecryptFailed(m) -> "failed to decrypt credential: " + m
  }
}

// ─── BCL bindings (slice[Byte] ⇄ byte[]) ───────────────────────────────────────
@externTarget("System.Convert.FromBase64String")
func fromBase64(s: in String): slice[Byte] = []

@externTarget("System.Convert.ToBase64String")
func toBase64(b: in slice[Byte]): String = ""

@externTarget("System.Text.Encoding.get_UTF8")
func utf8(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetBytes")
func encGetBytes(enc: in Encoding, s: in String): slice[Byte] = []

@externInstance
@externTarget("System.Text.Encoding.GetString")
func encGetString(enc: in Encoding, b: in slice[Byte]): String = ""

@externTarget("System.Security.Cryptography.RandomNumberGenerator.GetBytes")
func rngGetBytes(count: in Int): slice[Byte] = []

@externTarget("System.Security.Cryptography.SHA256.HashData")
func sha256(data: in slice[Byte]): slice[Byte] = []

@externTarget("System.Security.Cryptography.Aes.Create")
func aesCreate(): Aes = ()

@externInstance
@externTarget("System.Security.Cryptography.Aes.set_Key")
func aesSetKey(self: in Aes, key: in slice[Byte]): Unit = ()

@externInstance
@externTarget("System.Security.Cryptography.Aes.set_IV")
func aesSetIV(self: in Aes, iv: in slice[Byte]): Unit = ()

// Aes defaults to CipherMode.CBC + PaddingMode.PKCS7, so the transform path
// needs no enum argument (EncryptCbc/DecryptCbc take a PaddingMode enum, which
// the boundary marshals as Int32 and .NET then can't resolve). CreateEncryptor
// /CreateDecryptor + ICryptoTransform.TransformFinalBlock use only byte[]/int.
@externInstance
@externTarget("System.Security.Cryptography.Aes.CreateEncryptor")
func aesCreateEncryptor(self: in Aes): CryptoTransform = ()

@externInstance
@externTarget("System.Security.Cryptography.Aes.CreateDecryptor")
func aesCreateDecryptor(self: in Aes): CryptoTransform = ()

@externInstance
@externTarget("System.Security.Cryptography.ICryptoTransform.TransformFinalBlock")
func transformFinal(self: in CryptoTransform, input: in slice[Byte], offset: in Int, count: in Int): slice[Byte] = []

@externInstance
@externTarget("System.IDisposable.Dispose")
func transformDispose(self: in CryptoTransform): Unit = ()

@externInstance
@externTarget("System.IDisposable.Dispose")
func aesDispose(self: in Aes): Unit = ()

// Static one-shot HMAC (byte[] key, byte[] source) -> byte[]. Avoids the
// HMACSHA256(byte[]) constructor, whose `.new` extern binding does not
// resolve (CI: `Method not found: ...HMACSHA256.new(Byte[])`), the same way
// SHA256.HashData is used above.
@externTarget("System.Security.Cryptography.HMACSHA256.HashData")
func hmacHashData(key: in slice[Byte], source: in slice[Byte]): slice[Byte] = []

val ivLen = 16
val macLen = 32

/// Constant-time equality of two base64 strings (the two 44-char MAC tags).
/// Comparing the base64 encodings sidesteps byte-slice indexing (which needs
/// Nat indices, and Int.toNat() is broken at runtime — see
/// docs/lyric/gotchas.md); String.substring/.length are known-good.
///
/// Thin re-export of CloudAgents.Text.constantTimeEquals (#204) — that
/// shared implementation is the already-hardened, expected-length-bound
/// shape #212 fixed CloudAgents.Auth's copy to; this function used to be an
/// independently maintained, max-length-bound copy — a latent variant of
/// the same timing leak #212 fixed in the token check.
func constantTimeEqualsB64(presented: in String, expected: in String): Bool {
  return CloudAgents.Text.constantTimeEquals(presented, expected)
}

/// Whether credential encryption is available (ENCRYPTION_KEY present).
pub func isConfigured(): Bool {
  return not DotNetString.IsNullOrEmpty(Env.GetEnvironmentVariable("ENCRYPTION_KEY"))
}

func loadKey(): Result[slice[Byte], CryptoError] {
  val raw = Env.GetEnvironmentVariable("ENCRYPTION_KEY")
  if DotNetString.IsNullOrEmpty(raw) {
    return Err(error = NotConfigured)
  }
  return try {
    val key = fromBase64(raw)
    if key.length.toInt() != 32 {
      Err(error = BadKey(message = "must be 32 bytes (base64) for AES-256, got " + toString(key.length.toInt())))
    } else {
      Ok(value = key)
    }
  } catch Bug as b {
    Err(error = BadKey(message = "not valid base64: " + b.message))
  }
}

/// Separate the MAC key from the AES key by hashing it with a domain label, so
/// the same bytes are never used for both cipher and MAC.
func macKeyFor(aesKey: in slice[Byte]): slice[Byte] {
  return sha256(aesKey.concat(encGetBytes(utf8(), "cloud-agents-hmac")))
}

func macOf(macKey: in slice[Byte], data: in slice[Byte]): slice[Byte] {
  return hmacHashData(macKey, data)
}

/// Encrypt a plaintext value, returning base64(IV ‖ ciphertext ‖ tag).
pub func encrypt(plaintext: in String): Result[String, CryptoError] {
  val key = loadKey()?
  return try {
    val ptBytes = encGetBytes(utf8(), plaintext)
    val iv = rngGetBytes(ivLen)
    val aes = aesCreate()
    aesSetKey(aes, key)
    aesSetIV(aes, iv)
    val enc = aesCreateEncryptor(aes)
    val ct = transformFinal(enc, ptBytes, 0, ptBytes.length.toInt())
    transformDispose(enc)
    aesDispose(aes)

    val ivAndCt = iv.concat(ct)
    val tag = macOf(macKeyFor(key), ivAndCt)
    Ok(value = toBase64(ivAndCt.concat(tag)))
  } catch Bug as b {
    Err(error = BadKey(message = b.message))
  }
}

/// Decrypt a blob produced by `encrypt`, verifying its tag first.
pub func decrypt(blob: in String): Result[String, CryptoError] {
  val key = loadKey()?
  return try {
    val all = fromBase64(blob)
    val total = all.length.toInt()
    val ctLen = total - ivLen - macLen
    if ctLen < 0 {
      Err(error = DecryptFailed(message = "blob too short"))
    } else {
      val ivAndCt = all.slice(0, ivLen + ctLen)
      val presentedTag = toBase64(all.slice(ivLen + ctLen, total))
      val expectedTag = toBase64(macOf(macKeyFor(key), ivAndCt))
      if not constantTimeEqualsB64(presentedTag, expectedTag) {
        Err(error = DecryptFailed(message = "authentication failed (wrong key or tampered data)"))
      } else {
        val iv = all.slice(0, ivLen)
        val ct = all.slice(ivLen, ivLen + ctLen)
        val aes = aesCreate()
        aesSetKey(aes, key)
        aesSetIV(aes, iv)
        val dec = aesCreateDecryptor(aes)
        val pt = transformFinal(dec, ct, 0, ct.length.toInt())
        transformDispose(dec)
        aesDispose(aes)
        Ok(value = encGetString(utf8(), pt))
      }
    }
  } catch Bug as b {
    Err(error = DecryptFailed(message = b.message))
  }
}
