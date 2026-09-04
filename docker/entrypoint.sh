#!/bin/bash
# Runner entrypoint for a single Claude Code invocation.
#
# Inputs (environment variables set by the API server):
#   PROMPT            - the user's message text (required)
#   REPO_URL          - git remote to clone on first run (required)
#   BRANCH            - branch to check out (default: main)
#   MODEL             - Claude model to use (default: claude-opus-4-8)
#   HARNESS           - harness identifier, e.g. "claude" (required; used by
#                       create-fallback-branch.sh and inject-library.sh)
#   SESSION_ID        - cloud-agents session ID, distinct from NATIVE_SESSION_ID
#                       (required; used for fallback branch naming)
#   NATIVE_SESSION_ID - session ID to resume; if non-empty passed to --resume
#   GITHUB_TOKEN      - PAT used for git push/clone auth, and (if the user has
#                       enabled the seeded "github" MCP server via the
#                       Library) for that server's credential
#   CLOUD_AGENTS_MCP_CALLBACKS  - "0" to disable the Phase 6 MCP-callback shim
#                                 (docs/phase6-mcp-callbacks.md); on by
#                                 default as of stage 4 (§8). Mirrors
#                                 CloudAgents.NetworkPolicy.callbacksFeatureEnabled's
#                                 on-unless-"0" default — keep the two in
#                                 sync. Registering the shim's MCP-server
#                                 entry below is additionally guarded on the
#                                 template file actually existing in this
#                                 image, so an image built before stage 3
#                                 shipped the shim still runs fine with the
#                                 flag on.
#   CLOUD_AGENTS_API_URL        - host API base URL, as reachable from this
#                                 container (only used when the flag above is
#                                 set; minted by CloudAgents.Docker)
#   CLOUD_AGENTS_CALLBACK_TOKEN - per-session callback bearer token (ditto)
#
# State persists across runs via two mounted volumes:
#   /workspace            - the cloned repository + our own mcp.json/settings.json
#                            and a NATIVE_SESSION_MARKER file (see below); this
#                            volume is per-session
#   /home/claude-user     - the user's authenticated ~/.claude credentials AND
#                            Claude Code's own conversation history
#                            (~/.claude/projects/...); this volume is shared
#                            across all of a user's sessions (per user+harness,
#                            not per session — docker_manager.l)
#
# Each container handles exactly one prompt and then exits; --resume reads the
# conversation history from ~/.claude on the home volume so context survives.

set -euo pipefail

