# claude-code:base — Phase 1 runner image.
#
# Provides everything a Claude Code session needs inside an ephemeral
# container: the Claude Code CLI (via Node), the .NET 10 SDK, and the Lyric
# compiler so the agent can build/format/test Lyric code in the sandbox.
#
# Build:  docker build -t claude-code:base -f docker/Dockerfile .
# Context: the REPO ROOT, not docker/ — this Dockerfile COPYs from both
#   docker/ and shim/, so the build context must be wide enough to see both.
#   (Every COPY below is written repo-root-relative accordingly.)
# Arch:   linux/amd64 (required — see docs/phase1-core-loop.md §Constraints)

# ─── Stage 1: build cloud-agents-shim (docs/phase6-mcp-callbacks.md §5) ──────
#
# The in-container MCP callback server, built from shim/ via the Lyric
# compiler. This used to be built OUTSIDE Docker by scripts/build-docker.sh's
# stage_shim step and copied in as docker/shim-dist/ — but that only worked
# when something ran that script before invoking `docker build`, which no
# generic orchestrator does. Coolify's `docker compose build` (and a bare
# `docker build`) just runs this Dockerfile directly, so shim-dist/ never
# existed and `COPY shim-dist/ ...` failed with "not found" (confirmed
# 2026-07-20). Building the shim in its own stage here makes the image
# buildable standalone by any orchestrator, with no external pre-build step.
FROM --platform=linux/amd64 mcr.microsoft.com/dotnet/sdk:10.0 AS shim-builder

# Pinned explicitly rather than `curl .../install.sh | sh`'s old approach of
# always fetching "latest": that RUN step has no cache-busting mechanism of
# its own, so once Docker caches this layer it stays cached indefinitely
# regardless of new commits or new upstream Lyric releases — this image
# could silently keep compiling with whatever version happened to be
# "latest" the very first time it was ever built on a given host, with no
# visible signal that anything's stale (exactly the class of regression
# AGENTS.md's seven tracked upstream compiler bugs warn about). Mirrors
# deploy/api.Dockerfile's ARG LYRIC_VERSION pattern and downloads the exact
# release tarball directly rather than trusting install.sh's own --version
# handling — see that file's comments for the full reasoning. Never pin
# below MIN_LYRIC_VERSION (repo root), the documented known-good floor.
ARG LYRIC_VERSION=0.4.33
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 \
        -o /tmp/lyric.tgz \
        "https://github.com/nichobbs/lyric-lang/releases/download/v${LYRIC_VERSION}/lyric-${LYRIC_VERSION}-linux-x64.tar.gz" \
    && mkdir -p /usr/local/bin \
    && tar -xzf /tmp/lyric.tgz -C /usr/local/bin \
    && rm -f /tmp/lyric.tgz \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/shim
COPY shim/ ./
RUN lyric restore && lyric build

# ─── Stage 2: the runner image itself ────────────────────────────────────────
FROM --platform=linux/amd64 mcr.microsoft.com/dotnet/sdk:10.0

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling + Node 20 (for the Claude Code CLI and the GitHub MCP server).
RUN apt-get update && apt-get install -y --no-install-recommends \
        git bash make python3 python3-pip curl ca-certificates jq \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && rm -rf /var/lib/apt/lists/*

# Install the Lyric compiler to a system location. Pinned to the same
# explicit ARG LYRIC_VERSION as the shim-builder stage above (predates that
# stage's addition, but is the same unpinned-"latest" anti-pattern — see
# that stage's comment and deploy/api.Dockerfile for the full reasoning).
ARG LYRIC_VERSION=0.4.33
RUN curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 \
        -o /tmp/lyric.tgz \
        "https://github.com/nichobbs/lyric-lang/releases/download/v${LYRIC_VERSION}/lyric-${LYRIC_VERSION}-linux-x64.tar.gz" \
    && tar -xzf /tmp/lyric.tgz -C /usr/local/bin \
    && rm -f /tmp/lyric.tgz \
    && lyric --version

# Non-root user. The home directory is mounted from the per-user credential
# volume at runtime (holds the authenticated ~/.claude folder).
RUN useradd --create-home --home-dir /home/claude-user --shell /bin/bash claude-user
WORKDIR /workspace
RUN chown claude-user:claude-user /workspace

# cloud-agents-shim, built in the shim-builder stage above. Shipped
# unconditionally; docker/entrypoint.sh's CLOUD_AGENTS_MCP_CALLBACKS gate
# (default off) controls whether it's ever actually registered/invoked.
COPY --from=shim-builder /src/shim/bin/. /opt/cloud-agents-shim/
COPY docker/cloud-agents-shim /usr/local/bin/cloud-agents-shim

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/reconcile-repos.sh /usr/local/bin/reconcile-repos.sh
COPY docker/inject-library.sh /usr/local/bin/inject-library.sh
COPY docker/mcp.json.template /etc/claude/mcp.json.template
COPY docker/mcp-callbacks.json.template /etc/claude/mcp-callbacks.json.template
COPY docker/settings.json.template /etc/claude/settings.json.template
COPY docker/settings-callbacks.json.template /etc/claude/settings-callbacks.json.template
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/reconcile-repos.sh /usr/local/bin/inject-library.sh /usr/local/bin/cloud-agents-shim

USER claude-user
ENV HOME=/home/claude-user

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
