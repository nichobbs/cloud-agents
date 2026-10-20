#!/usr/bin/env bash
# Tests docker/user-tools.sh: the user-space install environment and the
# profile setup script runner (run once per script content, retried after a
# failure, never failing the caller). Sources the real file under a temp HOME;
# no Docker, no network.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/docker/user-tools.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

# Each case runs in a fresh bash under `set -euo pipefail`, like the
# entrypoints, with its own HOME and workspace. --norc and stdin from
# /dev/null matter: a non-interactive bash whose stdin is a socket reads the
# system bashrc (Debian's SSH_SOURCE_BASHRC), which on some hosts prepends to
# PATH and made the PATH checks flaky.
run_case() {
  local home="$1"; shift
  mkdir -p "$home" "$WORK/ws"
  env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$home" "$@" \
    bash --norc --noprofile -c 'set -euo pipefail; source "$0"; cloud_agents_user_tools_env; cloud_agents_run_setup_script test "$WS"; echo "PATH=$PATH"; echo "NPM_CONFIG_PREFIX=${NPM_CONFIG_PREFIX:-}"; echo "PIP_BREAK_SYSTEM_PACKAGES=${PIP_BREAK_SYSTEM_PACKAGES:-}"; echo "PIP_USER=${PIP_USER:-}"; echo "GOBIN=${GOBIN:-}"; echo "UV_TOOL_BIN_DIR=${UV_TOOL_BIN_DIR:-}"' \
    "$HELPER" 2>&1 < /dev/null
}
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# 1. Environment, no setup script.
H="$WORK/home1"
out="$(run_case "$H" WS="$WORK/ws")"
check "env: ~/.local/bin created"               [ -d "$H/.local/bin" ]
check "env: ~/.local/bin appended to PATH"      grep -qx "PATH=/usr/local/bin:/usr/bin:/bin:$H/.local/bin:$H/.cargo/bin" <<< "$out"
# If this ever fails, show what case 1 printed (an empty capture points at the
# command substitution itself failing, e.g. fork errors on a loaded machine).
if ! grep -qx "PATH=/usr/local/bin:/usr/bin:/bin:$H/.local/bin:$H/.cargo/bin" <<< "$out"; then
  printf 'case 1 output was:\n%s\n' "$out" >&2
fi
check "env: npm global prefix is ~/.local"      grep -qx "NPM_CONFIG_PREFIX=$H/.local" <<< "$out"
check "env: pip may fall back to --user"        grep -qx "PIP_BREAK_SYSTEM_PACKAGES=1" <<< "$out"
check "env: PIP_USER left unset (venv-safe)"    grep -qx "PIP_USER=" <<< "$out"
check "env: go install targets ~/.local/bin"    grep -qx "GOBIN=$H/.local/bin" <<< "$out"
check "env: uv tools target ~/.local/bin"       grep -qx "UV_TOOL_BIN_DIR=$H/.local/bin" <<< "$out"
check "env: no setup cache without a script"    [ ! -d "$H/.cache/cloud-agents/setup" ]

# 2. An image binary is not shadowed by a user install of the same name.
mkdir -p "$H/.local/bin"
printf '#!/bin/sh\necho shadow\n' > "$H/.local/bin/ls"; chmod +x "$H/.local/bin/ls"
shadow="$(env -i PATH=/usr/bin:/bin HOME="$H" bash --norc --noprofile -c 'source "$0"; cloud_agents_user_tools_env; command -v ls' "$HELPER" < /dev/null)"
check "env: image binary wins over ~/.local/bin" [ "$shadow" != "$H/.local/bin/ls" ]
printf '#!/bin/sh\necho user-tool\n' > "$H/.local/bin/my-tool"; chmod +x "$H/.local/bin/my-tool"
user_tool="$(env -i PATH=/usr/bin:/bin HOME="$H" bash --norc --noprofile -c 'source "$0"; cloud_agents_user_tools_env; my-tool' "$HELPER" < /dev/null)"
check "env: user-installed tool is on PATH"     [ "$user_tool" = user-tool ]

# 3. Setup script runs once, in the workspace, with the user env in place.
H="$WORK/home2"
script='echo ran >> "$HOME/runs"; pwd > "$HOME/cwd"; echo "$NPM_CONFIG_PREFIX" > "$HOME/prefix"'
out="$(run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$script")")"
check "setup: ran"                              [ "$(cat "$H/runs")" = ran ]
check "setup: ran in the workspace"             [ "$(cat "$H/cwd")" = "$WORK/ws" ]
check "setup: saw the user-tools env"           [ "$(cat "$H/prefix")" = "$H/.local" ]
check "setup: marker written"                   bash --norc --noprofile -c "ls '$H/.cache/cloud-agents/setup/'*.done >/dev/null"
run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$script")" > "$WORK/out2"
check "setup: same script not rerun"            [ "$(wc -l < "$H/runs")" -eq 1 ]
check "setup: says it already ran"              grep -q "already ran" "$WORK/out2"
run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$script # edited")" > /dev/null
check "setup: edited script runs again"         [ "$(wc -l < "$H/runs")" -eq 2 ]

