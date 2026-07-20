//! src/v2_client.l — CloudAgents.Shim.V2Client: the state machines behind
//! the three phase-6 §7 v2 tools (docs/phase6-mcp-callbacks.md):
//! request_secret (long-poll, like request_permission, but writes the
//! approved value to a container-local file instead of returning it),
//! add_followup_task (a single create call), report_artifact (reads and
//! base64-encodes a local file, then a single upload call).
//!
//! Fully synchronous, same reasoning as CloudAgents.Shim.Callbacks' module
//! doc: importable directly from a `@test_module` (docs/lyric/gotchas.md —
//! a test module cannot invoke anything reached by importing a package
//! that contains `async func`s), and matches Mcp.Server's synchronous
//! `McpToolHandler.call` contract. `Std.File`/`Std.Process` (used below)
//! declare no `async func`s, so this holds.
package CloudAgents.Shim.V2Client

import Std.Core
import Std.Collections
import Std.Errors
import Std.File
import Std.Process
import extern System.IO.FileInfo as FileInfo
import CloudAgents.Shim.Transport
import CloudAgents.Shim.V2Transport

/// 8 MiB — matches CloudAgents.Callbacks' maxArtifactBytes exactly
/// (docs/phase6 §7.3). Checked client-side BEFORE reading the file, so an
/// oversize artifact is rejected without paying for a full read + base64
/// encode of a file that will just be refused server-side anyway.
val maxArtifactBytes = 8388608

/// A pending-status guard: never loop forever on a pathological
/// pollIntervalMs of 0 (mirrors CloudAgents.Shim.Callbacks.safePollIntervalMs
/// — duplicated here rather than imported since that package is on this
/// change's avoid-list, see this file's module doc).
func safePollIntervalMs(pollIntervalMs: in Int): Int {
  if pollIntervalMs > 0 {
    pollIntervalMs
  } else {
    1
  }
}

// ── request_secret ────────────────────────────────────────────────────────────
/// The outcome of `requestSecret`. `Approved` carries the container-local
/// FILE PATH the value was written to — never the value itself, so it
/// cannot flow into the MCP tool-result text (docs/phase6 §7.1's threat
/// model: never let the secret value enter the agent-visible transcript).
pub union SecretOutcome {
  case Approved(path: String)
  case Refused(message: String)
}

/// The final path segment of `name` with any path separators stripped —
/// defense in depth only. In practice `name` never reaches here containing
/// a separator: the host's request_secret create endpoint already verified
/// it matches an EXISTING stored credential name before this call could
/// ever see an 'approved' decision, and stored credential names are
/// restricted to `[A-Za-z_][A-Za-z0-9_]*`
/// (CloudAgents.Credentials.isValidCredentialName on the host). This
/// exists so a future change on either side can't silently reopen a
/// path-traversal seam in the local file path.
func sanitizedSecretFileName(name: in String): String {
  var acc = ""
  var i = 0
  while i < name.length {
    val c = name.substring(i, 1)
    if c != "/" and c != "\\" {
      acc = acc + c
    }
    i = i + 1
  }
  if acc.length == 0 {
    return "secret"
  }
  return acc
}

/// Base directory for the secret file. `/run` is tmpfs (memory-backed, not
/// persisted to disk) on essentially every Linux container runtime, so it
/// is preferred when present; if it doesn't exist at all in this
/// environment, fall back to a container-local tmp path rather than
/// failing the whole tool call (docs/phase6 §7.1: "tmpfs when available").
func secretsBaseDir(): String {
  if Std.File.dirExists("/run") {
    return "/run/cloud-agents-secrets"
  }
  return "/tmp/cloud-agents-secrets"
}

