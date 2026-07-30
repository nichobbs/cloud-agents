#!/usr/bin/env bash
# Guards the byte-identical shim-builder stages across all four runner
# Dockerfiles (#795): docker/Dockerfile is canonical; Dockerfile.codex/
# .gemini/.opencode each carry a condensed copy whose NON-COMMENT
# instructions must match the canonical stage exactly — that identity is
# what lets Docker's layer cache build the shim once and share it across a
# sequential single-host build (Coolify, build-docker.sh). Before this
# check, the property was enforced only by a code comment.
#
# Extraction: every line from the `FROM ... AS shim-builder` line through
# `RUN lyric restore && lyric build` (inclusive), with comment-only and
# blank lines dropped — comments are allowed to differ (the canonical stage
# is fully commented, the copies are condensed by design).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

extract_stage() {
  awk '
    /^FROM .* AS shim-builder$/ {collecting = 1}
    collecting {
      if ($0 !~ /^[[:space:]]*#/ && $0 !~ /^[[:space:]]*$/) print
      if ($0 == "RUN lyric restore && lyric build") exit
    }
  ' "$1"
}

CANONICAL="$(extract_stage "$REPO_ROOT/docker/Dockerfile")"
if [ -z "$CANONICAL" ]; then
  echo "check-shim-stage-sync: could not extract the shim-builder stage from docker/Dockerfile" >&2
  exit 1
fi
if ! printf '%s\n' "$CANONICAL" | grep -q '^RUN lyric restore && lyric build$'; then
  echo "check-shim-stage-sync: canonical stage extraction did not reach 'RUN lyric restore && lyric build' — the marker changed?" >&2
  exit 1
fi

fails=0
for f in Dockerfile.codex Dockerfile.gemini Dockerfile.opencode; do
  STAGE="$(extract_stage "$REPO_ROOT/docker/$f")"
  if [ -z "$STAGE" ]; then
    echo "FAIL docker/$f: no shim-builder stage found" >&2
    fails=$((fails + 1))
    continue
  fi
  if [ "$STAGE" = "$CANONICAL" ]; then
    echo "ok   docker/$f: shim-builder stage matches the canonical one"
  else
    echo "FAIL docker/$f: shim-builder stage has drifted from docker/Dockerfile's canonical stage:" >&2
    diff <(printf '%s\n' "$CANONICAL") <(printf '%s\n' "$STAGE") >&2 || true
    fails=$((fails + 1))
  fi
done

# The final stages must also actually CONSUME the stage (#815): a drifted or
# deleted COPY --from=shim-builder line would ship an image whose stage built
# fine but whose shim is missing at runtime.
SHIM_COPY='COPY --from=shim-builder /src/shim/bin/. /opt/cloud-agents-shim/'
for f in Dockerfile Dockerfile.codex Dockerfile.gemini Dockerfile.opencode; do
  if grep -qF "$SHIM_COPY" "$REPO_ROOT/docker/$f"; then
    echo "ok   docker/$f: final stage copies the built shim"
  else
    echo "FAIL docker/$f: missing '$SHIM_COPY'" >&2
    fails=$((fails + 1))
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "==> check-shim-stage-sync: ${fails} Dockerfile(s) drifted — keep the four stages' instructions byte-identical (docker/Dockerfile is canonical) so the layer cache builds the shim once" >&2
  exit 1
fi
echo "==> check-shim-stage-sync: all four shim-builder stages are in sync"
