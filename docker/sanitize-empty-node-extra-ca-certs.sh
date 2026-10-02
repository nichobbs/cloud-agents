#!/bin/bash
# Unsets NODE_EXTRA_CA_CERTS when the file it points at is missing or empty.
#
# Every runner Dockerfile sets `ENV NODE_EXTRA_CA_CERTS=.../extra-combined.pem`
# unconditionally (docker/trust-extra-cas.sh always writes that file, even
# empty, when no corporate/proxy root CA was dropped into
# docker/extra-ca-certs/ before the build — see that directory's README). The
# assumption baked into trust-extra-cas.sh's header comment was that Node
# treats a missing or empty NODE_EXTRA_CA_CERTS file as a harmless no-op.
#
# Confirmed false for the Node runtime bundled inside `claude` (and, by the
# same mechanism, likely `codex`/`gemini`/`opencode`): pointing
# NODE_EXTRA_CA_CERTS at an empty file breaks TLS certificate validation for
# every HTTPS call that runtime makes, surfacing as a generic, undiagnosable
# connection failure (no HTTP status ever reached) on literally the first
# request of every single run — root-caused live against a production
# container: `curl` succeeded consistently (it validates TLS via the system
# OpenSSL store, untouched by this), while `claude` failed deterministically
# every time; overriding NODE_EXTRA_CA_CERTS to empty for one test run fixed
# it immediately.
#
# MUST be sourced (`source`/`.`), never executed as its own process — `unset`
# in a subshell can't reach back into entrypoint.sh's own environment, which
# is what the final `exec <harness>` call inherits.
#
# Call site: AFTER the root-only prelude drops privilege (entrypoint.sh's
# "#652" re-exec) and BEFORE the harness is invoked, in every entrypoint
# variant — never at image-build time, since whether an operator's
# `/etc/host-ca.pem` is mounted is a per-session runtime decision
# (CloudAgents.Docker's NODE_EXTRA_CA_CERTS passthrough in docker_manager.l),
# not something fixed at build time.

if [ -z "${NODE_EXTRA_CA_CERTS:-}" ] || [ ! -s "$NODE_EXTRA_CA_CERTS" ]; then
    unset NODE_EXTRA_CA_CERTS
fi
