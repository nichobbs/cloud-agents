#!/usr/bin/env bash
# Tests docker/check-harness-cli.sh and docker/install-harness-cli.sh, and
# keeps them in sync with what launches the tools:
#   - every flag an entrypoint or delegate-task.sh passes a harness CLI is in
#     check-harness-cli.sh's required list for it, so the build-time check
#     covers it;
#   - every runner image installs its CLIs and uv through install-harness-cli.sh
#     with no version pin left behind, and each ADD fetches the registry
#     metadata of the package that is actually installed;
#   - the checker accepts a tool that lists every flag and rejects one that
#     lacks any, and the installer falls back to the known-good release when
#     the newest one fails the check.
# Stubs only; no network. Set REAL_CLI_DIR to a directory holding real claude,
# codex, gemini and opencode binaries (and uv/uvx) to also check those.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/docker/check-harness-cli.sh"
INSTALL="$REPO_ROOT/docker/install-harness-cli.sh"
D="$REPO_ROOT/docker"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}

# flags_in TEXT: the option tokens (-x, --long) in TEXT, one per line.
flags_in() { grep -oE -- '(^|[[:space:](])-{1,2}[a-zA-Z][a-zA-Z0-9-]*' <<< "$1" | sed -E 's/^[[:space:](]+//' | sort -u; }

# launch_text TOOL: every line that launches TOOL from an entrypoint or from
# delegate-task.sh, plus the flag arrays those lines expand.
launch_text() {
  case "$1" in
    claude)
      grep -hE '^\s*exec claude ' "$D/entrypoint.sh"
      grep -hE '^(STREAM_JSON_ARGS|\s*PERMISSION_PROMPT_ARGS)=\(' "$D/entrypoint.sh" ;;
    codex)    grep -hE '^\s*exec codex ' "$D/entrypoint-codex.sh" ;;
    gemini)
      grep -hE '^\s*exec gemini ' "$D/entrypoint-gemini.sh"
      grep -hE '^\s*exec (agy|gemini) ' "$D/entrypoint-antigravity.sh" ;;
    opencode) grep -hE '^\s*exec opencode ' "$D/entrypoint-opencode.sh" ;;
  esac
  grep -hE "^\s*$1\)\s+cmd=\(" "$D/delegate-task.sh"
  grep -hE '^\s*\[ -n "\$model" \] && m=\(' "$D/delegate-task.sh" | sed 's/.*m=(/m=(/'
}

# 1. Every flag passed is checked at build time.
for tool in claude codex gemini opencode; do
  text="$(launch_text "$tool")"
  check "$tool: launch lines found" [ "$(grep -c . <<< "$text")" -ge 2 ]
  listed="$("$CHECK" --list "$tool")"
  while IFS= read -r flag; do
    [ -n "$flag" ] || continue
    check "$tool: $flag is in the build-time check" grep -qxF -- "$flag" <<< "$listed"
  done < <(flags_in "$text")
done

# 2. Images install through install-harness-cli.sh, unpinned and consistent.
images="Dockerfile Dockerfile.codex Dockerfile.gemini Dockerfile.opencode Dockerfile.antigravity"
for img in $images; do
  f="$D/$img"
  check "$img: ships the checker and installer" grep -qxF 'COPY docker/check-harness-cli.sh docker/install-harness-cli.sh /usr/local/bin/' "$f"
  check "$img: no pinned npm CLI install" bash -c '! grep -qE "npm install -g [^ ]*@[0-9]" "$0"' "$f"
  check "$img: no pinned uv installer" bash -c '! grep -qE "astral\.sh/uv/[0-9]" "$0"' "$f"
  check "$img: uv through the installer" grep -qF 'install-harness-cli.sh --latest-json /tmp/cli-latest/uv-install.sh uv' "$f"
  check "$img: uv ADD is the unversioned installer" grep -qxF 'ADD https://astral.sh/uv/install.sh /tmp/cli-latest/uv-install.sh' "$f"
  while read -r tool; do
    pkg="$("$INSTALL" --package "$tool")"
    check "$img: $tool ADD fetches $pkg's latest" grep -qxF "ADD https://registry.npmjs.org/$pkg/latest /tmp/cli-latest/$tool.json" "$f"
  done < <(grep -oE 'install-harness-cli\.sh --latest-json /tmp/cli-latest/[a-z]+\.json [a-z]+' "$f" | awk '{print $NF}' | grep -vx uv)
