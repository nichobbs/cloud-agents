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