# Workspace-inspect mode (workspace inspector, src/handlers/workspace.l):
# when CLOUD_AGENTS_INSPECT_MODE is set this container is a short-lived,
# read-only look at /workspace — the API server started it with NO
# credentials, NO home volume, and NetworkMode "none"
# (docker_manager.l's runInspectContainer), so nothing below this block
# (credential helpers, clone, harness launch) may run. Prints the
# CLOUD_AGENTS_INSPECT_OK / ===CLOUD_AGENTS_SECTION=== /
# CLOUD_AGENTS_INSPECT_ERR marker protocol that the pure
# CloudAgents.Workspace package parses out of the container logs — keep the
# two in byte-for-byte sync — and ALWAYS exits 0 so waitForContainer treats
# the run as complete. Every command is guarded so `set -e`/pipefail can
# never kill the script before a marker is printed (e.g. `head -5000`
# SIGPIPE-ing `git ls-files` under pipefail).
if [ -n "${CLOUD_AGENTS_INSPECT_MODE:-}" ]; then
    if [ ! -d /workspace/.git ]; then
        # The workspace volume auto-creates on bind, so it always mounts —
        # but no run has ever cloned a repo into it yet.
        echo "CLOUD_AGENTS_INSPECT_ERR no workspace"
        exit 0
    fi
    cd /workspace || { echo "CLOUD_AGENTS_INSPECT_ERR no workspace"; exit 0; }
    # The checkout is typically owned by the harness user while inspect runs
    # as root; without this, modern git refuses with "dubious ownership".
    # The normal-run path sidesteps that by chown-ing — inspect stays
    # read-only instead.
    git config --global --add safe.directory /workspace >/dev/null 2>&1 || true
    case "${CLOUD_AGENTS_INSPECT_MODE}" in
        diff)
            echo "CLOUD_AGENTS_INSPECT_OK"
            git status --porcelain || true
            echo "===CLOUD_AGENTS_SECTION==="
            { git diff HEAD --numstat 2>/dev/null || git diff --numstat; } || true
            echo "===CLOUD_AGENTS_SECTION==="
            { git diff HEAD 2>/dev/null || git diff; } || true
            echo "===CLOUD_AGENTS_SECTION==="
            # Section 3 (M1.2, docs/capture-runtime-handoff.md §4): the workspace
            # tree hash, so the runner's emitRunnerCheckpoint can thread it as the
            # terminal checkpoint's base anchor. PREFER the committed tree
            # (HEAD^{tree}) — that is the correct *base* anchor, the agent's
            # uncommitted edits live in the section-2 `git diff HEAD` (the
            # file_change hunks); do NOT replace this with a working-tree write-tree
            # when a HEAD exists. FALL BACK to a working-tree tree ONLY when there is
            # no HEAD yet (a fresh repo before its first commit): compute it in a
            # THROWAWAY index (GIT_INDEX_FILE to an unused temp path, so the real
            # index and checkout are never touched) so a terminal checkpoint still
            # lands instead of steps-only (dogfood F3). Prints nothing only if even
            # the fallback fails, and the runner then falls back to steps-only
            # (treeHash None).
            #
            # NOTE `--verify`: a bare `git rev-parse HEAD^{tree}` on a no-HEAD repo
            # prints the LITERAL string "HEAD^{tree}" to stdout (and exits non-zero),
            # so without `--verify` section 3 would be that bogus literal, not empty
            # — the runner would then thread `treeHash = "HEAD^{tree}"`. `--verify`
            # prints nothing on failure, so the `||` fallback fires cleanly.
            #
            # The fallback computes a working-tree tree WITHOUT touching the real
            # repo — a throwaway index AND a throwaway object dir, so the new blobs
            # and tree write into a temp dir, never the workspace's persistent
            # `.git/objects`. That keeps inspect mode READ-ONLY (#1028: this path is
            # also reachable from `GET /api/sessions/{id}/workspace/diff`), and the
            # tree hash is still correct (content addressing is independent of where
            # the object is stored). `mktemp -d` (not `-u`) avoids the TOCTOU race
            # (#1029). The temp dir is always removed.
            {
                git rev-parse --verify HEAD^{tree} 2>/dev/null || {
                    # Guard mktemp -d: if it fails (returns empty), skip entirely
                    # rather than collapsing the paths to a root-relative
                    # /objects,/index (#1031). Empty section 3 ⇒ steps-only, the safe
                    # fallback.
                    _ca_tree_tmp="$(mktemp -d 2>/dev/null)"
                    if [ -n "${_ca_tree_tmp}" ] && [ -d "${_ca_tree_tmp}" ]; then
                        mkdir -p "${_ca_tree_tmp}/objects"
                        GIT_INDEX_FILE="${_ca_tree_tmp}/index" GIT_OBJECT_DIRECTORY="${_ca_tree_tmp}/objects" \
                            git add -A 2>/dev/null \
                            && GIT_INDEX_FILE="${_ca_tree_tmp}/index" GIT_OBJECT_DIRECTORY="${_ca_tree_tmp}/objects" \
                                git write-tree 2>/dev/null
                        rm -rf "${_ca_tree_tmp}"
                    fi
                }
            } || true
            ;;
        tree)
            echo "CLOUD_AGENTS_INSPECT_OK"
            { git ls-files --cached --others --exclude-standard | head -5000; } || true
            ;;
        file)
            if [ -f "${CLOUD_AGENTS_INSPECT_PATH:-}" ]; then
                echo "CLOUD_AGENTS_INSPECT_OK"
                wc -c < "${CLOUD_AGENTS_INSPECT_PATH}" || true
                echo "===CLOUD_AGENTS_SECTION==="
                { head -c 1048576 "${CLOUD_AGENTS_INSPECT_PATH}" | base64; } || true
            else
                echo "CLOUD_AGENTS_INSPECT_ERR not found"
            fi
            ;;
        *)
            echo "CLOUD_AGENTS_INSPECT_ERR bad mode"
            ;;
    esac
    exit 0
fi

BRANCH="${BRANCH:-main}"
MODEL="${MODEL:-claude-opus-4-8}"
NATIVE_SESSION_ID="${NATIVE_SESSION_ID:-}"
# Default-on unless explicitly "0" — mirrors
# CloudAgents.NetworkPolicy.callbacksFeatureEnabled()'s Lyric-side default
# (docs/phase6 §8). Deliberately NOT "${CLOUD_AGENTS_MCP_CALLBACKS:-1}": that
# form only substitutes when the var is unset/empty, which happens to give
# the same on-unless-"0" result for every value the var actually takes, but
# spells out the "off-unless-1" default this stage replaced — normalizing
# through the explicit comparison below keeps the intent obvious and matches
# the Lyric side's `!= "0"` check byte-for-byte.
if [ "${CLOUD_AGENTS_MCP_CALLBACKS:-}" = "0" ]; then
    CLOUD_AGENTS_MCP_CALLBACKS="0"
