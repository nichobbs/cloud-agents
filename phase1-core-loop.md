# Phase 1: Core Loop – Message → Container → Stream

**Goal**: Prove end-to-end: receive a text prompt from the web UI, run `claude -p "..." --resume` in a Docker container, and stream the output back to the browser in real time.

**Duration**: 2-3 weeks

## Implementation Details

### 1. API Server (Node.js / Express or Fastify)

#### Endpoints

- `POST /api/sessions` – create a session (repo, branch), clone repo, return `sessionId`.
- `POST /api/sessions/:id/messages` – accept `{ text }`, start container, stream SSE response.
- `DELETE /api/sessions/:id` – remove container and volumes.

#### Container management (dockerode / docker-py)

```js
const container = await docker.createContainer({
  Image: 'claude-code:base',
  Env: [`PROMPT=${text}`, `REPO_URL=...`, `BRANCH=main`],
  Volumes: { /* workspace + home mounts */ },
  HostConfig: { Binds: [...] }
});
const stream = await container.attach({ stream: true, stdout: true, stderr: true });
await container.start();
```

SSE streaming

Each stdout line is wrapped as data: {"chunk":"..."}\n\n. ANSI codes are stripped before sending (can also be done on the frontend with ansi_up).

2. Base Docker Image

Dockerfile:

```dockerfile
FROM node:20-slim
RUN apt-get update && apt-get install -y git bash make python3 python3-pip curl \
    && npm install -g @anthropic-ai/claude-code
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
