//! Testamur.CheckpointFormat.Chain — content-addressing and hash-chain
//! verification (docs/specs/checkpoint-format.md §2 intro, §4).
//!
//! IDs are `sess-` / `step-` / `ckpt-` + lowercase-hex SHA-256 of the
//! object's TAG-LESS canonical body: `Canon.encodeCanonical` of the Model
//! encoding, UTF-8 bytes, SHA-256. For checkpoints the hashed body is
//! `Model.encodeCheckpoint` — the `signature` field is excluded (§3.7)
//! structurally, because the `Checkpoint` record cannot carry one.
//!
//! `verifyChain` (§4): given a checkpoint id and an object store, recompute
//! every reachable object's hash against the id it is stored under, check
//! parent links, check frontier consistency (every listed step exists; none
//! has a descendant within the checkpoint's step closure), check
//! continuity across checkpoint boundaries (every step in a parent
//! checkpoint's frontier is an ancestor of the child checkpoint's frontier,
//! so a later checkpoint cannot splice in a history disjoint from the tip it
//! claims to build on), and check timestamps are non-decreasing along every
//! parent path (steps and checkpoints). Verdicts are typed: `Valid`,
//! `Broken(objectId, reason)`,
//! or `Incomplete(missingIds)` — `Incomplete` is NOT `Broken` (§4: partial
//! mirrors are legitimate; policy decides). A structural violation found on
//! the objects that ARE present wins over missing objects; a store that is
//! merely missing objects, with everything present consistent, is
//! `Incomplete`.
//!
//! Timestamp comparison is plain byte comparison of the RFC 3339 strings.
//! ASSUMPTION (documented per §4): all timestamps in a chain are RFC 3339
//! UTC (`Z` suffix) at the same precision — the spec fixes second precision
//! (§2.1) — under which lexicographic byte order coincides with temporal
//! order. Mixed offsets or mixed precision would need real parsing; the
//! format does not admit them.
//!
//! The in-memory `ObjectStore` here is deliberately minimal (a parallel
//! id/object list pair): enough for verification and tests. It is NOT the
//! platform store — the git ref mapping (§5) is a separate concern.
//!
//! Attribution (§4 last sentence): `classifyAttribution` grades a
//! checkpoint as attributed or unattributed through a `Sign.Verifier`.
//! Unsigned or verify-failing checkpoints are UNATTRIBUTED-grade — a
//! verdict, never an error.
//!
//! FFI note: Sign is the checkpoint format's crypto surface, but its
//! SHA-256 binding is package-private, so this package carries its own
//! two static BCL bindings (same pattern as cloud-agents
//! src/crypto/crypto.l); UTF-8 byte conversion reuses `Sign.utf8Bytes`.
@runtime_checked
package Testamur.CheckpointFormat.Chain

import Std.Collections
import Std.Core
import Std.Encoding
import Testamur.CheckpointFormat.Canon
import Testamur.CheckpointFormat.Model
import Testamur.CheckpointFormat.Sign

@externTarget("System.Security.Cryptography.SHA256.HashData")
func sha256(data: in slice[Byte]): slice[Byte] = []

@externTarget("System.Convert.ToHexStringLower")
func toHexLower(b: in slice[Byte]): String = ""

// ─── Content addressing (spec §2 intro, §3.7) ──────────────────────────────
func bodyHashHex(v: in JsonValue): String {
  return toHexLower(sha256(utf8Bytes(encodeCanonical(v))))
}

/// The content address of a `Session`: `sess-` + lowercase-hex SHA-256 of
/// its canonical body.
pub func sessionIdOf(session: in Session): String {
  return "sess-" + bodyHashHex(encodeSession(session))
}

/// The content address of a `Step`: `step-` + lowercase-hex SHA-256 of its
/// canonical body. A step's body commits to its parents' ids, so the DAG is
/// a Merkle structure (§4): tampering with any ancestor changes every
/// descendant's expected content.
pub func stepIdOf(step: in Step): String {
  return "step-" + bodyHashHex(encodeStep(step))
}

