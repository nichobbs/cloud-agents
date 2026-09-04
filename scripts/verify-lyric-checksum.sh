#!/usr/bin/env sh
# Verifies a downloaded Lyric compiler release archive against the release's
# own published SHASUMS256.txt manifest before anything extracts it (#157).
# Mirrors the check lyric-lang's own install.sh added to its download path;
# this is the shared version behind every download site in THIS repo:
# docker/Dockerfile (both stages, plus its four sibling runner Dockerfiles'
# shim-builder stages) and deploy/api.Dockerfile. scripts/install.sh sources
# this file directly when run from a checked-out clone, with an inline
# fallback for the `curl | bash` case where no local file exists to source
# (see its own comments) — same pattern as scripts/lyric-rid.sh (#675).
#
# Fails closed: any download/parse failure, a missing manifest entry for
# this exact archive, or a digest mismatch exits non-zero and leaves the
# archive unverified — never install unverified bytes.
#
# Usage: verify-lyric-checksum.sh <version> <archive-path> <archive-name>
#   <version>       release version with no leading 'v', e.g. 0.4.36
#   <archive-path>  local path to the already-downloaded .tar.gz/.zip
#   <archive-name>  the exact release-asset filename, e.g.
#                   lyric-0.4.36-linux-x64.tar.gz
set -eu

version="$1"
archive_path="$2"
archive_name="$3"

shasums_url="https://github.com/nichobbs/lyric-lang/releases/download/v${version}/SHASUMS256.txt"
shasums_file="$(mktemp)"
trap 'rm -f "$shasums_file"' EXIT INT TERM

if ! curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 3 \
     -o "$shasums_file" "$shasums_url"; then
  echo "ERROR: failed to download SHASUMS256.txt from $shasums_url — cannot verify $archive_name" >&2
  exit 1
fi

expected="$(awk -v name="$archive_name" '$2 == name { print tolower($1) }' "$shasums_file" | head -1)"
if [ -z "$expected" ]; then
  echo "ERROR: no SHASUMS256.txt entry for $archive_name; refusing to install an unverified archive" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$archive_path" | awk '{print tolower($1)}')"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$archive_path" | awk '{print tolower($1)}')"
else
  echo "ERROR: neither sha256sum nor shasum found; cannot verify $archive_name" >&2
  exit 1
fi

if [ "$actual" != "$expected" ]; then
  echo "ERROR: checksum mismatch for $archive_name: expected $expected, got $actual" >&2
  exit 1
fi

echo "Checksum OK: $archive_name"
