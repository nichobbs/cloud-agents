//! Pure network-policy resolution: maps a profile's network_policy to a Docker
//! NetworkMode and the optional egress-proxy env vars.
//!
//! This lives in its own package rather than CloudAgents.Docker so the logic is
//! unit-testable: invoking ANY function from the async CloudAgents.Docker
//! package via the @test_module harness throws "The signature is incorrect."
//! (a documented Lyric runtime limitation, docs/lyric/gotchas.md), even for a
//! pure leaf function — so a test can't reach these while they live there. A
//! test importing this pure package hits no such limitation.
package CloudAgents.NetworkPolicy

import Std.Core
import extern System.Environment as Env
import extern System.String as DotNetString

/// Docker NetworkMode for a profile's network policy. "none" fully isolates the
/// container; "full" (and no profile) keeps the default bridge (full egress).
///
/// "restricted" must never fall through to full egress (#247). If the operator
/// has provisioned an egress network — CLOUD_AGENTS_RESTRICTED_NETWORK, a Docker
/// network (typically created `--internal`) whose only route out is an
/// allowlisting proxy — the container joins it; otherwise "restricted" fails
/// closed to full isolation ("none") rather than the default bridge. This is
/// network-level enforcement: the advisory HTTP(S)_PROXY vars from
/// proxyEnvForPolicy alone don't restrict anything (a process can ignore them).
pub func networkModeForPolicy(policy: in String): String {
  if policy == "none" {
    return "none"
  }
  if policy == "restricted" {
    val net = Env.GetEnvironmentVariable("CLOUD_AGENTS_RESTRICTED_NETWORK")
    if DotNetString.IsNullOrEmpty(net) {
      return "none"
    }
    return net
  }
  return ""
}

/// Proxy env vars for the 'restricted' network policy: point the container at
/// the egress proxy named by CLOUD_AGENTS_EGRESS_PROXY, if configured. These
/// are a convenience for proxy-aware clients on top of the network-level
/// enforcement in networkModeForPolicy (which fails closed to full isolation
/// when no restricted network is configured) — they do not themselves restrict
/// egress. With no proxy configured the container gets no proxy vars.
pub func proxyEnvForPolicy(policy: in String): slice[String] {
  val empty: slice[String] = []
  if policy != "restricted" {
    return empty
  }
  val proxy = Env.GetEnvironmentVariable("CLOUD_AGENTS_EGRESS_PROXY")
  if DotNetString.IsNullOrEmpty(proxy) {
    return empty
  }
  return ["HTTP_PROXY=" + proxy, "HTTPS_PROXY=" + proxy, "http_proxy=" + proxy, "https_proxy=" + proxy]
}

// ─── Phase 6: MCP callbacks (docs/phase6-mcp-callbacks.md) ───────────────────
//
// Stage 4 (docs/phase6 §8): on by default now that the in-container shim
// (`cloud-agents-shim`, stage 3) ships in every runner image — see
// CloudAgents.Docker, which reads this flag before minting a callback token
// or injecting the two callback env vars, and docker/entrypoint.sh, which
// reads the SAME env var name (mirroring this same on-unless-"0" default in
// shell) before registering the shim's MCP-server entry or adding
// `--permission-prompt-tool`. An operator opts OUT with
// CLOUD_AGENTS_MCP_CALLBACKS=0. The entrypoint's existing guards (template
// present, env vars minted) keep a run working even when the flag is on but
// no token was minted (mint failure, pre-Phase-6 upgrade path) — see
// docker_manager.l's best-effort mint comment and entrypoint.sh's template
// existence checks.
/// Whether the MCP-callback feature is enabled for this deployment.
pub func callbacksFeatureEnabled(): Bool {
  return Env.GetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS") != "0"
}

/// The operator-set CLOUD_AGENTS_CALLBACK_TIMEOUT_MS, or "" when unset.
/// Forwarded verbatim into session containers by CloudAgents.Docker so the
/// shim's client-side deadline and the host-side backstop share one knob
/// (#528). Not validated here — both consumers fall back to their default
/// on an unparseable value.
pub func callbackTimeoutOverride(): String {
  val raw = Env.GetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_TIMEOUT_MS")
  if DotNetString.IsNullOrEmpty(raw) {
    return ""
  }
  return raw
}

