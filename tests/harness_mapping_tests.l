//! Every harness in CloudAgents.Harnesses.harnessIds() must have its own
//! entry in each per-harness mapping. The mappings fall back to claude's
//! values for an unknown harness, so a harness added to the list without a
//! mapping would otherwise run claude's image, home and providers silently
//! (#1254). Observer credentials are covered in ledger_observer_tests.l.
@test_module
package CloudAgents.HarnessMappingTests

import Std.Core
import Std.Testing
import CloudAgents.Harnesses
import CloudAgents.Db
import CloudAgents.Proxy
import CloudAgents.SessionStore

val unknownHarness = "not-a-harness"

func joined(xs: in slice[String]): String {
  var text = ""
  var i = 0
  while i < xs.length {
    text = text + xs[i] + ","
    i = i + 1
  }
  return text
}

func containsString(xs: in slice[String], x: in String): Bool {
  var i = 0
  while i < xs.length {
    if xs[i] == x {
      return true
    }
    i = i + 1
  }
  return false
}

test "the harness list is non-empty and has no duplicates" {
  val ids = harnessIds()
  assertTrue(ids.length > 0, "at least one harness")
  var seen: slice[String] = []
  var i = 0
  while i < ids.length {
    assertFalse(containsString(seen, ids[i]), ids[i] + " is listed once")
    seen = seen.append(ids[i])
    i = i + 1
  }
}

test "every harness has its own runner image" {
  val ids = harnessIds()
  val fallback = imageForHarness(unknownHarness)
  var seen: slice[String] = []
  var i = 0
  while i < ids.length {
    val image = imageForHarness(ids[i])
    if ids[i] != "claude" {
      assertTrue(image != fallback, ids[i] + " does not fall back to the claude image")
    }
    assertFalse(containsString(seen, image), ids[i] + " has an image no other harness uses")
    seen = seen.append(image)
    i = i + 1
  }
}

test "every harness has its own home mount path and home volume" {
  val ids = harnessIds()
  val fallbackPath = homeMountPathForHarness(unknownHarness)
  val fallbackVolume = homeVolumeBindForHarness(unknownHarness)
  var paths: slice[String] = []
  var volumes: slice[String] = []
  var i = 0
  while i < ids.length {
    val path = homeMountPathForHarness(ids[i])
    val volume = homeVolumeBindForHarness(ids[i])
    if ids[i] != "claude" {
      assertTrue(path != fallbackPath, ids[i] + " does not fall back to claude's home path")
      assertTrue(volume != fallbackVolume, ids[i] + " does not fall back to claude's home volume")
    }
    assertFalse(containsString(paths, path), ids[i] + " has a home path no other harness uses")
    assertFalse(containsString(volumes, volume), ids[i] + " has a home volume no other harness uses")
    assertTrue(
      homeVolumeBindFor("user-1", ids[i]).contains("-" + ids[i] + "-home:"),
      ids[i] + " keys its per-user volume by name"
    )
    paths = paths.append(path)
    volumes = volumes.append(volume)
    i = i + 1
  }
}

test "every harness has model providers and a default model" {
  val ids = harnessIds()
  val fallback = joined(providersForHarness(unknownHarness))
  var i = 0
  while i < ids.length {
    val providers = providersForHarness(ids[i])
    assertTrue(providers.length > 0, ids[i] + " has model providers")
    assertTrue(joined(providers) != fallback, ids[i] + " has its own provider mapping, not the unknown-harness fallback")
    assertTrue(defaultModelForHarness(ids[i]).length > 0, ids[i] + " has a default model")
    i = i + 1
  }
}
