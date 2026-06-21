//! Docker socket path helpers.
//!
//! Pure utilities for locating the Docker daemon's Unix socket across the
//! common configurations. Client construction lives in `Lyric.Docker`, which
//! wraps the connection in the opaque `DockerClient` handle; these helpers only
//! resolve socket *paths* so they expose no platform/extern types.
@runtime_checked
package Lyric.Docker.Sockets

import Std.Core
import Std.Environment

/// Linux/macOS Unix domain socket path (most common).
pub func unixSocketPath(): String {
  "/var/run/docker.sock"
}

/// Alternative socket location on some systems.
pub func alternateSocketPath(): String {
  "/var/run/docker.sock.raw"
}

/// Resolve the rootless Docker socket path from $XDG_RUNTIME_DIR.
/// Returns an error message when the variable is unset.
pub func resolveRootlessSocket(): Result[String, String] {
  match Std.Environment.getVar("XDG_RUNTIME_DIR") {
    case Ok(runtimeDir) -> Ok(value = runtimeDir + "/docker.sock")
    case Err(_) -> Err(error = "XDG_RUNTIME_DIR not set; required for rootless Docker")
  }
}

/// Parse the DOCKER_HOST environment variable to extract a Unix socket path.
///
/// Returns `Some(socketPath)` if DOCKER_HOST is set and is a valid unix:// URL.
/// Returns `None` if DOCKER_HOST is not set, not a unix:// URL, or is malformed.
pub func parseDockerHost(): Option[String] {
  match Std.Environment.getVar("DOCKER_HOST") {
    case Ok(dockerHost) -> parseUnixSocketUrl(dockerHost)
    case Err(_) -> None
  }
}

/// Parse a unix:// URL to extract the socket path.
///
/// - `unix:///var/run/docker.sock` -> `/var/run/docker.sock`
/// - `unix://docker.sock` -> `docker.sock` (relative, unusual)
/// - Non-unix URLs (tcp://, npipe://, ...) are rejected.
pub func parseUnixSocketUrl(url: in String): Option[String] {
  val prefix = "unix://"
  if not url.startsWith(prefix) {
    return None
  }

  val withoutPrefix = url.substring(prefix.length)

  if withoutPrefix.length == 0 {
    return None
  }

  val path = if withoutPrefix.startsWith("//") {
    withoutPrefix.substring(2)
  } else {
    withoutPrefix
  }

  if path.length > 0 {
    Some(value = path)
  } else {
    None
  }
}
