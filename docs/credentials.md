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
`src/docker_manager.l`; the home bind comes from
`CloudAgents.Db.homeVolumeBindForHarness`, one shared volume per harness so
each CLI's config/history persists at its image's real `$HOME` — #409):

| Host / volume | Container path | Purpose |
|---------------|----------------|---------|
| `session-<id>-workspace` | `/workspace` | cloned repo + `.claude` session files |
| `claude-home-default` (claude, Phase 1) | `/home/claude-user` | authenticated `~/.claude` |
| `codex-home-default` (codex) | `/home/codex-user` | Codex CLI config + history |
| `opencode-home-default` (opencode) | `/home/opencode-user` | OpenCode config + history |
| `gemini-home-default` (gemini) | `/home/gemini-user` | Gemini CLI config + history |

The names above are the single-operator (`default` tenant) shapes.
OAuth-authenticated tenants get per-user volumes instead —
`user-<userId>-<harness>-home` (empty harness normalised to `claude`) and
`session-<userId>-<sessionId>-workspace`, via
`CloudAgents.Db.homeVolumeBindFor` / `workspaceVolumeBindFor` — while the
operator identity keeps the legacy shared names so existing installs keep
their authenticated `~/.claude` and workspaces.

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
- Volumes are per-user **(implemented)**: OAuth tenants mount
  `user-<userId>-<harness>-home` and `session-<userId>-<sessionId>-workspace`
  (see `CloudAgents.Db.homeVolumeBindFor` / `workspaceVolumeBindFor`), while
  the operator `default` identity keeps the legacy shared names from the
  Phase 1 table above.

The auth layer **never** stores the GitHub OAuth token — per-request
validation (`CloudAgents.Auth`) keeps only a short-TTL cache row keyed by
the token's SHA-256 (`github_token_cache`). The one place it is persisted
is the credential vault, encrypted at rest: signing in stores it as your
tenant's `GITHUB_TOKEN` when `ENCRYPTION_KEY` is configured (see "GitHub
OAuth setup" below).

## GitHub OAuth setup

1. Create a GitHub OAuth app (Settings → Developer settings → OAuth Apps)
   with the callback URL `https://<your-host>/auth/callback` (or
   `http://localhost:5173/auth/callback` for the Vite dev server).
2. Set `CLOUD_AGENTS_GITHUB_CLIENT_ID` and
   `CLOUD_AGENTS_GITHUB_CLIENT_SECRET` in the API server's environment, and
   optionally `CLOUD_AGENTS_WHITELIST` to a comma-separated list of GitHub
   numeric user ids allowed in (empty = any authenticated GitHub user).
3. "Sign in with GitHub" appears in the nav. Signing in stores the OAuth
   token as the API bearer (all data becomes scoped to your `gh-<id>`
   tenant) and connects GitHub in the UI (repo browser, PR/CI panels) in
   one step. The requested scopes are `repo read:user`.
4. Signing in also stores the token as a `GITHUB_TOKEN` credential in the
   vault for your tenant (when `ENCRYPTION_KEY` is configured) — but **only
   if none exists yet** (#441): a manually-configured `GITHUB_TOKEN` (e.g. a
   deliberately-scoped fine-grained PAT) is never silently replaced by
   sign-in. If an auto-vaulted token goes stale, delete the credential and
   sign in again to refresh it. "Sign out" forgets the device's copy **and**
   invalidates the server's validation-cache row for that token.

   Note the asymmetry (#439): sign-out does **not** delete the vaulted
   `GITHUB_TOKEN` (your containers keep working across sign-ins by design)
   and cannot revoke the token at GitHub. For full revocation, delete the
   credential on the Credentials page and revoke the app grant at
   github.com/settings/applications — revoking there invalidates every copy
   at once.

The static `CLOUD_AGENTS_API_TOKEN` keeps working as the single-operator
fallback; a bearer matching it authenticates as the `default` tenant exactly
as before.

Validation-cache latencies: whitelist changes — removals *and* additions —
take effect on the affected user's **next request** (the whitelist is
re-applied on every cache hit, and a whitelist-miss caches the identity
positively rather than negatively); revoking the OAuth token *at GitHub* is
only noticed at revalidation, i.e. within the 10-minute cache TTL. Tokens
GitHub itself rejects are negatively cached for 1 minute so repeated bad
bearers don't each cost an outbound round trip, with a global backstop that
stops validating unrecognised bearers entirely once 30 distinct failures are
in-window.

