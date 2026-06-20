# Phase 5 — builds and runs the Cloud Agents API server.
#
# The server is a Lyric application; this image compiles it with the Lyric
# toolchain and runs the resulting .NET assembly. It needs the Docker CLI to
# manage runner containers via the mounted host socket.
#
# NOTE: the build expects the lyric-lang workspace beside the project (see
# docs/BUILD.md). Provide it via build context or a private registry in CI.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && curl -fsSL https://raw.githubusercontent.com/nichobbs/lyric-lang/main/scripts/install.sh \
        | sh -s -- --dir /usr/local/bin --no-path \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
RUN lyric build && lyric test

FROM mcr.microsoft.com/dotnet/aspnet:10.0
RUN apt-get update && apt-get install -y --no-install-recommends docker.io \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/bin/ /app/
EXPOSE 8080
ENTRYPOINT ["dotnet", "/app/CloudAgents.dll"]
