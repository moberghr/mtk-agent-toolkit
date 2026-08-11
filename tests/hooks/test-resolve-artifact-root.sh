#!/usr/bin/env bash
set -euo pipefail

# Test: scripts/resolve-artifact-root.sh  (F2)
#
# Field report: a .NET repo root whose ServiceDeskWeb/ subtree has its own
# established docs/specs/ (25 specs) and a CLAUDE.md declaring itself
# authoritative. MTK mandated repo-root docs/specs/ and had no notion of the
# subtree convention.
#
# Covers:
#   (a) BACKWARD COMPATIBILITY — a plain repo with no qualifying subtree
#       resolves to the repo root, exactly as before
#   (b) a subtree with BOTH CLAUDE.md and docs/specs/ wins for paths inside it
#   (c) ONE signal alone is not enough (docs/specs without CLAUDE.md, and
#       CLAUDE.md without docs/specs both fall through to the root)
#   (d) the explicit `.claude/artifact-root` marker wins over rule (b), and
#       lets the repo root claim itself to opt out
#   (e) $MTK_ARTIFACT_ROOT overrides everything
#   (f) nearest-wins when subtrees nest

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
R="$REPO_ROOT/scripts/resolve-artifact-root.sh"

echo "=== resolve-artifact-root.sh Test (F2) ==="
[ -f "$R" ] || { echo "  FAIL  script not found: $R" >&2; exit 1; }

FAILS=0
FIX="$(mktemp -d)"
# The fixture root itself must be the git root; resolve physical up front so
# comparisons are apples-to-apples (macOS /var -> /private/var).
FIX="$(cd "$FIX" && pwd -P)"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

ROOT="$FIX/repo"
mkdir -p "$ROOT/docs/specs" "$ROOT/plain/nested"
git -C "$ROOT" init -q . 2>/dev/null || { mkdir -p "$ROOT"; git -C "$ROOT" init -q .; }
: > "$ROOT/CLAUDE.md"

check() { # $1=label $2=expected $3=actual
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1 — expected [$2], got [$3]" >&2
    FAILS=$((FAILS + 1))
  fi
}

# --- (a) backward compatibility ---------------------------------------------
check "plain repo -> repo root" "$ROOT" "$(bash "$R" "$ROOT")"
check "nested dir, no subtree -> repo root" "$ROOT" "$(bash "$R" "$ROOT/plain/nested")"

# --- (b) authoritative subtree (both signals) --------------------------------
WEB="$ROOT/ServiceDeskWeb"
mkdir -p "$WEB/docs/specs" "$WEB/src/components"
: > "$WEB/CLAUDE.md"
check "subtree with CLAUDE.md + docs/specs" "$WEB" "$(bash "$R" "$WEB")"
check "deep inside subtree -> subtree"      "$WEB" "$(bash "$R" "$WEB/src/components")"
check "sibling outside subtree -> root"     "$ROOT" "$(bash "$R" "$ROOT/plain/nested")"

# --- (c) one signal alone is NOT enough --------------------------------------
ONLY_SPECS="$ROOT/only-specs"
mkdir -p "$ONLY_SPECS/docs/specs"
check "docs/specs without CLAUDE.md -> root" "$ROOT" "$(bash "$R" "$ONLY_SPECS")"

ONLY_MD="$ROOT/only-md"
mkdir -p "$ONLY_MD"
: > "$ONLY_MD/CLAUDE.md"
check "CLAUDE.md without docs/specs -> root" "$ROOT" "$(bash "$R" "$ONLY_MD")"

# --- (d) explicit marker -----------------------------------------------------
MARKED="$ROOT/marked"
mkdir -p "$MARKED/.claude"
: > "$MARKED/.claude/artifact-root"
check "explicit marker, no other signals" "$MARKED" "$(bash "$R" "$MARKED")"

# Marker beats the CLAUDE.md+docs/specs rule when it is nearer.
mkdir -p "$WEB/inner/.claude"
: > "$WEB/inner/.claude/artifact-root"
check "nearer marker beats outer subtree" "$WEB/inner" "$(bash "$R" "$WEB/inner")"

# The repo root can claim itself to opt out of subtree resolution entirely.
mkdir -p "$ROOT/.claude"
: > "$ROOT/.claude/artifact-root"
check "root marker does NOT override a nearer subtree" "$WEB" "$(bash "$R" "$WEB/src/components")"
check "root marker claims plain dirs" "$ROOT" "$(bash "$R" "$ROOT/plain/nested")"
rm -f "$ROOT/.claude/artifact-root"

# --- (e) env override wins over everything ----------------------------------
out="$(MTK_ARTIFACT_ROOT=/somewhere/else bash "$R" "$WEB/src/components")"
check "MTK_ARTIFACT_ROOT overrides all" "/somewhere/else" "$out"

# --- (f) --explain reports a source -----------------------------------------
err="$(bash "$R" --explain "$WEB" 2>&1 >/dev/null)"
case "$err" in
  *"CLAUDE.md + docs/specs"*) echo "  PASS  --explain names the resolution source" ;;
  *) echo "  FAIL  --explain source unclear: [$err]" >&2; FAILS=$((FAILS + 1)) ;;
esac

echo
if [ "$FAILS" -eq 0 ]; then
  echo "=== resolve-artifact-root.sh: ALL PASS ==="
else
  echo "=== resolve-artifact-root.sh: $FAILS FAILURE(S) ===" >&2
  exit 1
fi
