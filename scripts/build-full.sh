#!/usr/bin/env bash
# build-full.sh — build the complete Cloud Agents server (API + web + docker).
#
# Unlike scripts/verify.sh (which runtime-checks the Docker-independent logic),
# this builds every package, including the Web- and Docker-dependent ones, by
# assembling the lyric-lang workspace the compiler needs:
#
#   * the full Std.Core (Option/Result/List/...) is only available when the
#     compiler can discover the stdlib *sources*, i.e. when the project is built
#     inside the lyric-lang workspace — so we build there;
#   * the in-repo, enhanced Docker library (vendor/lyric-docker) is dropped in
#     over the workspace's copy;
#   * the Std.Time DateTimeOffset/TimeZone contract leak is patched so the
#     stdlib restores (see patches/).
#
# Requirements on PATH: lyric, dotnet (10.x).
# Env: LYRIC_LANG  path to a lyric-lang checkout (default: ../lyric-lang, cloned
#      if absent).
#
# NOTE: this builds (compiles) the project. Running the @test_module suites
# additionally needs the per-package stdlib runtime DLLs, which the standalone
# Lyric install does not ship; see docs/BUILD.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LYRIC_LANG="${LYRIC_LANG:-$(cd "$REPO_ROOT/.." && pwd)/lyric-lang}"

command -v lyric  >/dev/null || { echo "build-full: 'lyric' not on PATH"  >&2; exit 1; }
command -v dotnet >/dev/null || { echo "build-full: 'dotnet' not on PATH" >&2; exit 1; }

if [ ! -d "$LYRIC_LANG/lyric-stdlib/std" ]; then
  echo "==> cloning lyric-lang into $LYRIC_LANG"
  git clone --depth 1 https://github.com/nichobbs/lyric-lang.git "$LYRIC_LANG"
fi

echo "==> applying stdlib contract-leak patch (idempotent)"
git -C "$LYRIC_LANG" apply --reverse --check "$REPO_ROOT/patches/lyric-stdlib-datetimeoffset-leak.patch" 2>/dev/null \
  && echo "    already applied" \
  || git -C "$LYRIC_LANG" apply "$REPO_ROOT/patches/lyric-stdlib-datetimeoffset-leak.patch"

echo "==> applying lyric-auth contract-leak patch (idempotent)"
git -C "$LYRIC_LANG" apply --reverse --check "$REPO_ROOT/patches/lyric-auth-contract-leak.patch" 2>/dev/null \
  && echo "    already applied" \
  || git -C "$LYRIC_LANG" apply "$REPO_ROOT/patches/lyric-auth-contract-leak.patch"

echo "==> demoting Auth.Kernel.Net pub declarations (contract-synthesis bug workaround)"
# All pub funcs in lyric-auth/src/_kernel/ are in internal packages (Auth.Kernel.*)
# that lyric-web never imports directly; demoting them to package-private prevents
# the contract synthesizer from including their signatures in the contract JSON.
find "$LYRIC_LANG/lyric-auth/src/_kernel" -name '*.l' -type f 2>/dev/null | while IFS= read -r f; do
  if grep -qE '^pub (async )?func ' "$f"; then
    sed -i 's/^pub func /func /g; s/^pub async func /async func /g' "$f"
    echo "    demoted pub funcs in $f"
  fi
done

echo "==> installing the in-repo Docker library into the workspace"
rm -rf "$LYRIC_LANG/lyric-docker/src"
cp -r "$REPO_ROOT/vendor/lyric-docker/src" "$LYRIC_LANG/lyric-docker/src"

echo "==> building dependency libraries"
for lib in lyric-stdlib lyric-logging lyric-auth lyric-resilience lyric-web lyric-docker; do
  ( cd "$LYRIC_LANG/$lib" && rm -f lyric.lock && lyric build >/dev/null )
  echo "    built $lib"
  if [ "$lib" = "lyric-auth" ]; then
    echo "==> diagnosing Lyric.Contract.Auth resource"
    AUTH_DLL="$LYRIC_LANG/lyric-auth/bin/Lyric.Auth.dll"
    python3 - "$AUTH_DLL" <<'PYEOF' 2>&1 || true
import sys, re
dll_path = sys.argv[1]
with open(dll_path, 'rb') as f:
    data = f.read()
# Find the resource name then look for JSON content that follows it
marker = b'Lyric.Contract.Auth'
pos = data.find(marker)
if pos < 0:
    print("  [diag] resource name not found in DLL binary")
    sys.exit(0)
print(f"  [diag] resource name at offset {pos}")
after = data[pos + len(marker):pos + len(marker) + 4096]
for i, b in enumerate(after):
    if chr(b) in ('{', '['):
        snip = after[i:i+800]
        printable = ''.join(chr(x) if 32 <= x < 127 else f'\\x{x:02x}' for x in snip)
        print(f"  [diag] JSON-like content starts at +{i}:")
        print(f"  [diag] {printable[:600]}")
        import json
        try:
            raw = snip.split(b'\x00')[0]
            json.loads(raw.decode('utf-8', errors='replace'))
            print("  [diag] JSON is VALID")
        except Exception as e:
            print(f"  [diag] JSON is INVALID: {e}")
        break
PYEOF
  fi
done

echo "==> building the full Cloud Agents project"
WS="$LYRIC_LANG/.cloud-agents-full"
rm -rf "$WS"; mkdir -p "$WS"
cp -r "$REPO_ROOT/src" "$REPO_ROOT/tests" "$WS/"
cat > "$WS/lyric.toml" <<'TOML'
[package]
name = "CloudAgents"
version = "0.1.0"
[features]
default = ["dotnet", "sqlite"]
dotnet  = []
sqlite  = []
[project]
name = "CloudAgents"
output = "single"
output_assembly = "CloudAgents.dll"
[project.packages]
"CloudAgents"              = "src/main.l"
"CloudAgents.SessionStore" = "src/sessions/session_manager.l"
"CloudAgents.Handlers"     = "src/handlers/sessions.l"
"CloudAgents.Interactions" = "src/handlers/interactions.l"
"CloudAgents.Docker"       = "src/docker_manager.l"
"CloudAgents.Db"           = "src/db/db_client.l"
"CloudAgents.Sqlite"       = "src/db/sqlite_driver.l"
"CloudAgents.Repository"   = "src/db/repository.l"
"CloudAgents.Auth"         = "src/handlers/auth.l"
"CloudAgents.Streaming"    = "src/streaming/streaming.l"
[dependencies]
"Lyric.Web"    = { path = "../lyric-web" }
"Lyric.Docker" = { path = "../lyric-docker" }
"Std.Logging"  = { path = "../lyric-logging" }
TOML

( cd "$WS" && lyric build )
echo "==> Full build succeeded"
rm -rf "$WS"
