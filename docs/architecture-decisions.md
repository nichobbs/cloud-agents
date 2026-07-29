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
  best end state. *Update (GitHub OAuth PR):* outbound HTTPS with request
  headers is now proven from the backend via direct `HttpWebRequest` externs
  (`src/github_api.l`, used by the OAuth flow), so this migration is
  unblocked and is the recommended next step. *Update (proxy PR): landed —
  see below.*
- Local-copy-on-connect — the vault stays write-only; the Integrations page
  keeps a browser-side copy of only the keys the user explicitly connects,
  documented with mitigations in `docs/credentials.md`. Now the *fallback*
  path rather than the only path.

**Decision**: Keep the vault write-only. **The proxy migration has landed**:
`GET /api/github/repos/{page}`, `/api/github/repos/{owner}/{repo}`,
`/api/github/pulls/{owner}/{repo}/{branch}`,
`/api/github/checks/{owner}/{repo}/{branch}` and `/api/models/{harness}`
(`src/handlers/proxy.l`) call GitHub and the model providers server-side with
vault keys and pass the raw JSON through; the frontend
(`lib/github.ts`/`lib/models.ts`) tries the proxy first and keeps the
browser-side copies only as a fallback (no vault key stored, an older
backend without the routes, or a branch name with `/` that doesn't fit the
proxy's single path segment). Browser-held provider keys are therefore now
**optional** for the repo browser, PR/CI panels and live model discovery.

**Consequences**:

- Vault compromise via the web surface stays limited to *writing* secrets,
  never reading them: the proxy endpoints return provider *responses*
  (listings), never the keys themselves; a hostile write is visible (names
  are listable) and recoverable (rotate + overwrite).
- The browser holds at most the four connect-able provider keys, and only if
  the user explicitly connects them for the fallback path; each is revocable
  at the provider, and "Disconnect" removes the local copy without touching
  the vault. With vault keys present, connecting locally is unnecessary.
- Two copies of a connected key exist only for users still relying on the
  fallback; the direct browser path (and this ADR's remaining trade-off) can
  be removed entirely once slashed-branch routing lands and old backends age
  out.

---

## ADR-007: Pre-accept the Claude harness's workspace trust dialog

**Context**: Claude Code asks interactively whether to trust a project
directory before honoring `settings.json`'s `permissions.allow` entries or
auto-loading other trust-gated project config (notably a repo-root
`.mcp.json`). `docker/entrypoint.sh` runs `claude -p` non-interactively, so
that prompt can never be answered — every run printed a warning and fell
back to unconfigured defaults (fixed in #705 by pre-accepting `/workspace`
in `~/.claude.json` before invoking `claude`).

**Consequence worth recording** (raised in #705's review, #711):
`/workspace` is populated by cloning `REPO_URL`, which is user-supplied.
Pre-accepting its trust means that if a cloned repo ships its own root
`.mcp.json`, Claude Code will now auto-load it and start whatever MCP
servers it declares, with no human confirmation — previously impossible
(the dialog blocked everything), now live.

**Decision**: Accept this. It is not a novel exposure for this project:
`docker/entrypoint-gemini.sh` already runs its harness with `--yolo`
("the container itself is the sandbox, same trust model as the other
harnesses") — an even broader auto-approval than a trust dialog would
have gated. The Claude harness now matches that existing precedent rather
than being the one harness still (uselessly) blocked by a prompt nothing
can answer.

**Consequences**:

- A malicious or compromised `REPO_URL` can register and run MCP servers
  inside the runner container with no human review step, same as it
  already could invoke arbitrary tools once the harness starts working the
  repo.
- Containment still rests on the container being the trust boundary (fresh
  per session, no host access beyond what's explicitly mounted/exposed) —
  if that sandboxing assumption ever changes, this decision needs
  revisiting alongside `entrypoint-gemini.sh`'s `--yolo`.
