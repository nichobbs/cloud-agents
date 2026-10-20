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
prefix=""; pkg=""
while [ \$# -gt 0 ]; do case "\$1" in --prefix) prefix="\$2"; shift 2 ;; install|-g) shift ;; *) pkg="\$1"; shift ;; esac; done
mkdir -p "\$prefix/bin"
case "\$pkg" in
  *@broken|*@9.9.9-broken) cp "$(stub codex --json)" "\$prefix/bin/codex" ;;
  *@fail) exit 1 ;;
  *) cp "$(stub codex)" "\$prefix/bin/codex" ;;
esac
STUB
chmod +x "$WORK/npm/npm"
inst() { PATH="$WORK/npm:$PATH" "$INSTALL" "$@" > "$WORK/inst.out" 2>&1; }
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
check "installer: both failing fails"           bash -c '! PATH="$1:$PATH" "$0" --prefix "$2" codex >/dev/null 2>&1' "$INSTALL" "$WORK/npmfail" "$WORK/p4"
rc=0; "$INSTALL" nosuchtool 2>/dev/null || rc=$?
check "installer: unknown tool is a usage error" [ "$rc" -eq 2 ]

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
