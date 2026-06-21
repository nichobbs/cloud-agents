//! Docker Engine API v1.40+ client bindings.
//!
//! Type-safe Lyric bindings for the Docker Engine REST API. The current
//! surface is a placeholder demonstrating the shape of generated operations;
//! the full client is generated from Docker's OpenAPI spec.
//!
//! API Documentation: https://docs.docker.com/engine/api/v1.40/

@runtime_checked
package Lyric.Docker.Api

import Std.Core

/// Placeholder Docker API response type.
///
/// In the generated client this is replaced with strongly-typed container,
/// image, and system response records derived from the OpenAPI spec.
pub record DockerResponsePlaceholder {
  /// Container or image ID (placeholder).
  pub id: String
  /// Human-readable name (placeholder).
  pub name: String
}