/// Base URL of the host API as reachable from the container network — the
/// value injected as CLOUD_AGENTS_API_URL (docs/phase6 §2). Configurable
/// because the reachable address depends entirely on the deployment's Docker
/// networking (bridge vs. host-gateway vs. a custom network); the
/// `host.docker.internal` default only works out of the box on Docker
/// Desktop.
pub func callbackApiUrl(): String {
  val url = Env.GetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_API_URL")
  if DotNetString.IsNullOrEmpty(url) {
    return "http://host.docker.internal:8080"
  }
  return url
}

/// networkModeForPolicy, extended to admit outbound calls to the host
/// callback API for a "none" (fully isolated) session when callbacks are
/// enabled — exactly enough to reach the callback origin, and nothing else
/// new (#docs/phase6 §5). Only takes effect when BOTH `callbacksEnabled` is
/// true AND the operator has configured a dedicated callback-only Docker
/// network via CLOUD_AGENTS_CALLBACK_NETWORK (typically an `--internal`
/// network whose only reachable host is this API — the same "provision an
/// egress network" pattern 'restricted' already uses via
/// CLOUD_AGENTS_RESTRICTED_NETWORK). Without that opt-in, behaviour is
/// byte-for-byte identical to networkModeForPolicy — a "none" session stays
/// fully isolated, and 'restricted'/'full' are untouched (an operator who
/// wants restricted sessions to reach the callback API adds the callback
/// origin to their existing egress allowlist, same as any other required
/// egress).
pub func networkModeForPolicyWithCallbacks(policy: in String, callbacksEnabled: in Bool): String {
  if callbacksEnabled and policy == "none" {
    val net = Env.GetEnvironmentVariable("CLOUD_AGENTS_CALLBACK_NETWORK")
    if not DotNetString.IsNullOrEmpty(net) {
      return net
    }
  }
  return networkModeForPolicy(policy)
}

// ─── Docker transport selection (#377) ───────────────────────────────────────
//
// CloudAgents.Docker.dockerClient() picks between the TCP and Unix-socket
// Docker transports based on CLOUD_AGENTS_DOCKER_TCP_HOST — see that
// function's doc comment for the full rationale (the socket transport's
// upstream dependency is absent from a standalone compiled program's
// output). The branch DECISION is pure (env var present-and-non-empty -> TCP
// at that host:port; present-but-empty or absent -> socket) but lived
// entirely inside CloudAgents.Docker, an async-bearing package a
// @test_module can't invoke even a single pure function from (docs/lyric/
// gotchas.md) — so it had zero test coverage. Extracted here, the same way
// networkModeForPolicy/proxyEnvForPolicy were split out of CloudAgents.Docker
// for exactly this reason, so the three branches (TCP / empty-falls-back-to-
// socket / absent-falls-back-to-socket) are unit-testable.
/// Which Docker transport dockerClient() should use, given the result of
/// looking up CLOUD_AGENTS_DOCKER_TCP_HOST (`Some(value)` when the env var is
/// set, `None` when it is absent or unreadable — the caller normalizes
/// Std.Environment.getVar's `Result[String, IOError]` to this before calling,
/// so this package stays free of any Std.Environment error type).
pub union DockerTransport {
  case Tcp(hostPort: String)
  case Socket
}

/// Pure decision: a set-and-non-empty value selects TCP at that host:port;
/// a set-but-empty value or an absent value both fall back to the
/// Unix-socket default.
pub func dockerTransportFor(hostPortVar: in Option[String]): DockerTransport {
  return match hostPortVar {
    case Some(hostPort) -> if hostPort.length > 0 { Tcp(hostPort = hostPort) } else { Socket }
    case None -> Socket
  }
}

