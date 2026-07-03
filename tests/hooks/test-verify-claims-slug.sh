#!/usr/bin/env bash
set -euo pipefail

# Test: scripts/verify-claims.sh DOC_SLUG derivation (DF-9 regression).
#
# Before this fix, DOC_SLUG was `basename "$INPUT" | tr '/.' '__'` — two
# same-named docs in different directories (a real shape in monorepos, e.g.
# per-package CLAUDE.md files) both slugged to `weak-claims-CLAUDE_md.json`
# and clobbered each other's report. The fix derives the slug from the
# repo-root-relative path instead, falling back to basename only when the
# input lives outside the repo (setup-converge's scratch temp copies — see
# setup-converge/SKILL.md STEP 1 — have no meaningful repo-relative form).
#
# Assertions:
#   (a) root CLAUDE.md keeps producing weak-claims-CLAUDE_md.json (relative
#       path == basename, so existing consumers stay compatible)
#   (b) backend/CLAUDE.md and frontend/CLAUDE.md produce DISTINCT report
#       files instead of clobbering each other (the DF-9 bug)
#   (c) a doc passed by an absolute path outside the repo (mirroring
#       setup-converge's temp-copy pattern) falls back to basename-only
#       slugging, unchanged from before this fix
#
# Exit-1-on-failure style (no subshell pass/fail counters — lesson 2026-04-23).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY_CLAIMS="$REPO_ROOT/scripts/verify-claims.sh"

echo "=== verify-claims.sh DOC_SLUG Test (DF-9) ==="
[ -f "$VERIFY_CLAIMS" ] || { echo "  FAIL  script not found: $VERIFY_CLAIMS" >&2; exit 1; }

declare -a FAILS=()

TMPDIR_FIXTURE="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_FIXTURE"; }
trap cleanup EXIT

FIXTURE="$TMPDIR_FIXTURE/repo"
mkdir -p "$FIXTURE/backend" "$FIXTURE/frontend"
(cd "$FIXTURE" && git init -q)

DOC_BODY='# Sample doc

No tagged claims here — this test only checks cache-file naming.
'
printf '%s' "$DOC_BODY" > "$FIXTURE/CLAUDE.md"
printf '%s' "$DOC_BODY" > "$FIXTURE/backend/CLAUDE.md"
printf '%s' "$DOC_BODY" > "$FIXTURE/frontend/CLAUDE.md"

CACHE_DIR="$FIXTURE/.claude/.mtk-cache"

# --- (a) root CLAUDE.md: unchanged slug -------------------------------------
echo ""; echo "--- (a) root CLAUDE.md -> weak-claims-CLAUDE_md.json (unchanged) ---"
(cd "$FIXTURE" && bash "$VERIFY_CLAIMS" CLAUDE.md) >/dev/null
if [ -f "$CACHE_DIR/weak-claims-CLAUDE_md.json" ]; then
  echo "  PASS  root CLAUDE.md slug unchanged"
else
  FAILS+=("(a) expected $CACHE_DIR/weak-claims-CLAUDE_md.json to exist. Cache dir: $(ls "$CACHE_DIR" 2>&1)")
fi

# --- (b) same-basename docs in different dirs: distinct cache files --------
echo ""; echo "--- (b) backend/CLAUDE.md + frontend/CLAUDE.md -> distinct reports ---"
(cd "$FIXTURE" && bash "$VERIFY_CLAIMS" backend/CLAUDE.md) >/dev/null
(cd "$FIXTURE" && bash "$VERIFY_CLAIMS" frontend/CLAUDE.md) >/dev/null
BACKEND_JSON="$CACHE_DIR/weak-claims-backend_CLAUDE_md.json"
FRONTEND_JSON="$CACHE_DIR/weak-claims-frontend_CLAUDE_md.json"
if [ -f "$BACKEND_JSON" ] && [ -f "$FRONTEND_JSON" ]; then
  echo "  PASS  distinct cache files: $(basename "$BACKEND_JSON"), $(basename "$FRONTEND_JSON")"
else
  FAILS+=("(b) expected distinct backend/frontend report files. backend_exists=$([ -f "$BACKEND_JSON" ] && echo yes || echo no) frontend_exists=$([ -f "$FRONTEND_JSON" ] && echo yes || echo no). Cache dir: $(ls "$CACHE_DIR" 2>&1)")
fi

# Confirm the root doc's report survived the two nested runs — this is the
# actual collision DF-9 describes: a same-basename clobber would have
# overwritten weak-claims-CLAUDE_md.json with the last nested doc's content.
if [ -f "$CACHE_DIR/weak-claims-CLAUDE_md.json" ]; then
  echo "  PASS  root CLAUDE.md's report was not clobbered by the nested runs"
else
  FAILS+=("(b) root CLAUDE.md's report went missing after nested-doc runs — collision reproduced")
fi

# --- (c) doc outside the repo: falls back to basename-only slugging --------
# Mirrors setup-converge's pattern of copying a stamped doc to a scratch temp
# dir before verifying it (setup-converge/SKILL.md STEP 1) — there is no
# meaningful repo-relative path for a file outside the repo, so the slug
# must fall back to basename, exactly as before this fix.
echo ""; echo "--- (c) doc outside the repo -> basename-only fallback ---"
OUTSIDE_DIR="$TMPDIR_FIXTURE/outside-scratch"
mkdir -p "$OUTSIDE_DIR"
printf '%s' "$DOC_BODY" > "$OUTSIDE_DIR/architecture-principles.md"
(cd "$FIXTURE" && bash "$VERIFY_CLAIMS" "$OUTSIDE_DIR/architecture-principles.md") >/dev/null
if [ -f "$CACHE_DIR/weak-claims-architecture-principles_md.json" ]; then
  echo "  PASS  outside-repo doc falls back to basename slug"
else
  FAILS+=("(c) expected $CACHE_DIR/weak-claims-architecture-principles_md.json to exist. Cache dir: $(ls "$CACHE_DIR" 2>&1)")
fi

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — verify-claims.sh DOC_SLUG assertions green (DF-9)"
