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
// Stage 4 (docs/phase6 §8): default-on, opt out with the literal "0".
test "callbacksFeatureEnabled is on unless explicitly set to \"0\"" {
  Env.SetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS", "")
  assertTrue(callbacksFeatureEnabled(), "unset -> on by default")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS", "0")
  assertFalse(callbacksFeatureEnabled(), "explicit \"0\" -> off")
  Env.SetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS", "false")
  assertTrue(callbacksFeatureEnabled(), "anything other than the literal \"0\" -> on")
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

// ── DNS-based SSRF bypass guard for repoUrl (#300) ───────────────────────────
//
// isPrivateOrReservedIpv4/isPrivateOrReservedIpv6/isPrivateOrReservedIpLiteral
// are pure string classification and need no network access at all.
// resolveHostAddresses/isBlockedResolvedHost do call the real .NET resolver,
// but every case below is answered without a network round trip: passing a
// literal IP address (v4 or v6) makes System.Net.Dns.GetHostAddresses parse
// it straight back out with no lookup, "localhost" resolves via the local
// NSS/hosts-file path everywhere, and an over-long host name is rejected by
// the BCL's own local length check before it would ever query a resolver.

test "isPrivateOrReservedIpv4 covers loopback, RFC1918, link-local/metadata, and 172.16-31 boundaries" {
  assertTrue(isPrivateOrReservedIpv4("127.0.0.1"), "loopback")
  assertTrue(isPrivateOrReservedIpv4("10.1.2.3"), "10/8")
  assertTrue(isPrivateOrReservedIpv4("192.168.1.1"), "192.168/16")
  assertTrue(isPrivateOrReservedIpv4("169.254.169.254"), "the cloud metadata address, inside 169.254/16")
  assertTrue(isPrivateOrReservedIpv4("0.0.0.0"), "unspecified address")
  assertFalse(isPrivateOrReservedIpv4("172.15.255.255"), "just below the 172.16/12 range")
  assertTrue(isPrivateOrReservedIpv4("172.16.0.1"), "start of the 172.16/12 range")
  assertTrue(isPrivateOrReservedIpv4("172.31.255.255"), "end of the 172.16/12 range")
  assertFalse(isPrivateOrReservedIpv4("172.32.0.1"), "just above the 172.16/12 range")
  assertFalse(isPrivateOrReservedIpv4("8.8.8.8"), "an ordinary public address")
}

test "isPrivateOrReservedIpv6 covers loopback, unspecified, link-local, ULA, zone ids, and IPv4-mapped forms" {
  assertTrue(isPrivateOrReservedIpv6("::1"), "loopback")
  assertTrue(isPrivateOrReservedIpv6("::"), "unspecified")
  assertTrue(isPrivateOrReservedIpv6("fe80::1"), "fe80::/10 link-local")
  assertTrue(isPrivateOrReservedIpv6("FE80::1"), "link-local, case-insensitively")
  assertTrue(isPrivateOrReservedIpv6("fe80::1%3"), "link-local with a zone id stripped before classifying")
  assertTrue(isPrivateOrReservedIpv6("fc00::1"), "fc00::/7 unique local (fc)")
  assertTrue(isPrivateOrReservedIpv6("fd12:3456::1"), "fc00::/7 unique local (fd)")
  assertTrue(
    isPrivateOrReservedIpv6("::ffff:169.254.169.254"),
    "IPv4-mapped form of the metadata address is classified via the embedded IPv4"
  )
  assertFalse(isPrivateOrReservedIpv6("2001:4860:4860::8888"), "an ordinary public address (Google public DNS)")
}

test "isPrivateOrReservedIpLiteral dispatches on ':' between the IPv4 and IPv6 checks" {
  assertTrue(isPrivateOrReservedIpLiteral("127.0.0.1"), "IPv4 loopback")
  assertTrue(isPrivateOrReservedIpLiteral("::1"), "IPv6 loopback")
  assertFalse(isPrivateOrReservedIpLiteral("8.8.8.8"), "IPv4 public")
  assertFalse(isPrivateOrReservedIpLiteral("2001:4860:4860::8888"), "IPv6 public")
}

test "resolveHostAddresses parses a literal IP straight back out with no lookup" {
  match resolveHostAddresses("169.254.169.254") {
    case Ok(addrs) -> {
      assertTrue(addrs.length == 1, "a literal resolves to exactly itself")
      assertEqual(addrs[0], "169.254.169.254", "no rewriting")
    }
    case Err(e) -> assertTrue(false, "expected Ok, got Err(" + e + ")")
  }
}

test "isBlockedResolvedHost blocks a repoUrl host resolving to the metadata address" {
  // Stands in for the #300 scenario (a public DNS name an attacker points at
  // 169.254.169.254): the classification path is identical whether the
  // address came from a real DNS answer or, as here, a literal-IP "resolve".
  assertTrue(isBlockedResolvedHost("169.254.169.254"), "resolves to the metadata address")
  assertTrue(isBlockedResolvedHost("::1"), "resolves to an IPv6 loopback literal")
  assertFalse(isBlockedResolvedHost("8.8.8.8"), "resolves to an ordinary public address")
}

test "isBlockedResolvedHost blocks 'localhost', exercising a real (offline) DNS resolution" {
  // localhost resolves via the local NSS/hosts-file lookup on every platform
  // this runs on, never a real network query.
  assertTrue(isBlockedResolvedHost("localhost"), "localhost resolves to a loopback address")
}

func makeOverlongHost(): String {
  // System.Net.Dns.GetHostAddresses rejects a name over 255 characters with
  // a local, synchronous ArgumentOutOfRangeException, before any resolver
  // would be consulted — so this exercises the fail-closed Err path with no
  // network dependency at all.
  var s = ""
  var i = 0
  while i < 260 {
    s = s + "a"
    i = i + 1
  }
  return s
}

test "resolveHostAddresses / isBlockedResolvedHost fail closed on a resolution error (#300)" {
  match resolveHostAddresses(makeOverlongHost()) {
    case Ok(_) -> assertTrue(false, "an over-255-character host must not resolve")
    case Err(_) -> assertTrue(true, "resolution failure surfaces as Err")
  }
  assertTrue(
    isBlockedResolvedHost(makeOverlongHost()),
    "a host that cannot be resolved is treated as blocked (fail closed), not allowed through"
  )
}