done
for pair in "Dockerfile claude" "Dockerfile opencode" "Dockerfile.codex codex" "Dockerfile.gemini gemini" \
            "Dockerfile.opencode opencode" "Dockerfile.antigravity gemini"; do
  set -- $pair
  check "$1 installs $2" grep -qE "install-harness-cli\.sh --latest-json /tmp/cli-latest/$2\.json $2( |$)" "$D/$1"
done
check "delegate-task installs through the installer" grep -q 'install-harness-cli.sh" --prefix' "$D/delegate-task.sh"
check "delegate-task keeps no version pins" bash -c '! grep -qE "@(anthropic-ai/claude-code|openai/codex|google/gemini-cli)@[0-9]|opencode-ai@[0-9]" "$0"' "$D/delegate-task.sh"

# 3. The checker against stubs.
mkdir -p "$WORK/bin"
# stub TOOL [FLAG-TO-DROP]: a CLI whose help lists TOOL's required flags.
stub() {
  local tool="$1" drop="${2:-}" dir="$WORK/stub-$1-${2:-all}"
  mkdir -p "$dir"
  {
    echo '#!/usr/bin/env bash'
    echo 'case " $* " in *" --version "*) echo "9.9.9"; exit 0 ;; esac'
    echo "cat <<'HELP'"
    echo "Usage: $tool [options]"
    "$CHECK" --list "$tool" | grep -vxF -- "${drop:-@none@}" | sed 's/^/  /; s/$/  some description/'
    echo '  stream-json json'
    echo HELP
    # The hidden flag lives in the program text, as in the real binary.
    [ "$drop" = --permission-prompt-tool ] || echo '# --permission-prompt-tool'
  } > "$dir/$tool"
  chmod +x "$dir/$tool"
  echo "$dir/$tool"
}
for tool in claude codex gemini opencode; do
  check "checker: complete $tool passes" "$CHECK" --bin "$(stub "$tool")" "$tool"
done
out="$("$CHECK" --bin "$(stub codex --ephemeral)" codex 2>&1)" && rc=0 || rc=$?
check "checker: missing flag fails"             [ "$rc" -ne 0 ]
check "checker: ...and names the flag"          grep -q -- '--ephemeral' <<< "$out"
out="$("$CHECK" --bin "$(stub claude --permission-prompt-tool)" claude 2>&1)" && rc=0 || rc=$?
check "checker: missing hidden flag fails"      [ "$rc" -ne 0 ]
check "checker: an absent tool fails"           bash -c '! PATH=/usr/bin:/bin "$0" opencode 2>/dev/null' "$CHECK"
rc=0; "$CHECK" nosuchtool 2>/dev/null || rc=$?
check "checker: unknown tool is a usage error"  [ "$rc" -eq 2 ]
# uv: needs the `tool` subcommand and a working uvx beside it.
mkdir -p "$WORK/uv"
printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "uv 9.9";; *) printf "Commands:\\n  run   Run\\n  tool  Tools\\n";; esac\n' > "$WORK/uv/uv"
chmod +x "$WORK/uv/uv"
check "checker: uv without uvx fails"           bash -c '! "$0" --bin "$1" uv 2>/dev/null' "$CHECK" "$WORK/uv/uv"
printf '#!/usr/bin/env bash\necho "uvx 9.9"\n' > "$WORK/uv/uvx"; chmod +x "$WORK/uv/uvx"
check "checker: uv with tool and uvx passes"    "$CHECK" --bin "$WORK/uv/uv" uv

# 4. The installer against a stub npm.
mkdir -p "$WORK/npm"
cat > "$WORK/npm/npm" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$WORK/npm.args"
if [ "\$1" = view ]; then
  case "\$3" in
    time) jq -n --slurpfile t "$WORK/times.json" --slurpfile v "$WORK/versions.json" '{time: \$t[0], versions: \$v[0]}' ;;
    dist-tags.latest) cat "$WORK/dist-latest" ;;
  esac
  exit 0
fi
prefix=""; pkg=""
while [ \$# -gt 0 ]; do case "\$1" in --prefix) prefix="\$2"; shift 2 ;; install|-g) shift ;; *) pkg="\$1"; shift ;; esac; done
mkdir -p "\$prefix/bin"
case "\$pkg" in
  *@broken|*@9.9.9-broken|*@\$(cat "$WORK/broken-version" 2>/dev/null)) cp "$(stub codex --json)" "\$prefix/bin/codex" ;;
  *@fail) exit 1 ;;
  *) cp "$(stub codex)" "\$prefix/bin/codex" ;;
