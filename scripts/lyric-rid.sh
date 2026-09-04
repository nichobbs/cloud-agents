#!/usr/bin/env sh
# Shared Lyric release RID (Runtime Identifier) mapping from `uname -m` for
# Linux builds — the single source of truth behind docker/Dockerfile (and
# its four sibling runner Dockerfiles' shim-builder stages, kept
# byte-identical by scripts/check-shim-stage-sync.sh), deploy/api.Dockerfile,
# and scripts/install.sh (#675). Before this existed, the same x86_64 ->
# linux-x64 / aarch64 -> linux-arm64 case statement was hand-copied into
# each of those independently, with nothing enforcing they stayed in sync.
#
# Linux only: the Dockerfile call sites only ever build on Linux, and
# install.sh's own macOS/Windows RID branches don't overlap with this table,
# so this script covers just the shared Linux case.
#
# Usage: LYRIC_RID="$(scripts/lyric-rid.sh)" — prints the RID on stdout, or
# exits non-zero with a message on stderr for an unsupported architecture.
set -eu

arch="$(uname -m)"
case "$arch" in
  x86_64)  echo "linux-x64" ;;
  aarch64) echo "linux-arm64" ;;
  *)
    echo "ERROR: unsupported architecture for the Lyric compiler: $arch (supported: x86_64, aarch64)" >&2
    exit 1
    ;;
esac
