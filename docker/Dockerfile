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

# Resolves to the latest lyric-lang release by default (empty ARG) via the
# same GitHub API + sed extraction install.sh itself uses internally when no
# --version is given (no jq required) — auditable in the build log (the
# resolved version is echoed below) without piping install.sh's script
# straight into a shell. Pass --build-arg LYRIC_VERSION=X.Y.Z to pin to a
# specific release instead (e.g. to work around a fresh regression, or for a
# fully reproducible build) — never pin below MIN_LYRIC_VERSION (repo root),
# the documented known-good floor. Still downloads the exact release tarball
# directly either way, not trusting install.sh's own --version handling —
# see deploy/api.Dockerfile's comments for the full reasoning on that part.
ARG LYRIC_VERSION=""
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && if [ -z "$LYRIC_VERSION" ]; then \
         LYRIC_VERSION="$(curl -fsSL --connect-timeout 10 --max-time 30 https://api.github.com/repos/nichobbs/lyric-lang/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')"; \
       fi \
    && if [ -z "$LYRIC_VERSION" ]; then echo "ERROR: could not resolve the latest Lyric version from the GitHub API" >&2; exit 1; fi \
    && echo "Installing Lyric compiler v${LYRIC_VERSION}" \
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
FROM mcr.microsoft.com/dotnet/sdk:10.0

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling + Node and npm from standard APT repositories (plain HTTP, avoiding SSL intercept issues).
RUN apt-get update && apt-get install -y --no-install-recommends \
        git bash make python3 python3-pip curl ca-certificates jq nodejs npm \
    && npm install -g @anthropic-ai/claude-code \
    && rm -rf /var/lib/apt/lists/*

# Install the Lyric compiler to a system location. Same auto-latest-with-
# override behavior as the shim-builder stage above — see its comment for
# the full reasoning. Resolved independently here (this stage starts from a
# fresh FROM, no ARG/state carries over from stage 1), so pass the SAME
# --build-arg LYRIC_VERSION=X.Y.Z to both stages if pinning for a
# reproducible build across both.
ARG LYRIC_VERSION=""
RUN if [ -z "$LYRIC_VERSION" ]; then \
      LYRIC_VERSION="$(curl -fsSL --connect-timeout 10 --max-time 30 https://api.github.com/repos/nichobbs/lyric-lang/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')"; \
    fi \
    && if [ -z "$LYRIC_VERSION" ]; then echo "ERROR: could not resolve the latest Lyric version from the GitHub API" >&2; exit 1; fi \
    && echo "Installing Lyric compiler v${LYRIC_VERSION}" \
    && curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 \
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

ENV HOME=/home/claude-user

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
