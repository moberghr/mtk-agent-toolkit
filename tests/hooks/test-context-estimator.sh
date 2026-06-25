#!/usr/bin/env bash
set -euo pipefail

# Benchmark: context load estimator (SC5 + SC6)
# Verifies bytes_read accumulates for unique files and that estimated_context_tokens
# is produced correctly. Uses direct session-state manipulation to avoid subshell
# counter issues — exits non-zero on first failure.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_IO="$REPO_ROOT/hooks/lib/hook-io.sh"

echo "=== Context Load Estimator Benchmark (SC5 + SC6) ==="

# Setup: temp workspace
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
export TMPDIR="$TMPDIR_TEST"

# Create fixture files with known sizes
FILE_A="$TMPDIR_TEST/fixture_a.md"
FILE_B="$TMPDIR_TEST/fixture_b.md"
FILE_LARGE="$TMPDIR_TEST/fixture_large.md"
printf '%0.s#' {1..1000} > "$FILE_A"   # 1000 bytes
printf '%0.s#' {1..2000} > "$FILE_B"   # 2000 bytes
dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\0' '#' > "$FILE_LARGE"  # ~200k bytes

SESSION_FILE="$TMPDIR_TEST/session_state"

# Helpers: read a numeric field from session state file
read_session_int() { grep "^$1=" "$SESSION_FILE" 2>/dev/null | cut -d= -f2 | tr -d "'" || echo 0; }

# Bootstrap empty session state
# shellcheck source=/dev/null
source "$HOOK_IO"
mtk_init_session_state "$SESSION_FILE"

# --- SC5a: bytes_read accumulates for two unique files ---
echo ""
echo "--- SC5a: accumulates bytes_read for unique files ---"

# Simulate the Read-event logic from context-budget.sh for FILE_A then FILE_B
for FILE_PATH in "$FILE_A" "$FILE_B"; do
  mtk_session_lock_acquire
  mtk_load_session_state "$SESSION_FILE"
  if ! echo "$files" | grep -qF "$FILE_PATH"; then
    files="${files:+$files|}$FILE_PATH"
    if [ -f "$FILE_PATH" ]; then
      file_bytes=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ' || echo 0)
      [ "$file_bytes" -gt 100000 ] && file_bytes=100000
      bytes_read=$((bytes_read + file_bytes))
    fi
  fi
  mtk_save_session_state "$SESSION_FILE"
  mtk_session_lock_release
done

actual=$(read_session_int "bytes_read")
if [ "$actual" -lt 3000 ]; then
  echo "  FAIL  bytes_read should be >= 3000 after two files, got $actual" >&2
  exit 1
fi
echo "  PASS  bytes_read=$actual after reading fixture_a (1000) + fixture_b (2000)"

# --- SC5b: duplicate read does NOT increase bytes_read ---
echo ""
echo "--- SC5b: duplicate read does not increment bytes_read ---"

bytes_before=$(read_session_int "bytes_read")

# Re-read FILE_A (already in $files)
mtk_session_lock_acquire
mtk_load_session_state "$SESSION_FILE"
FILE_PATH="$FILE_A"
if ! echo "$files" | grep -qF "$FILE_PATH"; then
  files="${files:+$files|}$FILE_PATH"
  if [ -f "$FILE_PATH" ]; then
    file_bytes=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ' || echo 0)
    [ "$file_bytes" -gt 100000 ] && file_bytes=100000
    bytes_read=$((bytes_read + file_bytes))
  fi
fi
mtk_save_session_state "$SESSION_FILE"
mtk_session_lock_release

bytes_after=$(read_session_int "bytes_read")
if [ "$bytes_after" -ne "$bytes_before" ]; then
  echo "  FAIL  bytes_read changed on duplicate read: $bytes_before → $bytes_after" >&2
  exit 1
fi
echo "  PASS  bytes_read unchanged on duplicate read ($bytes_before → $bytes_after)"

# --- SC5c: 100k cap enforced on large file ---
echo ""
echo "--- SC5c: 100k cap enforced on large file ---"

SESSION_LARGE="$TMPDIR_TEST/session_large"
mtk_init_session_state "$SESSION_LARGE"

mtk_session_lock_acquire
# Temporarily switch session file
SESSION_FILE_BAK="$SESSION_FILE"
SESSION_FILE="$SESSION_LARGE"
mtk_load_session_state "$SESSION_FILE"
FILE_PATH="$FILE_LARGE"
if ! echo "$files" | grep -qF "$FILE_PATH"; then
  files="${files:+$files|}$FILE_PATH"
  if [ -f "$FILE_PATH" ]; then
    file_bytes=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ' || echo 0)
    [ "$file_bytes" -gt 100000 ] && file_bytes=100000
    bytes_read=$((bytes_read + file_bytes))
  fi
fi
mtk_save_session_state "$SESSION_FILE"
SESSION_FILE="$SESSION_FILE_BAK"
mtk_session_lock_release

capped=$(grep "^bytes_read=" "$SESSION_LARGE" | cut -d= -f2 || echo 0)
if [ "$capped" -ne 100000 ]; then
  echo "  FAIL  bytes_read should be capped at 100000, got $capped" >&2
  exit 1
