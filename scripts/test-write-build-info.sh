#!/usr/bin/env bash
# Regression test for scripts/write-build-info.sh (#1340): feeds a synthetic
# project.assets.json plus stub `lyric`/`dotnet` through the real script and
# checks the emitted build-info.txt. No toolchain or network needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho "lyric 9.8.7"\n' > "$tmp/bin/lyric"
printf '#!/bin/sh\necho "10.0.1"\n' > "$tmp/bin/dotnet"
chmod +x "$tmp/bin/lyric" "$tmp/bin/dotnet"
cat > "$tmp/assets.json" <<'JSON'
{ "targets": { "net10.0": {
    "Lyric.Db/1.2.3": { "type": "package" },
    "Npgsql/8.0.3": { "type": "package" },
    "Lyric.Web/0.9.0-beta.1": { "type": "package" }
  } },
  "libraries": {
    "Lyric.Db/1.2.3": { "sha512": "x" },
    "Npgsql/8.0.3": { "sha512": "y" }
  } }
JSON

fails=0
check() { if grep -qxF -- "$2" "$tmp/out/build-info.txt"; then echo "ok   $1"; else echo "FAIL $1 (missing '$2')" >&2; fails=$((fails + 1)); fi; }

PATH="$tmp/bin:$PATH" BUILD_INFO_ASSETS="$tmp/assets.json" "$HERE/write-build-info.sh" "$tmp/out" >/dev/null
check "lyric version"        "lyric: 9.8.7"
check "dotnet version"       "dotnet: 10.0.1"
check "floor recorded"       "min_lyric_version: $(tr -d '[:space:]' < "$HERE/../MIN_LYRIC_VERSION")"
check "nuget header"         "nuget:"
check "package listed"       "  Lyric.Db 1.2.3"
check "prerelease listed"    "  Lyric.Web 0.9.0-beta.1"
check "deduplicated"         "  Npgsql 8.0.3"
[ "$(grep -c 'Lyric.Db 1.2.3' "$tmp/out/build-info.txt")" = 1 ] || { echo "FAIL duplicate entry" >&2; fails=$((fails + 1)); }

if PATH="$tmp/bin:$PATH" BUILD_INFO_ASSETS="$tmp/missing.json" "$HERE/write-build-info.sh" "$tmp/out2" >/dev/null 2>&1; then
  echo "FAIL missing assets should fail" >&2; fails=$((fails + 1))
else echo "ok   missing assets fails"; fi

[ "$fails" = 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
echo "all ok"
