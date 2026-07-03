# Phase 5 — builds and runs the Cloud Agents API server.
#
# The server is a Lyric application; this image compiles it with the Lyric
# toolchain and runs the resulting .NET assembly. It needs the Docker CLI to
# manage runner containers via the mounted host socket.
#
# Lyric.Web, Std.Logging, and Microsoft.Data.Sqlite are declared as NuGet
# packages in lyric.toml and fetched by `lyric restore`. Lyric.Docker is
# compiled from vendor/lyric-docker as an ordinary local package (the
# published NuGet Lyric.Docker package doesn't expose the container-lifecycle
# API this project depends on) — no sibling lyric-lang checkout required
# either way.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSL https://raw.githubusercontent.com/nichobbs/lyric-lang/main/scripts/install.sh \
        | sh -s -- --dir /usr/local/bin --no-path \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
# `lyric test` crashes on this project's manifest under the current compiler
# (see scripts/verify.sh) — run the working runtime-verification harness
# instead of the broken command.
RUN lyric restore && lyric build && ./scripts/verify.sh

FROM mcr.microsoft.com/dotnet/aspnet:10.0
RUN apt-get update && apt-get install -y --no-install-recommends docker.io \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/bin/ /app/
EXPOSE 8080
ENTRYPOINT ["dotnet", "/app/CloudAgents.dll"]
