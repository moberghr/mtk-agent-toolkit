#!/usr/bin/env bash
set -euo pipefail

# Test: scripts/secret-scan.sh — url-credential pattern (DF-1).
#
# A real repo had plaintext basic-auth credentials embedded in a webhook URL
# (https://user:password@host/...) inside a committed GitHub workflow file,
# and secret-scan.sh returned exit 0 on it (VERIFIED live miss). This test
# asserts the url-credential pattern now catches that case, while a small set
# of negative controls (placeholder creds, a plain URL, a port-only URL)
# stay clean so the pattern does not become noisy.
#
# Exit-1-on-failure style (no subshell pass/fail counters — lesson
# 2026-04-23). Runs entirely in a mktemp scratch dir; the script under test
# is never asked to touch the real repo.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCAN="$REPO_ROOT/scripts/secret-scan.sh"

echo "=== secret-scan Test (DF-1 — url-credential) ==="
[ -f "$SCAN" ] || { echo "  FAIL  script not found: $SCAN" >&2; exit 1; }
[ -x "$SCAN" ] || { echo "  FAIL  script not executable: $SCAN" >&2; exit 1; }

declare -a FAILS=()

TMPDIR_SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_SCRATCH"; }
trap cleanup EXIT

# --- positive: real-looking credential in a webhook URL ---------------------
POS_FILE="$TMPDIR_SCRATCH/positive.yml"
printf 'url: https://deployer:S3cr3tPass@example.azurewebsites.net/hook\n' > "$POS_FILE"

rc=0
bash "$SCAN" "$POS_FILE" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "  PASS  URL-embedded credential -> blocked (exit $rc)"
else
  FAILS+=("expected nonzero exit for URL-embedded credential, got 0")
fi

# --- negative: placeholder credential ---------------------------------------
NEG_PLACEHOLDER="$TMPDIR_SCRATCH/placeholder.yml"
printf 'url: https://user:pass@host/\n' > "$NEG_PLACEHOLDER"

rc=0
bash "$SCAN" "$NEG_PLACEHOLDER" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  PASS  placeholder credential (user:pass@) -> clean"
else
  FAILS+=("expected exit 0 for placeholder credential user:pass@, got $rc")
fi

# --- negative: plain URL, no credentials -------------------------------------
NEG_PLAIN="$TMPDIR_SCRATCH/plain.yml"
printf 'url: https://example.com/webhook\n' > "$NEG_PLAIN"

rc=0
bash "$SCAN" "$NEG_PLAIN" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  PASS  plain URL without credentials -> clean"
else
  FAILS+=("expected exit 0 for plain URL without credentials, got $rc")
fi

# --- negative: port, no credentials ------------------------------------------
NEG_PORT="$TMPDIR_SCRATCH/port.yml"
printf 'url: mongodb://localhost:27017\n' > "$NEG_PORT"

rc=0
bash "$SCAN" "$NEG_PORT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  PASS  host:port with no credentials -> clean"
else
  FAILS+=("expected exit 0 for host:port URL with no credentials, got $rc")
fi

# --- self-test still passes with the new pattern -----------------------------
rc=0
bash "$SCAN" --self-test >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  PASS  --self-test still green with url-credential added"
else
  FAILS+=("expected --self-test to exit 0, got $rc")
fi

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — all DF-1 url-credential assertions green"
