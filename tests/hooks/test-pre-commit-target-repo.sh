#!/usr/bin/env bash
#
# Verifies the git pre-commit hook works in a BOOTSTRAPPED target repo, where
# .git/hooks/pre-commit is a symlink into the plugin checkout and the target
# repo contains no hooks/ directory of its own. Proves:
#   1. A staged hardcoded secret produces a blocked commit (NEEDS_CHANGES).
#   2. A clean staged change commits successfully.
#   3. A genuinely missing linter warns to stderr and exits 0 (never silent,
#      never a hard block for a tooling gap).

set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK_SOURCE="$TOOLKIT_ROOT/hooks/git-hooks/pre-commit"

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- Build a scratch "target" repo mimicking a bootstrapped install ----------
REPO="$SANDBOX/target"
mkdir -p "$REPO"
cd "$REPO"
git init -q
git config user.email test@example.com
git config user.name "MTK Test"
# Bootstrap installs the hook as an absolute symlink into the plugin checkout.
ln -s "$HOOK_SOURCE" .git/hooks/pre-commit

# --- Case 1: staged hardcoded secret must block the commit -------------------
printf 'password = "supersecretvalue123"\n' > config.py
git add config.py
if git commit -q -m "add secret" 2>/dev/null; then
  fail "commit with hardcoded secret was NOT blocked"
fi
echo "PASS: hardcoded secret blocked the commit"

# Confirm the linter itself reports NEEDS_CHANGES against this working tree.
VERDICT_JSON="$(bash "$TOOLKIT_ROOT/hooks/pre-commit-linters.sh" --cached 2>/dev/null || true)"
case "$VERDICT_JSON" in
  *'"verdict":"NEEDS_CHANGES"'*) echo "PASS: linter verdict is NEEDS_CHANGES" ;;
  *) fail "expected NEEDS_CHANGES verdict, got: $VERDICT_JSON" ;;
esac

# --- Case 2: clean staged change must commit successfully --------------------
git reset -q
rm -f config.py
printf 'def add(a, b):\n    return a + b\n' > math_utils.py
git add math_utils.py
if git commit -q -m "add helper" 2>/dev/null; then
  echo "PASS: clean change committed successfully"
else
  fail "clean change was incorrectly blocked"
fi

# --- Case 3: missing linter warns and exits 0 --------------------------------
# Simulate a broken install by pointing the hook at a checkout with no linter.
BROKEN="$SANDBOX/broken-plugin/hooks/git-hooks"
mkdir -p "$BROKEN"
cp "$HOOK_SOURCE" "$BROKEN/pre-commit"
chmod +x "$BROKEN/pre-commit"
REPO2="$SANDBOX/target2"
mkdir -p "$REPO2"
cd "$REPO2"
git init -q
git config user.email test@example.com
git config user.name "MTK Test"
ln -s "$BROKEN/pre-commit" .git/hooks/pre-commit
printf 'password = "supersecretvalue123"\n' > config.py
git add config.py
STDERR_FILE="$SANDBOX/stderr.txt"
if git commit -q -m "no linter present" 2>"$STDERR_FILE"; then
  if grep -q "linter not found" "$STDERR_FILE"; then
    echo "PASS: missing linter warned to stderr and allowed the commit"
  else
    fail "missing linter did not print the expected warning"
  fi
else
  fail "missing linter blocked the commit (should warn + exit 0)"
fi

echo "ALL PASS: test-pre-commit-target-repo"