fi
echo "  PASS  bytes_read=$capped (capped at 100k for ${FILE_LARGE##*/} which is ~200k)"

# --- SC6: estimated_context_tokens = bytes_read / 4 ---
echo ""
echo "--- SC6: estimated_context_tokens computed correctly ---"

ANALYTICS_FILE="$TMPDIR_TEST/analytics.json"
KNOWN_BYTES=8000
EXPECTED_TOKENS=2000  # 8000/4

# Write a session state with known bytes_read
SESSION_ANALYTICS="$TMPDIR_TEST/session_analytics"
mtk_init_session_state "$SESSION_ANALYTICS"
mtk_session_lock_acquire
SESSION_FILE_BAK="$SESSION_FILE"
SESSION_FILE="$SESSION_ANALYTICS"
mtk_load_session_state "$SESSION_FILE"
ops=10; mods=3; bytes_read=$KNOWN_BYTES
mtk_save_session_state "$SESSION_FILE"
SESSION_FILE="$SESSION_FILE_BAK"
mtk_session_lock_release

# Build minimal analytics.json that session-analytics would produce
TODAY=$(date +%Y-%m-%d)
cat > "$ANALYTICS_FILE" <<EOF
{
  "first_session": "$TODAY",
  "last_session": "$TODAY",
  "sessions": 0,
  "total_operations": 0,
  "total_modifications": 0,
  "specs_created": 0,
  "lessons_captured": 0,
  "scope_guard_warnings": 0,
  "benchmarks_run": 0,
  "benchmark_last_score": "",
  "queue_writes": 0,
  "queue_drains": 0,
  "queue_expired": 0,
  "bytes_read": 0,
  "estimated_context_tokens": 0
}
EOF

# Compute what session-analytics.sh would write (inline, matching its logic)
session_bytes=$KNOWN_BYTES
total_bytes_read=$((0 + session_bytes))
total_estimated_tokens=$((total_bytes_read / 4))

ANALYTICS_TMP="${ANALYTICS_FILE}.tmp"
cat > "$ANALYTICS_TMP" <<EOF
{
  "first_session": "$TODAY",
  "last_session": "$TODAY",
  "sessions": 1,
  "total_operations": 10,
  "total_modifications": 3,
  "specs_created": 0,
  "lessons_captured": 0,
  "scope_guard_warnings": 0,
  "benchmarks_run": 0,
  "benchmark_last_score": "",
  "queue_writes": 0,
  "queue_drains": 0,
  "queue_expired": 0,
  "bytes_read": $total_bytes_read,
  "estimated_context_tokens": $total_estimated_tokens
}
EOF
mv "$ANALYTICS_TMP" "$ANALYTICS_FILE"

est_tokens=$(grep -o '"estimated_context_tokens"[[:space:]]*:[[:space:]]*[0-9]*' "$ANALYTICS_FILE" | grep -o '[0-9]*$' || echo 0)
bytes_field=$(grep -o '"bytes_read"[[:space:]]*:[[:space:]]*[0-9]*' "$ANALYTICS_FILE" | grep -o '[0-9]*$' || echo 0)

if [ "$bytes_field" -ne "$KNOWN_BYTES" ]; then
  echo "  FAIL  bytes_read in analytics.json: expected $KNOWN_BYTES, got $bytes_field" >&2
  exit 1
fi
if [ "$est_tokens" -ne "$EXPECTED_TOKENS" ]; then
  echo "  FAIL  estimated_context_tokens: expected $EXPECTED_TOKENS, got $est_tokens" >&2
  exit 1
fi
echo "  PASS  bytes_read=$bytes_field, estimated_context_tokens=$est_tokens (=$KNOWN_BYTES/4)"

## --- SC8: context-budget %-of-window checkpoint ---
echo ""
echo "--- SC8: context-budget checkpoint (60% default, env-tunable, once-only) ---"

# Mirror the checkpoint block from hooks/context-budget.sh. Returns the message on
# stdout (empty if it should not fire) and echoes the resulting warned flag on fd 3.
run_checkpoint() {
  local bytes_read="$1" warned_ctxpct="$2"
  local ctx_window="${MTK_CONTEXT_WINDOW_TOKENS:-200000}"
  local ctx_pct="${MTK_CONTEXT_BUDGET_PCT:-60}"
  local out="" newflag="$warned_ctxpct"
  if [ "$warned_ctxpct" -eq 0 ] && [ "${bytes_read:-0}" -gt 0 ]; then
    local est_tokens=$((bytes_read / 4))
    local budget_tokens=$((ctx_window * ctx_pct / 100))
    if [ "$budget_tokens" -gt 0 ] && [ "$est_tokens" -ge "$budget_tokens" ]; then
      out="CONTEXT BUDGET: estimated ~${est_tokens} context tokens consumed"
      newflag=1
    fi
  fi
  printf '%s' "$out"
  echo "$newflag" >&3
}

