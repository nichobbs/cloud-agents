#!/usr/bin/env bash
# Regression test for docker/split-ca-bundle.sh (#716). Runs the REAL script
# against real temp files covering the single-certificate passthrough,
# multi-certificate bundle split, mixed certificate+CRL bundle split (#714),
# and non-PEM passthrough cases — no Docker, no network.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/docker/split-ca-bundle.sh"
[ -f "$SCRIPT" ] || { echo "test-split-ca-bundle: $SCRIPT not found" >&2; exit 1; }

WORK="$(mktemp -d)"
DEST="$WORK/dest"
mkdir -p "$DEST"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fails=0
check() {
  local desc="$1"; shift
  if "$@"; then echo "ok   $desc"; else echo "FAIL $desc" >&2; fails=$((fails + 1)); fi
}
file_eq() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }

# ── Single certificate: passes through under the plain (no -N) name ──
cat > "$WORK/single.pem" <<'EOF'
-----BEGIN CERTIFICATE-----
SINGLECERTDATA
-----END CERTIFICATE-----
EOF
"$SCRIPT" "$WORK/single.pem" "$DEST" single
check "single-cert: no split (only single.crt written)" \
  bash -c "[ \$(ls '$DEST' | wc -l) -eq 1 ]"
check "single-cert: content preserved" \
  file_eq "$DEST/single.crt" "$(cat "$WORK/single.pem")"

# ── Multi-certificate bundle: one file per certificate ──
cat > "$WORK/bundle.pem" <<'EOF'
-----BEGIN CERTIFICATE-----
ROOTCERTDATA
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
INTERMEDIATECERTDATA
-----END CERTIFICATE-----
EOF
"$SCRIPT" "$WORK/bundle.pem" "$DEST" bundle
check "bundle: root cert split out"         file_eq "$DEST/bundle-1.crt" $'-----BEGIN CERTIFICATE-----\nROOTCERTDATA\n-----END CERTIFICATE-----'
check "bundle: intermediate cert split out" file_eq "$DEST/bundle-2.crt" $'-----BEGIN CERTIFICATE-----\nINTERMEDIATECERTDATA\n-----END CERTIFICATE-----'
check "bundle: no combined bundle.crt left behind" \
  bash -c "[ ! -e '$DEST/bundle.crt' ]"

# ── Certificate(s) + trailing CRL: CRL gets its own file, not merged (#714) ──
cat > "$WORK/mixed.pem" <<'EOF'
-----BEGIN CERTIFICATE-----
AAAAROOTAAAA
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
BBBBINTERMEDIATEBBBB
-----END CERTIFICATE-----
-----BEGIN X509 CRL-----
CCCCCRLDATACCCC
-----END X509 CRL-----
EOF
"$SCRIPT" "$WORK/mixed.pem" "$DEST" mixed
check "mixed: 3 files written (2 certs + 1 CRL)" \
  bash -c "[ \$(ls '$DEST'/mixed-*.crt | wc -l) -eq 3 ]"
check "mixed: CRL split into its own file" \
  file_eq "$DEST/mixed-3.crt" $'-----BEGIN X509 CRL-----\nCCCCCRLDATACCCC\n-----END X509 CRL-----'
check "mixed: CRL not merged into the preceding cert's file" \
  bash -c "! grep -q 'X509 CRL' '$DEST/mixed-2.crt'"

# ── Non-PEM input: copied through unchanged, matching the old plain-cp behavior ──
echo "not a cert" > "$WORK/junk.pem"
"$SCRIPT" "$WORK/junk.pem" "$DEST" junk
check "non-PEM: copied through as-is" file_eq "$DEST/junk.crt" "not a cert"

if [ "$fails" -gt 0 ]; then
  echo "test-split-ca-bundle: $fails check(s) failed" >&2
  exit 1
fi
echo "test-split-ca-bundle: all checks passed"