else
    CLOUD_AGENTS_MCP_CALLBACKS="1"
fi

: "${HOME:=/home/claude-user}"

if [ -z "${PROMPT:-}" ]; then
    echo "entrypoint: PROMPT is required" >&2
    exit 64
fi

# ─── Root-only prelude (#652) ────────────────────────────────────────────────
# docker/Dockerfile no longer sets `USER claude-user`, so this container
# always STARTS as root — but only the handful of steps in this block
# genuinely need that privilege: trusting a host CA into the SYSTEM store,
# healing the shared home volume's ownership, restoring vault credentials
# into it, and writing the git --system config a non-root user can't write.
# Everything that used to run as root after this point purely because
# nothing ever dropped privilege — the clone, reconcile-repos.sh/
# create-fallback-branch.sh, mcp.json/settings.json rendering,
# inject-library.sh, the marker file, and the final harness invocation — now
# runs as claude-user instead, via the chown-then-re-exec at the end of this
# block. CLOUD_AGENTS_ENTRYPOINT_STAGE=user marks that second pass (the
# re-exec below sets it) so it skips straight past this whole block instead
# of repeating it.
if [ "${CLOUD_AGENTS_ENTRYPOINT_STAGE:-}" != "user" ]; then

    # If a host-provided CA certificate bundle is mounted at /etc/host-ca.pem,
    # register it in the container's system CA trust store so that curl, git, and Node
    # trust the host's SSL-intercepting proxy natively and globally. The mounted
    # file is the operator's own NODE_EXTRA_CA_CERTS value, which is commonly
    # itself a multi-certificate bundle (a root + intermediate chain, or several
    # CAs concatenated) — split it into one file per certificate first so
    # update-ca-certificates' rehash step doesn't warn "does not contain exactly
    # one certificate or CRL" and skip hashing every certificate but the first
    # (see docker/split-ca-bundle.sh's header comment).
    if [ -f "/etc/host-ca.pem" ]; then
        echo "entrypoint: registering host CA certificate bundle in system store..." >&2
        /usr/local/bin/split-ca-bundle.sh /etc/host-ca.pem /usr/local/share/ca-certificates host-ca
        update-ca-certificates >/dev/null
    fi

    # Ensure /home/claude-user and everything inside it is owned by claude-user.
    # This heals any permissions/UID mismatches if the volume was populated on the host
    # with host-specific UIDs (e.g. 504 on Colima macOS). Guarded on the top-level
    # directory's current owner (#653): /home/claude-user is a volume shared
    # across every session for a user+harness, so after the first message ever
    # fixes it up, every later message's container would otherwise pay for a
    # full recursive walk of the user's entire Claude history/config for no
    # ownership change at all. A top-level-only check is sufficient here — unlike
    # /workspace below, nothing between messages writes new root-owned files
    # into this volume (only claude-user itself, via the claude-user process
    # this script hands off to below, ever writes here after this point).
    if [ "$(stat -c '%U' /home/claude-user 2>/dev/null || echo '?')" != "claude-user" ]; then
        chown -R claude-user:claude-user /home/claude-user || true
        chmod 700 /home/claude-user || true
    fi

    # Must be written to the SYSTEM config (/etc/gitconfig, root-owned) so it
    # applies to every user that later touches /workspace — including
    # claude-user, once this script hands off to it below — regardless of
    # whatever UID currently owns the volume (e.g. host-populated content
    # with a foreign UID, or a pre-existing checkout from before this fix).
    git config --system --add safe.directory /workspace >/dev/null 2>&1 || git config --global --add safe.directory /workspace >/dev/null 2>&1 || true

    # Restore a Claude subscription (OAuth) login from the vault on a fresh home
    # volume. A subscription login is a ~/.claude directory, not an API key, so it
    # ships as a base64 tar.gz in the CLAUDE_HOME_TARBALL_B64 credential (see
    # scripts/upload-credentials.sh --claude-home). Unpack it only when the
    # persisted home volume has no credentials yet, so an existing — possibly
    # token-refreshed — login is never overwritten. The blob is never echoed.
    if [ -n "${CLAUDE_HOME_TARBALL_B64:-}" ] && [ ! -f "$HOME/.claude/.credentials.json" ]; then
        echo "entrypoint: restoring ~/.claude auth from the vault bundle" >&2
        mkdir -p "$HOME/.claude"
        printf '%s' "${CLAUDE_HOME_TARBALL_B64}" | base64 -d | tar -xzf - -C "$HOME/.claude"
        chown -R claude-user:claude-user "$HOME/.claude" || true
    fi

    # If CLAUDE_CODE_OAUTH_TOKEN is injected from the credential vault, populate
    # ~/.claude/.credentials.json so the Claude Code CLI discovers it.
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        has_oauth=0
        if [ -f "$HOME/.claude/.credentials.json" ] && command -v jq >/dev/null 2>&1; then
            if jq -e '.claudeAiOauth.accessToken' "$HOME/.claude/.credentials.json" >/dev/null 2>&1; then
                has_oauth=1
            fi
        fi
        if [ "$has_oauth" != "1" ]; then
            echo "entrypoint: configuring ~/.claude/.credentials.json from CLAUDE_CODE_OAUTH_TOKEN" >&2
            mkdir -p "$HOME/.claude"
            if printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN}" | grep -q '^{'; then
                printf '%s\n' "${CLAUDE_CODE_OAUTH_TOKEN}" > "$HOME/.claude/.credentials.json"
            else
                cat > "$HOME/.claude/.credentials.json" <<EOF
{
  "claudeAiOauth": {
    "accessToken": "${CLAUDE_CODE_OAUTH_TOKEN}"
  }
}
EOF
            fi
            chown -R claude-user:claude-user "$HOME/.claude" || true
            chmod 600 "$HOME/.claude/.credentials.json" || true
        fi
    fi

    # Hand off to claude-user for everything else (#652). chown /workspace
    # ONCE, guarded the same way as /home/claude-user above — after this
    # first heal nothing writes into /workspace as root ever again, since
    # every step from here down (clone, reconcile-repos.sh,
    # create-fallback-branch.sh, the mcp.json/settings.json rendering,
    # inject-library.sh, the marker file, the final `claude` exec) runs as
    # claude-user, so there is no more root-owned churn to chown away
    # afterward the way the old unconditional end-of-script chown had to.
    # This also self-heals a workspace left root-owned by a container built
    # before this fix (or by this container's own inspect-mode path, which
    # intentionally stays root — see the top of this file).
    if [ "$(stat -c '%U' /workspace 2>/dev/null || echo '?')" != "claude-user" ]; then
        chown -R claude-user:claude-user /workspace || true
    fi

    # Re-exec this SAME script under claude-user. `-m` (preserve environment)
    # carries every input var (PROMPT, REPO_URL, GITHUB_TOKEN, the
    # CLOUD_AGENTS_* vars, HOME, ...) through unchanged — exactly as it
    # already did for the final `claude` invocation before this change, which
    # is why nothing below needs its own `runuser` wrapper any more.
    export CLOUD_AGENTS_ENTRYPOINT_STAGE=user
    exec runuser -u claude-user -m -- "$0" "$@"