esac
STUB
chmod +x "$WORK/npm/npm"
# The cool-down is covered separately below; these cases take the newest.
inst() { PATH="$WORK/npm:$PATH" HARNESS_CLI_MIN_AGE_DAYS=0 "$INSTALL" "$@" > "$WORK/inst.out" 2>&1; }
rm -f "$WORK/npm.args"
check "installer: newest release passing is kept" inst --prefix "$WORK/p1" codex
check "installer: ...installed @latest"         grep -q '@openai/codex@latest' "$WORK/npm.args"
check "installer: ...no fallback"               bash -c '! grep -q "@$1" "$0"' "$WORK/npm.args" "$("$INSTALL" --fallback codex)"
echo '{"version":"1.2.3"}' > "$WORK/latest.json"
rm -f "$WORK/npm.args"
check "installer: --latest-json pins that build" inst --prefix "$WORK/p2" --latest-json "$WORK/latest.json" codex
check "installer: ...to the metadata's version" grep -q '@openai/codex@1.2.3' "$WORK/npm.args"
echo '{"version":"9.9.9-broken"}' > "$WORK/latest.json"
rm -f "$WORK/npm.args"
check "installer: failing newest falls back"    inst --prefix "$WORK/p3" --latest-json "$WORK/latest.json" codex
check "installer: ...to the known-good version" grep -q "@openai/codex@$("$INSTALL" --fallback codex)" "$WORK/npm.args"
check "installer: ...with a warning"            grep -q WARNING "$WORK/inst.out"
mkdir -p "$WORK/npmfail"; printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/npmfail/npm"; chmod +x "$WORK/npmfail/npm"
check "installer: both failing fails"           bash -c '! PATH="$1:$PATH" HARNESS_CLI_MIN_AGE_DAYS=0 "$0" --prefix "$2" codex >/dev/null 2>&1' "$INSTALL" "$WORK/npmfail" "$WORK/p4"
rc=0; "$INSTALL" nosuchtool 2>/dev/null || rc=$?
check "installer: unknown tool is a usage error" [ "$rc" -eq 2 ]

# The cool-down: the newest stable release at least HARNESS_CLI_MIN_AGE_DAYS
# old, never above the registry's `latest` tag.
ago() { date -u -d "@$(( $(date +%s) - $1 * 86400 ))" +%Y-%m-%dT%H:%M:%S.000Z; }
cat > "$WORK/times.json" <<JSON
{"created": "$(ago 400)", "modified": "$(ago 1)",
 "1.9.0": "$(ago 300)", "1.10.0": "$(ago 20)", "1.10.1": "$(ago 8)",
 "1.11.0-alpha.1": "$(ago 10)", "1.10.2-linux-x64": "$(ago 9)",
 "1.11.0": "$(ago 2)", "9.0.0": "$(ago 30)", "1.10.5": "$(ago 9)"}
