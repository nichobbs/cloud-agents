//! CloudAgents.KeyCache: membership, expiry, removal and the size bound.
@test_module
package CloudAgents.KeyCacheTests

import Std.Core
import Std.Testing
import CloudAgents.KeyCache

protected type TestCache {
  var table: CloudAgents.KeyCache.Hashtable = CloudAgents.KeyCache.newTable()
  entry isLive(key: in String, nowMs: in Long): Bool {
    return CloudAgents.KeyCache.liveIn(table, key, nowMs)
  }
  entry remember(key: in String, expiresAtMs: in Long): Unit {
    CloudAgents.KeyCache.rememberIn(table, key, expiresAtMs, 3)
  }
  entry forget(key: in String): Unit {
    CloudAgents.KeyCache.forgetIn(table, key)
  }
  entry entryCount(): Int {
    return CloudAgents.KeyCache.countIn(table)
  }
}

test "a key is present until it expires" {
  val c = TestCache()
  val now = CloudAgents.KeyCache.nowMillis()
  assertFalse(c.isLive("a", now), "absent before put")
  c.remember("a", now + 1000.toLong())
  assertTrue(c.isLive("a", now), "present before expiry")
  assertFalse(c.isLive("a", now + 1000.toLong()), "gone at expiry")
  assertFalse(c.isLive("a", now), "and removed once seen expired")
}

test "remove drops a key and put refreshes one" {
  val c = TestCache()
  val now = CloudAgents.KeyCache.nowMillis()
  c.remember("k", now + 10.toLong())
  c.remember("k", now + 100000.toLong())
  assertTrue(c.isLive("k", now + 50.toLong()), "the later expiry wins")
  c.forget("k")
  assertFalse(c.isLive("k", now), "removed")
  assertEqualInt(c.entryCount(), 0, "empty")
}

test "a full table is cleared before the next key goes in" {
  val c = TestCache()
  val later = CloudAgents.KeyCache.nowMillis() + 100000.toLong()
  c.remember("a", later)
  c.remember("b", later)
  c.remember("c", later)
  assertEqualInt(c.entryCount(), 3, "full")
  c.remember("d", later)
  assertEqualInt(c.entryCount(), 1, "cleared, then the new key added")
}

test "expiry stamps sort as times" {
  assertTrue(CloudAgents.KeyCache.stamp(999.toLong()) < CloudAgents.KeyCache.stamp(1000.toLong()), "fixed width")
  assertEqualInt(CloudAgents.KeyCache.stamp(42.toLong()).length.toInt(), 19, "19 digits")
}
