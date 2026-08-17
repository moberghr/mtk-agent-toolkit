#!/usr/bin/env bash
set -euo pipefail

# Outcome-aware verification ledger: a verification that RAN is not a
# verification that PASSED. context-budget.sh classifies the tool_response of
# a verification command as pass|fail|unknown, and verify-completion blocks a
# strong completion claim when the latest verification was observed failing.
# `unknown` never blocks (fail-open on ambiguity).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"

TMPDIR_OVERRIDE="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_OVERRIDE"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- Part 1: classifier unit checks -----------------------------------------

classify() {
  bash -c '
    source "'"$REPO_ROOT"'/hooks/lib/hook-io.sh"
    mtk_classify_verification_outcome "$1"
  ' _ "$1"
}

[ "$(classify '{"stdout":"===== 2 failed, 10 passed in 1.2s ====="}')" = "fail" ] \
  || fail "pytest '2 failed, 10 passed' must classify as fail (fail beats pass)"
[ "$(classify '{"stdout":"===== 12 passed in 0.8s ====="}')" = "pass" ] \
  || fail "pytest '12 passed' must classify as pass"
[ "$(classify '{"stdout":"Build FAILED. 3 Warning(s) 2 Error(s)"}')" = "fail" ] \
  || fail "dotnet 'Build FAILED' must classify as fail"
[ "$(classify '{"stdout":"Build succeeded.\n    0 Warning(s)"}')" = "pass" ] \
  || fail "dotnet 'Build succeeded' must classify as pass"
[ "$(classify '{"stdout":"Program.cs(12,4): error CS1002: ; expected"}')" = "fail" ] \
  || fail "dotnet compile error CSnnnn must classify as fail"
[ "$(classify '{"stdout":"FAIL src/cart.test.ts\nTests: 1 failed, 4 passed"}')" = "fail" ] \
  || fail "jest FAIL header must classify as fail"
[ "$(classify '{"stdout":"XFAIL test_legacy_path — expected failure"}')" = "unknown" ] \
  || fail "XFAIL alone must NOT classify as fail (word-boundary check)"
[ "$(classify '{"stdout":"Toolkit validation passed"}')" = "pass" ] \
  || fail "'Toolkit validation passed' must classify as pass"
[ "$(classify '{"stdout":"some unrecognised runner output"}')" = "unknown" ] \
  || fail "unrecognised output must classify as unknown"
[ "$(classify '')" = "unknown" ] \
  || fail "empty output must classify as unknown"
printf '  PASS  classifier: pass/fail/unknown shapes\n'

# --- Part 2: context-budget.sh records the outcome column --------------------

SESSION_FILE="$(TMPDIR="$TMPDIR_OVERRIDE" bash -c '
  source "'"$REPO_ROOT"'/hooks/lib/hook-io.sh"
  mtk_session_file
')"

post_tool_use() {
  # $1 = command, $2 = stdout text placed in tool_response
  python3 - "$1" "$2" <<'PY' | TMPDIR="$TMPDIR_OVERRIDE" bash "$REPO_ROOT/hooks/context-budget.sh" >/dev/null 2>&1 || true
import json, sys
print(json.dumps({
    "hook_event_name": "PostToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[1]},
    "tool_response": {"stdout": sys.argv[2], "stderr": ""},
}))
PY
}

read_status() {
  # shellcheck disable=SC1090
  ( . "$SESSION_FILE" && printf '%s' "${last_verification_status:-missing}" )
}

rm -f "$SESSION_FILE"
post_tool_use "pytest tests/" "===== 3 failed, 9 passed in 2.1s ====="
[ "$(read_status)" = "fail" ] \
  || fail "failing pytest run must record last_verification_status=fail (got: $(read_status))"
printf '  PASS  context-budget records fail outcome\n'

post_tool_use "git status" "on branch main — 2 failed experiments mentioned in a commit message"
[ "$(read_status)" = "fail" ] \
  || fail "non-verification command must not touch the outcome column (got: $(read_status))"
printf '  PASS  non-verification command leaves outcome untouched\n'

post_tool_use "pytest tests/" "===== 12 passed in 1.9s ====="
[ "$(read_status)" = "pass" ] \
  || fail "passing pytest re-run must overwrite the outcome to pass (got: $(read_status))"
printf '  PASS  passing re-run overwrites outcome\n'

# Outcome markers inside the COMMAND text must not classify the run: the
# payload is sliced at tool_response before classification.
post_tool_use "pytest tests/ -k 'not FAIL_marker'" "output with no recognisable summary"
[ "$(read_status)" = "unknown" ] \
  || fail "FAIL marker in tool_input must not classify the run (got: $(read_status))"
printf '  PASS  markers in the command text do not classify\n'

# --- Part 3: verify-completion blocks on an observed-failing verification ----

HOOK="$REPO_ROOT/hooks/verify-completion"

write_state() {
  # $1 = last_verification_status
  cat > "$SESSION_FILE" <<EOF
event_seq=5
last_edit_seq=3
last_verification_epoch=900
last_verification_seq=5
last_verification_command='pytest tests/'
last_verification_status='$1'
EOF
}

run_stop_hook() {
  local msg="$1"
  python3 - "$msg" <<'PY' | TMPDIR="$TMPDIR_OVERRIDE" bash "$HOOK" 2>&1 || true
import json, sys
print(json.dumps({"hook_event_name": "Stop", "last_assistant_message": sys.argv[1],
                  "stop_hook_active": False}))
PY
}

write_state fail
out="$(run_stop_hook 'All done. Task complete. Tests: 3 failed, 9 passed.')"
echo "$out" | grep -q 'observed FAILING' \
  || fail "completion claim over a failing verification must emit the outcome gap. Got: $out"
echo "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' \
  || fail "outcome gap must be a decision:block Stop envelope. Got: $out"
printf '  PASS  completion claim over failing verification blocks\n'

write_state pass
out="$(run_stop_hook 'All done. Task complete. Tests: 12 passed, exit code 0.')"
[ -z "$out" ] || fail "passing verification + cited evidence must not block. Got: $out"
printf '  PASS  passing verification does not block\n'

write_state unknown
out="$(run_stop_hook 'All done. Task complete. Tests: 12 passed, exit code 0.')"
[ -z "$out" ] || fail "unknown outcome must fail open (never block). Got: $out"
printf '  PASS  unknown outcome fails open\n'

printf '\nAll verification-outcome checks passed.\n'