The backstop is global rather than per-IP by design (#433): the only
per-caller signal, `X-Forwarded-For`, is attacker-controlled on
direct-exposure deployments, and partitioning by it would let a flooder
escape its own bucket. A tripped backstop does **not** affect signed-in
users (positive cache) or new sign-ins (the exchange endpoint validates
directly and primes the cache) — only bearers that never went through this
server's exchange, which re-running "Sign in with GitHub" self-heals.

The exchange endpoint has its own, independent backstop (#434): a code
GitHub already rejected is refused while its 1-minute negative row lives,
and 30 distinct rejected codes in-window pause outbound exchanges. The two
counters are separate, so a garbage-bearer flood can never lock out
sign-ins and a garbage-code flood only throttles the exchange itself. Only
confirmed GitHub rejections (HTTP 401/403) are negatively cached — transport
failures fail the request but are never cached or counted (#435).

## Auto-uploading harness credentials

Two convenience paths feed the credential vault (`POST /api/credentials`)
without hand-typing names and values:

- **Integrations page (frontend).** Connect a provider key (Anthropic, OpenAI,
  Google, GitHub): the key is validated against the provider's API, uploaded
  to the vault under its canonical env-var name (`ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GITHUB_TOKEN`), and kept locally in the
  browser as a *fallback* for live model discovery and the GitHub repo/PR/CI
  panels (the vault is write-only, so the UI cannot read the key back; the
  primary path for those features is now the backend proxy, which uses the
  vault copy server-side — see the security note below). The page also
  imports pasted credential files — `~/.claude/.credentials.json` (Claude Code
  OAuth → `CLAUDE_CODE_OAUTH_TOKEN`), `~/.codex/auth.json`, and OpenCode's
  `auth.json` — recognising each secret and uploading it under the right name.
- **`scripts/upload-credentials.sh` (CLI).** Auto-detects credentials on your
  workstation (the env vars above, the same three credential files, and
  `gh auth token`) and uploads whatever it finds. Supports `--dry-run` and
  `--claude-home` (see below); configure `CLOUD_AGENTS_URL` /
  `CLOUD_AGENTS_API_TOKEN`.

## Claude subscription (OAuth) credentials

A Claude Code **API key** (`ANTHROPIC_API_KEY`) is a single value and rides the
normal credential vault like any other secret. A Claude Code **subscription
login** is different: it's not an API key but an OAuth session stored as a
`~/.claude` directory (`~/.claude/.credentials.json`, with a refreshable access
token). There's no single value to hand a container as one env var, and no
browser OAuth flow inside a headless runner — so a subscription login needs the
directory itself.

`--claude-home` bundles the essentials of that directory and ships them through
the same vault:

```sh
CLOUD_AGENTS_URL=http://localhost:8080 \
CLOUD_AGENTS_API_TOKEN=... \
./scripts/upload-credentials.sh --claude-home
```

- **What's in the bundle.** Only `~/.claude/.credentials.json` (the login) plus
  `~/.claude/settings.json` if present — tarred, gzipped, and base64-encoded
  into a single credential named `CLAUDE_HOME_TARBALL_B64`. The bulky
  `projects/`, `todos/`, `statsig/`, and cache directories are deliberately
  excluded so the bundle stays small.
- **Size cap.** The vault rejects a credential value over **65536 characters**
  (`maxCredentialValueLen`), so the base64 bundle must fit under it. The script
  fails with the included files and their sizes if it doesn't — trim `~/.claude`
  (it's almost always the excluded dirs bloating it) and retry.
- **How it's delivered.** `CLAUDE_HOME_TARBALL_B64` is injected into the claude
  runner container as an env var like any vault credential (no backend change —
  the injection path is generic). The claude entrypoint (`docker/entrypoint.sh`)
  unpacks it into `$HOME/.claude` **only on a fresh home volume** — i.e. when no
  `.credentials.json` is already present — so an existing, possibly
  token-refreshed, login is never overwritten. The blob is never echoed.
- **Rotation.** Re-run `--claude-home` to upload a new bundle; **new** sessions
  (fresh home volumes) pick it up. An existing session's home volume keeps its
  current `~/.claude` until that volume is cleared, by design — the entrypoint
  won't clobber a live login.
- **Security.** The bundle is encrypted at rest in the write-only vault like
  every other credential; it is decrypted server-side only when building the
  container env, and then lives as an env var inside that container — the same
  trust domain as the agent running there (which can already read every other
  injected secret). Treat it as equivalent to handing that container your Claude
  login, because that is exactly what it does.

**Security note on local connections.** UI features that call provider APIs
(live model discovery, the GitHub repo/PR/CI panels) now go through the
backend's proxy endpoints (`/api/github/*`, `/api/models/{harness}` — see
ADR-006), which use the *vault* copy of each key server-side. Locally-held
Integrations keys are therefore **optional** for those features whenever the
vault has the key: the browser tries the proxy first and only uses its
`localStorage` copy as a fallback (no key in the vault, an older backend
without the proxy routes, or a branch name containing `/`, which doesn't fit
the proxy's single path segment). Where the fallback is used, the original
trade-off still applies: any XSS on the frontend origin could read the
locally-held keys. Mitigations: skip connecting locally at all when the
vault has the key (the proxy covers the UI features), use least-privilege
keys (fine-grained GitHub PATs scoped to the repos you need; provider keys
with spend limits), the frontend renders no untrusted HTML except
ANSI-converted run output (`ansi_up` escapes HTML), and "Disconnect" on the
Integrations page removes the local copy without touching the vault. The
vault upload on the Credentials page never keeps a local copy.