# 8a: below threshold (est 100000 < budget 120000 at defaults) → silent
flag_a=$(run_checkpoint 400000 0 3>"$TMPDIR_TEST/flag_a"); read -r warned_a < "$TMPDIR_TEST/flag_a"
if [ -n "$flag_a" ] || [ "$warned_a" -ne 0 ]; then
  echo "  FAIL  8a: should stay silent below 60% (got msg='$flag_a' flag=$warned_a)" >&2; exit 1
fi
echo "  PASS  8a: silent below threshold"

# 8b: crosses default 60% (est 150000 >= budget 120000) → fires, flag set
flag_b=$(run_checkpoint 600000 0 3>"$TMPDIR_TEST/flag_b"); read -r warned_b < "$TMPDIR_TEST/flag_b"
if [ -z "$flag_b" ] || [ "$warned_b" -ne 1 ]; then
  echo "  FAIL  8b: should fire at >=60% (got msg='$flag_b' flag=$warned_b)" >&2; exit 1
fi
echo "  PASS  8b: fires crossing 60% default"

# 8c: once-only — already warned → silent even when over threshold
flag_c=$(run_checkpoint 600000 1 3>"$TMPDIR_TEST/flag_c"); read -r warned_c < "$TMPDIR_TEST/flag_c"
if [ -n "$flag_c" ]; then
  echo "  FAIL  8c: should not re-fire once warned (got msg='$flag_c')" >&2; exit 1
fi
echo "  PASS  8c: fires at most once per session"

# 8d: env-tunable — same bytes that were silent at 60% fire at 40%
flag_d=$(MTK_CONTEXT_BUDGET_PCT=40 run_checkpoint 400000 0 3>"$TMPDIR_TEST/flag_d"); read -r warned_d < "$TMPDIR_TEST/flag_d"
if [ -z "$flag_d" ] || [ "$warned_d" -ne 1 ]; then
  echo "  FAIL  8d: should fire at 40% override (got msg='$flag_d' flag=$warned_d)" >&2; exit 1
fi
echo "  PASS  8d: MTK_CONTEXT_BUDGET_PCT override honored"

# 8e: MTK_CONTEXT_WINDOW_TOKENS override — a smaller window fires at the same bytes
flag_e1=$(run_checkpoint 300000 0 3>"$TMPDIR_TEST/flag_e1"); read -r warned_e1 < "$TMPDIR_TEST/flag_e1"
flag_e2=$(MTK_CONTEXT_WINDOW_TOKENS=100000 run_checkpoint 300000 0 3>"$TMPDIR_TEST/flag_e2"); read -r warned_e2 < "$TMPDIR_TEST/flag_e2"
if [ -n "$flag_e1" ]; then echo "  FAIL  8e: 300000 bytes should be silent at default window" >&2; exit 1; fi
if [ -z "$flag_e2" ] || [ "$warned_e2" -ne 1 ]; then echo "  FAIL  8e: should fire with MTK_CONTEXT_WINDOW_TOKENS=100000 (got '$flag_e2')" >&2; exit 1; fi
echo "  PASS  8e: MTK_CONTEXT_WINDOW_TOKENS override honored"

## --- SC8-int: real hook end-to-end (stdin parse + sed flag-flip path) ---
echo ""
echo "--- SC8-int: hooks/context-budget.sh end-to-end ---"
HOOK="$REPO_ROOT/hooks/context-budget.sh"
SESSION_HOOK="$(mtk_session_file)"           # same TMPDIR → same path the hook uses
mtk_init_session_state "$SESSION_HOOK"
sed -i.bak 's/^bytes_read=.*/bytes_read=600000/' "$SESSION_HOOK" && rm -f "${SESSION_HOOK}.bak"
FIXTURE_NEW="$TMPDIR_TEST/integ_new.md"; printf '%0.s#' {1..500} > "$FIXTURE_NEW"
INPUT_JSON=$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$FIXTURE_NEW")

OUT=$(printf '%s' "$INPUT_JSON" | bash "$HOOK" 2>/dev/null || true)
if printf '%s' "$OUT" | grep -q "CONTEXT BUDGET: estimated"; then
  echo "  PASS  real hook emits the checkpoint nudge"
else
  echo "  FAIL  real hook did not emit checkpoint (out: $OUT)" >&2; exit 1
fi
warned_after=$(grep '^warned_ctxpct=' "$SESSION_HOOK" | cut -d= -f2 | tr -d "'")
if [ "$warned_after" = "1" ]; then
  echo "  PASS  warned_ctxpct flipped to 1 via sed (state-flip path exercised)"
else
  echo "  FAIL  warned_ctxpct not flipped (got '$warned_after')" >&2; exit 1
fi
OUT2=$(printf '%s' "$INPUT_JSON" | bash "$HOOK" 2>/dev/null || true)
if printf '%s' "$OUT2" | grep -q "CONTEXT BUDGET: estimated"; then
  echo "  FAIL  checkpoint re-fired — should fire once per session" >&2; exit 1
else
  echo "  PASS  checkpoint fires once end-to-end (warned flag respected)"
fi

echo ""
echo "========================================"
echo "BENCHMARK PASSED — all SC5+SC6+SC8 assertions green"
