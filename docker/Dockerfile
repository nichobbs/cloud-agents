# claude-code:base — Phase 1 runner image.
#
# Provides everything a Claude Code session needs inside an ephemeral
# container: the Claude Code CLI (via Node), the .NET 10 SDK, and the Lyric
# compiler so the agent can build/format/test Lyric code in the sandbox.
#
# Build:  docker build -t claude-code:base -f docker/Dockerfile docker
# Arch:   linux/amd64 (required — see docs/phase1-core-loop.md §Constraints)

FROM --platform=linux/amd64 mcr.microsoft.com/dotnet/sdk:10.0

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling + Node 20 (for the Claude Code CLI and the GitHub MCP server).
RUN apt-get update && apt-get install -y --no-install-recommends \
        git bash make python3 python3-pip curl ca-certificates jq \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && rm -rf /var/lib/apt/lists/*

# Install the Lyric compiler to a system location.
RUN curl -fsSL https://raw.githubusercontent.com/nichobbs/lyric-lang/main/scripts/install.sh \
        | sh -s -- --dir /usr/local/bin --no-path \
    && lyric --version

# Non-root user. The home directory is mounted from the per-user credential
# volume at runtime (holds the authenticated ~/.claude folder).
RUN useradd --create-home --home-dir /home/claude-user --shell /bin/bash claude-user
WORKDIR /workspace
RUN chown claude-user:claude-user /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY mcp.json.template /etc/claude/mcp.json.template
COPY settings.json.template /etc/claude/settings.json.template
RUN chmod +x /usr/local/bin/entrypoint.sh

USER claude-user
ENV HOME=/home/claude-user

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