fi

# ─── Everything below here runs as claude-user (#652) ───────────────────────

# If ~/.claude.json is missing, but backups exist, automatically restore the latest backup!
if [ ! -f "$HOME/.claude.json" ]; then
    LATEST_BACKUP=$(ls -t "$HOME"/.claude/backups/.claude.json.backup.* 2>/dev/null | head -n 1 || true)
    if [ -n "$LATEST_BACKUP" ]; then
        echo "entrypoint: restoring ~/.claude.json from latest backup: $LATEST_BACKUP" >&2
        cp "$LATEST_BACKUP" "$HOME/.claude.json"
        chmod 600 "$HOME/.claude.json"
    fi
fi

# Pre-accept the workspace trust dialog. Claude Code normally asks
# interactively whether to trust a project directory before honoring
# settings.json's permissions.allow entries; this runner is always
# non-interactive (-p), so that prompt can never be answered, and every
# invocation would otherwise print "Ignoring N permissions.allow entries...
# this workspace has not been trusted" and fall back to unconfigured
# defaults. /workspace is always this container's (and every container's)
# project directory, so trusting it here is equivalent to a human accepting
# the dialog once. Merged with jq rather than overwritten so any other keys
# already in ~/.claude.json (e.g. a restored subscription login above) survive.
#
# This trust flag is broader than just our own /workspace/.claude/settings.json
# (which we fully control and overwrite every run, below): it also governs
# whether Claude Code auto-loads other trust-gated project config it finds in
# the cloned repo itself, e.g. a repo-root .mcp.json — REPO_URL is
# user-supplied and this entrypoint does not render/overwrite that path the
# way it does /workspace/.claude/mcp.json. That's an intentional tradeoff
# here, not an oversight: this container IS the sandbox, the same trust model
# entrypoint-gemini.sh already states explicitly for --yolo.
#
# ~/.claude.json lives on the home volume, which is shared across all of a
# user's sessions (docker_manager.l's homeVolumeBindFor is keyed on
# user+harness, not sessionId) — and unlike this file's other ~/.claude.json
# writes above, which are gated on the file being absent (a true first-run
# case), this block would otherwise run a read-modify-write on EVERY message
# of EVERY session for that user. Two of that user's sessions genuinely can
# run concurrently (their own containers, their own per-session locks; see
# docs/phase2-session-management.md), so an unconditional write here would
# race an unrelated concurrent write to the same file (e.g. an OAuth token
# refresh) and could clobber it with our stale read. Skip the write entirely
# once the flag is already set — after the first message, every later run is
# a pure read, so the race window shrinks to first-use only. The temp file
# name is PID-suffixed so two sessions racing that first write don't also
# collide with each other's temp file.
if command -v jq >/dev/null 2>&1; then
    already_trusted=0
    if [ -f "$HOME/.claude.json" ] && jq -e '.projects["/workspace"].hasTrustDialogAccepted == true' "$HOME/.claude.json" >/dev/null 2>&1; then
        already_trusted=1
    fi
    if [ "$already_trusted" != "1" ]; then
        base_json='{}'
        if [ -f "$HOME/.claude.json" ]; then
            base_json=$(cat "$HOME/.claude.json")
        fi
        if printf '%s' "${base_json}" | jq '.projects["/workspace"].hasTrustDialogAccepted = true' > "$HOME/.claude.json.tmp.$$" 2>/dev/null; then
            mv "$HOME/.claude.json.tmp.$$" "$HOME/.claude.json"
            chmod 600 "$HOME/.claude.json"
        else
            rm -f "$HOME/.claude.json.tmp.$$"
            echo "entrypoint: could not pre-accept the workspace trust dialog, continuing without it" >&2
        fi
    fi
