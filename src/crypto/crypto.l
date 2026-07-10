//! Authenticated encryption at rest for stored credentials.
//!
//! AES-256-CBC then HMAC-SHA256 (encrypt-then-MAC): a random 16-byte IV per
//! encryption, AES-256-CBC/PKCS7 ciphertext, and a 32-byte HMAC-SHA256 tag
//! over `IV ‖ ciphertext`. The stored blob is base64(IV ‖ ciphertext ‖ tag).
//! Decryption verifies the tag in constant time before decrypting, so
//! tampering or a wrong key fails cleanly rather than returning garbage.
//!
//! Why CBC+HMAC and not AES-GCM: .NET's `AesGcm` and `RandomNumberGenerator
//! .Fill` are Span<byte>-only APIs, and the Lyric↔BCL boundary cannot marshal
//! a `byte[]` into a `Span<byte>` (confirmed in CI: `Method not found: ...
//! .Fill(System.Object)`). Every call here uses a `byte[]`-shaped overload:
//! `RandomNumberGenerator.GetBytes(int)`, `Aes.EncryptCbc/DecryptCbc(byte[],
//! byte[], PaddingMode)`, `HMACSHA256.ComputeHash(byte[])`. `Encoding.GetBytes
//! /GetString` are confirmed working at v0.4.19 (see docs/lyric/gotchas.md).
@runtime_checked
package CloudAgents.Crypto

import Std.Core
import extern System.Environment as Env
import extern System.String as DotNetString

extern type ByteArray = "System.Byte[]"
extern type Encoding = "System.Text.Encoding"
extern type Aes = "System.Security.Cryptography.Aes"
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

// ─── BCL bindings (all byte[]-shaped, no Span) ─────────────────────────────────
@externTarget("System.Convert.FromBase64String")
func fromBase64(s: in String): ByteArray = ()

@externTarget("System.Convert.ToBase64String")
func toBase64(b: in ByteArray): String = ()

@externInstance
@externTarget("System.Array.get_Length")
func byteArrayLength(b: in ByteArray): Int = ()

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

@externTarget("System.Text.Encoding.get_UTF8")
func utf8(): Encoding = ()

@externInstance
@externTarget("System.Text.Encoding.GetBytes")
func encGetBytes(enc: in Encoding, s: in String): ByteArray = ()

@externInstance
@externTarget("System.Text.Encoding.GetString")
func encGetString(enc: in Encoding, b: in ByteArray): String = ()

/// `RandomNumberGenerator.GetBytes(count)` — returns a fresh byte[] (unlike
/// `Fill`, which takes a Span the boundary cannot marshal).
@externTarget("System.Security.Cryptography.RandomNumberGenerator.GetBytes")
func rngGetBytes(count: in Int): ByteArray = ()

/// `SHA256.HashData(byte[])` — static, byte[] in / byte[] out.
@externTarget("System.Security.Cryptography.SHA256.HashData")
func sha256(data: in ByteArray): ByteArray = ()

@externTarget("System.Security.Cryptography.Aes.Create")
func aesCreate(): Aes = ()

@externInstance
@externTarget("System.Security.Cryptography.Aes.set_Key")
func aesSetKey(self: in Aes, key: in ByteArray): Unit = ()

// PaddingMode.PKCS7 = 2. EncryptCbc/DecryptCbc take (byte[], byte[],
// PaddingMode) and return byte[].
@externInstance
@externTarget("System.Security.Cryptography.Aes.EncryptCbc")
func aesEncryptCbc(self: in Aes, plaintext: in ByteArray, iv: in ByteArray, padding: in Int): ByteArray = ()

@externInstance
@externTarget("System.Security.Cryptography.Aes.DecryptCbc")
func aesDecryptCbc(self: in Aes, ciphertext: in ByteArray, iv: in ByteArray, padding: in Int): ByteArray = ()

@externInstance
@externTarget("System.IDisposable.Dispose")
func aesDispose(self: in Aes): Unit = ()

@externTarget("System.Security.Cryptography.HMACSHA256.new")
func hmacNew(key: in ByteArray): HmacSha256 = ()

@externInstance
@externTarget("System.Security.Cryptography.HMACSHA256.ComputeHash")
func hmacCompute(self: in HmacSha256, data: in ByteArray): ByteArray = ()

