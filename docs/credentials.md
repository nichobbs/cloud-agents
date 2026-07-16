# Credential Handling

Claude Code runs headlessly inside the runner containers, so it needs a
pre-authenticated `~/.claude` folder. There is no browser OAuth flow inside the
container (see ADR-003).

## Phase 1 — manual bind mount (development)

Authenticate Claude Code locally once:

```sh
claude   # complete the login flow on your workstation
```

This populates `~/.claude` with the OAuth credentials. For Phase 1 the platform
mounts that folder directly into the runner container as the user-home volume.

The API server starts runner containers with two mounts (see
`src/docker_manager.l`):

| Host / volume | Container path | Purpose |
|---------------|----------------|---------|
| `session-<id>-workspace` | `/workspace` | cloned repo + `.claude` session files |
| `claude-home-default` (Phase 1) | `/home/claude-user` | authenticated `~/.claude` |

To seed the shared home volume from your local credentials during development:

```sh
docker volume create claude-home-default
docker run --rm -v claude-home-default:/dst -v "$HOME/.claude:/src:ro" \
    alpine sh -c 'cp -a /src/. /dst/.claude/'
```

The refresh token lives for months, so this is a one-time step until it expires.

## Phase 3 — encrypted upload (production)

Phase 1's shared `claude-home-default` volume is replaced by per-user encrypted
storage (see `docs/phase3-multi-tenancy.md`):

- Endpoint `PUT /api/users/me/credentials` accepts a `tar.gz` of the `.claude`
  folder.
- The blob is encrypted at rest with a server-side key (`ENCRYPTION_KEY`) and
  the GitHub user ID as associated data, stored as `credentials/<githubId>.enc`.
- On container start the blob is decrypted to a temp dir, mounted at
  `/home/claude-user/.claude`, and securely wiped after the container exits.
- Volumes become per-user: `user-<githubId>-home`,
  `session-<githubId>-<sessionId>` (see `CloudAgents.Db.homeVolumeName` /
  `workspaceVolumeName`).

The GitHub OAuth token is **never** stored — it is only used to validate
identity per request (`CloudAgents.Auth`).

## Auto-uploading harness credentials

Two convenience paths feed the credential vault (`POST /api/credentials`)
without hand-typing names and values:

- **Integrations page (frontend).** Connect a provider key (Anthropic, OpenAI,
  Google, GitHub): the key is validated against the provider's API, uploaded
  to the vault under its canonical env-var name (`ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GITHUB_TOKEN`), and kept locally in the
  browser to power live model discovery and the GitHub repo/PR/CI panels
  (the vault is write-only, so the UI cannot read the key back). The page also
  imports pasted credential files — `~/.claude/.credentials.json` (Claude Code
  OAuth → `CLAUDE_CODE_OAUTH_TOKEN`), `~/.codex/auth.json`, and OpenCode's
  `auth.json` — recognising each secret and uploading it under the right name.
- **`scripts/upload-credentials.sh` (CLI).** Auto-detects credentials on your
  workstation (the env vars above, the same three credential files, and
  `gh auth token`) and uploads whatever it finds. Supports `--dry-run`;
  configure `CLOUD_AGENTS_URL` / `CLOUD_AGENTS_API_TOKEN`.

**Security note on local connections.** The browser-side copy kept by the
Integrations page lives in `localStorage`, and the UI calls provider APIs
(Anthropic/OpenAI/Google/GitHub) directly from the browser. This is a
deliberate trade-off forced by the write-only vault plus the Lyric backend's
lack of outbound HTTPS — but it means any XSS on the frontend origin could
read those keys. Mitigations: use least-privilege keys (fine-grained GitHub
PATs scoped to the repos you need; provider keys with spend limits), the
frontend renders no untrusted HTML except ANSI-converted run output
(`ansi_up` escapes HTML), and "Disconnect" on the Integrations page removes
the local copy without touching the vault. Skip connecting a provider
entirely if you only need runner-container injection — the vault upload on
the Credentials page never keeps a local copy.
