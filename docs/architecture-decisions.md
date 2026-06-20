# Architecture Decision Record

## ADR-001: Use `claude -p` in one-shot containers

**Context**: We need a web UI to send prompts to Claude Code and stream responses without API credits.

**Options considered**:

1. Persistent PTY with interactive `claude` – rejected because it requires a terminal UI, not chat bubbles.
2. Extract OAuth tokens and call Anthropic API directly – prohibited by ToS.
3. Official managed agents API – requires API credits, not subscription.
4. `claude -p` in ephemeral containers with `--resume` – compliant, chat-friendly, state on volume.

**Decision**: Option 4.

**Consequences**:

- Must manage container lifecycle carefully (idle recycling).
- Streaming depends on stdout of `claude` process.
- Credential management via volume mount of user’s `.claude` folder.
- Each message is a discrete invocation; no autonomous loops.

---

## ADR-002: Persistent volumes for session state

**Context**: Conversation history and workspace files must survive container restarts.

**Alternatives**:

- Database-backed state – complex, out of sync with CLI history format.
- Keep containers always running – expensive, hard to scale.

**Decision**: Docker volumes (one for user home, one per session workspace). Volumes persist; containers are ephemeral.

**Consequences**:

- Idle state is near-zero cost (disk only).
- Restoring = starting a new container with the same volumes.
- Must serialise messages per session to prevent volume corruption.

---

## ADR-003: Credential upload instead of browser OAuth flow

**Context**: The official CLI needs pre-authenticated credentials to run headlessly.

**Alternatives**:

- Implement headless OAuth – risky, may trigger anti-abuse.
- Copy already-authenticated `.claude` folder into the platform.

**Decision**: User authenticates locally, uploads the folder. The platform stores it encrypted and mounts it into containers.

**Consequences**:

- Re-upload only when refresh token expires (months).
- Security: encryption at rest and in transit is critical.
- No need to reverse-engineer OAuth endpoints.

---

## ADR-004: Single VM with Docker (no Kubernetes)

**Context**: Target is “cheapest possible” for 10-15 concurrent sessions.

**Alternatives**:

- Kubernetes – overhead, higher minimum cost.
- Serverless containers – cost unpredictability, cold starts.

**Decision**: Single cloud VM (Hetzner CX41) running Docker and the API server. Containers started on demand, stopped when idle.

**Consequences**:

- Manual scaling if needed.
- Single point of failure (acceptable for personal tool).
- Infrastructure cost ~€10-15/month.

---

## ADR-005: Use existing GitHub OAuth for user identity

**Context**: The frontend already authenticates users via a custom GitHub OAuth app.

**Alternatives**:

- Separate email/password auth – duplicates user management.
- Auth0/Clerk with GitHub social login – adds external dependency.

**Decision**: Re-use the GitHub OAuth token as the API authentication mechanism.

- Frontend sends token in `Authorization: Bearer <github_token>` header.
- API server validates it by calling `https://api.github.com/user`.
- The returned GitHub user ID is the stable tenant key.

**Consequences**:

- Each API call requires synchronous token validation (cached for token lifetime).
- No persistent user records needed.
- Credentials are stored keyed by GitHub user ID, encrypted with server-side key.
