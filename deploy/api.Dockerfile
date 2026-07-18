# Phase 5 — builds and runs the Cloud Agents API server.
#
# The server is a Lyric application; this image compiles it with the Lyric
# toolchain and runs the resulting .NET assembly. It needs the Docker CLI to
# manage runner containers via the mounted host socket.
#
# Lyric.Web, Lyric.Docker, Std.Logging, and Microsoft.Data.Sqlite are all
# declared as NuGet packages in lyric.toml and fetched by `lyric restore` —
# no sibling lyric-lang checkout or vendored package required.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build

# Pinned explicitly rather than `curl .../install.sh | sh`'s old approach of
# always fetching "latest": that RUN step has no cache-busting mechanism of
# its own, so once Docker caches this layer it stays cached indefinitely
# regardless of new commits or new upstream Lyric releases — this image
# could silently keep compiling with whatever version happened to be
# "latest" the very first time it was ever built on a given host, with no
# visible signal that anything's stale. An explicit version pin makes an
# upgrade a deliberate, visible Dockerfile change that naturally busts the
# cache on its own.
#
# Relationship to MIN_LYRIC_VERSION (repo root): that file is the floor
# ci.yml enforces against whatever "latest" resolves to at CI run time —
# it's a check on the compiler's own release stream, unrelated to what any
# particular built artifact happens to be pinned to. LYRIC_VERSION here is
# the actual version THIS image compiles with, and should never be pinned
# below MIN_LYRIC_VERSION (that would mean deliberately deploying with a
# compiler older than the documented known-good floor) — but it doesn't need
# to equal it either; being ahead of the floor is normal and fine. Bump this
# whenever you want the deployed image to use a newer compiler; there's no
# requirement to bump it in lockstep with MIN_LYRIC_VERSION.
# Downloads the exact tarball directly rather than trusting install.sh's own
# --version flag, mirroring .github/workflows/ci.yml's same reasoning
# (see its "Install Lyric compiler" step and docs/BUILD.md).
ARG LYRIC_VERSION=0.4.33
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 3 \
        -o /tmp/lyric.tgz \
        "https://github.com/nichobbs/lyric-lang/releases/download/v${LYRIC_VERSION}/lyric-${LYRIC_VERSION}-linux-x64.tar.gz" \
    && mkdir -p /usr/local/bin \
    && tar -xzf /tmp/lyric.tgz -C /usr/local/bin \
    && rm -f /tmp/lyric.tgz \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
# build-full.sh handles the NuGet restore and a compiler workaround (see its
# own comments and docs/BUILD.md); verify.sh is the working test harness —
# `lyric test` crashes on this project's manifest under the current compiler.
RUN ./scripts/build-full.sh && ./scripts/verify.sh

FROM mcr.microsoft.com/dotnet/aspnet:10.0
RUN apt-get update && apt-get install -y --no-install-recommends docker.io \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/bin/ /app/
EXPOSE 8080
ENTRYPOINT ["dotnet", "/app/CloudAgents.dll"]
