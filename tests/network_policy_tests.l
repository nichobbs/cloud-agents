@test_module
package CloudAgents.NetworkPolicyTests

import Std.Core
import Std.Testing
import CloudAgents.Docker

test "networkModeForPolicy maps policies to a Docker NetworkMode" {
  assertEqual(networkModeForPolicy("none"), "none", "'none' isolates the container")
  assertEqual(networkModeForPolicy("full"), "", "'full' uses the default bridge")
  // With no CLOUD_AGENTS_RESTRICTED_NETWORK configured (as in CI), 'restricted'
  // must fail closed to full isolation, never the default bridge (#247/#302).
  assertEqual(networkModeForPolicy("restricted"), "none", "'restricted' fails closed without an egress network")
}

test "proxyEnvForPolicy only emits proxy vars for the restricted policy" {
  assertTrue(proxyEnvForPolicy("full").length == 0, "'full' gets no proxy vars")
  assertTrue(proxyEnvForPolicy("none").length == 0, "'none' gets no proxy vars")
}
