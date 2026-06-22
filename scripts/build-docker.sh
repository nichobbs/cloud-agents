#!/usr/bin/env bash
# Build harness runner images for local development and deployment.
#
# Usage:  ./scripts/build-docker.sh [target]
#   target: claude (default) | codex | opencode | all
#
# Images produced:
#   claude-code:base  — Claude Code CLI runner
#   codex:base        — OpenAI Codex CLI runner
#   opencode:base     — OpenCode runner

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_DIR="$REPO_ROOT/docker"
TARGET="${1:-claude}"

command -v docker >/dev/null || { echo "build-docker: 'docker' not on PATH" >&2; exit 1; }

build_claude() {
    echo "==> Building claude-code:base"
    docker build -t claude-code:base -f "$DOCKER_DIR/Dockerfile" "$DOCKER_DIR"
    echo "    claude-code:base  ✓"
}

build_codex() {
    echo "==> Building codex:base"
    docker build -t codex:base -f "$DOCKER_DIR/Dockerfile.codex" "$DOCKER_DIR"
    echo "    codex:base  ✓"
}

build_opencode() {
    echo "==> Building opencode:base"
    docker build -t opencode:base -f "$DOCKER_DIR/Dockerfile.opencode" "$DOCKER_DIR"
    echo "    opencode:base  ✓"
}

case "$TARGET" in
    claude)   build_claude ;;
    codex)    build_codex ;;
    opencode) build_opencode ;;
    all)      build_claude; build_codex; build_opencode ;;
    *)
        echo "build-docker: unknown target '$TARGET'" >&2
        echo "  usage: $0 [claude|codex|opencode|all]" >&2
        exit 1
        ;;
esac

echo "==> Done"
