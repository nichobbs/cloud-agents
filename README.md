# Cloud Agents

A self-hosted web platform for running [Claude Code](https://claude.com/claude-code),
[Codex](https://openai.com/index/introducing-codex/), and
[OpenCode](https://opencode.ai/) sessions against a git repository from a
browser, instead of a local terminal. Each message you send spins up an
ephemeral Docker container that clones the repo, runs the selected CLI
non-interactively, and returns its output.

**Status: early / personal-scale.** See [`docs/PROGRESS.md`](docs/PROGRESS.md)
for what's actually shipped vs. designed, and
[`docs/review-2026-07-03.md`](docs/review-2026-07-03.md) /
[`docs/review-2026-07-03-followup.md`](docs/review-2026-07-03-followup.md) for
known gaps — notably, **no endpoint currently enforces authentication** and
output is not yet truly real-time (see the followup review's headline
finding). Read those before deploying this anywhere reachable by untrusted
traffic.

## Architecture

- **`src/`** — the API server, written in [Lyric](https://nichobbs.github.io/lyric-lang/)
  (a safety-oriented language targeting .NET 10). Handles session lifecycle,
  Docker container orchestration, and a SQLite-backed transcript/comments/todos
  store. See [`CLAUDE.md`](CLAUDE.md) for the Lyric-specific build/coding
  conventions, and `docs/lyric/` for language reference material.
- **`frontend/`** — a Vite + React + TypeScript single-page app: create
  sessions, send messages, watch output, and anchor comments/todos to
  specific agent responses.
- **`docker/`** — runner images for each harness (`claude-code:base`,
  `codex:base`, `opencode:base`), plus tool-pack variants
  (`Dockerfile.rust`, `Dockerfile.data`) and the entrypoint scripts that
  render MCP/settings config into each container.
- **`deploy/`** — a `docker-compose.yml` topology (API + frontend + Caddy
  reverse proxy) for running this on a single VM, with a
  [runbook](deploy/RUNBOOK.md) for day-2 operations.

See [`docs/architecture-decisions.md`](docs/architecture-decisions.md) for the
reasoning behind the major design choices (why `claude -p` in ephemeral
containers, why Docker volumes over a database for session state, etc.), and
`docs/phase*-*.md` for the phased design docs each part of the system was
built against.

## Build and run

The backend requires the Lyric compiler (v0.4.14+) and .NET 10 SDK. **A
full `lyric build` succeeds** — the first time in this project's history,
after four sequential upstream compiler bugs (three now fixed). **Actually
running the built server (`lyric run`) still doesn't work**: an open
upstream bug means NuGet-restored dependency DLLs aren't copied to the
output directory at runtime. See [`docs/BUILD.md`](docs/BUILD.md)
"Compiler notes" for the full history and
`./scripts/repro-compiler-bug.sh` for a runnable check of your compiler's
status.

```sh
lyric restore && lyric build   # or: ./scripts/build-full.sh — succeeds as of v0.4.14
./scripts/verify.sh            # runtime-verifies the core logic — genuinely passes
./scripts/run-api.sh           # build + start the API server locally — still blocked, see docs/BUILD.md
```

```sh
cd frontend
npm install
npm run dev                    # Vite dev server at http://localhost:5173
```

Or use the [`Makefile`](Makefile) targets (`make dev`, `make build`, `make
test`, `make run`, `make docker[-codex|-opencode|-all]`) — run `make help`
for the full list.

## Deploying

`deploy/` has a single-VM Docker Compose setup (API + frontend + Caddy) and a
runbook covering provisioning, backups, and troubleshooting — start with
[`deploy/RUNBOOK.md`](deploy/RUNBOOK.md).

## License

MIT — see [`LICENSE`](LICENSE).
