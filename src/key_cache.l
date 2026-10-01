//! CloudAgents.KeyCache — a bounded, thread-safe set of string keys, each
//! with an expiry, for per-process caches on the request path (the personal
//! tenants already provisioned, organisation memberships already checked).
//!
//! Lookups are O(1): the keys live in a .NET `Hashtable` (non-generic, so it
//! binds without generic extern types; `Std.Collections.Map` does not
//! construct on this toolchain, see `CloudAgents.Handlers`' run-output
//! cache). When the table
//! reaches its bound it is cleared rather than evicted entry by entry: a
//! cache miss only costs the database round trip the cache saves.
//!
//! The lock is the caller's: each package declares its own small protected
//! type holding a table from `newTable()` and calls these helpers from its
//! entries. (On Lyric 0.7.5 a protected type's entries cannot be called
//! from another package, so the lock cannot live here.)
@runtime_checked
package CloudAgents.KeyCache

import Std.Core

extern type Hashtable = "System.Collections.Hashtable"

extern type DateTimeOffset = "System.DateTimeOffset"

@externTarget("System.DateTimeOffset.get_UtcNow")
func dtoUtcNow(): DateTimeOffset = ()

@externInstance
@externTarget("System.DateTimeOffset.ToUnixTimeMilliseconds")
func dtoToUnixMillis(t: in DateTimeOffset): Long = ()

@externInstance
@externTarget("System.Collections.Hashtable.ContainsKey")
func htContains(h: in Hashtable, key: in String): Bool = ()

// The value is stored as fixed-width text (see `stamp`): the getter returns
// object, and a String declaration binds where a boxed Long would not.
@externInstance
@externTarget("System.Collections.Hashtable.get_Item")
func htGet(h: in Hashtable, key: in String): String = ""

@externInstance
@externTarget("System.Collections.Hashtable.set_Item")
func htSet(h: in Hashtable, key: in String, value: in String): Unit = ()

@externInstance
@externTarget("System.Collections.Hashtable.Remove")
func htRemove(h: in Hashtable, key: in String): Unit = ()

@externInstance
@externTarget("System.Collections.Hashtable.Clear")
func htClear(h: in Hashtable): Unit = ()

@externInstance
@externTarget("System.Collections.Hashtable.get_Count")
func htCount(h: in Hashtable): Int = 0

pub func newTable(): Hashtable {
  return Hashtable.new()
}

/// The current time in epoch milliseconds.
pub func nowMillis(): Long {
  return dtoToUnixMillis(dtoUtcNow())
}

/// An expiry as fixed-width text, so string order is time order.
pub func stamp(ms: in Long): String {
  var s = toString(ms)
  while s.length < 19 {
    s = "0" + s
  }
  return s
}

/// Whether `key` is in `table` and unexpired at `nowMs`; an expired key is
/// dropped. Callers hold the table inside a protected type, which serialises
/// every call.
pub func liveIn(table: in Hashtable, key: in String, nowMs: in Long): Bool {
  if not htContains(table, key) {
    return false
  }
  if htGet(table, key) <= stamp(nowMs) {
    htRemove(table, key)
    return false
  }
  return true
}

/// Add or refresh `key` until `expiresAtMs`, clearing the table first when it
/// holds `maxEntries`.
pub func rememberIn(table: in Hashtable, key: in String, expiresAtMs: in Long, maxEntries: in Int): Unit {
  if htCount(table) >= maxEntries {
    htClear(table)
  }
  htSet(table, key, stamp(expiresAtMs))
}

pub func forgetIn(table: in Hashtable, key: in String): Unit {
  htRemove(table, key)
}

pub func countIn(table: in Hashtable): Int {
  return htCount(table)
}
