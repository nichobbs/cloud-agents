@test_module
package CloudAgents.CryptoTests

import Std.Core
import Std.Testing
import CloudAgents.Crypto
import extern System.Environment as Env

// A fixed 32-byte key (base64 of 32 zero bytes is 44 chars) for deterministic
// setup. Real deployments use a random ENCRYPTION_KEY.
val testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

func useTestKey(): Unit {
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", testKey)
}

func mustEncrypt(s: in String): String {
  return match CloudAgents.Crypto.encrypt(s) {
    case Ok(blob) -> blob
    case Err(e) -> panic("encrypt failed: " + CloudAgents.Crypto.cryptoErrorMessage(e))
  }
}

func mustDecrypt(blob: in String): String {
  return match CloudAgents.Crypto.decrypt(blob) {
    case Ok(s) -> s
    case Err(e) -> panic("decrypt failed: " + CloudAgents.Crypto.cryptoErrorMessage(e))
  }
}

test "AES-GCM round-trips plaintext" {
  useTestKey()
  assertEqual(mustDecrypt(mustEncrypt("hello")), "hello", "short value round-trips")
  assertEqual(mustDecrypt(mustEncrypt("")), "", "empty value round-trips")
  val secret = "ghp_16C7e42F292c6912E7710c838347Ae178B4a"
  assertEqual(mustDecrypt(mustEncrypt(secret)), secret, "github-token-shaped value round-trips")
  val multiline = "line1\nline2\twith tabs\r\nand a quote \" and backslash \\"
  assertEqual(mustDecrypt(mustEncrypt(multiline)), multiline, "value with control/meta chars round-trips")
}

test "Ciphertext is non-deterministic (random nonce)" {
  useTestKey()
  val a = mustEncrypt("same plaintext")
  val b = mustEncrypt("same plaintext")
  assertFalse(a == b, "two encryptions of the same value differ (fresh nonce)")
  // ...but both decrypt back to the original.
  assertEqual(mustDecrypt(a), "same plaintext", "first blob decrypts")
  assertEqual(mustDecrypt(b), "same plaintext", "second blob decrypts")
}

test "Tampered ciphertext fails authentication" {
  useTestKey()
  val blob = mustEncrypt("authentic")
  // Flip the final base64 character to a different valid one — corrupts the
  // GCM tag, which must fail decryption rather than return garbage.
  val lastChar = blob.substring(blob.length.toInt() - 1, 1)
  val replacement = if lastChar == "A" then "B" else "A"
  val tampered = blob.substring(0, blob.length.toInt() - 1) + replacement
  match CloudAgents.Crypto.decrypt(tampered) {
    case Ok(_) -> assertTrue(false, "tampered ciphertext must not decrypt")
    case Err(_) -> assertTrue(true, "tampering is rejected")
  }
}

test "Missing key is a typed error, not a crash" {
  Env.SetEnvironmentVariable("ENCRYPTION_KEY", "")
  match CloudAgents.Crypto.encrypt("x") {
    case Ok(_) -> assertTrue(false, "encryption without a key must fail")
    case Err(e) -> assertEqual(CloudAgents.Crypto.cryptoErrorMessage(e), "ENCRYPTION_KEY is not set — credential storage is disabled", "unconfigured -> NotConfigured")
  }
  assertFalse(CloudAgents.Crypto.isConfigured(), "isConfigured false without a key")
  useTestKey()
  assertTrue(CloudAgents.Crypto.isConfigured(), "isConfigured true with a key")
}
