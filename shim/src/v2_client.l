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
import Std.Environment
import Std.Errors
import Std.File
import Std.Process
import extern System.IO.FileInfo as FileInfo
import CloudAgents.Shim.Transport
import CloudAgents.Shim.Callbacks
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

/// Ordered candidate base directories for the secret file. An explicit
/// `CLOUD_AGENTS_SECRETS_DIR` override wins (deployments with an unusual
/// layout, and tests that need a writable throwaway dir). Otherwise `/run`
/// is preferred — tmpfs (memory-backed, not persisted to disk) on
/// essentially every Linux container runtime (docs/phase6 §7.1: "tmpfs
/// when available") — with a container-local `/tmp` path as the fallback.
/// `writeSecretFile` tries each in turn and uses the first whose directory
/// it can actually create: `/run` *exists* on Linux even when it is not
/// writable by a non-root shim user, so presence alone is not enough — the
/// fallback must trigger on a failed create, not just an absent path.
func secretsBaseDirCandidates(): List[String] {
  val candidates: List[String] = newList()
  val override = Std.Environment.getVarOrDefault("CLOUD_AGENTS_SECRETS_DIR", "")
  if override.length > 0 {
    candidates.add(override)
    return candidates
  }
  candidates.add("/run/cloud-agents-secrets")
  candidates.add("/tmp/cloud-agents-secrets")
  return candidates
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
  val candidates = secretsBaseDirCandidates()
  var chosen = ""
  var lastErr = ""
  var i = 0
  while i < candidates.length and chosen.length == 0 {
    val cand = candidates[i]
    val created = match Std.File.createDir(cand) {
      case Ok(_) -> true
      case Err(e) -> {
        lastErr = "failed to create the secrets directory " + cand + ": " + IOError.message(e)
        false
      }
    }
    if created {
      chosen = cand
    }
    i = i + 1
  }
  if chosen.length == 0 {
    return Err(error = lastErr)
  }
  val dir = chosen
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
  val clock: CloudAgents.Shim.Callbacks.Clock = SystemClock()
  return requestSecretWithClock(transport, name, reason, pollIntervalMs, timeoutMs, clock)
}

