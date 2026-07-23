#!/bin/sh
# Splits a PEM file that may hold zero, one, or many certificates into one
# file per certificate under a destination directory.
#
# update-ca-certificates rebuilds /etc/ssl/certs' by-hash symlinks from
# whatever lands in /usr/local/share/ca-certificates, and that step expects
# exactly one certificate per file — a multi-certificate bundle (a root +
# intermediate chain, or several unrelated CAs concatenated into one file,
# both common exports from corporate MDM/proxy tooling) makes it warn
# "<file> does not contain exactly one certificate or CRL" and skip hashing
# every certificate but the first, so only that first one is reliably
# resolvable via CApath-style directory lookups. The certs still end up
# trusted via the concatenated /etc/ssl/certs/ca-certificates.crt (the CAfile
# route curl/git/openssl use by default), so this is mostly cosmetic noise
# today — but splitting avoids the warning and gets every certificate its own
# hash symlink too.
#
# Usage: split-ca-bundle.sh <src-file> <dest-dir> <name-prefix>
# Writes <dest-dir>/<name-prefix>.crt for a single-certificate input
# (unchanged naming for the common case), or <dest-dir>/<name-prefix>-N.crt
# per certificate for a bundle. A file with no recognizable certificate is
# copied through as-is, matching the prior behavior for that edge case.
set -eu

src="$1"
dest_dir="$2"
prefix="$3"

cert_count=$(grep -c '^-----BEGIN CERTIFICATE-----' "$src" 2>/dev/null || true)

if [ -z "$cert_count" ] || [ "$cert_count" -le 1 ]; then
    cp "$src" "$dest_dir/$prefix.crt"
    exit 0
fi

awk -v dest="$dest_dir" -v prefix="$prefix" '
    /-----BEGIN CERTIFICATE-----/ { n++; out = dest "/" prefix "-" n ".crt" }
    n { print > out }
' "$src"
