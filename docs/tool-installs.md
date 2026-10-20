# Installing tools in runner containers

Each runner image (one per harness) ships a fixed toolset. This document
covers the two ways to add tools without building a new image: the agent
installing what it needs while it works, and a per-profile setup script.

## Constraints these work within

- The harness runs as an unprivileged user. Only the claude image starts as
  root, and it drops to `claude-user` before anything from the profile or
  repository runs. No image ships `sudo`. So `apt` is out.
- Each run gets a fresh container. Only two volumes persist:
  - `/workspace`, per session;
  - the home directory, per user per harness
    (`user-<userId>-<harness>-home`), shared by every session of that user on
    that harness.
- Network access follows the profile's network policy. With `none` nothing can
  be downloaded. With `restricted`, only what the egress proxy allows.

## User-space installs

`docker/user-tools.sh` is sourced by all five entrypoints after the privilege
drop. `cloud_agents_user_tools_env` sets:

| Variable | Value | Effect |
|---|---|---|
| `NPM_CONFIG_PREFIX` | `~/.local` | `npm i -g` works without root |
| `PIP_BREAK_SYSTEM_PACKAGES` | `1` | `pip install` outside a virtualenv falls back to a user install instead of refusing (PEP 668); no effect inside one |
| `UV_TOOL_BIN_DIR` | `~/.local/bin` | `uv tool install` binaries |
| `GOBIN` | `~/.local/bin` | `go install` binaries |
| `PATH` | `…:~/.local/bin:~/.cargo/bin` | appended, not prepended |

`PIP_USER` is deliberately not set, because it breaks `pip install` inside a
virtualenv.

The directories go at the end of `PATH`. The image's binaries (git, node,
python, the harness CLI) therefore always win. A user install can't shadow
them, and neither can a CLI's self-updater writing into the npm prefix.

Because `$HOME` persists per user per harness, a tool installed in one session
is available in the next. The session tools guide
(`docker/session-tools-guide.md`) tells the agent it may install tools, where
they go, and to check before reinstalling.

The trade-off is that installs are shared across all of that user's sessions
on that harness. That includes a compromised package. Removing the home volume
resets it.

## Profile setup script

A profile has a `setupScript` field: up to 24576 characters of bash, edited
on the profiles page. The limit keeps the base64-encoded script under Linux's
128 KiB cap on a single environment variable, whatever characters it uses. It is stored in `profiles.setup_script` (migration
`0003_profile_setup_script`) and passed to the profile's session containers as
`CLOUD_AGENTS_SETUP_SCRIPT_B64`. Observer containers do not get it.

`cloud_agents_run_setup_script` handles it:

- runs it with `bash` as the harness user, in `/workspace`, after the clone and
  library injection and before the harness, with the user-tools environment
  already in place;
- runs it **once per distinct content**. A marker
  `~/.cache/cloud-agents/setup/<sha256-prefix>.done` records a successful run.
  Its installs persist on the home volume, so running it on every message would
  only cost time. Editing the script makes it run again;
- holds a lock (`flock`) on the home volume while it runs. A second session of
  the same user and harness starting at the same moment waits up to
  `CLOUD_AGENTS_SETUP_LOCK_WAIT` seconds (default 120), then sees the marker and
  skips, or carries on without the script if the other run is still going;
- has a time limit of `CLOUD_AGENTS_SETUP_TIMEOUT` seconds (default 600);
- never fails the run. On failure it writes a warning with the log tail to the
  container log and records the log path in
  `~/.cache/cloud-agents/setup/last-failure`, which the agent is told to check.
  It retries the same script only after `CLOUD_AGENTS_SETUP_RETRY_SECS` (default
  3600), so a broken script does not add its timeout to every message.

The container log shows the last 20 lines of a failed run. Avoid `set -x` or
echoing secrets in the script, since that output ends up there.

The script has the session's full environment, including its credentials. It
is owner-authored profile configuration, unlike repository content, so it is
treated like the profile's other settings.

Write scripts to be idempotent and fast to re-check, for example:

```sh
set -e
command -v pnpm >/dev/null || npm i -g pnpm@9
command -v ruff >/dev/null || uv tool install ruff
```

Because it runs once per content, it is for installing things, not for
per-run setup. Exports in the script do not reach the harness, and anything it
changes outside the home volume (`/workspace` aside, which persists per
session) is lost when the container exits and is not redone on the next run.
Install into `~/.local`, not system paths.

## Not covered: system packages

Native libraries and anything else that needs `apt` are not possible as the
harness user. Options, roughly in order of effort:

1. A static or user-space build of the tool (many CLIs publish one).
2. Root-phase package installs in the claude image, from a validated package
   list on the profile. This applies to the claude image only: the other four
   images run as their harness user from the start and would first need the
   same privilege drop.
3. Per-profile custom images built on the base harness image (this would bring
   back `docker/Dockerfile.rust` / `Dockerfile.data`, which nothing currently
   builds or selects).

## Tests

- `scripts/test-user-tools.sh` (CI) covers the environment, `PATH` precedence,
  run-once, re-run on change, the lock between concurrent sessions, retry
  backoff after failure, timeout, bad input, and that every entrypoint and image
  wires the helper in.
- `tests/profile_tests.l` covers the request decode with and without
  `setupScript`, the length limit, and storing, returning, preserving and
  clearing the script. `tests/runner_env_tests.l` covers the env entry.
- `frontend/src/pages/Profiles.test.tsx` covers the form field.