@externInstance
@externTarget("System.IDisposable.Dispose")
func hmacDispose(self: in HmacSha256): Unit = ()

val ivLen = 16
val macLen = 32
val pkcs7 = 2

func emptyBytes(): ByteArray {
  return fromBase64("")
}

func newBytes(length: in Int): ByteArray {
  return createByteArray(byteType(emptyBytes()), length)
}

func concatBytes(a: in ByteArray, b: in ByteArray): ByteArray {
  val aLen = byteArrayLength(a)
  val bLen = byteArrayLength(b)
  val dst = newBytes(aLen + bLen)
  copyBytes(a, 0, dst, 0, aLen)
  copyBytes(b, 0, dst, aLen, bLen)
  return dst
}

func sliceBytes(src: in ByteArray, start: in Int, length: in Int): ByteArray {
  val dst = newBytes(length)
  copyBytes(src, start, dst, 0, length)
  return dst
}

/// Constant-time equality of two base64 strings (the two MACs). Both are a
/// fixed 44 chars, so comparing the full length leaks nothing about where a
/// forged tag first diverges.
func constantTimeEqualsB64(a: in String, b: in String): Bool {
  val aLen = a.length.toInt()
  val bLen = b.length.toInt()
  val maxLen = if aLen > bLen then aLen else bLen
  var diff = if aLen == bLen then 0 else 1
  var i = 0
  while i < maxLen {
    val ca = if i < aLen then a.substring(i, 1) else ""
    val cb = if i < bLen then b.substring(i, 1) else ""
    if ca != cb {
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

/// Separate MAC key from the AES key by hashing it with a domain-separation
/// label, so the same bytes are never used for both cipher and MAC.
func macKeyFor(aesKey: in ByteArray): ByteArray {
  return sha256(concatBytes(aesKey, encGetBytes(utf8(), "cloud-agents-hmac")))
}

func macOf(macKey: in ByteArray, data: in ByteArray): String {
  val h = hmacNew(macKey)
  val tag = hmacCompute(h, data)
  hmacDispose(h)
  return toBase64(tag)
}

/// Encrypt a plaintext value, returning base64(IV ‖ ciphertext ‖ tag).
pub func encrypt(plaintext: in String): Result[String, CryptoError] {
  val key = loadKey()?
  return try {
    val ptBytes = encGetBytes(utf8(), plaintext)
    val iv = rngGetBytes(ivLen)
    val aes = aesCreate()
    aesSetKey(aes, key)
    val ct = aesEncryptCbc(aes, ptBytes, iv, pkcs7)
    aesDispose(aes)

    val ivAndCt = concatBytes(iv, ct)
    val macB64 = macOf(macKeyFor(key), ivAndCt)
    // blob = IV ‖ ct ‖ tag ; tag comes from base64-decoding macB64 back to bytes
    val blob = concatBytes(ivAndCt, fromBase64(macB64))
    Ok(value = toBase64(blob))
  } catch Bug as b {
    Err(error = BadKey(message = b.message))
  }
}

/// Decrypt a blob produced by `encrypt`, verifying its tag first.
pub func decrypt(blob: in String): Result[String, CryptoError] {
  val key = loadKey()?
  return try {
    val all = fromBase64(blob)
    val total = byteArrayLength(all)
    val ctLen = total - ivLen - macLen
    if ctLen < 0 {
      Err(error = DecryptFailed(message = "blob too short"))
    } else {
      val ivAndCt = sliceBytes(all, 0, ivLen + ctLen)
      val presentedMac = toBase64(sliceBytes(all, ivLen + ctLen, macLen))
      val expectedMac = macOf(macKeyFor(key), ivAndCt)
      if not constantTimeEqualsB64(presentedMac, expectedMac) {
        Err(error = DecryptFailed(message = "authentication failed (wrong key or tampered data)"))
      } else {
        val iv = sliceBytes(all, 0, ivLen)
        val ct = sliceBytes(all, ivLen, ctLen)
        val aes = aesCreate()
        aesSetKey(aes, key)
        val pt = aesDecryptCbc(aes, ct, iv, pkcs7)
        aesDispose(aes)
        Ok(value = encGetString(utf8(), pt))
      }
    }
  } catch Bug as b {
    Err(error = DecryptFailed(message = b.message))
  }
}
