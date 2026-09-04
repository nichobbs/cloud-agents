#!/usr/bin/env bash
# Regression test for docker/entrypoint.sh's privilege drop (#652): the
# container always STARTS as root (docker/Dockerfile no longer sets `USER
# claude-user`), and entrypoint.sh must do only the root-only prelude (host
# CA trust, the /home/claude-user ownership heal, restoring vault
# credentials, the git --system config) before chowning /workspace once and
# re-execing itself as claude-user for everything else — the clone,
# reconcile-repos.sh/create-fallback-branch.sh, the mcp.json/settings.json
# rendering, inject-library.sh, the marker file, and the final harness
# invocation.
#
# This can only be verified against a REAL container: the whole point is
# which UID actually runs which step, which a mocked/sourced-function test
# (like scripts/test-entrypoint-session-resume.sh) can't observe. Builds a
# small purpose-built image (debian:bookworm-slim + git/jq/util-linux, NOT
# the full runner image) that COPYs the REAL docker/entrypoint.sh and its
# helper scripts/templates to the same paths docker/Dockerfile ships them
# at, creates claude-user the same way, and swaps in a fake `claude` binary
# that reports who/where it actually ran instead of doing anything real.
# Runs it twice against a temp /workspace + home volume and a local bare git
# repo (file:// URL — no network): once to clone, once to resume — then
# once more in CLOUD_AGENTS_INSPECT_MODE to confirm that path (which
# deliberately stays root) still behaves exactly as before.
#
# Needs Docker; skips (exit 0) rather than failing when it isn't available,
# so this is safe to invoke from an environment that doesn't guarantee it.
# Always cleans up: every container runs with --rm, and the trap below
# removes the temp build context, temp volumes, and the test image.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/docker/entrypoint.sh"
[ -f "$ENTRYPOINT" ] || { echo "test-entrypoint-privsep: $ENTRYPOINT not found" >&2; exit 1; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "test-entrypoint-privsep: Docker not available, skipping" >&2
    exit 0
fi

IMAGE="cloud-agents-entrypoint-privsep-test:$$"
BUILD_CTX="$(mktemp -d)"
WORK="$(mktemp -d)"

# in_image runs a one-off command inside the test image as root, over a
# bind-mount of the temp work dir. Every host-side step that needs to touch
# or inspect files owned by claude-user's uid goes through it (the chown of
# the bare repo, the ownership assertions, and the final cleanup), so the
# test behaves identically whether the HOST user is root (a local sandbox)
# or an unprivileged CI runner — a plain host `chown`/`find`/`rm` on files
# owned by another uid fails with "Operation not permitted" in the latter.
in_image() {
    docker run --rm --network none --entrypoint "$1" -v "$WORK:/work" "$IMAGE" "${@:2}"
}

cleanup() {
    # The containers leave /work owned by claude-user's uid; delete it from
    # inside the image (root there) before removing the image itself.
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        in_image rm -rf /work/workspace /work/home /work/repo.git /work/seed >/dev/null 2>&1 || true
        docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
    fi
    rm -rf "$BUILD_CTX" "$WORK"
}
trap cleanup EXIT

fails=0
check() {
    local desc="$1"; shift
    if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# ── Build context: the REAL scripts/templates, at the paths docker/Dockerfile
# ships them at, plus a fake `claude` and a purpose-built Dockerfile ──────────
cp "$REPO_ROOT/docker/entrypoint.sh" \
   "$REPO_ROOT/docker/reconcile-repos.sh" \
   "$REPO_ROOT/docker/create-fallback-branch.sh" \
   "$REPO_ROOT/docker/inject-library.sh" \
   "$REPO_ROOT/docker/render-branch-policy.sh" \
   "$REPO_ROOT/docker/register-callbacks-mcp.sh" \
   "$REPO_ROOT/docker/split-ca-bundle.sh" \
   "$REPO_ROOT/docker/mcp-callbacks.json.template" \
   "$REPO_ROOT/docker/settings.json.template" \
   "$REPO_ROOT/docker/settings-callbacks.json.template" \
   "$REPO_ROOT/docker/branch-policy-rules.md" \
   "$REPO_ROOT/docker/session-tools-guide.md" \
   "$BUILD_CTX/"

cat > "$BUILD_CTX/fake-claude" <<'FAKE'
#!/bin/bash
# Fake `claude` CLI for test-entrypoint-privsep.sh: prints one
# stream-json-looking NDJSON line reporting who/where it actually ran as,
# instead of doing anything real.
set -euo pipefail
args_json=$(printf '%s\n' "$@" | sed 's/"/\\"/g' | awk '{printf "%s\"%s\"", (NR>1?",":""), $0}')
printf '{"type":"result","uid":"%s","user":"%s","home":"%s","pwd":"%s","args":[%s]}\n' \
    "$(id -u)" "$(id -un)" "${HOME:-}" "$(pwd)" "${args_json}"
FAKE
chmod +x "$BUILD_CTX/fake-claude"

# Sandbox intercepting proxy CA, if this environment has one (see
# /root/.ccr/README.md) — harmless empty placeholder otherwise, so the
# Dockerfile's COPY always has something to copy.
if [ -f /root/.ccr/ca-bundle.crt ]; then
    cp /root/.ccr/ca-bundle.crt "$BUILD_CTX/ca-bundle.crt"
else
    : > "$BUILD_CTX/ca-bundle.crt"
fi

cat > "$BUILD_CTX/Dockerfile" <<'DOCKERFILE'
# Purpose-built test image for scripts/test-entrypoint-privsep.sh (#652).
# NOT a runner image: mirrors just enough of docker/Dockerfile (the
# claude-user setup, the paths the real scripts/templates ship at) to run
# the REAL docker/entrypoint.sh + its helper scripts end to end, with a
# fake `claude` standing in for the real CLI.
FROM debian:bookworm-slim

ARG HTTPS_PROXY
ARG https_proxy
ARG HTTP_PROXY
ARG http_proxy

# Trust the sandbox's intercepting proxy CA (a no-op empty file outside that
# sandbox) before any apt/network access in this build.
COPY ca-bundle.crt /usr/local/share/ca-certificates/ccr-agent-proxy.crt
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && update-ca-certificates \
    && apt-get install -y --no-install-recommends git jq util-linux bash coreutils passwd findutils \
    && rm -rf /var/lib/apt/lists/*

# Same non-root user setup as docker/Dockerfile.
RUN useradd --create-home --home-dir /home/claude-user --shell /bin/bash claude-user
WORKDIR /workspace
RUN chown claude-user:claude-user /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY reconcile-repos.sh /usr/local/bin/reconcile-repos.sh
COPY create-fallback-branch.sh /usr/local/bin/create-fallback-branch.sh
COPY inject-library.sh /usr/local/bin/inject-library.sh
COPY render-branch-policy.sh /usr/local/bin/render-branch-policy.sh
COPY register-callbacks-mcp.sh /usr/local/bin/register-callbacks-mcp.sh
COPY split-ca-bundle.sh /usr/local/bin/split-ca-bundle.sh
COPY mcp-callbacks.json.template /etc/claude/mcp-callbacks.json.template
COPY settings.json.template /etc/claude/settings.json.template
COPY settings-callbacks.json.template /etc/claude/settings-callbacks.json.template
COPY branch-policy-rules.md /etc/cloud-agents/branch-policy-rules.md
COPY session-tools-guide.md /etc/cloud-agents/session-tools-guide.md

# Fake `claude` CLI: reports who/where it ran instead of doing anything real.
COPY fake-claude /usr/local/bin/claude

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/reconcile-repos.sh \
    /usr/local/bin/create-fallback-branch.sh /usr/local/bin/inject-library.sh \
    /usr/local/bin/render-branch-policy.sh /usr/local/bin/register-callbacks-mcp.sh \
    /usr/local/bin/split-ca-bundle.sh /usr/local/bin/claude

# Deliberately NO `USER claude-user` — the exact condition #652 is about:
# the container starts as root, and entrypoint.sh itself must drop to
# claude-user before doing anything but the root-only prelude.
ENV HOME=/home/claude-user
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
DOCKERFILE

echo "test-entrypoint-privsep: building test image..." >&2
docker build --network host \
    --build-arg HTTPS_PROXY="${HTTPS_PROXY:-}" \
    --build-arg https_proxy="${https_proxy:-}" \
    --build-arg HTTP_PROXY="${HTTP_PROXY:-}" \
    --build-arg http_proxy="${http_proxy:-}" \
    -t "$IMAGE" -f "$BUILD_CTX/Dockerfile" "$BUILD_CTX" >/dev/null

# ── Fixtures: temp workspace/home volumes + a local bare repo (file://, no
# network) ────────────────────────────────────────────────────────────────
mkdir -p "$WORK/workspace" "$WORK/home"
SEED="$WORK/seed"
mkdir -p "$SEED"
git -C "$SEED" init -q -b main
git -C "$SEED" config user.email t@t
git -C "$SEED" config user.name t
echo hello > "$SEED/README.md"
git -C "$SEED" add -A
git -C "$SEED" commit -qm init >/dev/null
git clone -q --bare "$SEED" "$WORK/repo.git"

CLAUDE_USER_UID="$(docker run --rm --entrypoint id "$IMAGE" -u claude-user)"

# The bare "remote" is a local host directory standing in for a real git
# host — git's dubious-ownership check applies to any repo path it touches,
# including a file:// source, so it must be owned by whatever uid
# claude-user has inside the image (a real REPO_URL is a remote host and
# never hits this; it's purely an artifact of testing file:// locally).
# Done inside the image (root) rather than on the host, which may itself be
# an unprivileged CI runner that cannot chown to a foreign uid.
in_image chown -R "$CLAUDE_USER_UID" /work/repo.git

run_container() {
    local prompt="$1"
    docker run --rm --network none \
        -v "$WORK/workspace:/workspace" \
        -v "$WORK/home:/home/claude-user" \
        -v "$WORK/repo.git:/repo.git:ro" \
        -e PROMPT="$prompt" \
        -e REPO_URL="file:///repo.git" \
        -e BRANCH="main" \
        -e MODEL="test-model" \
        -e HARNESS="claude" \
        -e SESSION_ID="test-session-1" \
        -e NATIVE_SESSION_ID="native-session-1" \
        -e GITHUB_TOKEN="test-token-not-real" \
        "$IMAGE"
}

# $1 is a path RELATIVE to the temp work dir (e.g. "workspace"), checked from
# inside the image: the home volume ends up mode 700 and owned by
# claude-user's uid, which an unprivileged host user cannot even descend
# into, so a host-side `find` would pass vacuously there.
is_owned_by() {
    local rel="$1" uid="$2"
    [ -e "$WORK/$rel" ] || return 1
    [ -z "$(in_image find "/work/$rel" -not -user "$uid" 2>/dev/null)" ]
}

# ── Message 1: fresh workspace -> clone ──────────────────────────────────────
echo "test-entrypoint-privsep: run 1 (fresh clone)..." >&2
run1_status=0
RUN1_OUT="$(run_container "hello world")" || run1_status=$?
check "message 1: container exits 0" test "$run1_status" -eq 0
check "message 1: fake claude ran as claude-user's uid" contains "\"uid\":\"$CLAUDE_USER_UID\"" "$RUN1_OUT"
check "message 1: fake claude saw HOME=/home/claude-user" contains '"home":"/home/claude-user"' "$RUN1_OUT"
check "message 1: fake claude ran in /workspace" contains '"pwd":"/workspace"' "$RUN1_OUT"
check "message 1: first invocation used --session-id" contains '"--session-id","native-session-1"' "$RUN1_OUT"
check "message 1: /workspace is entirely owned by claude-user's uid" is_owned_by workspace "$CLAUDE_USER_UID"
check "message 1: home volume is entirely owned by claude-user's uid" is_owned_by home "$CLAUDE_USER_UID"
check "message 1: mcp.json was rendered" test -f "$WORK/workspace/.claude/mcp.json"
check "message 1: settings.json was rendered" test -f "$WORK/workspace/.claude/settings.json"
check "message 1: the native-session marker file exists" test -f "$WORK/workspace/.claude/.native-session-initialized"
check "message 1: the repo was actually cloned" test -f "$WORK/workspace/README.md"
# The git credential helper is written to claude-user's --global config now
# that this block runs unprivileged (#1038): it must land in the home volume,
# not in a root-only /etc/gitconfig the dropped process could not write.
check "message 1: git credential helper landed in claude-user's global gitconfig" \
    in_image grep -q credential /work/home/.gitconfig

# ── Message 2: same session -> resume, not another clone ────────────────────
echo "test-entrypoint-privsep: run 2 (resume)..." >&2
run2_status=0
RUN2_OUT="$(run_container "second message")" || run2_status=$?
check "message 2: container exits 0" test "$run2_status" -eq 0
check "message 2: fake claude ran as claude-user's uid" contains "\"uid\":\"$CLAUDE_USER_UID\"" "$RUN2_OUT"
check "message 2: second invocation used --resume, not --session-id" contains '"--resume","native-session-1"' "$RUN2_OUT"
check "message 2: /workspace is still entirely owned by claude-user's uid" is_owned_by workspace "$CLAUDE_USER_UID"

# ── Inspect mode: unrelated to the privilege drop above, must keep behaving
# exactly as before (root, no home volume, network none) ────────────────────
echo "test-entrypoint-privsep: inspect mode..." >&2
INSPECT_OUT="$(docker run --rm --network none \
    -v "$WORK/workspace:/workspace" \
    -e CLOUD_AGENTS_INSPECT_MODE=diff \
    "$IMAGE")"
check "inspect mode: still prints its OK marker" contains "CLOUD_AGENTS_INSPECT_OK" "$INSPECT_OUT"
check "inspect mode: still prints its section marker" contains "===CLOUD_AGENTS_SECTION===" "$INSPECT_OUT"

# ── grep-pins: the real entrypoint must still carry the privilege-drop shape ──
check "entrypoint.sh still gates the root prelude on CLOUD_AGENTS_ENTRYPOINT_STAGE" \
    grep -q 'CLOUD_AGENTS_ENTRYPOINT_STAGE' "$ENTRYPOINT"
check "entrypoint.sh still re-execs itself as claude-user" \
    grep -q -- 'exec runuser -u claude-user -m -- "\$0"' "$ENTRYPOINT"
check "entrypoint.sh no longer wraps the final claude invocation in runuser" \
    bash -c "! grep -q -- 'runuser -u claude-user -m -- claude ' '$ENTRYPOINT'"

if [ "$fails" -ne 0 ]; then
    echo "test-entrypoint-privsep: $fails check(s) failed" >&2
    exit 1
fi
echo "test-entrypoint-privsep: all checks passed"
