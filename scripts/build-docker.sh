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

# Build cloud-agents-shim (docs/phase6-mcp-callbacks.md §5, stage 3) and
# stage its output into the docker/ build context as docker/shim-dist/ —
# `docker build`'s context here is docker/ itself (see build_claude below),
# which cannot COPY anything from ../shim/, so the compiled bin/ directory
# is copied in ahead of time. Always staged regardless of the
# CLOUD_AGENTS_MCP_CALLBACKS runtime flag (on by default in
# docker/entrypoint.sh as of stage 4, §8 — an operator opts out with =0) so
# the image always has the binary the flag's default now expects to find.
stage_shim() {
    command -v lyric >/dev/null || { echo "build-docker: 'lyric' not on PATH (needed to build shim/)" >&2; exit 1; }
    echo "==> Building cloud-agents-shim (shim/)"
    ( cd "$REPO_ROOT/shim" && lyric restore && lyric build )
    rm -rf "$DOCKER_DIR/shim-dist"
    mkdir -p "$DOCKER_DIR/shim-dist"
    cp -R "$REPO_ROOT/shim/bin/." "$DOCKER_DIR/shim-dist/"
    echo "    cloud-agents-shim staged at docker/shim-dist/  ✓"
}

build_claude() {
    stage_shim
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