# 4. A failing script warns, leaves no marker and is retried; caller succeeds.
H="$WORK/home3"
script='echo attempt >> "$HOME/attempts"; echo "boom detail"; exit 7'
rc=0; out="$(run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$script")")" || rc=$?
check "fail: caller still exits 0"              [ "$rc" -eq 0 ]
check "fail: warning names the exit code"       grep -q "exited 7" <<< "$out"
check "fail: log tail is shown"                 grep -q "boom detail" <<< "$out"
check "fail: last-failure written"              [ -f "$H/.cache/cloud-agents/setup/last-failure" ]
check "fail: no marker"                         bash --norc --noprofile -c "! ls '$H/.cache/cloud-agents/setup/'*.done >/dev/null 2>&1"
run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$script")" > "$WORK/out-backoff"
check "fail: not retried within the backoff"    [ "$(wc -l < "$H/attempts")" -eq 1 ]
check "fail: says it is backing off"            grep -q "failed recently" "$WORK/out-backoff"
run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_RETRY_SECS=0 CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$script")" > /dev/null
check "fail: retried once the backoff passed"   [ "$(wc -l < "$H/attempts")" -eq 2 ]
fixed='echo attempt >> "$HOME/attempts"'
run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$fixed")" > /dev/null
check "fail: success clears last-failure"       [ ! -f "$H/.cache/cloud-agents/setup/last-failure" ]

# 4b. A corrupt failure marker is ignored rather than breaking the caller.
H="$WORK/home-corrupt"
script='echo ran >> "$HOME/runs"; exit 1'
mkdir -p "$H/.cache/cloud-agents/setup"
hash="$(printf '%s' "$script" | sha256sum | cut -c1-16)"
printf 'garbage\n' > "$H/.cache/cloud-agents/setup/$hash.failed"
rc=0; run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$script")" > "$WORK/out-corrupt" || rc=$?
check "corrupt marker: caller exits 0"         [ "$rc" -eq 0 ]
check "corrupt marker: script still ran"       [ "$(cat "$H/runs")" = ran ]
check "corrupt marker: caller printed its env" grep -q "^NPM_CONFIG_PREFIX=" "$WORK/out-corrupt"

# 4c. Failures inside the runner itself (here an unwritable lock path, as on a
# full or read-only home volume) never abort the caller.
H="$WORK/home-broken"
mkdir -p "$H/.cache/cloud-agents/setup/lock"
rc=0; run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 'true')" > "$WORK/out-broken" || rc=$?
check "broken home: caller exits 0"            [ "$rc" -eq 0 ]
check "broken home: caller printed its env"    grep -q "^NPM_CONFIG_PREFIX=" "$WORK/out-broken"
check "broken home: says why it skipped"      grep -q "cannot open .*/lock" "$WORK/out-broken"

# 5. A script that runs too long is stopped and treated as a failure.
H="$WORK/home4"
rc=0; out="$(run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_TIMEOUT=1 CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 'sleep 30')")" || rc=$?
check "timeout: caller exits 0"                 [ "$rc" -eq 0 ]
check "timeout: reported as exit 124"           grep -q "exited 124" <<< "$out"

# 5b. Two sessions starting together run the script once, not concurrently.
H="$WORK/home-lock"
script='echo start >> "$HOME/trace"; sleep 2; echo end >> "$HOME/trace"'
run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$script")" > "$WORK/lock-a" &
pid_a=$!
sleep 0.5
run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$script")" > "$WORK/lock-b"
wait "$pid_a"
check "lock: script ran exactly once"           [ "$(tr '\n' ' ' < "$H/trace")" = "start end " ]
check "lock: second session saw it had run"     grep -q "already ran" "$WORK/lock-b"
H="$WORK/home-lock2"
script='sleep 4; echo done >> "$HOME/trace"'
run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$script")" > /dev/null &
pid_a=$!
sleep 0.5
run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_LOCK_WAIT=1 CLOUD_AGENTS_SETUP_SCRIPT_B64="$(b64 "$script")" > "$WORK/lock-c"
check "lock: gives up waiting after LOCK_WAIT"  grep -q "still running it" "$WORK/lock-c"
wait "$pid_a"

# 6. Invalid base64 is skipped without failing.
H="$WORK/home5"
rc=0; out="$(run_case "$H" WS="$WORK/ws" CLOUD_AGENTS_SETUP_SCRIPT_B64='%%%not base64%%%')" || rc=$?
check "bad b64: caller exits 0"                 [ "$rc" -eq 0 ]
check "bad b64: skipped with a message"         grep -q "not valid base64" <<< "$out"

# 7. Every entrypoint sources the helper and runs both steps.
for f in entrypoint.sh entrypoint-codex.sh entrypoint-gemini.sh entrypoint-opencode.sh entrypoint-antigravity.sh; do
  check "wired: $f sources user-tools.sh"       grep -qx 'source /usr/local/bin/user-tools.sh' "$REPO_ROOT/docker/$f"
  check "wired: $f sets the env"                grep -qx 'cloud_agents_user_tools_env' "$REPO_ROOT/docker/$f"
  check "wired: $f runs the setup script"       grep -q '^cloud_agents_run_setup_script "' "$REPO_ROOT/docker/$f"
done
for f in Dockerfile Dockerfile.codex Dockerfile.gemini Dockerfile.opencode Dockerfile.antigravity; do
  check "image: $f ships user-tools.sh"         grep -qx 'COPY docker/user-tools.sh /usr/local/bin/user-tools.sh' "$REPO_ROOT/docker/$f"
done

if [ "$fails" -gt 0 ]; then
  echo "test-user-tools: $fails check(s) failed" >&2
  exit 1
fi
echo "test-user-tools: all checks passed"