fi

# Configure git credential helper and push defaults dynamically inside the
# container. This runs as claude-user (see the hand-off above, #652), so the
# per-user --global config is the right (and only writable) scope; the old
# root-only `git config --system` branch is gone with the privilege drop.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "entrypoint: configuring git credential helper for GitHub" >&2
    git config --global credential.helper '!f() { cat >/dev/null; if [ "$1" = "get" ]; then echo "username=x-access-token"; echo "password=${GITHUB_TOKEN}"; fi; }; f'
    git config --global push.autoSetupRemote true
fi

# Clone the repository on first run; reuse the volume afterwards.
if [ ! -d /workspace/.git ]; then
    if [ -z "${REPO_URL:-}" ]; then
        echo "entrypoint: REPO_URL is required for the first run" >&2
        exit 64
    fi
    echo "entrypoint: cloning ${REPO_URL} (${BRANCH})" >&2
    git clone "${REPO_URL}" --branch "${BRANCH}" /workspace
fi

# Reconcile linked repositories (multi-repo sessions): clone the repos
# currently linked to the session, prune any that were unlinked. Shared
# across all five harness entrypoints (#468).
/usr/local/bin/reconcile-repos.sh "entrypoint"
cd /workspace

# Safety net: ensure we're not on the starting branch. Shared across all five
# harness entrypoints (#725) — see create-fallback-branch.sh.
create-fallback-branch.sh "entrypoint" "${HARNESS}" "${BRANCH}" "${SESSION_ID:-}"

mkdir -p /workspace/.claude

# Phase 6 (docs/phase6-mcp-callbacks.md §8): whether request_permission is
# actually live for THIS run — the flag is on AND a callback token was minted
# (mint is best-effort; docker_manager.l). Computed FIRST because it now drives
# three things that must always agree: the cloud-agents entry in mcp.json, the
# settings.json allowlist, and --permission-prompt-tool. A fresh container
# spins up per message while /workspace/.claude/{mcp.json,settings.json} persist
# across the session, so all three are reconciled every message against this
# value — a transient mint failure on one message followed by success on the
# next must not leave the persisted config disagreeing with the prompt tool
# (#548).
CALLBACKS_ACTIVE=0
if [ "${CLOUD_AGENTS_MCP_CALLBACKS}" = "1" ] && [ -n "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" ]; then
    CALLBACKS_ACTIVE=1
fi

