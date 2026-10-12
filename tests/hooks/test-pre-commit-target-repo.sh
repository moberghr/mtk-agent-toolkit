#!/usr/bin/env bash
#
# Verifies the git pre-commit hook works in a BOOTSTRAPPED target repo, where
# .git/hooks/pre-commit is a COPY of the stable shim (hooks/git-hooks/pre-commit)
# and the target repo contains no hooks/ directory of its own. Proves:
#   1. Default is blocking: a staged hardcoded secret is reported and the
#      commit is stopped (exit 1, NEEDS_CHANGES).
#   2. MTK_PRECOMMIT_BLOCK=0 makes it advisory: reported, commit proceeds.
#   3. A clean staged change commits successfully, even when blocking.
#   4. With no MTK_PLUGIN_ROOT, the shim resolves the NEWEST installed version
#      in the plugin cache (version-sorted, orphaned versions skipped).
#   5. A genuinely missing linter prints a one-line notice and exits 0 (never
#      silent, never a hard block for a tooling gap).

set -euo pipefail

TOOLKIT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK_SOURCE="$TOOLKIT_ROOT/hooks/git-hooks/pre-commit"

SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Isolate from the real plugin cache: every case runs against a sandbox HOME.
export HOME="$SANDBOX/home"
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR MTK_PLUGIN_ROOT MTK_PRECOMMIT_BLOCK

new_repo() {
  mkdir -p "$1"
  cd "$1"
  git init -q
  git config user.email test@example.com
  git config user.name "MTK Test"
  # Bootstrap installs the hook as a copy of the shim, not a symlink.
  cp "$HOOK_SOURCE" .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
}

# --- Case 1: secret is reported and the commit is blocked by default --------
new_repo "$SANDBOX/target"
[ ! -L .git/hooks/pre-commit ] || fail "hook should be installed as a copy, not a symlink"
printf '%s = "%s"\n' password supersecretvalue123 > config.py
git add config.py
STDERR_FILE="$SANDBOX/stderr1.txt"
if MTK_PLUGIN_ROOT="$TOOLKIT_ROOT" git commit -q -m "add secret" 2>"$STDERR_FILE"; then
  fail "commit with a hardcoded secret was NOT blocked by default"
fi
grep -q "critical finding" "$STDERR_FILE" || fail "default run did not report the finding"
grep -q "MTK_PRECOMMIT_BLOCK=0" "$STDERR_FILE" || fail "blocked run did not name the advisory switch"
echo "PASS: default blocks — finding reported, commit stopped"

# --- Case 2: MTK_PRECOMMIT_BLOCK=0 makes it advisory ------------------------
STDERR_FILE="$SANDBOX/stderr2.txt"
if MTK_PLUGIN_ROOT="$TOOLKIT_ROOT" MTK_PRECOMMIT_BLOCK=0 git commit -q -m "add secret (advisory)" 2>"$STDERR_FILE"; then
  grep -q "critical finding" "$STDERR_FILE" || fail "advisory run did not report the finding"
  echo "PASS: MTK_PRECOMMIT_BLOCK=0 reports the finding and lets the commit through"
else
  fail "MTK_PRECOMMIT_BLOCK=0 still blocked the commit"
fi
printf '%s = "%s"\n' password anothersecretvalue456 > config2.py
git add config2.py

VERDICT_JSON="$(bash "$TOOLKIT_ROOT/hooks/pre-commit-linters.sh" --cached 2>/dev/null || true)"
case "$VERDICT_JSON" in
  *'"verdict":"NEEDS_CHANGES"'*) echo "PASS: linter verdict is NEEDS_CHANGES" ;;
  *) fail "expected NEEDS_CHANGES verdict, got: $VERDICT_JSON" ;;
esac

# --- Case 3: clean change commits, even when blocking ------------------------
git reset -q
rm -f config2.py
printf 'def add(a, b):\n    return a + b\n' > math_utils.py
git add math_utils.py
if MTK_PLUGIN_ROOT="$TOOLKIT_ROOT" git commit -q -m "add helper" 2>/dev/null; then
  echo "PASS: clean change committed successfully"
else
  fail "clean change was incorrectly blocked"
fi

# --- Case 4: newest cached version wins, orphaned versions skipped -----------
CACHE="$HOME/.claude/plugins/cache/some-marketplace/mtk"
for v in 8.0.3 8.0.10 9.0.0; do
  mkdir -p "$CACHE/$v/hooks"
  cat > "$CACHE/$v/hooks/pre-commit-linters.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$v' > '$SANDBOX/which-linter'
printf '{"verdict":"PASS","findings":[]}\n'
EOF
done
touch "$CACHE/9.0.0/.orphaned_at"   # newest but orphaned by the plugin manager
printf 'x = 1\n' > other.py
git add other.py
git commit -q -m "cache resolution" 2>/dev/null || fail "commit failed under cached stub linter"
[ -f "$SANDBOX/which-linter" ] || fail "shim ran no cached linter"
PICKED="$(cat "$SANDBOX/which-linter")"
[ "$PICKED" = "8.0.10" ] || fail "shim picked cached version $PICKED, expected the newest live one (8.0.10)"
echo "PASS: shim resolved the newest live cached version (8.0.10)"
rm -rf "$HOME/.claude"

# --- Case 5: missing linter prints a notice and exits 0 ----------------------
new_repo "$SANDBOX/target2"
printf '%s = "%s"\n' password supersecretvalue123 > config.py
git add config.py
STDERR_FILE="$SANDBOX/stderr5.txt"
if MTK_PLUGIN_ROOT="$SANDBOX/no-such-plugin" git commit -q -m "no linter present" 2>"$STDERR_FILE"; then
  if grep -q "linter not found" "$STDERR_FILE"; then
    echo "PASS: missing linter printed a notice and allowed the commit"
  else
    fail "missing linter did not print the expected notice"
  fi
else
  fail "missing linter blocked the commit (should notice + exit 0)"
fi

echo "ALL PASS: test-pre-commit-target-repo"
