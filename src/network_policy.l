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
