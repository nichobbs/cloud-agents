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

---

## ADR-006: Keep the credential vault write-only

**Context**: The Integrations page needs provider keys in the browser (live
model discovery, GitHub repo/PR/CI panels), but the vault never returns a
stored value. This forces a second, local copy of each connected key in
`localStorage`, and the question arose whether the vault should simply become
read-write so the UI could fetch keys on demand instead.

**Alternatives**:

- Read-write vault (`GET /api/credentials/{name}` returns the secret) —
  removes the second copy, but converts every stored secret into something
  exfiltratable in one authenticated GET. Any XSS, leaked API token, or
  malicious browser extension could then enumerate and download the entire
  vault, including secrets the UI never needs (e.g. deploy keys injected only
  into containers). It also breaks the current auditability guarantee that a
  secret, once stored, only ever flows server→container.
- Backend proxy endpoints (`/api/github/*`, `/api/models/*`) that use vault
  credentials server-side — the browser never holds a key at all. This is the
  best end state, but it is blocked today: Lyric has no reliable outbound
  HTTPS (the same constraint behind the webhook outbox, see
  `src/handlers/webhooks.l`).
- Local-copy-on-connect (current) — the vault stays write-only; the
  Integrations page keeps a browser-side copy of only the keys the user
  explicitly connects, documented with mitigations in `docs/credentials.md`.

**Decision**: Keep the vault write-only; keep browser-side copies scoped to
explicitly-connected keys. Migrate the UI's provider calls behind backend
proxy endpoints when Lyric gains a usable outbound HTTP client, at which
point the local copies (and this ADR's trade-off) can be removed entirely.

**Consequences**:

- Vault compromise via the web surface stays limited to *writing* secrets,
  never reading them; a hostile write is visible (names are listable) and
  recoverable (rotate + overwrite).
- The browser holds at most the four connect-able provider keys, each also
  revocable at the provider; "Disconnect" removes the local copy without
  touching the vault.
- Two copies of a connected key exist until the proxy migration lands.
