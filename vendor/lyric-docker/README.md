# lyric-docker — Docker API Client for Lyric

A type-safe Docker API client for Lyric, built on Unix domain socket support in `Std.Http`.

## Overview

`lyric-docker` provides convenient, strongly-typed access to the Docker daemon via the Docker Engine REST API. It abstracts away HTTP details and provides intuitive Lyric-idiomatic functions for common operations.

### Features (Phase 1)

- ✅ Unix socket connections (Linux/macOS)
- ✅ Rootless Docker support
- ✅ System info and ping operations
- ✅ Container and image listing
- ✅ Error handling via `Result[T, DockerError]`

### Planned Features (Phase 2+)

- Strongly-typed container and image operations (from OpenAPI spec generation)
- Volume, network, and service management
- Event subscriptions and log streaming
- Windows named pipe support

## Installation

Add to your `lyric.toml`:

```toml
[dependencies]
"Lyric.Docker" = { workspace = true }
```

## Quick Start

```lyric
import Lyric.Docker
import Lyric.Docker.Sockets
import Std.Core

pub func main(): Int {
  val client = Lyric.Docker.makeDockerClient()
  
  match await Lyric.Docker.ping(client) {
    case Ok(_) -> {
      println("✓ Connected to Docker")
      match await Lyric.Docker.systemInfo(client) {
        case Ok(info) -> println("System: " + info)
        case Err(e) -> println("Error: " + e.message)
      }
      0
    }
    case Err(e) -> {
      println("✗ Docker connection failed: " + e.message)
      1
    }
  }
}
```

## Connection

### Standard Docker (Recommended)

```lyric
val client = Lyric.Docker.makeDockerClient()
```

This automatically follows the standard Docker connection priority:
1. `DOCKER_HOST` environment variable (if set and is a `unix://` URL)
2. Standard location `/var/run/docker.sock` (Linux/macOS)
3. Rootless location `$XDG_RUNTIME_DIR/docker.sock` (if available)

### Specifying Docker Host via Environment Variable

Set `DOCKER_HOST` to override the default socket location:

```bash
export DOCKER_HOST=unix:///custom/docker.sock
```

Supported formats:
- `unix:///path/to/docker.sock` — Unix socket (absolute path)
- `unix://docker.sock` — Unix socket (relative path)

TCP and named pipe transports are planned for future releases.

### Rootless Docker

```lyric
match Lyric.Docker.makeRootlessDockerClient() {
  case Ok(client) -> // Use client...
  case Err(e) -> println("Error: " + e)
}
```

Explicitly targets `$XDG_RUNTIME_DIR/docker.sock` for rootless Docker. Use this when you want to ensure rootless mode is used and get an error if it's not available.

### Custom Socket Path

```lyric
val client = Lyric.Docker.makeDockerClientAt("/custom/path/docker.sock")
```

## API Surface

### System Operations

- `ping(client)` — Verify Docker daemon connectivity
- `systemInfo(client)` — Get system information and Docker version

### Container Operations

- `listContainers(client)` — List all containers
- Future: `createContainer`, `startContainer`, `stopContainer`, `removeContainer`, etc.

### Image Operations

- `listImages(client)` — List all images
- Future: `pullImage`, `pushImage`, `buildImage`, `removeImage`, etc.

## Roadmap

**Phase 1 (Current):** Core convenience wrappers over basic Docker API endpoints.

**Phase 2:** Generate strongly-typed API bindings from Docker's OpenAPI 3.x specification using `lyric openapi`:

```bash
# Download Docker's OpenAPI spec
curl -L https://raw.githubusercontent.com/docker/cli/master/docs/swagger.json \
  -o docker-api-spec.json

# Generate Lyric bindings
lyric openapi docker-api-spec.json \
  -o lyric-docker/src/docker_api_generated.l \
  --client-name DockerEngineClient \
  --package Docker.Api.Generated
```

**Phase 3:** Advanced operations (events, logs streaming, compose, Swarm).

## Examples

See `examples/docker/` for runnable examples (coming soon):

- `list_containers.l` — List and inspect containers
- `pull_and_run.l` — Pull an image and run a container
- `health_check.l` — Monitor container health

## Error Handling

All API operations return `Result[T, DockerError]` with detailed error information:

```lyric
pub record DockerError {
  pub val statusCode: Option[Int]    // HTTP status code if available
  pub val message: String             // Human-readable error message
  pub val details: String             // Docker response body or additional context
}
```

## Unix Socket Support

`lyric-docker` depends on Unix socket support in `Std.Http.clientWithUnixSocket()`, which is available in Lyric 0.1.1+. This enables direct connection to the Docker daemon without needing TCP networking or TLS certificates.

### How It Works

1. Creates an `HttpClient` connected to `/var/run/docker.sock` via `System.Net.Sockets.UnixDomainSocketEndPoint`
2. Routes all HTTP requests through the Unix socket
3. Parses JSON responses and presents typed Lyric results

## License

Apache 2.0 (same as the Lyric project)

## See Also

- [Docker Engine API Reference](https://docs.docker.com/engine/api/)
- [Docker OpenAPI Specification](https://raw.githubusercontent.com/docker/cli/master/docs/swagger.json)
- [Lyric Std.Http Unix Socket Support](../lyric-stdlib/std/http.l)
