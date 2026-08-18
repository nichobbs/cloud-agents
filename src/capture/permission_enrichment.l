//! CloudAgents.PermissionEnrichment — per-tool permission derivation for the
//! capture → checkpoint path (docs/capture-permission-enrichment.md; audit-row
//! enrichment follow-up in AGENTS.md's "Provenance capture" section).
//!
//! ## The gap this closes
//!
//! `CloudAgents.CheckpointBridge` maps a captured session to the Testamur
//! checkpoint format through the vendored `Adapt.mapStreamJson`, which stamps a
//! SINGLE context-level `Permission` (`granted` | `denied` | `auto`) onto every
//! `tool_use` step of the session. But the runner already records finer-grained
//! evidence per tool call: the `permission_requests` table (one row per
//! prompted (tool, input), decided `allowed` / `denied` / timed-out-to-`denied`)
//! and the `secret_requests` table (one row per `request_secret` credential ask,
//! decided `approved` / `denied` / `timed_out`). This package folds those
//! per-request rows into a **per-tool permission map**: which tools the session
//! was actually granted, denied, or left to auto — so a checkpoint can reflect
//! the real per-tool decisions rather than one blanket mode.
//!
//! ## What it is (and is not)
//!
//! This is the **derivation + accessor**. It is pure over already-fetched rows
//! (`derivePermissions`, `permissionForTool`, the two status mappers), plus one
//! thin DB-facing convenience (`permissionsForSession`) that reads a session's
//! rows through `CloudAgents.Repository` and folds them. It does **not** rewrite
//! the emitted checkpoint steps: the mapper that assigns a step's `permission`
//! is vendored verbatim from the platform (`vendor/testamur-checkpoint-format/`,
//! the drift-guard / content-address contract) and supports only one
//! session-level permission — attaching a per-tool map is a cross-repo mapper
//! change, sequenced as a follow-up (see the spec §"Attachment point"). The
//! `permissionForTool` accessor is exactly the seam that future integration
//! calls per `tool_use` step.
//!
//! ## Mapping and precedence (spec §3–§4)
//!
//! Only an explicit human decision claims `Granted`/`Denied`; everything else
//! (pending, secret `timed_out`) is `Auto` — the least-claiming closed-set
//! value, matching the vendored adapter's stated philosophy ("claiming granted
//! would assert an explicit human grant the record does not show"). A
//! permission-request timeout is already materialized as `denied` by the
//! timeout sweep, so it presents as `Denied`; a secret-request timeout keeps its
//! own `timed_out` status and presents as `Auto`. When one tool key has several
//! rows, they fold with a conservative precedence `Denied > Granted > Auto`, so
//! a tool denied even once always surfaces as denied — the audit-safe reading
//! of a lossy per-tool-name aggregation.
@runtime_checked
package CloudAgents.PermissionEnrichment

import Std.Core
import Std.Collections
import Std.Encoding
import CloudAgents.Repository
import CloudAgents.Sqlite
import Testamur.CheckpointFormat.Model

// ─── Derived shape ───────────────────────────────────────────────────────────
/// One tool's derived permission outcome. `tool` is the checkpoint `tool_use`
/// tool name for a `permission_requests` row, or the synthetic
/// `request_secret:<name>` key (see `secretToolKey`) for a `secret_requests`
/// row. `permission` is the folded closed-set outcome.
pub record ToolPermission {
  pub tool: String
  pub permission: Permission
}

/// Construct a `ToolPermission` (one tool's outcome). Provided as a function so
/// callers outside this package build the value through the home package —
/// sidestepping the intermittent cross-package record-construction
/// `InvalidProgramException` documented in `docs/lyric/gotchas.md` (home-package
/// construction, as `derivePermissions`/`permissionsForSession` do below, is
/// unaffected).
pub func toolPermission(tool: in String, permission: in Permission): ToolPermission {
  return ToolPermission(tool = tool, permission = permission)
}

/// The synthetic per-secret tool key: secret asks flow through the
/// `request_secret` MCP tool, so each named credential decision is keyed
/// `request_secret:<name>` — distinct from real tool permissions, and it keeps
/// the credential name for audit rather than collapsing every ask onto one key.
pub func secretToolKey(name: in String): String {
  return "request_secret:" + name
}

// ─── Status → Permission mappers (spec §3) ───────────────────────────────────
/// Map a `permission_requests.status` to a checkpoint `Permission`. `allowed`
/// is an explicit human grant (`Granted`); `denied` an explicit human denial
/// (`Denied`) — the timeout sweep also stores `denied`, so a timed-out prompt
/// presents as `Denied`. Anything else (`pending`, or an unknown status) is
/// `Auto`: no explicit human decision to over-claim.
pub func permissionOfStatus(status: in String): Permission {
  if status == "allowed" {
    return Granted
  }
  if status == "denied" {
    return Denied
  }
  return Auto
}