/// Best-effort `chmod`, the most restrictive permission-setting mechanism
/// actually available: `Std.File` (lyric-stdlib/std/file.l, confirmed by
/// reading its full public surface) exposes createDir/writeText/writeBytes
/// with NO mode/permission parameter anywhere, and no dedicated
/// chmod-equivalent function exists in the stdlib today. Shelling out to
/// the real `chmod` binary — present on every runner base image
/// (docker/Dockerfile*, which are Debian/Ubuntu-derived with coreutils) —
/// is therefore the most restrictive approach this toolchain can express
/// without a new stdlib primitive. A failure here is logged and swallowed,
/// not fatal: the PRIMARY safeguard against the threat this feature is
/// designed for (prompt-injected exfiltration via the tool-result text) is
/// that the value never enters that text at all, independent of the file's
/// permission bits — see requestSecret below. 0600/0700 is defense in
/// depth layered on top of that primary safeguard, not a replacement for it.
func chmodBestEffort(path: in String, mode: in String): Result[Unit, String] {
  val args: List[String] = newList()
  args.add(mode)
  args.add(path)
  return match Std.Process.run("chmod", args) {
    case Ok(0) -> Ok(value = ())
    case Ok(code) -> Err(error = "chmod " + mode + " " + path + " exited " + toString(code))
    case Err(e) -> Err(error = "chmod " + mode + " " + path + " failed: " + IOError.message(e))
  }
}

/// Write the approved value to a container-local file locked down to the
/// owning user only, returning the path. The value is passed through ONLY
/// as far as this one write call — never logged, never returned to any
/// caller of this function.
func writeSecretFile(name: in String, value: in String): Result[String, String] {
  val dir = secretsBaseDir()
  match Std.File.createDir(dir) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = "failed to create the secrets directory " + dir + ": " + IOError.message(e))
  }
  match chmodBestEffort(dir, "700") {
    case Ok(_) -> ()
    case Err(msg) -> CloudAgents.Shim.Transport.eprintln("cloud-agents-shim: " + msg + " (secrets directory permissions may be looser than intended)")
  }
  val path = dir + "/" + sanitizedSecretFileName(name)
  match Std.File.writeText(path, value) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = "failed to write the secret file: " + IOError.message(e))
  }
  match chmodBestEffort(path, "600") {
    case Ok(_) -> ()
    case Err(msg) -> CloudAgents.Shim.Transport.eprintln("cloud-agents-shim: " + msg + " (secret file permissions may be looser than intended)")
  }
  return Ok(value = path)
}

/// Create a secret request, then long-poll for a human decision — same
/// create/poll/timeout shape as CloudAgents.Shim.Callbacks.requestPermission
/// (docs/phase6 §7.1). On approval, writes the value to a local file and
/// returns ONLY the path; on denial or any failure/timeout, returns a
/// refusal message. `pollIntervalMs`/`timeoutMs` mirror the same env-driven
/// defaults as the v1 tools (CloudAgents.Shim.Config).
pub func requestSecret(
  transport: in V2CallbackTransport,
  name: in String,
  reason: in String,
  pollIntervalMs: in Int,
  timeoutMs: in Int,
): SecretOutcome {
  val createResult: Result[String, String] = transport.createSecret(name, reason)
  val created = match createResult {
    case Ok(body) -> body
    case Err(e) -> return Refused(message = "failed to reach the cloud-agents host: " + e)
  }
  val createdResp = match tryDecodeCreateSecretRequestResponse(created) {
    case Some(r) -> r
    case None -> return Refused(message = "malformed response from the cloud-agents host when requesting the secret")
  }

  val interval = safePollIntervalMs(pollIntervalMs)
  var elapsedMs = 0
  var decision: Option[SecretDecision] = None
  while elapsedMs < timeoutMs {
    val polled = match transport.pollSecret(createdResp.id) {
      case Ok(body) -> body
      case Err(e) -> return Refused(message = "failed to reach the cloud-agents host while polling for a decision: " + e)
    }
    val d = match tryDecodeSecretDecision(polled) {
      case Some(dd) -> dd
      case None -> return Refused(message = "malformed response from the cloud-agents host while polling for a decision")
    }
    if d.status != "pending" {
      decision = Some(value = d)
      break
    }
    CloudAgents.Shim.Transport.sleepMillis(interval)
    elapsedMs = elapsedMs + interval
  }

  val finalDecision = match decision {
    case Some(d) -> d
    case None -> return Refused(message = "timed out after " + toString(timeoutMs) + "ms waiting for a human decision")
  }
  if finalDecision.status != "approved" {
    return Refused(message = "the request for '" + name + "' was denied by the human reviewer")
  }
  if finalDecision.value.length == 0 {
    // Approved, but the host had nothing to deliver — either this poll
    // raced a prior delivery (docs/phase6 §7.1 step 3: value returned at
    // most once) or the credential vanished between approval and delivery.
    return Refused(
      message = "the request for '" + name +
        "' was approved, but the value is unavailable (it may already have been delivered)"
    )
  }
  return match writeSecretFile(name, finalDecision.value) {
    case Ok(path) -> Approved(path = path)
    case Err(msg) -> Refused(message = msg)
  }
}

