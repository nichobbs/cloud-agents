//! CloudAgents.Ledger.Schema — the session ledger's JSON string-list codec
//! (docs/session-ledger.md §4): list-valued ledger columns (labels, refs,
//! options) are stored as a JSON array. The ledger tables themselves are in
//! the Postgres schema (src/pg/schema.l).
//!
//! A leaf package (it imports nothing from cloud-agents), so the stores can
//! use it without a dependency cycle.
package CloudAgents.Ledger.Schema

import Std.Core

// ── JSON string-array codec ───────────────────────────────────────────────────
@generate(Json)
pub record StringList {
  pub items: slice[String]
}

/// Encode a string list as a JSON array.
pub func encodeStringList(xs: in slice[String]): String {
  val body = StringList(items = xs).toJson()
  // StringList's JSON is {"items":[...]}; store just the array.
  return body.substring(9, body.length.toInt() - 10)
}

/// Decode a JSON string array stored by encodeStringList; [] for "" or
/// anything unreadable (a corrupt cell degrades to "no entries", never a
/// failed read of the whole row).
pub func decodeStringList(json: in String): slice[String] {
  val none: slice[String] = []
  if json.length.toInt() == 0 {
    return none
  }
  return try {
    match StringList.fromJson("{\"items\":" + json + "}") {
      case Ok(l) -> l.items
      case Err(_) -> none
    }
  } catch Bug as b {
    none
  }
}
