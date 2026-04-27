#!/usr/bin/env bash
# test-shrink-guard.sh — fixture-based tests for hooks/lib/shrink-guard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=hooks/lib/shrink-guard.sh
. "$ROOT_DIR/hooks/lib/shrink-guard.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

assert() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s — expected %s, got %s\n' "$label" "$expected" "$actual" >&2
  fi
}

make_file() {
  local path="$1"
  local lines="$2"
  : > "$path"
  local i
  for ((i = 1; i <= lines; i++)); do
    printf 'line %d with some padding to add bytes\n' "$i" >> "$path"
  done
}

# ---------------------------------------------------------------------------
# Case 1: target does not exist → write succeeds
# ---------------------------------------------------------------------------
make_file "$TMP/src1" 10
mtk_guarded_write "$TMP/new1" "$TMP/src1" >/dev/null 2>&1
rc=$?
assert "new file write succeeds" "$rc" "0"
assert "new file exists" "$([ -f "$TMP/new1" ] && echo yes || echo no)" "yes"

# ---------------------------------------------------------------------------
# Case 2: severe shrink (10 lines → 2 lines) → refused
# ---------------------------------------------------------------------------
make_file "$TMP/target2" 100
make_file "$TMP/src2" 10
set +e
err=$(mtk_guarded_write "$TMP/target2" "$TMP/src2" 2>&1 >/dev/null)
rc=$?
set -e
assert "severe shrink refused (exit 1)" "$rc" "1"
assert "stderr names target" "$(printf '%s' "$err" | grep -c "target2")" "1"
assert "stderr mentions override" "$(printf '%s' "$err" | grep -c "MTK_SHRINK_GUARD_OVERRIDE")" "1"
assert "target unchanged after refusal" "$(wc -l < "$TMP/target2" | tr -d ' ')" "100"
assert "source cleaned up after refusal" "$([ -e "$TMP/src2" ] && echo yes || echo no)" "no"

# ---------------------------------------------------------------------------
# Case 3: override env var → write succeeds with warning
# ---------------------------------------------------------------------------
make_file "$TMP/target3" 100
make_file "$TMP/src3" 10
set +e
err=$(MTK_SHRINK_GUARD_OVERRIDE=1 mtk_guarded_write "$TMP/target3" "$TMP/src3" 2>&1 >/dev/null)
rc=$?
set -e
assert "override write succeeds" "$rc" "0"
assert "override emits warning" "$(printf '%s' "$err" | grep -c "WARNING")" "1"
assert "target3 was overwritten" "$(wc -l < "$TMP/target3" | tr -d ' ')" "10"

# ---------------------------------------------------------------------------
# Case 4: small shrink within tolerance (100 → 85 lines) → allowed
# ---------------------------------------------------------------------------
make_file "$TMP/target4" 100
make_file "$TMP/src4" 85
set +e
mtk_guarded_write "$TMP/target4" "$TMP/src4" 2>/dev/null
rc=$?
set -e
assert "small shrink (85%) allowed" "$rc" "0"
assert "target4 was overwritten" "$(wc -l < "$TMP/target4" | tr -d ' ')" "85"

# ---------------------------------------------------------------------------
# Case 5: shrink exactly at line threshold (100 → 80) → allowed
# ---------------------------------------------------------------------------
make_file "$TMP/target5" 100
make_file "$TMP/src5" 80
set +e
mtk_guarded_write "$TMP/target5" "$TMP/src5" 2>/dev/null
rc=$?
set -e
assert "shrink at line threshold (80%) allowed" "$rc" "0"

# ---------------------------------------------------------------------------
# Case 6: shrink just below line threshold (100 → 79) → refused
# ---------------------------------------------------------------------------
make_file "$TMP/target6" 100
make_file "$TMP/src6" 79
set +e
mtk_guarded_write "$TMP/target6" "$TMP/src6" 2>/dev/null
rc=$?
set -e
assert "shrink below 80% lines refused" "$rc" "1"

# ---------------------------------------------------------------------------
# Case 7: empty target → any write allowed
# ---------------------------------------------------------------------------
: > "$TMP/target7"
make_file "$TMP/src7" 1
set +e
mtk_guarded_write "$TMP/target7" "$TMP/src7" 2>/dev/null
rc=$?
set -e
assert "empty target accepts any write" "$rc" "0"

# ---------------------------------------------------------------------------
# Case 8: missing args → usage error (exit 2)
# ---------------------------------------------------------------------------
set +e
mtk_guarded_write 2>/dev/null
rc=$?
set -e
assert "missing args → exit 2" "$rc" "2"

# ---------------------------------------------------------------------------
# Case 9: source not readable → exit 2
# ---------------------------------------------------------------------------
set +e
mtk_guarded_write "$TMP/target9" "$TMP/does-not-exist" 2>/dev/null
rc=$?
set -e
assert "missing source → exit 2" "$rc" "2"

# ---------------------------------------------------------------------------
echo ""
echo "shrink-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
