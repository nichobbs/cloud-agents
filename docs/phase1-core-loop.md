# Phase 1: Core Loop – Message → Container → Stream

**Goal**: Prove end-to-end: receive a text prompt from the web UI, run `claude -p "..." --resume` in a Docker container, and stream the output back to the browser in real time.

**Duration**: 2-3 weeks

## Implementation Details

### 1. API Server (Lyric / Web)

#### Endpoints

- `POST /api/sessions` – create a session (repo, branch), clone repo, return `sessionId`.
- `POST /api/sessions/{id}/messages` – accept `{ text }`, start container, stream SSE response.
- `DELETE /api/sessions/{id}` – remove container and volumes.

#### Container management (Lyric.Docker)

```lyric
import Std.Core
import Web.{Request, Response, HttpError}
import Docker

// Example: Container start and streaming invocation in Lyric
val client = Docker.makeDockerClient()
val envs = [
  "PROMPT=" + text,
  "REPO_URL=" + repoUrl,
  "BRANCH=" + branch
]
val config = Docker.CreateContainerRequest(
  image = "claude-code:base",
  env = envs
  // binds = [ "/var/run/docker.sock:/var/run/docker.sock" ]
)

match await Docker.createContainer(client, config) {
  case Ok(container) -> {
    await Docker.startContainer(client, container.id)?
    // Stream logs using Std.Http / custom stream chunking
  }
  case Err(e) -> Err(HttpError.internalError("Docker container failure: " + e.message))
}
```

SSE streaming

Each stdout line is wrapped as data: `{"chunk":"..."}\n\n`. ANSI codes are stripped before sending (can also be done on the frontend with `ansi_up`).

2. Base Docker Image (Runner Environment with Lyric SDK)

The runner container requires node for `claude-code` and the .NET 10 / Lyric SDK to compile, format, and test the Lyric code inside the sandbox.

Dockerfile:

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:10.0-slim
RUN apt-get update && apt-get install -y git bash make python3 python3-pip curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g @anthropic-ai/claude-code

# Install Lyric Compiler
COPY --from=lyric-compiler-source /usr/local/bin/lyric /usr/local/bin/lyric

COPY entrypoint.sh /entrypoint.sh
CMD ["/entrypoint.sh"]
```

entrypoint.sh:

```bash
#!/bin/bash
if [ ! -d /workspace/.git ]; then
    git clone "$REPO_URL" --branch "$BRANCH" /workspace
fi
cd /workspace
# Very first invocation? Create session with dummy prompt.
if [ ! -f .claude/history.jsonl ]; then
    claude -p "Initialise session" --resume
fi
claude -p "$PROMPT" --resume
```

3. Frontend Prototype

```javascript
const response = await fetch(`/api/sessions/${id}/messages`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${githubToken}`
  },
  body: JSON.stringify({ text: prompt })
})
const reader = response.body.getReader()
while (true) {
  const { done, value } = await reader.read()
  if (done) break
  // parse SSE, append to chat bubble
}
```

4. Credential Mount (Temporary)

For Phase 1, mount a local ~/.claude folder manually as a bind mount. This is replaced by encrypted upload in Phase 3.

5. Constraints & Risks

· Architecture must be linux/amd64.
· ANSI output may contain progress spinners; stripping them loses some visual feedback (acceptable for MVP).
· No concurrency control yet – two rapid messages on the same session may conflict. Added in Phase 2.

Rejected Alternatives

· WebSocket instead of SSE: More complex for one-shot request-response. SSE is simpler.
· docker exec into long-running container: Would keep container alive, wasting memory.

Deliverables

· Working API server (runs locally)
· Base Docker image
· Minimal web frontend with streaming
· Manual credential mount documented