JSON
# 1.10.5 has a publish time but was unpublished: npm no longer lists it.
jq '[keys[] | select(. != "created" and . != "modified" and . != "1.10.5")]' "$WORK/times.json" > "$WORK/versions.json"
echo "1.11.0" > "$WORK/dist-latest"
cool() { PATH="$WORK/npm:$PATH" HARNESS_CLI_MIN_AGE_DAYS="$1" "$INSTALL" --prefix "$WORK/c$1" codex > "$WORK/inst.out" 2>&1; }
rm -f "$WORK/npm.args"
check "cool-down: installs"                     cool 7
check "cool-down: newest release 7+ days old"   grep -q '@openai/codex@1.10.1$' "$WORK/npm.args"
check "cool-down: ...skipping an unpublished one" bash -c '! grep -q "@openai/codex@1.10.5" "$0"' "$WORK/npm.args"
check "cool-down: ...compared as versions"      bash -c '! grep -q "@openai/codex@1.9.0" "$0"' "$WORK/npm.args"
check "cool-down: ...says what it skipped"      grep -q 'newest release 1.11.0; trying the newest at least 7 days old: 1.10.1 1.10.0 1.9.0' "$WORK/inst.out"
# A chosen release that fails its check is followed by the next settled one.
echo 1.10.1 > "$WORK/broken-version"
rm -f "$WORK/npm.args"
check "cool-down: failing choice tries the next" cool 7
check "cool-down: ...which is 1.10.0"            grep -q '@openai/codex@1.10.0$' "$WORK/npm.args"
check "cool-down: ...not the known-good"         bash -c '! grep -q "@$1" "$0"' "$WORK/npm.args" "$("$INSTALL" --fallback codex)"
rm -f "$WORK/broken-version"
rm -f "$WORK/npm.args"
check "cool-down: a longer window"              cool 15
check "cool-down: ...goes further back"         grep -q '@openai/codex@1.10.0$' "$WORK/npm.args"
check "cool-down: never above latest's tag"     bash -c '! grep -q "@openai/codex@9.0.0" "$0"' "$WORK/npm.args"
rm -f "$WORK/npm.args"
check "cool-down: nothing old enough"           cool 1000
check "cool-down: ...falls back to known-good"  grep -q "@openai/codex@$("$INSTALL" --fallback codex)" "$WORK/npm.args"
check "cool-down: ...with a warning"            grep -q 'WARNING: could not find' "$WORK/inst.out"
echo '{}' > "$WORK/times.json"; echo '[]' > "$WORK/versions.json"
rm -f "$WORK/npm.args"
check "cool-down: registry gives no times"      cool 7
check "cool-down: ...falls back to known-good"  grep -q "@openai/codex@$("$INSTALL" --fallback codex)" "$WORK/npm.args"
# uv's cool-down reads PyPI: yanked and file-less releases don't count.
mkdir -p "$WORK/curlbin" "$WORK/uvdir" "$WORK/uvstub"
printf '#!/bin/sh\ncase "$1" in --version) echo "uv 9.9" ;; *) printf "Commands:\\n  tool  Tools\\n" ;; esac\n' > "$WORK/uvstub/uv"
printf '#!/bin/sh\necho "uvx 9.9"\n' > "$WORK/uvstub/uvx"
chmod +x "$WORK/uvstub/uv" "$WORK/uvstub/uvx"
cat > "$WORK/pypi.json" <<JSON
{"info": {"version": "0.13.4"},
 "releases": {
   "0.13.4": [{"upload_time_iso_8601": "$(ago 2)", "yanked": false}],
   "0.14.0a1": [{"upload_time_iso_8601": "$(ago 9)", "yanked": false}],
   "0.13.3": [{"upload_time_iso_8601": "$(ago 10)", "yanked": true}, {"upload_time_iso_8601": "$(ago 10)", "yanked": true}],
   "0.13.2": [{"upload_time_iso_8601": "$(ago 11)", "yanked": true}, {"upload_time_iso_8601": "$(ago 11)", "yanked": false}],
   "0.13.10": [],
   "0.13.1": [{"upload_time_iso_8601": "$(ago 12)", "yanked": false}]}}
JSON
cat > "$WORK/curlbin/curl" <<STUB
#!/usr/bin/env bash
url="\${@: -1}"
echo "\$url" >> "$WORK/curl.urls"
case "\$url" in
  https://pypi.org/pypi/uv/json) cat "$WORK/pypi.json" ;;
  https://astral.sh/uv/*/install.sh) printf 'cp "%s/uv" "%s/uvx" "\$UV_INSTALL_DIR/"\n' "$WORK/uvstub" "$WORK/uvstub" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$WORK/curlbin/curl"
rm -f "$WORK/curl.urls"
check "cool-down: uv installs"                  env PATH="$WORK/curlbin:$PATH" UV_INSTALL_DIR="$WORK/uvdir" HARNESS_CLI_MIN_AGE_DAYS=7 "$INSTALL" uv
check "cool-down: uv skips yanked and empty releases" grep -qx 'https://astral.sh/uv/0.13.2/install.sh' "$WORK/curl.urls"
check "cool-down: ...and pre-releases"          bash -c '! grep -q "0.14.0a1" "$0"' "$WORK/curl.urls"

rc=0; HARNESS_CLI_MIN_AGE_DAYS=soon "$INSTALL" codex 2>/dev/null || rc=$?
check "cool-down: a bad setting is a usage error" [ "$rc" -eq 2 ]
for img in $images; do
  check "$img: cool-down default is set"        grep -qxF 'ARG HARNESS_CLI_MIN_AGE_DAYS=7' "$D/$img"
done
check "delegate-task passes the cool-down on"   grep -q '"HARNESS_CLI_MIN_AGE_DAYS=${HARNESS_CLI_MIN_AGE_DAYS:-7}"' "$D/delegate-task.sh"

# 5. Real CLIs, when provided.
if [ -n "${REAL_CLI_DIR:-}" ]; then
  for tool in claude codex gemini opencode uv; do
    [ -x "$REAL_CLI_DIR/$tool" ] && check "real $tool passes the check" "$CHECK" --bin "$REAL_CLI_DIR/$tool" "$tool"
  done
fi

if [ "$fails" -gt 0 ]; then
  echo "test-check-harness-cli: $fails check(s) failed" >&2
  exit 1
fi
echo "test-check-harness-cli: all checks passed"
