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
// Off by default until the in-container shim (`cloud-agents-shim`, stage 3)
// actually ships in the runner images — see CloudAgents.Docker, which reads
// this flag before minting a callback token or injecting the two callback env
// vars, and docker/entrypoint.sh, which reads the SAME env var name before
// registering the shim's MCP-server entry or adding
// `--permission-prompt-tool`.
/// Whether the MCP-callback feature is enabled for this deployment.
pub func callbacksFeatureEnabled(): Bool {
  return Env.GetEnvironmentVariable("CLOUD_AGENTS_MCP_CALLBACKS") == "1"
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
