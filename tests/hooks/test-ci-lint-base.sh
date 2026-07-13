#!/usr/bin/env bash
#
# Verifies scripts/ci-lint.sh actually uses --base to diff base...HEAD, instead
# of the old vacuous `git diff HEAD` that is always empty on a clean CI
# checkout. Proves:
#   1. A PR branch that commits a critical pattern → non-zero exit.
#   2. A PR branch with only clean commits → exit 0 (PASS).
# ci-lint.sh loads pattern packs from its own checkout while diffing the repo in
# the current working directory (the simulated PR checkout).

set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_LINT="$TOOLKIT_ROOT/scripts/ci-lint.sh"

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- Scratch repo with a base branch -----------------------------------------
REPO="$SANDBOX/repo"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main
git config user.email test@example.com
git config user.name "MTK Test"
printf 'def add(a, b):\n    return a + b\n' > math_utils.py
git add math_utils.py
git commit -q -m "base"

# --- Case 1: PR branch introduces a critical pattern → FAIL (non-zero) --------
git checkout -q -b feature-secret
printf 'api_key = "abcdef1234567890xyz"\n' > secrets_cfg.py
git add secrets_cfg.py
git commit -q -m "add secret"
if bash "$CI_LINT" --base main >/dev/null 2>&1; then
  fail "ci-lint returned PASS for a PR that commits a hardcoded secret"
fi
echo "PASS: ci-lint failed on a PR with a critical finding"

# --- Case 2: clean PR branch → PASS (exit 0) ---------------------------------
git checkout -q main
git checkout -q -b feature-clean
printf 'def sub(a, b):\n    return a - b\n' >> math_utils.py
git add math_utils.py
git commit -q -m "clean change"
if bash "$CI_LINT" --base main >/dev/null 2>&1; then
  echo "PASS: ci-lint passed on a clean PR"
else
  fail "ci-lint failed on a clean PR (should PASS)"
fi

echo "ALL PASS: test-ci-lint-base"
