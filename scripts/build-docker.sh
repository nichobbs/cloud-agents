#!/usr/bin/env bash
# Build harness runner images for local development and deployment.
#
# Usage:  ./scripts/build-docker.sh [target]
#   target: claude (default) | codex | opencode | gemini | all
#
# Images produced:
#   claude-code:base  — Claude Code CLI runner
#   codex:base        — OpenAI Codex CLI runner
#   opencode:base     — OpenCode runner
#   gemini:base       — Google Gemini CLI runner

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_DIR="$REPO_ROOT/docker"
TARGET="${1:-claude}"

command -v docker >/dev/null || { echo "build-docker: 'docker' not on PATH" >&2; exit 1; }

# claude-code:base builds cloud-agents-shim (docs/phase6-mcp-callbacks.md §5,
# stage 3) INSIDE the Dockerfile's own shim-builder stage, so its context is
# the repo root (it needs to see both docker/ and shim/) rather than docker/
# alone — unlike the other three runner images below, which don't embed the
# shim and keep the narrower docker/ context.
build_claude() {
    echo "==> Building claude-code:base"
    docker build -t claude-code:base -f "$DOCKER_DIR/Dockerfile" "$REPO_ROOT"
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

build_gemini() {
    echo "==> Building gemini:base"
    docker build -t gemini:base -f "$DOCKER_DIR/Dockerfile.gemini" "$DOCKER_DIR"
    echo "    gemini:base  ✓"
}

case "$TARGET" in
    claude)   build_claude ;;
    codex)    build_codex ;;
    opencode) build_opencode ;;
    gemini)   build_gemini ;;
    all)      build_claude; build_codex; build_opencode; build_gemini ;;
    *)
        echo "build-docker: unknown target '$TARGET'" >&2
        echo "  usage: $0 [claude|codex|opencode|gemini|all]" >&2
        exit 1
        ;;
esac

echo "==> Done"
