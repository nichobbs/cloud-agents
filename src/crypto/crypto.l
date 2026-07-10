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
import extern System.Environment as Env
import extern System.String as DotNetString

extern type Encoding = "System.Text.Encoding"
extern type Aes = "System.Security.Cryptography.Aes"
extern type CryptoTransform = "System.Security.Cryptography.ICryptoTransform"
extern type HmacSha256 = "System.Security.Cryptography.HMACSHA256"

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

@externTarget("System.Security.Cryptography.HMACSHA256.new")
func hmacNew(key: in slice[Byte]): HmacSha256 = ()

@externInstance
@externTarget("System.Security.Cryptography.HMACSHA256.ComputeHash")
func hmacCompute(self: in HmacSha256, data: in slice[Byte]): slice[Byte] = []

@externInstance
@externTarget("System.IDisposable.Dispose")
func hmacDispose(self: in HmacSha256): Unit = ()

val ivLen = 16
val macLen = 32

/// Constant-time equality of two byte slices. Compares the full length of the
/// longer slice so a forged tag leaks nothing about where it first diverges.
func constantTimeEqualsBytes(a: in slice[Byte], b: in slice[Byte]): Bool {
  val aLen = a.length.toInt()
  val bLen = b.length.toInt()
  val maxLen = if aLen > bLen then aLen else bLen
  var diff = if aLen == bLen then 0 else 1
  var i = 0
  while i < maxLen {
    val ba = if i < aLen then a[i.toNat()].toInt() else -1
    val bb = if i < bLen then b[i.toNat()].toInt() else -2
    if ba != bb {
      diff = 1
    }
    i = i + 1
  }
  return diff == 0
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
  val h = hmacNew(macKey)
  val tag = hmacCompute(h, data)
  hmacDispose(h)
  return tag
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
      val presentedTag = all.slice(ivLen + ctLen, total)
      val expectedTag = macOf(macKeyFor(key), ivAndCt)
      if not constantTimeEqualsBytes(presentedTag, expectedTag) {
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
