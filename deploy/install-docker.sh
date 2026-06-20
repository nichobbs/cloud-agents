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

# Build the base runner image so the first session does not pay the cost.
if [ -f /opt/cloud-agents/docker/Dockerfile ]; then
    docker build -t claude-code:base -f /opt/cloud-agents/docker/Dockerfile /opt/cloud-agents/docker
fi

echo "Docker $(docker --version) installed."
echo "Next: copy the repo to /opt/cloud-agents, create deploy/.env, then run:"
echo "  cd /opt/cloud-agents/deploy && docker compose up -d"
