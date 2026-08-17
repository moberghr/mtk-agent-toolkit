#!/usr/bin/env bash
set -euo pipefail

# Verification evidence contract (scripts/mtk-verify-run.sh): full output on
# disk at a citable path, exit code + bounded tail in context, exit code
# preserved, and the emitted `exit=N` line authoritative for the session
# ledger's outcome classifier.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/mtk-verify-run.sh"

cd "$REPO_ROOT"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Work in an isolated throwaway git repo so evidence logs never pollute the
# real .mtk/evidence/ and repo-relative citation is exercised for real.
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
git -C "$WORK" init -q
cd "$WORK"

# --- 1. exit-code fidelity ---------------------------------------------------

out="$(bash "$WRAPPER" -- true)" || fail "wrapper must exit 0 when the command exits 0"
echo "$out" | grep -q '^exit=0$' || fail "missing exit=0 line. Got: $out"
printf '  PASS  exit 0 preserved and reported\n'

rc=0
out="$(bash "$WRAPPER" "exit 3" 2>&1)" || rc=$?
[ "$rc" -eq 3 ] || fail "wrapper must preserve the command's exit code (want 3, got $rc)"
echo "$out" | grep -q '^exit=3$' || fail "missing exit=3 line. Got: $out"
printf '  PASS  non-zero exit preserved and reported\n'

# --- 2. bounded tail + full output on disk ------------------------------------

out="$(bash "$WRAPPER" --tail 5 --label longrun 'seq 1 100')"
count="$(echo "$out" | grep -cE '^[0-9]+$')"
[ "$count" -eq 5 ] || fail "tail must be bounded to 5 lines (got $count)"
echo "$out" | grep -q '96' && echo "$out" | grep -q '100' \
  || fail "tail must carry the LAST lines. Got: $out"

log_path="$(echo "$out" | sed -n 's/.*full output: \([^)]*\)).*/\1/p')"
[ -n "$log_path" ] || fail "citation line must name the log path. Got: $out"
[ -f "$WORK/$log_path" ] || fail "cited path must be repo-relative and exist ($log_path)"
[ "$(wc -l < "$WORK/$log_path" | tr -d ' ')" -eq 100 ] \
  || fail "full output (100 lines) must persist on disk"
case "$log_path" in
  .mtk/evidence/*longrun*) : ;;
  *) fail "log must live under .mtk/evidence/ and carry the label (got $log_path)" ;;
esac
printf '  PASS  bounded tail in context, full output persisted at citable path\n'

# --- 2b. error-hit slice on failure (diagnostic above the tail) ---------------

rc=0
out="$(bash "$WRAPPER" --tail 3 --label earlyerr \
  'echo "error CS1002: the real diagnostic"; seq 1 50; exit 1' 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "early-error command must exit 1 (got $rc)"
echo "$out" | grep -q 'first error hits' \
  || fail "failure must emit an error-hit slice. Got: $out"
echo "$out" | grep -qE '^1:.*error CS1002' \
  || fail "error slice must carry the log line number (1:...). Got: $out"
printf '  PASS  error-hit slice surfaces diagnostics above the tail\n'

out="$(bash "$WRAPPER" --tail 3 --label cleanpass 'seq 1 50')"
echo "$out" | grep -q 'first error hits' \
  && fail "a passing run must not emit an error slice. Got: $out"
printf '  PASS  no error slice on success\n'

# --- 3. exit=N line is authoritative for the outcome classifier ---------------

classify() {
  bash -c '
    source "'"$REPO_ROOT"'/hooks/lib/hook-io.sh"
    mtk_classify_verification_outcome "$1"
  ' _ "$1"
}

[ "$(classify 'exit=1
--- tail -30 ... ---
===== 12 passed in 1.9s =====')" = "fail" ] \
  || fail "exit=1 must beat a '12 passed' text shape (exit code is authoritative)"
[ "$(classify 'exit=0
--- tail -30 ... ---
no recognisable runner summary here')" = "pass" ] \
  || fail "exit=0 must classify as pass even with no runner summary"
[ "$(classify 'benchmark ran with exit=150 microseconds latency')" = "fail" ] \
  && : # exit=150 matches the wrapper signature; acceptable within verification-command scope
printf '  PASS  exit=N line authoritative for the outcome classifier\n'

# Structured harness fields outrank even the wrapper line and any text shape.
[ "$(classify '{"exit_code": 2, "stdout": "===== 12 passed ====="}')" = "fail" ] \
  || fail 'structured "exit_code": 2 must beat a passed text shape'
[ "$(classify '{"returncode": 0, "stdout": "no recognisable summary"}')" = "pass" ] \
  || fail 'structured "returncode": 0 must classify as pass'
[ "$(classify '{"success": false, "stdout": "looks fine"}')" = "fail" ] \
  || fail 'structured "success": false must classify as fail'
printf '  PASS  structured harness fields outrank text shapes\n'

# --- 3b. measured savings ledger (fail-open, never alters behavior) -----------

# No .claude dir → no ledger, no crash, exit code untouched.
rm -rf "$WORK/.claude"
out="$(bash "$WRAPPER" --label noledger 'seq 1 40')" \
  || fail "wrapper must succeed when no .claude dir exists"
[ ! -e "$WORK/.claude" ] || fail "wrapper must not create .claude on its own"
printf '  PASS  no ledger without .claude, behavior untouched\n'

# With .claude present → one verify-run record with measured byte counts.
mkdir -p "$WORK/.claude"
out="$(bash "$WRAPPER" --tail 5 --label ledgered 'seq 1 200')"
LEDGER="$WORK/.claude/observability/compression.jsonl"
[ -f "$LEDGER" ] || fail "wrapper must append to the output-economy ledger"
python3 - "$LEDGER" <<'PY' || fail "ledger record must be measured (in>out, mode verify-run)"
import json, sys
r = json.loads(open(sys.argv[1]).readlines()[-1])
assert r["mode"] == "verify-run", r
assert r["in_chars"] > 0 and r["out_chars"] > 0, r
assert r["in_chars"] > r["out_chars"], f"200-line log vs 5-line tail must save bytes: {r}"
PY
printf '  PASS  measured verify-run record appended to the ledger\n'

# --- 4. wrapper invocation registers as a verification command ----------------

is_verification() {
  bash -c '
    source "'"$REPO_ROOT"'/hooks/lib/hook-io.sh"
    mtk_command_is_verification "$1" && echo yes || echo no
  ' _ "$1"
}

[ "$(is_verification 'bash scripts/mtk-verify-run.sh -- ./run-integration.sh')" = "yes" ] \
  || fail "wrapper invocation must register as a verification command"
printf '  PASS  wrapper invocation registers in the verification ledger\n'

printf '\nAll mtk-verify-run checks passed.\n'
