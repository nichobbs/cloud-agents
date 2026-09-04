#!/bin/sh
# Splits a PEM file that may hold zero, one, or many certificates/CRLs into
# one file per entry under a destination directory.
#
# update-ca-certificates rebuilds /etc/ssl/certs' by-hash symlinks from
# whatever lands in /usr/local/share/ca-certificates, and that step expects
# exactly one certificate (or CRL) per file — a multi-entry bundle (a root +
# intermediate chain, or several unrelated CAs concatenated into one file,
# both common exports from corporate MDM/proxy tooling) makes it warn
# "<file> does not contain exactly one certificate or CRL" and skip hashing
# every entry but the first, so only that first one is reliably resolvable
# via CApath-style directory lookups. The certs still end up trusted via the
# concatenated /etc/ssl/certs/ca-certificates.crt (the CAfile route
# curl/git/openssl use by default), so this is mostly cosmetic noise today —
# but splitting avoids the warning and gets every entry its own hash symlink
# too.
#
# Usage: split-ca-bundle.sh <src-file> <dest-dir> <name-prefix>
# Writes <dest-dir>/<name-prefix>.crt for a single-entry input (unchanged
# naming for the common case), or <dest-dir>/<name-prefix>-N.crt per entry
# for a bundle. A file with no recognizable certificate is copied through
# as-is, matching the prior behavior for that edge case.
set -eu

src="$1"
dest_dir="$2"
prefix="$3"

# update-ca-certificates' own warning names both certificate and CRL blocks
# as the unit it expects one-per-file, so a bundle can legitimately mix in a
# CRL alongside certificates (#714) — count both to decide whether to split.
entry_count=$(grep -c -E '^-----BEGIN (CERTIFICATE|X509 CRL)-----' "$src" 2>/dev/null || true)

if [ -z "$entry_count" ] || [ "$entry_count" -le 1 ]; then
    cp "$src" "$dest_dir/$prefix.crt"
    exit 0
fi

# `active` tracks whether we're inside a BEGIN..END block: text between two
# blocks (e.g. a "# Intermediate CA" label some annotated bundles put above
# each cert) is dropped rather than appended to the just-closed file, which
# is what a bare `n { print > out }` (n staying truthy for the rest of the
# file once set) used to do (#718) — it doesn't belong to either the
# preceding or following file, so dropping it is the safe choice.
awk -v dest="$dest_dir" -v prefix="$prefix" '
    /-----BEGIN CERTIFICATE-----/ { n++; out = dest "/" prefix "-" n ".crt"; active = 1 }
    /-----BEGIN X509 CRL-----/ { n++; out = dest "/" prefix "-" n ".crt"; active = 1 }
    active { print > out }
    /-----END CERTIFICATE-----/ { active = 0 }
    /-----END X509 CRL-----/ { active = 0 }
' "$src"
