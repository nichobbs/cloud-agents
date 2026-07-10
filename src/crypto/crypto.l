//! AES-256-GCM encryption at rest for stored credentials.
//!
//! Values are encrypted with a single deployment key from the ENCRYPTION_KEY
//! environment variable (base64, 32 bytes). The stored blob is
//! base64(nonce ‖ ciphertext ‖ tag): a fresh random 12-byte nonce per
//! encryption, then AES-GCM's ciphertext and 16-byte authentication tag. GCM
//! is authenticated, so tampering (or a wrong key) fails decryption rather
//! than returning garbage.
//!
//! All byte handling goes through the BCL. `Encoding.GetBytes`/`GetString`
//! are the extern-instance methods flagged in docs/BUILD.md (lyric-lang#3887)
//! for the *pre-compiled* Lyric.Web binary; bound freshly here with an
//! explicit @externInstance under v0.4.19 they are exercised by a round-trip
//! test so CI proves whether the binding holds.
@runtime_checked
package CloudAgents.Crypto

import Std.Core
import extern System.Environment as Env
import extern System.String as DotNetString

extern type ByteArray = "System.Byte[]"
extern type Encoding = "System.Text.Encoding"
extern type AesGcm = "System.Security.Cryptography.AesGcm"
extern type RandomNumberGenerator = "System.Security.Cryptography.RandomNumberGenerator"

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

// ─── BCL bindings ──────────────────────────────────────────────────────────────
@externTarget("System.Convert.FromBase64String")
func fromBase64(s: in String): ByteArray = ()

@externTarget("System.Convert.ToBase64String")
func toBase64(b: in ByteArray): String = ()

@externInstance
@externTarget("System.Array.get_Length")
func byteArrayLength(b: in ByteArray): Int = ()

@externTarget("System.Text.Encoding.get_UTF8")
func utf8(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetBytes")
func encGetBytes(enc: in Encoding, s: in String): ByteArray = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func encGetString(enc: in Encoding, b: in ByteArray): String = ()

extern type Type = "System.Type"

@externInstance
@externTarget("System.Object.GetType")
func byteType(obj: in ByteArray): Type = ()

@externTarget("System.Array.CreateInstance")
func createByteArray(elementType: in Type, length: in Int): ByteArray = ()

@externTarget("System.Array.Copy")
func copyBytes(
  src: in ByteArray, srcIndex: in Int, dst: in ByteArray, dstIndex: in Int, length: in Int
): Unit = ()

@externTarget("System.Security.Cryptography.RandomNumberGenerator.Fill")
func rngFill(data: in ByteArray): Unit = ()

// AesGcm(key, tagSizeInBytes) — the tag-size-in-ctor overload is required on
// .NET 8+.
@externTarget("System.Security.Cryptography.AesGcm.new")
func aesGcmNew(key: in ByteArray, tagSizeInBytes: in Int): AesGcm = ()

@externInstance
@externTarget("System.Security.Cryptography.AesGcm.Encrypt")
func aesGcmEncrypt(
  self: in AesGcm, nonce: in ByteArray, plaintext: in ByteArray, ciphertext: in ByteArray, tag: in ByteArray
): Unit = ()

@externInstance
@externTarget("System.Security.Cryptography.AesGcm.Decrypt")
func aesGcmDecrypt(
  self: in AesGcm, nonce: in ByteArray, ciphertext: in ByteArray, tag: in ByteArray, plaintext: in ByteArray
): Unit = ()

@externInstance
@externTarget("System.IDisposable.Dispose")
func aesGcmDispose(self: in AesGcm): Unit = ()

val nonceLen = 12
val tagLen = 16

func emptyBytes(): ByteArray {
  // Build a zero-length array whose element type is Byte by slicing a base64
  // of nothing — avoids needing a separate typeof(Byte) source.
  return fromBase64("")
}

func newBytes(length: in Int): ByteArray {
  val t = byteType(emptyBytes())
  return createByteArray(t, length)
}

/// Whether credential encryption is available (ENCRYPTION_KEY present).
pub func isConfigured(): Bool {
  return not DotNetString.IsNullOrEmpty(Env.GetEnvironmentVariable("ENCRYPTION_KEY"))
}

func loadKey(): Result[ByteArray, CryptoError] {
  val raw = Env.GetEnvironmentVariable("ENCRYPTION_KEY")
  if DotNetString.IsNullOrEmpty(raw) {
    return Err(error = NotConfigured)
  }
  return try {
    val key = fromBase64(raw)
    if byteArrayLength(key) != 32 {
      Err(error = BadKey(message = "must be 32 bytes (base64) for AES-256, got " + toString(byteArrayLength(key))))
    } else {
      Ok(value = key)
    }
  } catch Bug as b {
    Err(error = BadKey(message = "not valid base64: " + b.message))
  }
}

/// Encrypt a plaintext value, returning base64(nonce ‖ ciphertext ‖ tag).
pub func encrypt(plaintext: in String): Result[String, CryptoError] {
  val key = loadKey()?
  return try {
    val ptBytes = encGetBytes(utf8(), plaintext)
    val ptLen = byteArrayLength(ptBytes)
    val nonce = newBytes(nonceLen)
    rngFill(nonce)
    val ct = newBytes(ptLen)
    val tag = newBytes(tagLen)
    val gcm = aesGcmNew(key, tagLen)
    aesGcmEncrypt(gcm, nonce, ptBytes, ct, tag)
    aesGcmDispose(gcm)

    // Pack nonce ‖ ct ‖ tag into one array, then base64 it.
    val blob = newBytes(nonceLen + ptLen + tagLen)
    copyBytes(nonce, 0, blob, 0, nonceLen)
    copyBytes(ct, 0, blob, nonceLen, ptLen)
    copyBytes(tag, 0, blob, nonceLen + ptLen, tagLen)
    Ok(value = toBase64(blob))
  } catch Bug as b {
    Err(error = BadKey(message = b.message))
  }
}

/// Decrypt a base64(nonce ‖ ciphertext ‖ tag) blob produced by `encrypt`.
pub func decrypt(blob: in String): Result[String, CryptoError] {
  val key = loadKey()?
  return try {
    val all = fromBase64(blob)
    val total = byteArrayLength(all)
    val ctLen = total - nonceLen - tagLen
    if ctLen < 0 {
      Err(error = DecryptFailed(message = "blob too short"))
    } else {
      val nonce = newBytes(nonceLen)
      val ct = newBytes(ctLen)
      val tag = newBytes(tagLen)
      copyBytes(all, 0, nonce, 0, nonceLen)
      copyBytes(all, nonceLen, ct, 0, ctLen)
      copyBytes(all, nonceLen + ctLen, tag, 0, tagLen)
      val pt = newBytes(ctLen)
      val gcm = aesGcmNew(key, tagLen)
      aesGcmDecrypt(gcm, nonce, ct, tag, pt)
      aesGcmDispose(gcm)
      Ok(value = encGetString(utf8(), pt))
    }
  } catch Bug as b {
    // GCM authentication failure (tampering / wrong key) lands here.
    Err(error = DecryptFailed(message = b.message))
  }
}
