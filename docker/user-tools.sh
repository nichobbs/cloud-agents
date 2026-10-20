# docker/user-tools.sh — sourced (never executed) by every harness entrypoint
# once it runs as the harness user. Two things:
#
# 1. cloud_agents_user_tools_env: lets the agent install tools without root.
#    `npm i -g`, `pip install`, `uv tool install` and `go install` all land in
#    ~/.local (bin in ~/.local/bin), and ~/.cargo/bin is picked up for a
#    user-space rustup. $HOME is a volume shared by every session of this user
#    on this harness (CloudAgents.Db home volume naming), so an install made in
#    one session is there in the next. The directories are APPENDED to PATH:
#    the image's own binaries (git, the harness CLI, node, python) always win,
#    so neither a user install nor a CLI's self-updater can shadow them.
#
# 2. cloud_agents_run_setup_script: runs the profile's setup script
#    (CLOUD_AGENTS_SETUP_SCRIPT_B64, set by src/docker_manager.l from the
#    profile's setupScript) once per distinct script content. Its results
#    persist on the same home volume, so re-running it on every message would
#    only cost time; editing the script runs it again. A failed run leaves no
#    success marker and is retried once CLOUD_AGENTS_SETUP_RETRY_SECS (default
#    3600) have passed, so a broken script does not add its timeout to every
#    message. Runs hold a lock on the home volume, so two sessions starting
#    together do not install the same things at once. Never fails the
#    entrypoint: the prompt runs either way, and the agent can read the log.
#
# No `apt`: the harness user has no root. System packages need a custom image.
# See docs/tool-installs.md.

cloud_agents_user_tools_env() {
    local home="${HOME:-}"
    [ -n "$home" ] || return 0
    mkdir -p "$home/.local/bin" 2>/dev/null || true

    export NPM_CONFIG_PREFIX="$home/.local"
    # Debian marks the system Python as externally managed (PEP 668), which
    # makes a plain `pip install` refuse. Outside a virtualenv pip then falls
    # back to a --user install because site-packages is not writable; inside
    # one this setting has no effect. (PIP_USER is deliberately not set: it
    # breaks `pip install` inside a virtualenv.)
    export PIP_BREAK_SYSTEM_PACKAGES=1
    export UV_TOOL_BIN_DIR="$home/.local/bin"
    export GOBIN="$home/.local/bin"

    local dir
    for dir in "$home/.local/bin" "${CARGO_HOME:-$home/.cargo}/bin"; do
        case ":$PATH:" in
            *":$dir:"*) ;;
            *) PATH="$PATH:$dir" ;;
        esac
    done
    export PATH
}

# $1: log label (e.g. "entrypoint-codex"). $2: directory to run in (default
# /workspace).
cloud_agents_run_setup_script() {
    local label="${1:-entrypoint}" workdir="${2:-/workspace}"
    [ -n "${CLOUD_AGENTS_SETUP_SCRIPT_B64:-}" ] || return 0

    local dir="$HOME/.cache/cloud-agents/setup"
    mkdir -p "$dir" || { echo "$label: setup script skipped: cannot create $dir" >&2; return 0; }

    local tmp="$dir/incoming.$$"
    if ! printf '%s' "$CLOUD_AGENTS_SETUP_SCRIPT_B64" | base64 -d > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "$label: setup script skipped: CLOUD_AGENTS_SETUP_SCRIPT_B64 is not valid base64" >&2
        return 0
    fi
    local hash
    hash="$(sha256sum < "$tmp" | cut -c1-16)"
    mv -f "$tmp" "$dir/$hash.sh"

    if [ -f "$dir/$hash.done" ]; then
        echo "$label: setup script $hash already ran on this home volume" >&2
        return 0
    fi

    local timeout_secs="${CLOUD_AGENTS_SETUP_TIMEOUT:-600}"
    # Another session of this user on this harness may be running the same
    # script on the shared home volume. Wait for it (up to one run's timeout),
    # then re-check: its success makes this run unnecessary.
    exec 9> "$dir/lock"
    if ! flock -w "$timeout_secs" 9; then
        exec 9>&-
        echo "$label: setup script $hash skipped: another session still holds $dir/lock" >&2
        return 0
    fi
    if [ -f "$dir/$hash.done" ]; then
        exec 9>&-
        echo "$label: setup script $hash already ran on this home volume" >&2
        return 0
    fi

    local now last_fail
    now="$(date +%s)"
    last_fail="$(cat "$dir/$hash.failed" 2>/dev/null || echo 0)"
    if [ $((now - last_fail)) -lt "${CLOUD_AGENTS_SETUP_RETRY_SECS:-3600}" ]; then
        exec 9>&-
        echo "$label: setup script $hash failed recently; not retrying yet (see $dir/last-failure)" >&2
        return 0
    fi

    echo "$label: running setup script $hash (log: $dir/$hash.log)" >&2
    local rc=0
    ( cd "$workdir" 2>/dev/null || cd "$HOME"
      timeout --kill-after=10 "$timeout_secs" bash "$dir/$hash.sh"
    ) > "$dir/$hash.log" 2>&1 < /dev/null 9>&- || rc=$?

    if [ "$rc" -eq 0 ]; then
        date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/$hash.done"
        rm -f "$dir/last-failure" "$dir/$hash.failed"
        echo "$label: setup script $hash finished" >&2
    else
        echo "$now" > "$dir/$hash.failed"
        printf 'setup script %s exited %s; log: %s\n' "$hash" "$rc" "$dir/$hash.log" > "$dir/last-failure"
        echo "$label: WARNING: setup script $hash exited $rc; continuing. Last lines of $dir/$hash.log:" >&2
        tail -n 20 "$dir/$hash.log" >&2 || true
    fi
    exec 9>&-
    return 0
}
