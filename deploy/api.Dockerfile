# Phase 5 — builds and runs the Cloud Agents API server.
#
# The server is a Lyric application; this image compiles it with the Lyric
# toolchain and runs the resulting .NET assembly. It needs the Docker CLI to
# manage runner containers via the mounted host socket.
#
# Lyric.Web, Lyric.Docker, Std.Logging, Lyric.Db and Npgsql are all
# declared as NuGet packages in lyric.toml and fetched by `lyric restore` —
# no sibling lyric-lang checkout or vendored package required.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build

# The compiler version defaults to "" and resolves to the latest lyric-lang
# release at build time, matching docker/Dockerfile and install.sh's own
# no-argument behavior: the toolchain is deliberately not pinned. Pass
# --build-arg LYRIC_VERSION=X.Y.Z only to reproduce an old build. The RUN step
# below has no cache-busting input of its own, so a host that has cached the
# layer keeps its resolved version until the layer is invalidated (a change to
# MIN_LYRIC_VERSION, which is COPY'd in just before it, does that; so does
# `docker build --no-cache`). The resolved version is checked against
# MIN_LYRIC_VERSION (repo root), the documented known-good floor, and the
# tarball is verified against the release's SHASUMS256.txt.
ARG LYRIC_VERSION=""
# RID matches THIS build's actual architecture (this FROM has no --platform
# override, so it's whatever amd64/arm64 host actually runs the build) — the
# x86_64->linux-x64 / aarch64->linux-arm64 mapping now lives in one place,
# scripts/lyric-rid.sh (#675), COPY'd in below rather than duplicated as its
# own inline case statement. Previously hardcoded to linux-x64
# unconditionally: harmless on an amd64 host, but on an arm64 host the base
# image already resolves natively to arm64 while this step kept installing
# an amd64-only `lyric` binary — `lyric restore`/`lyric build` below (via
# build-full.sh) would then fail to even exec it (exec format error,
# surfacing as exit code 126), a real Coolify deploy failure once the
# arm64-host / amd64-forcing mismatch found in docker/Dockerfile
# (nichobbs/cloud-agents#670) was fixed there but not here too.
# Verified against the release's own SHASUMS256.txt manifest before
# extraction (#157) via the shared scripts/verify-lyric-checksum.sh — same
# script docker/Dockerfile's two stages and its four sibling runner
# Dockerfiles use.
COPY scripts/lyric-rid.sh scripts/verify-lyric-checksum.sh /usr/local/bin/
COPY MIN_LYRIC_VERSION /tmp/min-lyric-version.txt
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && chmod +x /usr/local/bin/lyric-rid.sh /usr/local/bin/verify-lyric-checksum.sh \
    && if [ -z "$LYRIC_VERSION" ]; then \
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
    && LYRIC_RID="$(/usr/local/bin/lyric-rid.sh)" \
    && LYRIC_ARCHIVE="lyric-${LYRIC_VERSION}-${LYRIC_RID}.tar.gz" \
    && curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 \
        -o /tmp/lyric.tgz \
        "https://github.com/nichobbs/lyric-lang/releases/download/v${LYRIC_VERSION}/${LYRIC_ARCHIVE}" \
    && /usr/local/bin/verify-lyric-checksum.sh "$LYRIC_VERSION" /tmp/lyric.tgz "$LYRIC_ARCHIVE" \
    && mkdir -p /usr/local/bin \
    && tar -xzf /tmp/lyric.tgz -C /usr/local/bin \
    && rm -f /tmp/lyric.tgz \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
# build-full.sh handles the NuGet restore and a compiler workaround (see its
# own comments and docs/BUILD.md); verify.sh is the hand-rolled, `lyric
# test`-free harness this image builds against. `lyric test` itself needs a
# migrated Postgres (LYRIC_CONFIG_DB_CONNECTION_URL) for its live suites,
# which an image build doesn't have, so verify.sh is what's wired in here.
RUN ./scripts/build-full.sh && ./scripts/verify.sh && ./scripts/write-build-info.sh

FROM mcr.microsoft.com/dotnet/aspnet:10.0
RUN apt-get update && apt-get install -y --no-install-recommends docker.io \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# bin/ also carries build-info.txt: the compiler and NuGet versions this image
# actually resolved (they float), printed by the API at startup.
COPY --from=build /src/bin/ /app/
# CloudAgents.LibrarySeed/CloudAgents.McpServerSeed read these at sign-in time
# (CLOUD_AGENTS_SEED_SUBAGENTS_DIR / CLOUD_AGENTS_SEED_SKILLS_DIR /
# CLOUD_AGENTS_SEED_MCP_SERVERS_DIR, defaulting to "seed/subagents" / "seed/skills" /
# "seed/mcp-servers" resolved relative to this WORKDIR) to seed a brand-new user's
# subagent/skill/MCP-server library — see src/handlers/library_seed.l and
# src/handlers/mcp_server_seed.l.
COPY --from=build /src/seed/ /app/seed/
EXPOSE 8080
ENTRYPOINT ["dotnet", "/app/CloudAgents.dll"]