// ─── DNS-based SSRF bypass guard for repoUrl (#300) ─────────────────────────
//
// `CloudAgents.Handlers.isBlockedRepoHost` only ever inspected the LITERAL
// repoUrl hostname string against a blocklist of loopback/private/link-local
// hostnames and obvious IP-literal forms (reusing
// `CloudAgents.Webhooks.isBlockedWebhookHost`). A public DNS name an
// attacker controls (e.g. `evil.example.com` -> `169.254.169.254`) sails
// straight through that check — the SSRF only happens later, at `git clone`
// time, inside the session's Docker container, whose default
// `network_policy` is `'full'` (unrestricted bridge egress) unless the
// session's profile explicitly opts into `'restricted'`/`'none'`. Unlike the
// webhook-delivery path the literal check was borrowed from, there is no
// secondary backstop for repoUrl in the common (no-profile) case, so
// resolving the hostname and checking every answer against the same
// private/loopback/link-local/ULA/metadata ranges is the only remaining
// control.
//
// This stays a synchronous BCL call (no `async func`), so — like everything
// else in this file — it stays reachable from a plain @test_module (docs/
// lyric/gotchas.md's async-package test restriction doesn't apply). The
// `localhost` host used in tests resolves via the local NSS/hosts-file
// lookup on every platform this runs on, never a real network query, so the
// suite stays offline.
//
// Still not a complete fix for TOCTOU/DNS-rebinding (the answer could change
// between this check and the later `git clone`) — that residual risk is the
// same one `isBlockedWebhookHost`'s own doc comment already calls out for
// the webhook path, and closing it fully needs re-checking at connect time
// inside the clone itself (or the network_policy-level defense-in-depth
// #300 also suggests: default un-profiled sessions to a restricted network).

extern type IPAddress = "System.Net.IPAddress"
extern type IPAddressArray = "System.Net.IPAddress[]"

// Explicit @externTarget binding (not the lighter `import extern X as Y`
// form network_policy.l otherwise uses for Environment) — that lighter form
// is only proven elsewhere for primitive returns; a complex array return
// type follows the explicit-binding shape confirmed working for
// AgentSessionArray/StringArray/RowArray (session_manager.l, sqlite_driver.l).
@externTarget("System.Net.Dns.GetHostAddresses")
func dnsGetHostAddresses(host: in String): IPAddressArray = ()

@externInstance
@externTarget("System.Array.get_Length")
func ipAddressArrayLength(arr: in IPAddressArray): Int = ()

@externInstance
@externTarget("System.Array.GetValue")
func ipAddressArrayValue(arr: in IPAddressArray, index: in Int): IPAddress = ()

@externInstance
@externTarget("System.Net.IPAddress.ToString")
func ipAddressToString(ip: in IPAddress): String = ""

@externInstance
@externTarget("System.String.ToLowerInvariant")
func toLowerInvariant(s: in String): String = ()

/// Resolve `host` to its literal IP address strings via the real .NET
/// resolver (`System.Net.Dns.GetHostAddresses`), or `Err` with the
/// platform's message when resolution fails (unknown host, no resolver
/// reachable, ...). A bare IP-literal `host` round-trips with no network
/// query — the BCL parses it straight back out.
pub func resolveHostAddresses(host: in String): Result[slice[String], String] {
  return try {
    val addrs = dnsGetHostAddresses(host)
    val len = ipAddressArrayLength(addrs)
    var addrStrings: slice[String] = []
    var i = 0
    while i < len {
      addrStrings = addrStrings.append(ipAddressToString(ipAddressArrayValue(addrs, i)))
      i = i + 1
    }
    Ok(value = addrStrings)
  } catch Bug as b {
    Err(error = "DNS resolution of '" + host + "' failed: " + b.message)
  }
}

func digitValNp(c: in String): Int {
  if c == "0" {
    return 0
  }
  if c == "1" {
    return 1
  }
  if c == "2" {
    return 2
  }
  if c == "3" {
    return 3
  }
  if c == "4" {
    return 4
  }
  if c == "5" {
    return 5
  }
  if c == "6" {
    return 6
  }
  if c == "7" {
    return 7
  }
  if c == "8" {
    return 8
  }
  if c == "9" {
    return 9
  }
  return 0
}

/// The value of the digit run starting at `start` in `ip`, up to (but not
/// including) the next '.' or the end of the string. `ip` is assumed to be
/// canonical dotted-decimal (it always is here — the only caller passes a
/// `System.Net.IPAddress.ToString()` result, never a raw attacker string),
/// so no overflow guard is needed the way `isPrivate172` in webhooks.l needs
/// one against a fully attacker-controlled literal.
func octetStartingAt(ip: in String, start: in Int): Int {
  var n = 0
  var i = start
  while i < ip.length and ip.substring(i, 1) != "." {
    n = n * 10 + digitValNp(ip.substring(i, 1))
    i = i + 1
  }
  return n
}

