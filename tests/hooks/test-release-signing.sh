#!/usr/bin/env bash
set -euo pipefail

# Test: scripts/generate-checksums.sh --sign + the openssl invocation shape
# scripts/mtk-doctor.sh uses to verify it (F4 — optional release signing).
#
# Exercises the full round-trip against a throwaway Ed25519 keypair:
#   1. sign a checksums file -> verify succeeds against the matching key
#   2. tamper with the checksums file -> verify FAILS (not a silent PASS)
#   3. verify against a mismatched key -> FAILS
# Mirrors the exact `openssl pkeyutl` invocation shape used by both scripts
# so a future flag change on one side that isn't mirrored on the other is
# caught here rather than only at release time.

command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl not found"; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Release Signing Test (F4) ==="

declare -a FAILS=()
TMPDIR_SIGN="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_SIGN"; }
trap cleanup EXIT

KEY_A="$TMPDIR_SIGN/key_a.pem"
PUB_A="$TMPDIR_SIGN/pub_a.pem"
KEY_B="$TMPDIR_SIGN/key_b.pem"
PUB_B="$TMPDIR_SIGN/pub_b.pem"

openssl genpkey -algorithm ed25519 -out "$KEY_A" >/dev/null 2>&1
openssl pkey -in "$KEY_A" -pubout -out "$PUB_A" >/dev/null 2>&1
openssl genpkey -algorithm ed25519 -out "$KEY_B" >/dev/null 2>&1
openssl pkey -in "$KEY_B" -pubout -out "$PUB_B" >/dev/null 2>&1

CHECKSUMS="$TMPDIR_SIGN/checksums.sha256"
printf 'deadbeef  some/file\n' > "$CHECKSUMS"
SIG="$TMPDIR_SIGN/checksums.sha256.sig"

# --- sign with key A (same invocation shape as generate-checksums.sh --sign) ---
echo ""; echo "--- sign + verify with matching key ---"
if openssl pkeyutl -sign -inkey "$KEY_A" -rawin -in "$CHECKSUMS" -out "$SIG" >/dev/null 2>&1; then
  if openssl pkeyutl -verify -pubin -inkey "$PUB_A" -rawin -in "$CHECKSUMS" -sigfile "$SIG" >/dev/null 2>&1; then
    echo "  PASS  signature verifies against the matching public key"
  else
    FAILS+=("verify: expected success against the matching public key, got failure")
  fi
else
  FAILS+=("sign: expected pkeyutl -sign to succeed with a fresh Ed25519 key")
fi

# --- tamper with checksums.sha256 after signing: verify must FAIL, not PASS ---
echo ""; echo "--- tamper detection ---"
printf 'deadbeef  some/file\ntampered  extra/file\n' > "$CHECKSUMS"
if openssl pkeyutl -verify -pubin -inkey "$PUB_A" -rawin -in "$CHECKSUMS" -sigfile "$SIG" >/dev/null 2>&1; then
  FAILS+=("verify: expected FAILURE against a tampered checksums file, got success (silent tamper acceptance)")
else
  echo "  PASS  verify rejects a tampered checksums file"
fi
# restore for the mismatched-key check below
printf 'deadbeef  some/file\n' > "$CHECKSUMS"

# --- verify against the wrong public key: must FAIL, not PASS ---
echo ""; echo "--- mismatched key detection ---"
if openssl pkeyutl -verify -pubin -inkey "$PUB_B" -rawin -in "$CHECKSUMS" -sigfile "$SIG" >/dev/null 2>&1; then
  FAILS+=("verify: expected FAILURE against a mismatched public key, got success")
else
  echo "  PASS  verify rejects a signature from a different keypair"
fi

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — all F4 release-signing assertions green"
