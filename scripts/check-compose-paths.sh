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
# the resolved build.context and bind-mount source paths back out of `docker
# compose config --format json` and stats each one.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

check_json_paths() {
  local label="$1" json="$2"
  local paths
  paths="$(python3 - "$json" <<'PYEOF'
import json, sys
cfg = json.loads(sys.argv[1])
paths = []
for svc in cfg.get("services", {}).values():
    build = svc.get("build")
    if isinstance(build, dict) and build.get("context"):
        paths.append(build["context"])
    for vol in svc.get("volumes", []) or []:
        if isinstance(vol, dict) and vol.get("type") == "bind":
            paths.append(vol["source"])
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
json_coolify="$(cd "$REPO_ROOT" && ENCRYPTION_KEY=ci-check docker compose --project-directory . -f deploy/docker-compose.coolify.yml config --format json)"
check_json_paths "docker-compose.coolify.yml" "$json_coolify"

exit $FAIL
