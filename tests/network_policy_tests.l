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

// ── Phase 6: MCP callbacks (docs/phase6-mcp-callbacks.md) ───────────────────
test "callbacksFeatureEnabled is off unless explicitly set to \"1\"" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS", "")
  assertFalse(callbacksFeatureEnabled(), "unset -> off by default")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS", "0")
  assertFalse(callbacksFeatureEnabled(), "explicit \"0\" -> off")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS", "true")
  assertFalse(callbacksFeatureEnabled(), "anything other than the literal \"1\" -> off")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS", "1")
  assertTrue(callbacksFeatureEnabled(), "explicit \"1\" -> on")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS", "")
}

test "callbackApiUrl defaults to host.docker.internal, overridable" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_API_URL", "")
  assertEqual(callbackApiUrl(), "http://host.docker.internal:8080", "default reachable-from-container URL")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_API_URL", "http://cloud-agents-api:8080")
  assertEqual(callbackApiUrl(), "http://cloud-agents-api:8080", "operator override wins")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_API_URL", "")
}

test "networkModeForPolicyWithCallbacks matches networkModeForPolicy except opted-in 'none'+callbacks" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_RESTRICTED_NETWORK", "")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_NETWORK", "")

  // Callbacks off: identical to networkModeForPolicy in every case, including
  // 'none' — the whole point of the flag being off by default (#6).
  assertEqual(networkModeForPolicyWithCallbacks("none", false), "none", "callbacks off: 'none' still fully isolates")
  assertEqual(networkModeForPolicyWithCallbacks("full", false), "", "callbacks off: 'full' unchanged")
  assertEqual(
    networkModeForPolicyWithCallbacks("restricted", false),
    "none",
    "callbacks off: 'restricted' unchanged (fails closed)"
  )

  // Callbacks on but NO dedicated callback network configured: 'none' still
  // stays fully isolated — the extension is opt-in on both axes, not just one.
  assertEqual(
    networkModeForPolicyWithCallbacks("none", true),
    "none",
    "callbacks on with no callback network: still isolated"
  )
  // 'full'/'restricted' are never touched by this function regardless of the
  // callbacks flag — only 'none' has a callbacks-specific carve-out (#5).
  assertEqual(networkModeForPolicyWithCallbacks("full", true), "", "callbacks on: 'full' still unchanged")
  assertEqual(
    networkModeForPolicyWithCallbacks("restricted", true),
    "none",
    "callbacks on: 'restricted' still fails closed without its own egress network"
  )

  // Callbacks on AND a dedicated callback-only network configured: 'none'
  // joins it instead of full isolation — exactly enough to reach the
  // callback origin (#5).
  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_NETWORK", "callback-only-net")
  assertEqual(
    networkModeForPolicyWithCallbacks("none", true),
    "callback-only-net",
    "callbacks on + configured network: 'none' joins the callback-only network"
  )
  assertEqual(
    networkModeForPolicyWithCallbacks("none", false),
    "none",
    "the callback network is only consulted when callbacksEnabled is true"
  )
  Env.SetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_NETWORK", "")
}

// ── Docker transport selection (#377) ────────────────────────────────────────
//
// dockerClient()'s branching (env var set-and-non-empty -> TCP; set-but-empty
// -> socket fallback; unset/error -> socket fallback) lived entirely inside
// CloudAgents.Docker, an async-bearing package a @test_module can't invoke
// even a single pure function from (docs/lyric/gotchas.md) — so it had zero
// coverage. The decision itself is now the pure dockerTransportFor here.
func transportLabel(t: in DockerTransport): String {
  return match t {
    case Tcp(hostPort) -> "tcp:" + hostPort
    case Socket -> "socket"
  }
}

test "dockerTransportFor selects TCP for a set, non-empty host:port (#377)" {
  assertEqual(
    transportLabel(dockerTransportFor(Some(value = "127.0.0.1:2375"))),
    "tcp:127.0.0.1:2375",
    "a configured CLOUD_AGENTS_DOCKER_TCP_HOST selects the TCP transport at that host:port"
  )
}

test "dockerTransportFor falls back to the socket transport when the var is set but empty (#377)" {
  assertEqual(
    transportLabel(dockerTransportFor(Some(value = ""))),
    "socket",
    "an explicitly empty CLOUD_AGENTS_DOCKER_TCP_HOST falls back to the socket transport, not an empty-host TCP client"
  )
}

test "dockerTransportFor falls back to the socket transport when the var is absent (#377)" {
  assertEqual(
    transportLabel(dockerTransportFor(None)),
    "socket",
    "an absent/unreadable CLOUD_AGENTS_DOCKER_TCP_HOST falls back to the socket transport"
  )
}