// ── add_followup_task ─────────────────────────────────────────────────────────
/// Create a follow-up task (todo) for the human, returning its id.
pub func addFollowupTask(transport: in V2CallbackTransport, description: in String): Result[String, String] {
  val created = match transport.createTodo(description) {
    case Ok(body) -> body
    case Err(e) -> return Err(error = "failed to reach the cloud-agents host: " + e)
  }
  return match tryDecodeCreateFollowupTaskResponse(created) {
    case Some(r) -> Ok(value = r.id)
    case None -> Err(error = "malformed response from the cloud-agents host when creating the follow-up task")
  }
}

// ── report_artifact ───────────────────────────────────────────────────────────
@externTarget("System.Convert.ToBase64String")
func encodeBase64(b: in slice[Byte]): String = ""

@externInstance
@externTarget("System.IO.FileInfo.get_Length")
func fileInfoLength(fi: in FileInfo): Long = ()

/// The file's size in bytes, checked BEFORE reading it — so an oversize
/// artifact is rejected with a clear message without paying for a full
/// read (docs/phase6 §7.3: "reject larger with a clear message" before the
/// shim reads the whole file).
func fileSizeBytes(path: in String): Result[Int, String] {
  return try {
    Ok(value = fileInfoLength(FileInfo.new(path)).toInt())
  } catch Bug as b {
    Err(error = "failed to stat " + path + ": " + b.message)
  }
}

func basenameOfLocalPath(path: in String): String {
  var lastSep = -1
  var i = 0
  while i < path.length {
    val c = path.substring(i, 1)
    if c == "/" or c == "\\" {
      lastSep = i
    }
    i = i + 1
  }
  if lastSep < 0 {
    return path
  }
  return path.substring(lastSep + 1, path.length - lastSep - 1)
}

/// Read `path`, base64-encode it, and upload it as an artifact, returning
/// the host-assigned artifact id. Rejects a file over 8 MiB BEFORE reading
/// it in full (fileSizeBytes above).
pub func reportArtifact(
  transport: in V2CallbackTransport, path: in String, mimeType: in String, description: in String
): Result[String, String] {
  val size = match fileSizeBytes(path) { case Ok(n) -> n; case Err(msg) -> return Err(error = msg) }
  if size > maxArtifactBytes {
    return Err(error = "artifact exceeds the 8 MiB limit (" + toString(size) + " bytes): " + path)
  }
  val bytes = match Std.File.readBytes(path) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = "failed to read " + path + ": " + IOError.message(e))
  }
  val contentBase64 = encodeBase64(bytes.toArray())
  val fileName = basenameOfLocalPath(path)
  val created = match transport.uploadArtifact(fileName, mimeType, description, contentBase64) {
    case Ok(body) -> body
    case Err(e) -> return Err(error = "failed to reach the cloud-agents host: " + e)
  }
  return match tryDecodeUploadArtifactResponse(created) {
    case Some(r) -> Ok(value = r.id)
    case None -> Err(error = "malformed response from the cloud-agents host when uploading the artifact")
  }
}
