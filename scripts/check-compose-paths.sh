#!/usr/bin/env bash
# Validates that deploy/docker-compose.yml and deploy/docker-compose.coolify.yml
# resolve their relative paths (build context, bind mounts) to real files/
# directories — each under its own actual invocation convention:
#   - docker-compose.yml: RUNBOOK.md `cd`s into deploy/ before running
#     `docker compose up`, so relative paths resolve against deploy/.
#   - docker-compose.coolify.yml: Coolify instead invokes compose with
#     --project-directory set to the repo root checkout, which overrides
#     Compose's normal compose-file-relative resolution — a path written for
#     the deploy/-relative convention silently resolves one directory off
#     under this one. This exact class of bug shipped and broke a real
#     deploy (nichobbs/cloud-agents#464).
#
# `docker compose config` alone only validates variable interpolation — it
# does not check that a resolved host path actually exists, which is exactly
# how #464 got through review as a plausible-looking diff. This script reads
# the resolved relative-path-bearing fields back out of `docker compose
# config --format json` and stats each one: build.context, build.dockerfile
# (joined onto its context — `docker compose config` leaves it relative to
# context, not resolved to absolute, unlike build.context itself),
# bind-mount volume sources, and top-level configs/secrets `file:` sources
# (nichobbs/cloud-agents#472 — the script previously only covered
# build.context and bind-mount sources).
#
# env_file deliberately has no separate check here: `docker compose config`
# itself resolves and reads env_file eagerly and hard-fails (non-zero exit,
# before ever producing JSON) if the referenced file doesn't exist — see the
# `docker compose config` invocations below, which run under `set -euo
# pipefail` and so already fail this script the same way a MISSING path
# would. There is nothing left for check_json_paths to add for that key.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

check_json_paths() {
  local label="$1" json="$2"
  local paths
  paths="$(python3 - "$json" <<'PYEOF'
import json, os, sys
cfg = json.loads(sys.argv[1])
paths = []
for svc in cfg.get("services", {}).values():
    build = svc.get("build")
    if isinstance(build, dict) and build.get("context"):
        context = build["context"]
        paths.append(context)
        # build.dockerfile is left relative to build.context by `docker
        # compose config` (unlike build.context itself, which is resolved
        # to an absolute path) — join them before stat-ing. Skip
        # dockerfile_inline (no on-disk file to check).
        dockerfile = build.get("dockerfile")
        if dockerfile and not build.get("dockerfile_inline"):
            paths.append(os.path.join(context, dockerfile))
    for vol in svc.get("volumes", []) or []:
        if isinstance(vol, dict) and vol.get("type") == "bind":
            paths.append(vol["source"])
# Top-level configs:/secrets: entries with a `file:` source. Services
# reference these by name (services.*.configs/secrets), but the actual
# host path only appears in these top-level sections.
for section in ("configs", "secrets"):
    for entry in cfg.get(section, {}).values():
        if isinstance(entry, dict) and entry.get("file"):
            paths.append(entry["file"])
print("\n".join(paths))
PYEOF
)"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    # Only exists on a real Docker host, not this CI runner — not what this
    # check is for.
    [ "$p" = "/var/run/docker.sock" ] && continue
    if [ -e "$p" ]; then
      echo "ok ($label): $p"
    else
      echo "MISSING ($label): $p" >&2
      FAIL=1
    fi
  done <<< "$paths"
}

echo "== docker-compose.yml (cd deploy/ invocation, per RUNBOOK.md) =="
json_std="$(cd "$REPO_ROOT/deploy" && ENCRYPTION_KEY=ci-check docker compose config --format json)"
check_json_paths "docker-compose.yml" "$json_std"

echo "== docker-compose.coolify.yml (--project-directory repo-root, per Coolify) =="
# codex-base/opencode-base/gemini-base build unconditionally now (no
# `profiles:` gating — see the compose file's own comments for why that
# gating existed and why it's no longer necessary), so `docker compose
# config` always renders all four services and this check validates all of
# their paths with no special activation needed.
#
# exclude_from_hc (nichobbs/cloud-agents#516) is a real, documented Coolify
# service property (https://coolify.io/docs/knowledge-base/docker/compose)
# — Coolify's own deploy-time parser accepts it fine — but it isn't part of
# the upstream Compose Specification, so the real `docker compose` CLI used
# here purely to resolve/validate paths rejects it outright ("additional
# properties 'exclude_from_hc' not allowed"). Strip it from a scratch copy
# before running that CLI against it; the committed file (with the field
# Coolify actually needs) is untouched.
coolify_scratch="$(mktemp "$REPO_ROOT/deploy/.coolify-path-check.XXXXXX.yml")"
trap 'rm -f "$coolify_scratch"' EXIT
grep -v 'exclude_from_hc:' "$REPO_ROOT/deploy/docker-compose.coolify.yml" > "$coolify_scratch"
json_coolify="$(cd "$REPO_ROOT" && ENCRYPTION_KEY=ci-check docker compose --project-directory . -f "$coolify_scratch" config --format json)"
check_json_paths "docker-compose.coolify.yml" "$json_coolify"

exit $FAIL