/// Map a `secret_requests.status` to a checkpoint `Permission`. `approved` is
/// an explicit grant (`Granted`), `denied` an explicit denial (`Denied`).
/// `timed_out` (a distinct secret status, unlike the permission table) and
/// `pending` are `Auto` — no explicit human decision.
pub func permissionOfSecretStatus(status: in String): Permission {
  if status == "approved" {
    return Granted
  }
  if status == "denied" {
    return Denied
  }
  return Auto
}

// ─── Conservative fold (spec §4) ─────────────────────────────────────────────
// Precedence rank for the conservative fold: Denied (2) > Granted (1) >
// Auto (0). Higher rank wins, so a tool key with any denial folds to Denied.
func permissionRank(p: in Permission): Int {
  return match p { case Denied -> 2; case Granted -> 1; case Auto -> 0 }
}

func moreConservative(a: in Permission, b: in Permission): Permission {
  if permissionRank(a) >= permissionRank(b) {
    return a
  }
  return b
}

func indexOfKey(keys: in List[String], key: in String): Int {
  var i = 0
  while i < keys.count {
    if keys[i] == key {
      return i
    }
    i = i + 1
  }
  return -1
}

// Strict UTF-8 byte-order less-than, so the derived list has a stable order
// independent of row insertion timing. Byte-for-byte the vendored model.l's
// `utf8Less` (encode both, compare `Byte.toInt()` codes) — the fully-verified
// pattern used throughout the tested checkpoint-format code, so no reliance on
// string indexing or a `String < String` operator. Tool names are ASCII in
// practice, where byte order coincides with ordinal order; total for any string.
func keyLess(a: in String, b: in String): Bool {
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

// Insertion sort on strings (rebuild-on-insert, same shape as the vendored
// adapter's sortNames), the derivation's row count is tiny.
func sortKeys(keys: in List[String]): List[String] {
  var sorted: List[String] = newList()
  var i = 0
  while i < keys.count {
    val key = keys[i]
    val next: List[String] = newList()
    var j = 0
    var inserted = false
    while j < sorted.count {
      if not inserted and keyLess(key, sorted[j]) {
        next.add(key)
        inserted = true
      }
      next.add(sorted[j])
      j = j + 1
    }
    if not inserted {
      next.add(key)
    }
    sorted = next
    i = i + 1
  }
  return sorted
}

/// Fold one-entry-per-source-row `ToolPermission`s into one entry per distinct
/// tool key, combining duplicates with the conservative precedence
/// `Denied > Granted > Auto`. Output is sorted by tool key (deterministic
/// regardless of input order). Pure — no DB, no clock.
pub func derivePermissions(rows: in List[ToolPermission]): List[ToolPermission] {
  val keys: List[String] = newList()
  var i = 0
  while i < rows.count {
    if indexOfKey(keys, rows[i].tool) < 0 {
      keys.add(rows[i].tool)
    }
    i = i + 1
  }
  val ordered = sortKeys(keys)
  val entries: List[ToolPermission] = newList()
  var k = 0
  while k < ordered.count {
    val key = ordered[k]
    var acc: Permission = Auto
    var j = 0
    while j < rows.count {
      if rows[j].tool == key {
        acc = moreConservative(acc, rows[j].permission)
      }
      j = j + 1
    }
    entries.add(ToolPermission(tool = key, permission = acc))
    k = k + 1
  }
  return entries
}

/// The folded permission for one tool key, or `Auto` when the session recorded
/// no request row for it (the mapper's default — an unprompted tool was
/// auto-approved, never claims an explicit grant/denial). This is the accessor
/// a future mapper integration calls per `tool_use` step to pick the step's
/// permission from the derived map.
pub func permissionForTool(perms: in List[ToolPermission], tool: in String): Permission {
  var i = 0
  while i < perms.count {
    if perms[i].tool == tool {
      return perms[i].permission
    }
    i = i + 1
  }
  return Auto
}

// ─── DB-facing convenience ───────────────────────────────────────────────────
/// Read a session's `permission_requests` and `secret_requests` rows and fold
/// them into the per-tool permission map. Reuses the existing session-scoped
/// accessors with the empty cursor (`created_at > ''` matches every row, since
/// `created_at` is always a non-empty millis string), so no new SQL is needed.
/// Synchronous — the whole repository layer is.
pub func permissionsForSession(sessionId: in String): Result[List[ToolPermission], CloudAgents.Sqlite.DbError] {
  val perms = CloudAgents.Repository.permissionRequestsCreatedAfter(sessionId, "")?
  val secrets = CloudAgents.Repository.secretRequestsCreatedAfter(sessionId, "")?
  val rows: List[ToolPermission] = newList()
  var i = 0
  while i < perms.length.toInt() {
    rows.add(ToolPermission(tool = perms[i].toolName, permission = permissionOfStatus(perms[i].status)))
    i = i + 1
  }
  var j = 0
  while j < secrets.length.toInt() {
    rows.add(
      ToolPermission(tool = secretToolKey(secrets[j].name), permission = permissionOfSecretStatus(secrets[j].status))
    )
    j = j + 1
  }
  return Ok(value = derivePermissions(rows))
}
