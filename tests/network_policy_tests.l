@test_module
package CloudAgents.NetworkPolicyTests

import Std.Core
import Std.Testing
import CloudAgents.NetworkPolicy
import extern System.Environment as Env

test "networkModeForPolicy maps policies to a Docker NetworkMode" {
  // Start from a clean slate so a stray inherited value can't taint the
  // fail-closed assertions below.
  Env.SetEnvironmentVariable("CLOUD_AGENTS_RESTRICTED_NETWORK", "")
  assertEqual(networkModeForPolicy("none"), "none", "'none' isolates the container")
  assertEqual(networkModeForPolicy("full"), "", "'full' uses the default bridge")
  // With no CLOUD_AGENTS_RESTRICTED_NETWORK configured, 'restricted' must fail
  // closed to full isolation, never the default bridge (#247).
  assertEqual(networkModeForPolicy("restricted"), "none", "'restricted' fails closed without an egress network")
  // With an egress network configured, 'restricted' joins it (#303).
  Env.SetEnvironmentVariable("CLOUD_AGENTS_RESTRICTED_NETWORK", "egress-net")
  assertEqual(networkModeForPolicy("restricted"), "egress-net", "'restricted' joins the configured egress network")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_RESTRICTED_NETWORK", "")
}

test "proxyEnvForPolicy only emits proxy vars for restricted, when a proxy is set" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_EGRESS_PROXY", "")
  assertTrue(proxyEnvForPolicy("full").length == 0, "'full' gets no proxy vars")
  assertTrue(proxyEnvForPolicy("none").length == 0, "'none' gets no proxy vars")
  assertTrue(proxyEnvForPolicy("restricted").length == 0, "'restricted' with no proxy configured gets no proxy vars")
  // With a proxy configured, restricted emits the four proxy vars (#303).
  Env.SetEnvironmentVariable("CLOUD_AGENTS_EGRESS_PROXY", "http://proxy:3128")
  val vars = proxyEnvForPolicy("restricted")
  assertTrue(vars.length == 4, "'restricted' with a proxy emits four proxy vars")
  assertEqual(vars[0], "HTTP_PROXY=http://proxy:3128", "first var is HTTP_PROXY")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_EGRESS_PROXY", "")
}