# Phase 4: seed /workspace/.claude/mcp.json with an empty baseline on the
# workspace's first-ever message, so the Phase 6 reconciliation below and
# inject-library.sh (called near the end of this script) always have a file
# to work with. Previously this rendered a template that unconditionally
# wired up a live "github" MCP server whenever GITHUB_TOKEN was present —
# bypassing the enabled/disabled gate the Library's seeded MCP server catalog
# now provides (CloudAgents.McpServerSeed) and duplicating the entry once a
# user enabled the seeded one too. That mechanism is retired in favor of the
# Library's own "github" entry (seed/mcp-servers/github.json, disabled by
# default, gated by CloudAgents.Repository.mcpServersForProfile) — the
# supported way to grant this now, whether seeded or hand-authored.
if [ ! -f /workspace/.claude/mcp.json ]; then
    mkdir -p /workspace/.claude
    printf '%s' '{"mcpServers": {}}' > /workspace/.claude/mcp.json
fi

# mcp.json can carry the per-session callback token (the cloud-agents entry
# reconciled below) — keep the file we created out of an agent's `git add .`
# via .git/info/exclude (#788). Untracked paths only, so a repo that
# deliberately commits a .claude/mcp.json of its own is unaffected;
# idempotent across messages. Reuses register-callbacks-mcp.sh's
# exclude_from_git rather than duplicating it (#792) — this harness never
# calls that script's register_callbacks_mcp itself (claude's registration
# is the reconcile block below, coupled to --permission-prompt-tool).
if [ -f /usr/local/bin/register-callbacks-mcp.sh ]; then
    # shellcheck source=register-callbacks-mcp.sh
    source /usr/local/bin/register-callbacks-mcp.sh
    # Best-effort (#798): this runs under set -e, and a failure here (e.g. an
    # unwritable .git/info) must never abort the whole run over an exclusion
    # entry — same tolerance the other entrypoints give their registration.
    exclude_from_git /workspace ".claude/mcp.json" \
        || echo "entrypoint: could not git-exclude .claude/mcp.json, continuing" >&2
fi

