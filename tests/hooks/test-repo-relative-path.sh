#!/usr/bin/env bash
set -euo pipefail

# Test: hooks/lib/hook-io.sh :: mtk_repo_relative_path  (X1)
#
# Four hooks derived a repo-relative path with `"${FILE_PATH#"$REPO_ROOT"/}"`.
# That is a STRING operation, so it no-ops whenever the payload spells the root
# differently than `git rev-parse --show-toplevel` does — a case-insensitive
# filesystem serves the same checkout as both /Users/x/Dev/repo and
# /Users/x/dev/repo, and `pwd -P` resolves symlinks but not case. REL_PATH then
# stays absolute, every `case "$REL_PATH" in docs/specs/*)` match misses, and
# the hook exits 0. scope-guard and read-guard FAIL OPEN in that condition.
#
# Covers:
#   (a) exact spelling (the fast path) still works
#   (b) a symlinked root resolves identically
#   (c) a file directly at the root, and a deeply nested one
#   (d) a path genuinely outside the root returns 1 and prints nothing
#   (e) a not-yet-existing file (PreToolUse Write) still resolves

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/hooks/lib/hook-io.sh"

echo "=== mtk_repo_relative_path Test (X1) ==="
FAILS=0
FIX="$(mktemp -d)"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

ROOT="$FIX/repo"
mkdir -p "$ROOT/docs/specs" "$ROOT/src/deep/deeper"
: > "$ROOT/docs/specs/a.md"
: > "$ROOT/src/deep/deeper/b.ts"
: > "$ROOT/top.md"

check() { # $1=label $2=expected $3=actual
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1 — expected [$2], got [$3]" >&2
    FAILS=$((FAILS + 1))
  fi
}

# --- (a) exact spelling ------------------------------------------------------
check "exact: nested spec" "docs/specs/a.md" \
  "$(mtk_repo_relative_path "$ROOT/docs/specs/a.md" "$ROOT")"
check "exact: deeply nested" "src/deep/deeper/b.ts" \
  "$(mtk_repo_relative_path "$ROOT/src/deep/deeper/b.ts" "$ROOT")"
check "exact: file at root" "top.md" \
  "$(mtk_repo_relative_path "$ROOT/top.md" "$ROOT")"

# --- (b) symlinked root — the /var -> /private/var class ---------------------
# The file is addressed through a symlink to the root; the answer must not change.
ln -s "$ROOT" "$FIX/link"
check "symlinked root: nested spec" "docs/specs/a.md" \
  "$(mtk_repo_relative_path "$FIX/link/docs/specs/a.md" "$ROOT")"
check "symlinked root: deeply nested" "src/deep/deeper/b.ts" \
  "$(mtk_repo_relative_path "$FIX/link/src/deep/deeper/b.ts" "$ROOT")"

# The reverse: root spelled via the symlink, file spelled directly.
check "root spelled via symlink" "docs/specs/a.md" \
  "$(mtk_repo_relative_path "$ROOT/docs/specs/a.md" "$FIX/link")"

# --- (c) not-yet-existing file (PreToolUse Write to a new path) --------------
check "new file in existing dir" "docs/specs/brand-new.md" \
  "$(mtk_repo_relative_path "$ROOT/docs/specs/brand-new.md" "$ROOT")"
check "new file via symlinked root" "docs/specs/brand-new.md" \
  "$(mtk_repo_relative_path "$FIX/link/docs/specs/brand-new.md" "$ROOT")"

# --- (d) genuinely outside the root -> return 1, print nothing ---------------
mkdir -p "$FIX/elsewhere"
: > "$FIX/elsewhere/c.md"
if out="$(mtk_repo_relative_path "$FIX/elsewhere/c.md" "$ROOT")"; then
  echo "  FAIL  outside root: expected non-zero return, got 0 with [$out]" >&2
  FAILS=$((FAILS + 1))
else
  check "outside root: prints nothing" "" "$out"
  echo "  PASS  outside root: returns non-zero"
fi

# --- (e) empty / malformed input ---------------------------------------------
if mtk_repo_relative_path "" "$ROOT" >/dev/null 2>&1; then
  echo "  FAIL  empty file arg should return non-zero" >&2; FAILS=$((FAILS + 1))
else
  echo "  PASS  empty file arg returns non-zero"
fi
if mtk_repo_relative_path "$ROOT/top.md" "" >/dev/null 2>&1; then
  echo "  FAIL  empty root arg should return non-zero" >&2; FAILS=$((FAILS + 1))
else
  echo "  PASS  empty root arg returns non-zero"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "=== mtk_repo_relative_path: ALL PASS ==="
else
  echo "=== mtk_repo_relative_path: $FAILS FAILURE(S) ===" >&2
  exit 1
fi
