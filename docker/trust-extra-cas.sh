#!/bin/sh
# Installs and trusts whatever corporate/proxy root CA(s) a local build
# dropped into docker/extra-ca-certs/ (see that directory's README) — the
# shared logic behind every runner Dockerfile's "Optional corporate/proxy
# root CA trust" step (#686). Factored out of the five runner Dockerfiles
# (docker/Dockerfile's two stages, and one stage each in Dockerfile.codex/
# .opencode/.gemini/.antigravity), which used to carry this same for-loop +
# update-ca-certificates block copy-pasted near-verbatim — the exact
# copy-paste that let the .cer glob gap (#685) slip into all of them
# identically. Now there is one source of truth: a fix here reaches every
# Dockerfile the next time its cached layer is invalidated.
#
# Expects /tmp/extra-ca-certs (COPY'd in by the caller) to hold zero or
# more .crt/.pem/.cer files, and split-ca-bundle.sh to already be on PATH
# (COPY'd in alongside this script — see any Dockerfile's call site).
#
# Always (re)writes /usr/local/share/ca-certificates/extra-combined.pem,
# even when nothing was dropped into extra-ca-certs/ (an empty file in that
# case) — Node treats a missing or empty NODE_EXTRA_CA_CERTS as a harmless
# no-op, so the Node-based runner stages can set that env var
# unconditionally rather than branching on whether any certs exist. The
# non-Node shim-builder stage doesn't consume the combined file, but
# writing an unused few-byte file there is harmless, and doing the same
# work unconditionally is what keeps this script identical everywhere it's
# called (docs/BUILD.md; see check-shim-stage-sync.sh for the stages this
# feeds that must stay byte-identical).
set -eu

: > /usr/local/share/ca-certificates/extra-combined.pem
for f in /tmp/extra-ca-certs/*.crt /tmp/extra-ca-certs/*.pem /tmp/extra-ca-certs/*.cer; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  split-ca-bundle.sh "$f" /usr/local/share/ca-certificates "${base%.*}"
  cat "$f" >> /usr/local/share/ca-certificates/extra-combined.pem
done
update-ca-certificates