# Phase 6 (docs/phase6-mcp-callbacks.md §8): reconcile the cloud-agents MCP
# server entry in mcp.json EVERY message to match CALLBACKS_ACTIVE — add/refresh
# it when callbacks are live, strip any stale entry when not (#548). This must
# run outside the persist-once base render above: mcp.json survives across the
# per-message containers, so a message whose mint succeeded after a prior
# message's failure would otherwise never register the server, yet
# --permission-prompt-tool (also keyed off CALLBACKS_ACTIVE) would point at it.
# The `del` branch also cleanly removes the entry if a later message loses its
# token. Both jq ops are idempotent (verified: re-adding over an already-merged
# file and deleting an absent key are both no-ops). Requires jq; without it we
# leave mcp.json as-is and CALLBACKS_ACTIVE is forced off below so nothing
# points at an unreconciled entry.
if command -v jq >/dev/null 2>&1 && [ -f /workspace/.claude/mcp.json ]; then
    if [ "${CALLBACKS_ACTIVE}" = "1" ] && [ -f /etc/claude/mcp-callbacks.json.template ]; then
        api_url_clean=$(printf '%s' "${CLOUD_AGENTS_API_URL:-}" | tr -d '\000-\037')
        api_url_json=$(printf '%s' "${api_url_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        api_url_escaped=$(printf '%s' "${api_url_json}" | sed -e 's/[&|\\]/\\&/g')
        token_clean=$(printf '%s' "${CLOUD_AGENTS_CALLBACK_TOKEN:-}" | tr -d '\000-\037')
        token_json=$(printf '%s' "${token_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        token_escaped=$(printf '%s' "${token_json}" | sed -e 's/[&|\\]/\\&/g')
        session_id_clean=$(printf '%s' "${NATIVE_SESSION_ID}" | tr -d '\000-\037')
        session_id_json=$(printf '%s' "${session_id_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        session_id_escaped=$(printf '%s' "${session_id_json}" | sed -e 's/[&|\\]/\\&/g')
        # Optional timeout override (docs/phase6 §2, #533): MCP servers only
        # receive env vars listed in mcp.json, so the container-level value
        # must be re-listed here. Unset renders as "" and the shim falls
        # back to its default.
        timeout_ms_clean=$(printf '%s' "${CLOUD_AGENTS_CALLBACK_TIMEOUT_MS:-}" | tr -d '\000-\037')
        timeout_ms_json=$(printf '%s' "${timeout_ms_clean}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        timeout_ms_escaped=$(printf '%s' "${timeout_ms_json}" | sed -e 's/[&|\\]/\\&/g')
        callbacks_fragment=$(sed \
            -e "s|\${CLOUD_AGENTS_API_URL}|${api_url_escaped}|g" \
            -e "s|\${CLOUD_AGENTS_CALLBACK_TOKEN}|${token_escaped}|g" \
            -e "s|\${CLOUD_AGENTS_SESSION_ID}|${session_id_escaped}|g" \
            -e "s|\${CLOUD_AGENTS_CALLBACK_TIMEOUT_MS}|${timeout_ms_escaped}|g" \
            /etc/claude/mcp-callbacks.json.template)
        merged=$(jq -s '.[0].mcpServers["cloud-agents"] = .[1].mcpServers["cloud-agents"] | .[0]' \
            /workspace/.claude/mcp.json <(printf '%s' "${callbacks_fragment}"))
        printf '%s' "${merged}" > /workspace/.claude/mcp.json
    else
        stripped=$(jq 'del(.mcpServers["cloud-agents"])' /workspace/.claude/mcp.json)
        printf '%s' "${stripped}" > /workspace/.claude/mcp.json
    fi
elif [ "${CALLBACKS_ACTIVE}" = "1" ]; then
    # jq absent (or mcp.json missing) — we cannot register/verify the callback
    # server, so force callbacks off for this run rather than wire the prompt
    # tool at an entry we could not reconcile (#548).
    CALLBACKS_ACTIVE=0
fi

# Final authority (#548): CALLBACKS_ACTIVE is derived from the ACTUAL persisted
# mcp.json, not just the preconditions above. Even after the reconcile, a
# silently-empty jq merge or an unexpected file state could leave the
# cloud-agents server absent while CALLBACKS_ACTIVE=1 — which would wire
# --permission-prompt-tool at a server that isn't there. So if callbacks are
# meant to be live but the persisted mcp.json doesn't actually contain the
# cloud-agents server entry, downgrade to inactive. From here down,
# CALLBACKS_ACTIVE == "the callback server is genuinely registered", and it is
# the single source of truth for both the settings allowlist and the prompt
# tool, so the two can never disagree.
if [ "${CALLBACKS_ACTIVE}" = "1" ]; then
    if [ ! -f /workspace/.claude/mcp.json ] || ! grep -q '"cloud-agents"' /workspace/.claude/mcp.json; then
        CALLBACKS_ACTIVE=0
    fi
fi

if [ "${CALLBACKS_ACTIVE}" = "1" ] && [ -f /etc/claude/settings-callbacks.json.template ]; then
    cp /etc/claude/settings-callbacks.json.template /workspace/.claude/settings.json
elif [ -f /etc/claude/settings.json.template ]; then
    cp /etc/claude/settings.json.template /workspace/.claude/settings.json
fi

# Render the session's profile-granted skills/subagents/MCP servers into
# Claude's own native config (docker/inject-library.sh). Reconciled every
# message like the mcp.json entries above; best-effort so a rendering hiccup
# never blocks the actual prompt run.
/usr/local/bin/inject-library.sh "claude" || echo "entrypoint: library injection failed, continuing without it" >&2

# No recursive /workspace chown here any more (#652): everything above
# (clone/reconcile-repos.sh/inject-library.sh/the mcp.json and settings.json
# rendering) now runs as claude-user, the same user that owns /workspace
# after the root prelude's one-time chown above — so there's nothing
# root-owned left behind to chown away.

# Phase 6 (docs/phase6-mcp-callbacks.md §3, §8): route Claude Code's own
# permission prompts through the cloud-agents MCP server instead of the
# static settings.json allowlist, so a tool call outside that allowlist pauses
# for a human decision instead of failing closed. On by default as of stage 4.
# Gated on the SAME condition as the mcp.json registration above (flag on AND
# a token for THIS run) rather than just the flag: pointing
# --permission-prompt-tool at an MCP server entry that was never actually
# registered (no token minted this run — mint is best-effort, see
# docker_manager.l) would make Claude Code route every permission decision
# through a tool that can't answer, instead of the pre-Phase-6 behavior this
# run must fall back to. An empty array is a no-op either way.
PERMISSION_PROMPT_ARGS=()
if [ "${CALLBACKS_ACTIVE}" = "1" ]; then
    PERMISSION_PROMPT_ARGS=(--permission-prompt-tool "mcp__cloud-agents__request_permission")
fi

# Emit the harness transcript as stream-json NDJSON rather than plain --print
# text (Testamur §4.1 / ADR-0004; CloudAgents.Capture). The API server's poll
# loop (src/docker_manager.l streamSessionMessage) parses each NDJSON line into
# a hash-chained CaptureEvent, persists it (appendSessionEvents), and
# reconstructs the SAME visible assistant transcript for the PWA via
# CloudAgents.Capture.Render — so this flip does not regress the UI while
# giving the provenance capture core real per-event data to work from.
# --verbose is REQUIRED alongside `--output-format stream-json` in
# --print/-p mode (the CLI errors out without it); it does not add extra
# stdout noise in this mode, it enables the per-event stream. Applied to every
# invocation path below via "${STREAM_JSON_ARGS[@]}".
STREAM_JSON_ARGS=(--output-format stream-json --verbose)

# Run the actual prompt. stdout is captured by the API server and streamed to
# the browser as SSE.
#
# Whether this is the very first invocation for this native session is NOT
# determined by /workspace/.claude/history.jsonl: Claude Code never actually
# writes a file by that name. Its own conversation storage
# (~/.claude/projects/<slug>/<session-id>.jsonl) lives on the *home* volume,
# which docker_manager.l mounts per user+harness, not per session
# (docs/phase2-session-management.md "Credential Management") — so it
# persists across every session for that user, while a stale/absent check
# here made every message look like the first one. That replayed
# --session-id "${NATIVE_SESSION_ID}" on message 2+, and the CLI rejected it
# with "Session ID ... is already in use" because message 1 had already
# registered it. (Separately, the old first-invocation check also used to
# gate a broken unconditional `claude -p ... --resume` seed step with no
# session ID, which always failed with "--resume requires a valid session
# ID..." in --print mode — that's #386, fixed here by removing the seed
# step entirely, since the real invocation below already handles the
# first-run case correctly.)
#
# Track "have we already initialized this native session" ourselves instead,
# with a marker file on the workspace volume, which genuinely is
# session-scoped. Written just before exec (not after, since exec replaces
# this process and nothing after it would ever run): once --session-id has
# been sent at all, the CLI may have registered it even if the run then
# fails for an unrelated reason, so every later invocation must use --resume
# regardless of how this one turns out.
NATIVE_SESSION_MARKER=/workspace/.claude/.native-session-initialized
if [ ! -f "$NATIVE_SESSION_MARKER" ]; then
    touch "$NATIVE_SESSION_MARKER"
    if [ -n "$NATIVE_SESSION_ID" ]; then
        # Self-heal (#710): a session that already reached message 2+ BEFORE
        # this marker-file scheme shipped has its NATIVE_SESSION_ID already
        # registered with the Claude CLI under ~/.claude/projects on the home
        # volume (shared across a user's sessions, not per-session — see the
        # comment above) even though ITS OWN /workspace has no marker, since
        # the marker is new. Without this check, this run would look like a
        # genuine first invocation and replay --session-id for an ID the CLI
        # already has, reproducing the exact "already in use" failure this
        # file was fixed for — permanently, since every later run keeps
        # hitting the same already-registered ID. Detected by checking
        # whether the CLI already has a transcript for this ID anywhere on
        # the home volume, rather than attempting --session-id and parsing
        # stderr for the specific failure, which would also mean buffering
        # the whole run instead of exec-ing straight into it and streaming
        # output live to the API server as it happens.
        if [ -n "$(find "$HOME/.claude/projects" -name "${NATIVE_SESSION_ID}.jsonl" 2>/dev/null | head -n 1)" ]; then
            exec claude -p "${PROMPT}" --model "${MODEL}" --resume "${NATIVE_SESSION_ID}" "${STREAM_JSON_ARGS[@]}" "${PERMISSION_PROMPT_ARGS[@]}"
        fi
        exec claude -p "${PROMPT}" --model "${MODEL}" --session-id "${NATIVE_SESSION_ID}" "${STREAM_JSON_ARGS[@]}" "${PERMISSION_PROMPT_ARGS[@]}"
    else
        exec claude -p "${PROMPT}" --model "${MODEL}" "${STREAM_JSON_ARGS[@]}" "${PERMISSION_PROMPT_ARGS[@]}"
    fi
else
    if [ -n "$NATIVE_SESSION_ID" ]; then
        exec claude -p "${PROMPT}" --model "${MODEL}" --resume "${NATIVE_SESSION_ID}" "${STREAM_JSON_ARGS[@]}" "${PERMISSION_PROMPT_ARGS[@]}"
    else
        # Depends on NATIVE_SESSION_ID always being non-empty by the time the
        # marker exists (src/handlers/sessions.l pre-assigns nativeSessionId =
        # sessionId at session creation; the DB column is NOT NULL) — a bare
        # --resume with no ID is invalid in --print mode and would reproduce
        # the exact #386 failure this file was just fixed for. Unreachable
        # today; kept only because nothing else in this branch needs it, not
        # because it's expected to fire.
        exec claude -p "${PROMPT}" --model "${MODEL}" --resume "${STREAM_JSON_ARGS[@]}" "${PERMISSION_PROMPT_ARGS[@]}"
    fi
fi
