//! Provenance data model: Session -> Step DAG -> Checkpoint, canonical
//! encoding, hash-chain verification, signing hooks, capture adapter
//! interface. Placeholder: implement against docs/specs/checkpoint-format.md
//! (reviewed spec required first — see AGENTS.md "Current phase").
package Testamur.CheckpointFormat

import Std.Core

// Schema identifiers are fixed by the spec (§2) and are the one piece of the
// contract safe to pin before implementation: adapters and fixtures key on
// them, and the golden-file ID tests (spec §8.2) will freeze them anyway.
/// Schema identifier for Session objects (spec §2.1).
pub func sessionSchema(): String {
  return "testamur/session/v1"
}

/// Schema identifier for Step objects (spec §2.2).
pub func stepSchema(): String {
  return "testamur/step/v1"
}

/// Schema identifier for Checkpoint objects (spec §2.6).
pub func checkpointSchema(): String {
  return "testamur/checkpoint/v1"
}