/// `requestSecret`, with an injectable `Clock` (#540) — reuses the exact
/// wall-clock seam CloudAgents.Shim.Callbacks defines, so the secret
/// long-poll deadline is real elapsed time, not an iteration count that
/// could drift past `timeoutMs` under slow polls. Thin `SystemClock`
/// wrapper above keeps main.l/the tool handler on the 5-arg signature;
/// tests call this directly with a `ManualClock`.
pub func requestSecretWithClock(
  transport: in V2CallbackTransport,
  name: in String,
  reason: in String,
  pollIntervalMs: in Int,
  timeoutMs: in Int,
  clock: in CloudAgents.Shim.Callbacks.Clock,
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
  val deadline = clock.nowMillis() + timeoutMs.toLong()
  var decision: Option[SecretDecision] = None
  while clock.nowMillis() < deadline {
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
    val remaining = deadline - clock.nowMillis()
    if remaining <= 0i64 {
      break
    }
    val sleepFor = if remaining < interval.toLong() { remaining } else { interval.toLong() }
    CloudAgents.Shim.Transport.sleepMillis(sleepFor.toInt())
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

// ── notify (phase 7 §5) ───────────────────────────────────────────────────────
/// Fire-and-forget push to the human that an autonomous run reached a
/// milestone. Single POST, no polling — same shape as addFollowupTask above.
pub func notify(transport: in V2CallbackTransport, summary: in String, level: in String): Result[String, String] {
  val created = match transport.notify(summary, level) {
    case Ok(body) -> body
    case Err(e) -> return Err(error = "failed to reach the cloud-agents host: " + e)
  }
  return match tryDecodeNotifyResponse(created) {
    case Some(r) -> Ok(value = r.id)
    case None -> Err(error = "malformed response from the cloud-agents host when sending the notification")
  }
}

// ── remember / recall (phase 7 §4) ────────────────────────────────────────────
/// Store a memory entry for this session's repo, returning a short
/// confirmation. Overwrites any existing value under the same key.
pub func remember(transport: in V2CallbackTransport, key: in String, value: in String): Result[String, String] {
  val created = match transport.remember(key, value) {
    case Ok(body) -> body
    case Err(e) -> return Err(error = "failed to reach the cloud-agents host: " + e)
  }
  return match tryDecodeRememberResponse(created) {
    case Some(r) -> Ok(value = "remembered '" + r.key + "' for this repository")
    case None -> Err(error = "malformed response from the cloud-agents host when storing memory")
  }
}

/// Read memory for this session's repo. With a non-empty `key`, does a
/// targeted single-key lookup (#590) and returns just that entry's value (or
/// a not-found message) — the host now supports this directly
/// (GET …/callbacks/memory?key=), instead of fetching the whole store and
/// filtering client-side. With an empty `key`, returns every entry as
/// `key: value` lines — the "load everything at session start" flow so a
/// later session picks up what an earlier one learned.
pub func recall(transport: in V2CallbackTransport, key: in String): Result[String, String] {
  if key.length > 0 {
    val body = match transport.recallByKey(key) {
      case Ok(b) -> b
      case Err(e) -> return Err(error = "failed to reach the cloud-agents host: " + e)
    }
    val list = match tryDecodeMemoryListResponse(body) {
      case Some(r) -> r
      case None -> return Err(error = "malformed response from the cloud-agents host when reading memory")
    }
    if list.entries.length == 0 {
      return Ok(value = "no memory stored under '" + key + "' for this repository")
    }
    return Ok(value = list.entries[0].value)
  }
  val body = match transport.recallAll() {
    case Ok(b) -> b
    case Err(e) -> return Err(error = "failed to reach the cloud-agents host: " + e)
  }
  val list = match tryDecodeMemoryListResponse(body) {
    case Some(r) -> r
    case None -> return Err(error = "malformed response from the cloud-agents host when reading memory")
  }
  if list.entries.length == 0 {
    return Ok(value = "no memory stored yet for this repository")
  }
  var acc = ""
  var i = 0
  while i < list.entries.length {
    val e = list.entries[i]
    if i > 0 {
      acc = acc + "\n"
    }
    acc = acc + e.key + ": " + e.value
    i = i + 1
  }
  return Ok(value = acc)
}

/// Delete a memory entry for this session's repo, freeing a slot under the
/// cap (#592). Reports whether the key existed; forgetting an absent key is a
/// success, not an error.
pub func forget(transport: in V2CallbackTransport, key: in String): Result[String, String] {
  val body = match transport.forget(key) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = "failed to reach the cloud-agents host: " + e)
  }
  return match tryDecodeForgetResponse(body) {
    case Some(r) -> if r.status == "deleted" { Ok(value = "forgot '" + r.key + "'") } else { Ok(value = "no memory stored under '" + r.key + "' for this repository") }
    case None -> Err(error = "malformed response from the cloud-agents host when forgetting memory")
  }
}

// ── add_task / list_tasks / complete_task (phase 7 §8) ───────────────────────
/// Create a repo-scoped task, returning its host-assigned id.
pub func addTask(transport: in V2CallbackTransport, description: in String): Result[String, String] {
  val created = match transport.createTask(description) {
    case Ok(body) -> body
    case Err(e) -> return Err(error = "failed to reach the cloud-agents host: " + e)
  }
  return match tryDecodeCreateTaskResponse(created) {
    case Some(r) -> Ok(value = r.id)
    case None -> Err(error = "malformed response from the cloud-agents host when creating the task")
  }
}

/// List repo-scoped tasks, optionally filtered by status ("open"/"done"; an
/// empty filter returns every status). Renders as `id [status]: description`
/// lines, newest first (the host's own ordering).
pub func listTasks(transport: in V2CallbackTransport, statusFilter: in String): Result[String, String] {
  val body = match transport.listTasks(statusFilter) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = "failed to reach the cloud-agents host: " + e)
  }
  val list = match tryDecodeTaskListResponse(body) {
    case Some(r) -> r
    case None -> return Err(error = "malformed response from the cloud-agents host when listing tasks")
  }
  if list.tasks.length == 0 {
    return Ok(value = "no tasks stored for this repository")
  }
  var acc = ""
  var i = 0
  while i < list.tasks.length {
    val t = list.tasks[i]
    if i > 0 {
      acc = acc + "\n"
    }
    acc = acc + t.id + " [" + t.status + "]: " + t.description
    i = i + 1
  }
  return Ok(value = acc)
}

/// Mark a repo-scoped task done. Idempotent: completing an already-done task
/// is reported as a success, not an error.
pub func completeTask(transport: in V2CallbackTransport, taskId: in String): Result[String, String] {
  val body = match transport.completeTask(taskId) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = "failed to reach the cloud-agents host: " + e)
  }
  return match tryDecodeCompleteTaskResponse(body) {
    case Some(r) -> Ok(value = "completed task '" + r.id + "'")
    case None -> Err(error = "malformed response from the cloud-agents host when completing the task")
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
