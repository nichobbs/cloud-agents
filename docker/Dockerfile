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

# Resolves to the latest lyric-lang release by default (empty ARG). Pass
# --build-arg LYRIC_VERSION=X.Y.Z to pin to a specific release instead
# (e.g. to work around a fresh regression, or for a fully reproducible
# build) — never below MIN_LYRIC_VERSION (repo root), enforced below.
# Resolved ONCE here and shared into stage 2 via /tmp/lyric-version.txt
# (#657) rather than each stage independently re-resolving 'latest' and
# risking a mismatch if a new release lands between the two, or their
# caches diverge — so --build-arg LYRIC_VERSION=X.Y.Z only needs passing to
# THIS stage now, not duplicated to both.
#
# Resolution uses `curl -sI .../releases/latest` (a plain web redirect) and
# extracts the version from the redirect's `Location: .../tag/vX.Y.Z`
# header, exactly mirroring ci.yml's already-proven "Resolve latest Lyric
# release" step — NOT api.github.com's REST API, which a real CI run of an
# earlier revision of this file hit and got a bare `curl: (22) ... 403`
# from: unauthenticated api.github.com calls share a 60-req/hour rate limit
# across GitHub Actions' entire runner IP pool, easily exhausted by
# unrelated traffic, and curl's own `--retry` does NOT retry 4xx responses
# by default (only certain transient/5xx conditions) — so the retry this
# step already had didn't help at all against that 403. The plain web
# redirect this now uses instead isn't subject to that API rate limit.
# Retries via an explicit bash loop (curl's --retry still wouldn't help on
# a genuine, if rare, redirect-page hiccup) rather than trusting --retry's
# narrower default retry conditions.
#
# On build caching (#655): a RUN instruction's cache key depends only on
# its own instruction TEXT, never on what it actually printed or fetched at
# runtime — so once this layer is cached, the resolved "latest" stays
# frozen at that value until something upstream (the base image digest,
# an earlier instruction) invalidates the cache, exactly like any other
# RUN. Docker's ADD-from-URL instruction is documented to auto-invalidate
# on a remote Last-Modified/ETag change and was tried here specifically to
# counter that — but it has no retry/fallback of its own, and a live test
# against api.github.com (before the switch to the web-redirect approach
# above) reproduced a bare, non-retried 403 that failed the ENTIRE build
# outright, before the retried curl fallback below ever got a chance to
# run. That trades "may go stale under caching" for "a new unretried
# hard-failure point" — a worse tradeoff, especially given the Coolify
# failure that motivated this whole change may itself have been exactly
# this kind of transient reachability blip. Rejected; not used. Freshness
# here instead comes from: any cache-cold build (a new host, a pruned
# cache, an upstream base-image digest bump) naturally re-resolving to
# whatever's actually latest at that time, the resolved version always
# being visible in the build log, and the override always being available
# — a real improvement over the prior hardcoded pin (which needed a manual
# commit to ever change at all) without adding a new failure mode. Forcing
# a fresh resolution on an otherwise-warm cache is an operational concern
# (docker build --no-cache, or Coolify's "Force rebuild (without cache)" —
# see deploy/COOLIFY.md "Picking up a newer Lyric release" for the concrete
# steps and a known Coolify-side caveat, #661), not something baked into
# the Dockerfile.
ARG LYRIC_VERSION=""
COPY MIN_LYRIC_VERSION /tmp/min-lyric-version.txt

# Split into three separate RUN steps (was one combined chain) so a build
# failure's Dockerfile line number actually narrows down which of
# apt-get/curl-resolve/curl-download failed, instead of pointing at a single
# ~20-line RUN covering all three — a real Coolify failure on this exact
# block (nichobbs/cloud-agents#654 postmortem) only ever surfaced BuildKit's
# generic "process ... did not complete successfully: exit code: 255"
# wrapper with no inner stderr visible in Coolify's UI, and the combined
# chain gave no way to tell which command inside it actually failed.
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN if [ -z "$LYRIC_VERSION" ]; then \
         for attempt in 1 2 3; do \
           LYRIC_VERSION="$(curl -sI --connect-timeout 10 --max-time 30 https://github.com/nichobbs/lyric-lang/releases/latest | sed -n 's/.*tag\/v\([0-9.]*\).*/\1/p' | tr -d '\r')"; \
           [ -n "$LYRIC_VERSION" ] && break; \
           echo "attempt $attempt: could not resolve latest Lyric release tag, retrying..." >&2; \
           sleep 3; \
         done; \
       fi \
    && if [ -z "$LYRIC_VERSION" ]; then echo "ERROR: could not resolve the latest Lyric version after 3 attempts" >&2; exit 1; fi \
    && MIN_VERSION="$(cat /tmp/min-lyric-version.txt)" \
    && LOWEST="$(printf '%s\n%s\n' "$MIN_VERSION" "$LYRIC_VERSION" | sort -V | head -1)" \
    && if [ "$LOWEST" != "$MIN_VERSION" ]; then echo "ERROR: Lyric version $LYRIC_VERSION is below the documented floor MIN_LYRIC_VERSION ($MIN_VERSION)" >&2; exit 1; fi \
    && echo "Installing Lyric compiler v${LYRIC_VERSION}" \
    && echo -n "${LYRIC_VERSION}" > /tmp/lyric-version.txt

RUN LYRIC_VERSION="$(cat /tmp/lyric-version.txt)" \
    && curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 \
        -o /tmp/lyric.tgz \
        "https://github.com/nichobbs/lyric-lang/releases/download/v${LYRIC_VERSION}/lyric-${LYRIC_VERSION}-linux-x64.tar.gz" \
    && mkdir -p /usr/local/bin \
    && tar -xzf /tmp/lyric.tgz -C /usr/local/bin \
    && rm -f /tmp/lyric.tgz
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

# Install the Lyric compiler to a system location — the EXACT SAME version
# the shim-builder stage above already resolved and floor-checked (#657),
# via the shared /tmp/lyric-version.txt it wrote. No independent ARG/
# resolution/floor-check here: a single source of truth for "which version"
# instead of two stages each hitting the GitHub API and risking a mismatch.
COPY --from=shim-builder /tmp/lyric-version.txt /tmp/lyric-version.txt
RUN LYRIC_VERSION="$(cat /tmp/lyric-version.txt)" \
    && echo "Installing Lyric compiler v${LYRIC_VERSION}" \
    && curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 \
        -o /tmp/lyric.tgz \
        "https://github.com/nichobbs/lyric-lang/releases/download/v${LYRIC_VERSION}/lyric-${LYRIC_VERSION}-linux-x64.tar.gz" \
    && rm -f /tmp/lyric-version.txt \
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
