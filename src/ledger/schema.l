//! CloudAgents.Ledger.Schema — the session ledger's SQLite DDL (migration
//! 0036_session_ledger) and its small JSON list codec
//! (docs/session-ledger.md §4).
//!
//! A leaf package (it imports nothing from cloud-agents) so
//! CloudAgents.Repository can register the migration without a dependency
//! cycle through CloudAgents.Ledger.Store, which itself depends on the
//! repository. Every column has TEXT affinity: the minimal
//! CloudAgents.Sqlite driver reads every column with GetString. Numeric
//! cursors (`seq`, `created_seq`, `updated_seq`, `ord`) are decimal TEXT and
//! are compared with CAST(... AS INTEGER).
package CloudAgents.Ledger.Schema

import Std.Core

/// Per-session ledger bookkeeping: the change cursor `seq` (bumped by every
/// ledger write in the same transaction as the write) and the cached repo
/// policy (`policy_status` is '' until first fetched, then 'absent',
/// 'loaded' or 'invalid').
pub func ledgerSessionsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS ledger_sessions (" + "session_id TEXT PRIMARY KEY, " + "seq TEXT NOT NULL, " +
    "policy_status TEXT NOT NULL, " +
    "policy_json TEXT NOT NULL, " +
    "policy_error TEXT NOT NULL, " +
    "created_at TEXT NOT NULL)"
}

/// Work items. `blocked_by` is a JSON string array.
pub func ledgerItemsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS ledger_items (" + "session_id TEXT NOT NULL, " + "item_id TEXT NOT NULL, " +
    "title TEXT NOT NULL, " +
    "url TEXT NOT NULL, " +
    "state TEXT NOT NULL, " +
    "blocked_by TEXT NOT NULL, " +
    "blocked_reason TEXT NOT NULL, " +
    "prerequisite_proposal TEXT NOT NULL, " +
    "recommendation TEXT NOT NULL, " +
    "pr_url TEXT NOT NULL, " +
    "ord TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL, " +
    "updated_seq TEXT NOT NULL, " +
    "PRIMARY KEY (session_id, item_id))"
}

/// Ledger entries. `options_json` / `files_json` / `tags_json` are JSON
/// string arrays.
pub func ledgerEntriesSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS ledger_entries (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "item_id TEXT NOT NULL, " +
    "kind TEXT NOT NULL, " +
    "severity TEXT NOT NULL, " +
    "declared_severity TEXT NOT NULL, " +
    "summary TEXT NOT NULL, " +
    "detail TEXT NOT NULL, " +
    "options_json TEXT NOT NULL, " +
    "chosen TEXT NOT NULL, " +
    "rationale TEXT NOT NULL, " +
    "recommendation TEXT NOT NULL, " +
    "proceeding_with TEXT NOT NULL, " +
    "reversible TEXT NOT NULL, " +
    "files_json TEXT NOT NULL, " +
    "tags_json TEXT NOT NULL, " +
    "source TEXT NOT NULL, " +
    "undeclared TEXT NOT NULL, " +
    "matched_entry_id TEXT NOT NULL, " +
    "origin TEXT NOT NULL, " +
    "supersedes TEXT NOT NULL, " +
    "transcript_seq TEXT NOT NULL, " +
    "review_state TEXT NOT NULL, " +
    "review_by TEXT NOT NULL, " +
    "review_at TEXT NOT NULL, " +
    "review_comment TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "created_seq TEXT NOT NULL, " +
    "updated_seq TEXT NOT NULL)"
}

pub func ledgerEntriesSessionIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_ledger_entries_session ON ledger_entries(session_id, review_state)"
}

pub func ledgerTransitionsSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS ledger_transitions (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "item_id TEXT NOT NULL, " +
    "from_state TEXT NOT NULL, " +
    "to_state TEXT NOT NULL, " +
    "actor TEXT NOT NULL, " +
    "reason TEXT NOT NULL, " +
    "at TEXT NOT NULL, " +
    "seq TEXT NOT NULL)"
}

pub func ledgerTransitionsIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_ledger_transitions_item ON ledger_transitions(session_id, item_id)"
}

/// Human -> agent feedback. `delivery_batch` tags the rows one
/// ledger_check_feedback call claimed, so claim-then-read is atomic.
pub func ledgerFeedbackSchemaSql(): String {
  return "CREATE TABLE IF NOT EXISTS ledger_feedback (" + "id TEXT PRIMARY KEY, " + "session_id TEXT NOT NULL, " +
    "entry_id TEXT NOT NULL, " +
    "item_id TEXT NOT NULL, " +
    "kind TEXT NOT NULL, " +
    "body TEXT NOT NULL, " +
    "created_by TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "delivered_at TEXT NOT NULL, " +
    "delivered_via TEXT NOT NULL, " +
    "delivery_batch TEXT NOT NULL, " +
    "updated_seq TEXT NOT NULL)"
}

pub func ledgerFeedbackIndexSql(): String {
  return "CREATE INDEX IF NOT EXISTS idx_ledger_feedback_session ON ledger_feedback(session_id, delivered_at)"
}

/// The ledger tools the in-container shim registers (shim/src/main.l —
/// kept in sync by hand, as CloudAgents.Profiles.validShimToolNames is).
pub func ledgerToolNames(): slice[String] {
  return [
    "ledger_register_items",
    "ledger_set_item_status",
    "ledger_record_decision",
    "ledger_record_deviation",
    "ledger_ask",
    "ledger_note",
    "ledger_check_feedback",
    "ledger_get_state"
  ]
}

val retiredToolsInList = "('add_todo', 'update_todo', 'list_todos', 'add_followup_task')"

/// Migration 0036_session_ledger: the ledger tables and indexes, then the
/// profile-grant rewrite. Grants are inserted before the retired rows are
/// deleted so the rewrite is a pure function of the pre-migration grants;
/// the NOT EXISTS guard makes it idempotent.
pub func sessionLedgerMigrationSql(): slice[String] {
  var stmts: slice[String] = [
    ledgerSessionsSchemaSql(),
    ledgerItemsSchemaSql(),
    ledgerEntriesSchemaSql(),
    ledgerEntriesSessionIndexSql(),
    ledgerTransitionsSchemaSql(),
    ledgerTransitionsIndexSql(),
    ledgerFeedbackSchemaSql(),
    ledgerFeedbackIndexSql()
  ]
  val names = ledgerToolNames()
  var i = 0
  while i < names.length.toInt() {
    val t = "'" + names[i] + "'"
    stmts = stmts.append(
      "INSERT INTO profile_tools (id, profile_id, user_id, tool_name) SELECT lower(hex(randomblob(16))), p.profile_id, p.user_id, " +
        t +
        " FROM (SELECT DISTINCT profile_id, user_id FROM profile_tools WHERE tool_name IN " +
        retiredToolsInList +
        ") p WHERE NOT EXISTS (SELECT 1 FROM profile_tools x WHERE x.profile_id = p.profile_id AND x.user_id = p.user_id AND x.tool_name = " +
        t +
        ")"
    )
    i = i + 1
  }
  stmts = stmts.append("DELETE FROM profile_tools WHERE tool_name IN " + retiredToolsInList)
  return stmts
}

/// The attention-queue size of one session (entries still pending a review
/// at review or blocking severity), as a SQL scalar subquery over
/// `sessions.id` for the session-list projection.
pub func attentionCountSubquery(): String {
  return "(SELECT COUNT(*) FROM ledger_entries WHERE session_id = sessions.id AND review_state = 'pending' AND severity IN ('review', 'blocking'))"
}

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