/// The content address of a `Checkpoint`: `ckpt-` + lowercase-hex SHA-256
/// of its canonical HASHED body — `signature` excluded (§3.7), which is
/// structural here: `Checkpoint` has no signature field. An envelope's id
/// is its checkpoint's id, signed or not.
pub func checkpointIdOf(checkpoint: in Checkpoint): String {
  return "ckpt-" + bodyHashHex(encodeCheckpoint(checkpoint))
}

/// The content address of any `ProvenanceObject`.
pub func objectIdOf(obj: in ProvenanceObject): String {
  return match obj {
    case SessionObject(session) -> sessionIdOf(session)
    case StepObject(step) -> stepIdOf(step)
    case CheckpointObject(envelope) -> checkpointIdOf(envelope.checkpoint)
  }
}

/// The canonical byte body a checkpoint signature covers (§3.7: the same
/// tag-less hashed body the id commits to, signature excluded). Sign this
/// with a `Sign.Signer`; `classifyAttribution` verifies over exactly these
/// bytes.
pub func checkpointPayload(checkpoint: in Checkpoint): slice[Byte] {
  return utf8Bytes(encodeCanonical(encodeCheckpoint(checkpoint)))
}

/// Strict UTF-8 byte order on strings — the order checkpoint `steps` must
/// be sorted in (§3.6) and the order used for the timestamp comparisons
/// (see the module doc's RFC 3339 assumption). Exposed so frontier builders
/// and tests sort exactly the way the verifier checks.
pub func idLess(a: in String, b: in String): Bool {
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

// ─── In-memory object store ────────────────────────────────────────────────
/// A minimal in-memory id → object map, sufficient for `verifyChain` and
/// tests (NOT the platform store, §5). Fields are package-private:
/// construct with `newObjectStore` and fill with `storePut`. Ids are stored
/// as CLAIMED — `storePut` does not recompute them, because verification
/// must be able to model a store whose content does not match its ids.
pub record ObjectStore {
  ids: List[String]
  objs: List[ProvenanceObject]
}

/// Create an empty `ObjectStore`.
pub func newObjectStore(): ObjectStore {
  val ids: List[String] = newList()
  val objs: List[ProvenanceObject] = newList()
  return ObjectStore(ids = ids, objs = objs)
}

/// Add `obj` under the claimed `id`. First put of an id wins on lookup;
/// re-putting an existing id never replaces it.
pub func storePut(store: in ObjectStore, id: in String, obj: in ProvenanceObject): Unit {
  store.ids.add(id)
  store.objs.add(obj)
}

/// Look up an object by id. First matching put wins.
pub func storeGet(store: in ObjectStore, id: in String): Option[ProvenanceObject] {
  var i = 0
  while i < store.ids.count {
    if store.ids[i] == id {
      return Some(value = store.objs[i])
    }
    i = i + 1
  }
  return None
}

/// Number of objects in the store (including any shadowed duplicate puts).
pub func storeSize(store: in ObjectStore): Int {
  return store.ids.count
}

// ─── verifyChain (spec §4) ─────────────────────────────────────────────────
/// The typed verdict of `verifyChain` (§4). `Incomplete` is NOT `Broken`:
/// a store that is merely missing objects (a partial mirror) is legitimate
/// and policy decides how to treat it; `Broken` means an object that IS
/// present fails recomputation or violates a chain invariant.
pub union ChainVerdict {
  case Valid
  case Broken(objectId: String, reason: String)
  case Incomplete(missingIds: List[String])
}

/// Human-readable rendering of a `ChainVerdict`, for logs and diagnostics.
pub func chainVerdictMessage(verdict: in ChainVerdict): String {
  return match verdict {
    case Valid -> "valid"
    case Broken(id, reason) -> "broken at " + id + ": " + reason
    case Incomplete(missingIds) -> {
      var buf = "incomplete: missing"
      var i = 0
      while i < missingIds.count {
        buf = buf + " " + missingIds[i]
        i = i + 1
      }
      buf
    }
  }
}

func noteMissing(missing: in List[String], id: in String): Unit {
  if not listContains(missing, id) {
    missing.add(id)
  }
}

/// Verify the hash chain reachable from the checkpoint stored under
/// `checkpointId` (§4): recompute every reachable object's hash against its
/// claimed id, walk the checkpoint parent chain, verify the session object,
/// and for every checkpoint in the chain verify its step closure — every
/// listed frontier step exists, no frontier step has a descendant within
/// that checkpoint's step closure, steps belong to the checkpoint's
/// session, and timestamps are non-decreasing along every parent path
/// (byte-compared RFC 3339 UTC strings; see the module doc's assumption).
/// Adjacent checkpoints must also be CONTINUOUS: every step in a parent
/// checkpoint's frontier must appear in the child checkpoint's transitive
/// step closure — a child that splices in a disjoint history (its steps do
/// not descend from the parent's tip) is `Broken`, not `Valid`.
///
/// Returns `Broken(objectId, reason)` naming the first offending PRESENT
/// object, else `Incomplete(missingIds)` naming every reachable-but-absent
/// id, else `Valid`.
pub func verifyChain(checkpointId: in String, store: in ObjectStore): ChainVerdict {
  val missing: List[String] = newList()
  val chainIds: List[String] = newList()
  val chainEnvelopes: List[CheckpointEnvelope] = newList()

  // Phase 1: the checkpoint parent chain, newest first. Hash-check each
  // checkpoint as it is reached; a cycle among the ids is itself tamper
  // evidence (content-addressed parents cannot cycle honestly).
  var cur = checkpointId
  var walking = true
  while walking {
    if listContains(chainIds, cur) {
      return Broken(objectId = cur, reason = "checkpoint parent chain revisits " + cur + " (cycle)")
    }
    match storeGet(store, cur) {
      case None -> {
        noteMissing(missing, cur)
        walking = false
      }
      case Some(obj) -> match obj { case CheckpointObject(envelope) -> { val recomputed = checkpointIdOf(envelope.checkpoint); if recomputed != cur { return Broken(objectId = cur, reason = "content hash mismatch: stored checkpoint re-hashes to " + recomputed) }; chainIds.add(cur); chainEnvelopes.add(envelope); match envelope.checkpoint.parent { case Some(p) -> { cur = p }; case None -> { walking = false } } }; case SessionObject(_) -> return Broken(objectId = cur, reason = "expected a checkpoint, found a session"); case StepObject(_) -> return Broken(objectId = cur, reason = "expected a checkpoint, found a step") }
    }
  }

  // Phase 2: pairwise checkpoint-chain invariants (child at index i, its
  // parent at i + 1): same session, and parent.at <= child.at.
  var ci = 0
  while ci + 1 < chainEnvelopes.count {
    val child = chainEnvelopes[ci]
    val parent = chainEnvelopes[ci + 1]
    if parent.checkpoint.session != child.checkpoint.session {
      return Broken(
        objectId = chainIds[ci],
        reason = "parent checkpoint " + chainIds[ci + 1] + " belongs to session " + parent.checkpoint.session +
          " but this checkpoint's session is " +
          child.checkpoint.session
      )
    }
    if idLess(child.checkpoint.at, parent.checkpoint.at) {
      return Broken(
        objectId = chainIds[ci],
        reason = "timestamp regression: checkpoint at " + child.checkpoint.at + " precedes its parent " +
          chainIds[ci + 1] +
          " at " +
          parent.checkpoint.at
      )
    }
    ci = ci + 1
  }

  // Phase 3: the session object (all chain checkpoints share it, phase 2).
  // Its verified `principal.id` is threaded into the per-step closure check
  // (phase 4) so a step cannot claim an `origin.sessionPrincipal` that
  // disagrees with the session it belongs to (spec §2.4). When the session
  // object is absent (a partial mirror), the principal stays `None` and the
  // cross-check is skipped — missing is Incomplete, never Broken.
  var sessionPrincipal: Option[String] = None
  if chainEnvelopes.count > 0 {
    val sessionId = chainEnvelopes[0].checkpoint.session
    match storeGet(store, sessionId) {
      case None -> noteMissing(missing, sessionId)
      case Some(obj) -> match obj { case SessionObject(session) -> { val recomputed = sessionIdOf(session); if recomputed != sessionId { return Broken(objectId = sessionId, reason = "content hash mismatch: stored session re-hashes to " + recomputed) }; sessionPrincipal = Some(value = session.principal.id) }; case StepObject(_) -> return Broken(objectId = sessionId, reason = "expected a session, found a step"); case CheckpointObject(_) -> return Broken(objectId = sessionId, reason = "expected a session, found a checkpoint") }
    }
  }

  // Phase 4: every chain checkpoint's step closure. Each checkpoint's
  // transitive parent-closure (its present, reachable steps) is captured for
  // phase 5's continuity check.
  val chainClosures: List[List[String]] = newList()
  var ei = 0
  while ei < chainEnvelopes.count {
    val closureIds: List[String] = newList()
    match verifyCheckpointSteps(chainIds[ei], chainEnvelopes[ei], store, missing, sessionPrincipal, closureIds) {
      case Valid -> ()
      case Broken(objectId, reason) -> return Broken(objectId = objectId, reason = reason)
      case Incomplete(missingIds) -> return Incomplete(missingIds = missingIds)
    }
    chainClosures.add(closureIds)
    ei = ei + 1
  }

  // Phase 5: parent-frontier continuity (child at index i, its parent at
  // i + 1 in the newest-first chain). An append-only session's later
  // checkpoint must build on the earlier tip, so EVERY step id in the parent
  // checkpoint's frontier must be an ancestor of — or equal to — some step in
  // the child's frontier, i.e. must appear in the child's transitive
  // parent-closure. A spliced/omitted history (a child whose steps are
  // disjoint from the parent's frontier) fails this. A parent-frontier step
  // that is PRESENT in the store but absent from the child's closure is
  // tamper evidence (`Broken`); one merely MISSING from the store cannot have
  // its ancestry proven and stays `Incomplete` via the existing
  // missing-tracking — never promoted to Broken. Broken (present-but-
  // violating) wins over Incomplete, consistent with the earlier phases. The
  // oldest checkpoint has no parent (no pair); a parent with an empty
  // frontier is vacuously satisfied.
  var pj = 0
  while pj + 1 < chainEnvelopes.count {
    val parentFrontier = chainEnvelopes[pj + 1].checkpoint.steps
    val childClosure = chainClosures[pj]
    var fj = 0
    while fj < parentFrontier.count {
      val frontierId = parentFrontier[fj]
      if not listContains(childClosure, frontierId) {
        match storeGet(store, frontierId) {
          case Some(_) -> return Broken(
            objectId = chainIds[pj],
            reason = "parent frontier step " + frontierId +
              " is not an ancestor of this checkpoint's frontier (history splice/omission)"
          )
          case None -> ()
        }
      }
      fj = fj + 1
    }
    pj = pj + 1
  }

  if missing.count > 0 {
    return Incomplete(missingIds = missing)
  }
  return Valid
}

// One checkpoint's step verification (§4): BFS the parent closure from the
// frontier, hash-checking and session-checking each present step, then
// check frontier-descendant and per-edge timestamp invariants over the
// loaded closure. Missing steps accumulate into `missing` (the caller
// decides Incomplete); this helper only ever returns Valid or Broken.
//
// On a `Valid` return the transitive parent-closure (every PRESENT step
// reachable from the frontier through parent edges) is appended to
// `closureOut`, so `verifyChain`'s pairwise continuity check (phase 5) can
// test parent-frontier containment without re-walking the DAG. On a `Broken`
// return `closureOut`'s contents are unspecified and the caller ignores them.
func verifyCheckpointSteps(
  checkpointId: in String,
  envelope: in CheckpointEnvelope,
  store: in ObjectStore,
  missing: in List[String],
  sessionPrincipal: in Option[String],
  closureOut: in List[String],
): ChainVerdict {
  val frontier = envelope.checkpoint.steps

  // Defence in depth: Model's decoder already rejects unsorted wire input
  // (§3.6), but an in-memory construction bypasses decode.
  var fi = 0
  while fi + 1 < frontier.count {
    if not idLess(frontier[fi], frontier[fi + 1]) {
      return Broken(
        objectId = checkpointId,
        reason = "frontier steps are not sorted strictly ascending at index " + toString(fi + 1)
      )
    }
    fi = fi + 1
  }

  val queue: List[String] = newList()
  var i = 0
  while i < frontier.count {
    queue.add(frontier[i])
    i = i + 1
  }
  val closureIds: List[String] = newList()
  val closureSteps: List[Step] = newList()
  var qi = 0
  while qi < queue.count {
    val sid = queue[qi]
    qi = qi + 1
    if not listContains(closureIds, sid) {
      match storeGet(store, sid) {
        case None -> noteMissing(missing, sid)
        case Some(obj) -> match obj { case StepObject(step) -> { val recomputed = stepIdOf(step); if recomputed != sid { return Broken(objectId = sid, reason = "content hash mismatch: stored step re-hashes to " + recomputed) }; if step.session != envelope.checkpoint.session { return Broken(objectId = sid, reason = "step belongs to session " + step.session + " but checkpoint " + checkpointId + "'s session is " + envelope.checkpoint.session) }; match sessionPrincipal { case Some(pid) -> { if step.origin.sessionPrincipal != pid { return Broken(objectId = sid, reason = "origin.sessionPrincipal " + step.origin.sessionPrincipal + " disagrees with session principal " + pid) } }; case None -> () }; closureIds.add(sid); closureSteps.add(step); var pi = 0; while pi < step.parents.count { queue.add(step.parents[pi]); pi = pi + 1 } }; case SessionObject(_) -> return Broken(objectId = sid, reason = "expected a step, found a session"); case CheckpointObject(_) -> return Broken(objectId = sid, reason = "expected a step, found a checkpoint") }
      }
    }
  }

  // Frontier consistency + timestamps over the loaded closure. A frontier
  // id appearing among ANY closure step's parents means the frontier lists
  // a step that has a descendant at snapshot time — the checkpoint is the
  // broken object (its frontier is wrong), not the steps.
  var si = 0
  while si < closureSteps.count {
    val step = closureSteps[si]
    val sid = closureIds[si]
    var pi = 0
    while pi < step.parents.count {
      val parentId = step.parents[pi]
      if listContains(frontier, parentId) {
        return Broken(
          objectId = checkpointId,
          reason = "frontier step " + parentId + " has descendant " + sid + " within the checkpoint's step closure"
        )
      }
      var ki = 0
      while ki < closureIds.count {
        if closureIds[ki] == parentId {
          if idLess(step.at, closureSteps[ki].at) {
            return Broken(
              objectId = sid,
              reason = "timestamp regression: step at " + step.at + " precedes its parent " + parentId + " at " +
                closureSteps[ki].at
            )
          }
        }
        ki = ki + 1
      }
      pi = pi + 1
    }
    si = si + 1
  }
  // Expose the computed closure to the caller (phase 5 continuity check).
  var co = 0
  while co < closureIds.count {
    closureOut.add(closureIds[co])
    co = co + 1
  }
  return Valid
}

// ─── Attribution grading (spec §4 last sentence) ───────────────────────────
/// The attribution grade of a checkpoint. Unsigned or verify-failing is
/// `Unattributed` — a grade, never an error (§4, §8.6): the record stays
/// valid, the review plane just cannot weight it on a verified origin.
pub union Attribution {
  case Attributed(keyid: String)
  case Unattributed(reason: String)
}

/// Human-readable rendering of an `Attribution`.
pub func attributionMessage(attribution: in Attribution): String {
  return match attribution {
    case Attributed(keyid) -> "attributed to keyid " + keyid
    case Unattributed(reason) -> "unattributed: " + reason
  }
}

/// Grade a checkpoint envelope through a `Sign.Verifier`: `Attributed` iff
/// a signature is present AND verifies over the checkpoint's canonical
/// hashed body (`checkpointPayload`, signature excluded per §3.7). Missing
/// signature, wrong key, tampered body, garbage signature — all degrade to
/// `Unattributed`; `Verifier.verify` is total, so no error path exists.
pub func classifyAttribution(envelope: in CheckpointEnvelope, verifier: in Verifier): Attribution {
  return match envelope.signature {
    case None -> Unattributed(reason = "checkpoint is unsigned")
    case Some(sig) -> {
      // Attribute to the keyid the verifier ACTUALLY matched, not the
      // attacker-controlled `sig.keyid` on the wire (spec §4).
      val payload = checkpointPayload(envelope.checkpoint)
      match verifyWith(verifier, payload, sig) {
        case Some(verifiedKeyid) -> Attributed(keyid = verifiedKeyid)
        case None -> Unattributed(reason = "signature by keyid " + sig.keyid + " failed verification")
      }
    }
  }
}