/// Whether a canonical dotted-decimal IPv4 literal is loopback (127/8),
/// RFC1918 private (10/8, 172.16/12, 192.168/16), link-local — which
/// includes the cloud-metadata address 169.254.169.254 (169.254/16) — or the
/// unspecified address (0.0.0.0).
pub func isPrivateOrReservedIpv4(ip: in String): Bool {
  if ip.startsWith("127.") {
    return true
  }
  if ip.startsWith("10.") {
    return true
  }
  if ip.startsWith("192.168.") {
    return true
  }
  if ip.startsWith("169.254.") {
    return true
  }
  if ip == "0.0.0.0" {
    return true
  }
  if ip.startsWith("172.") {
    val second = octetStartingAt(ip, 4)
    return second >= 16 and second <= 31
  }
  return false
}

/// Index of the last ':' in `s`, or -1 if there is none.
func lastColonIndex(s: in String): Int {
  var idx = -1
  var i = 0
  while i < s.length {
    if s.substring(i, 1) == ":" {
      idx = i
    }
    i = i + 1
  }
  return idx
}

/// `s` up to (not including) its first '%' — strips a zone/scope-id suffix
/// .NET appends to a link-local IPv6 address's ToString() (e.g.
/// "fe80::1%3").
func stripZoneId(s: in String): String {
  var i = 0
  while i < s.length {
    if s.substring(i, 1) == "%" {
      return s.substring(0, i)
    }
    i = i + 1
  }
  return s
}

func containsDot(s: in String): Bool {
  var i = 0
  while i < s.length {
    if s.substring(i, 1) == "." {
      return true
    }
    i = i + 1
  }
  return false
}

/// Whether an IPv6 literal (zone id already stripped, case-folded) is
/// loopback (::1), unspecified (::), link-local (fe80::/10), or a unique
/// local address (fc00::/7, i.e. the first hex group starts "fc" or "fd") —
/// or, for an IPv4-mapped/-compatible form (contains a '.', e.g.
/// "::ffff:169.254.169.254"), whether the embedded IPv4 address is one of
/// the above IPv4 categories.
pub func isPrivateOrReservedIpv6(ipRaw: in String): Bool {
  val ip = toLowerInvariant(stripZoneId(ipRaw))
  if ip == "::1" or ip == "::" {
    return true
  }
  if containsDot(ip) {
    val colonIdx = lastColonIndex(ip)
    val embedded = ip.substring(colonIdx + 1, ip.length - colonIdx - 1)
    return isPrivateOrReservedIpv4(embedded)
  }
  if ip.startsWith("fe8") or ip.startsWith("fe9") or ip.startsWith("fea") or ip.startsWith("feb") {
    return true // fe80::/10 link-local
  }
  if ip.startsWith("fc") or ip.startsWith("fd") {
    return true // fc00::/7 unique local address
  }
  return false
}

/// Whether a resolved literal address string (as returned by
/// `resolveHostAddresses`) is loopback/private/link-local/ULA/metadata,
/// dispatching on IPv4 vs. IPv6 by the presence of a ':'.
pub func isPrivateOrReservedIpLiteral(ip: in String): Bool {
  if ip.contains(":") {
    return isPrivateOrReservedIpv6(ip)
  }
  return isPrivateOrReservedIpv4(ip)
}

/// Whether `host` resolves to any loopback/private/link-local/ULA/metadata
/// address — the DNS-based half of the repoUrl SSRF guard (#300); the
/// literal-hostname half stays in `isBlockedWebhookHost`. Fails CLOSED: a
/// host that cannot be resolved at all is treated as blocked, since there is
/// no address to have verified safe (and if it's genuinely unresolvable,
/// the later `git clone` cannot succeed either, so nothing legitimate is
/// lost).
pub func isBlockedResolvedHost(host: in String): Bool {
  match resolveHostAddresses(host) {
    case Ok(addrs) -> {
      var blocked = false
      var i = 0
      while i < addrs.length {
        if isPrivateOrReservedIpLiteral(addrs[i]) {
          blocked = true
        }
        i = i + 1
      }
      blocked
    }
    case Err(_) -> true
  }
}
