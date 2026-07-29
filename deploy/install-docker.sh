#!/bin/bash
# Phase 5 — provision a fresh Ubuntu 22.04 VM (e.g. Hetzner CX41) with Docker.
#
# Usage:  sudo ./install-docker.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root (sudo)" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg

# Docker's official apt repository.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# Build every harness's runner image so the first session (whichever harness
# it picks) does not pay the cost. Tags must match imageForHarness()
# (src/docker_manager.l) exactly.
#
# REPO_ROOT is derived from this script's own location, NOT hardcoded to
# /opt/cloud-agents: per RUNBOOK.md's documented first-time-setup order,
# this script runs from the checked-out repo BEFORE that repo is rsynced to
# /opt/cloud-agents (the very next command). The previous hardcoded
# /opt/cloud-agents/docker/... path never existed yet at this point in the
# flow, so every `[ -f ... ]` guard below silently evaluated false and this
# entire build loop was a silent no-op — every fresh VM setup hit exactly
# the opaque "no such image" container-creation failure this loop exists to
# prevent. Building from the checkout's own path (wherever it happens to be
# on disk) fixes this regardless of when the rsync to /opt/cloud-agents runs.
#
# claude-code:base needs the REPO ROOT as build context (its Dockerfile COPYs
# from both docker/ and shim/, #601) — the other three only need docker/,
# matching docker-compose.coolify.yml's per-service build.context exactly.
#
# Parallel arrays, indexed together, rather than packing "dockerfile tag
# context" into one space-delimited string and cut -d' '-ing it apart:
# REPO_ROOT is derived from a real filesystem path (line below) and isn't
# guaranteed space-free, and cut -d' ' silently mis-parses a context
# containing one.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
dockerfiles=(Dockerfile Dockerfile.codex Dockerfile.opencode Dockerfile.gemini)
tags=(claude-code:base codex:base opencode:base gemini:base)
contexts=("$REPO_ROOT" "$REPO_ROOT/docker" "$REPO_ROOT/docker" "$REPO_ROOT/docker")
for i in "${!dockerfiles[@]}"; do
    dockerfile="${dockerfiles[$i]}"
    tag="${tags[$i]}"
    context="${contexts[$i]}"
    if [ ! -f "${REPO_ROOT}/docker/${dockerfile}" ]; then
        echo "install-docker.sh: ${REPO_ROOT}/docker/${dockerfile} not found — refusing to silently skip it" >&2
        exit 1
    fi
    docker build -t "$tag" -f "${REPO_ROOT}/docker/${dockerfile}" "$context"
done

echo "Docker $(docker --version) installed."
echo "Next: copy the repo to /opt/cloud-agents, create deploy/.env, then run:"
echo "  cd /opt/cloud-agents/deploy && docker compose up -d"
