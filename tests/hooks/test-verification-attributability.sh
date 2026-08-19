#!/usr/bin/env bash
set -euo pipefail

# Hermes hardening (round 8, option A): shell operators must not let a
# failing verification stamp the ledger PASS, and a targeted run must never
# satisfy a repo-green claim.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"

TMPDIR_OVERRIDE="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_OVERRIDE"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

attr() { bash -c 'source "'"$REPO_ROOT"'/hooks/lib/hook-io.sh"; mtk_verification_exit_attributable "$1"' _ "$1"; }
scope() { bash -c 'source "'"$REPO_ROOT"'/hooks/lib/hook-io.sh"; mtk_verification_scope "$1"' _ "$1"; }
classify() { bash -c 'source "'"$REPO_ROOT"'/hooks/lib/hook-io.sh"; mtk_classify_verification_outcome "$1" "$2"' _ "$1" "$2"; }

# --- 1. attributability -------------------------------------------------------

[ "$(attr 'pytest tests/')" = "yes" ] || fail "plain command must be attributable"
[ "$(attr 'pytest || true')" = "no" ] || fail "|| must mask attribution"
[ "$(attr 'pytest tests/x.py; echo done')" = "no" ] || fail "; with non-verification tail must mask"
[ "$(attr 'cd /tmp; pytest tests/')" = "yes" ] || fail "; with verification as LAST segment is attributable"
[ "$(attr 'pytest | tee log.txt')" = "no" ] || fail "pipe must mask attribution"
[ "$(attr 'pytest &')" = "no" ] || fail "backgrounding must mask attribution"
[ "$(attr 'pytest > out.log 2>&1')" = "yes" ] || fail "fd redirects (2>&1) are not backgrounding"
[ "$(attr 'npm install && npm test')" = "pass-only" ] || fail "&& chain must be pass-only"
printf '  PASS  attributability: operators classified correctly\n'

# --- 2. classifier honors attributability --------------------------------------

# Masked exit: harness exit_code describes `echo done`, not the failed pytest.
[ "$(classify '{"exit_code": 0, "stdout": "===== 2 failed, 3 passed ====="}' no)" = "fail" ] \
  || fail "masked exit_code 0 must not override failing text"
[ "$(classify '{"exit_code": 0, "stdout": "no recognisable summary"}' no)" = "unknown" ] \
  || fail "masked exit_code 0 with no text evidence must be unknown"
# pass-only: zero exit attributes, non-zero does not.
[ "$(classify '{"exit_code": 0, "stdout": "x"}' pass-only)" = "pass" ] \
  || fail "pass-only must honor exit 0"
[ "$(classify '{"exit_code": 2, "stdout": "===== 5 passed ====="}' pass-only)" = "pass" ] \
  || fail "pass-only nonzero exit may be an earlier link — text (5 passed) decides"
# unchanged default behavior
[ "$(classify '{"exit_code": 2, "stdout": "===== 5 passed ====="}' yes)" = "fail" ] \
  || fail "attributable nonzero exit still beats passing text"
printf '  PASS  classifier gates exit tiers on attributability\n'

# --- 3. ledger end-to-end: || true no longer stamps PASS -----------------------

SESSION_FILE="$(TMPDIR="$TMPDIR_OVERRIDE" bash -c '
  source "'"$REPO_ROOT"'/hooks/lib/hook-io.sh"
  mtk_session_file
')"
post() {
  python3 - "$1" "$2" <<'PY' | TMPDIR="$TMPDIR_OVERRIDE" bash "$REPO_ROOT/hooks/context-budget.sh" >/dev/null 2>&1 || true
import json, sys
print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash",
    "tool_input": {"command": sys.argv[1]},
    "tool_response": {"stdout": sys.argv[2], "stderr": "", "exit_code": 0}}))
PY
}
read_field() { ( . "$SESSION_FILE" && eval "printf '%s' \"\${$1:-missing}\"" ); }

rm -f "$SESSION_FILE"
post 'pytest tests/ || true' '===== 3 failed, 9 passed in 2.1s ====='
[ "$(read_field last_verification_status)" = "fail" ] \
  || fail "pytest || true with failing output must record fail (got: $(read_field last_verification_status))"
printf '  PASS  || true no longer stamps the ledger PASS\n'

post 'pytest tests/test_x.py' '===== 4 passed ====='
[ "$(read_field last_verification_scope)" = "targeted" ] \
  || fail "single-file run must record scope=targeted (got: $(read_field last_verification_scope))"
post 'pytest' '===== 44 passed ====='
[ "$(read_field last_verification_scope)" = "full" ] \
  || fail "bare runner must record scope=full (got: $(read_field last_verification_scope))"
printf '  PASS  ledger records verification scope\n'

# --- 4. scope heuristics --------------------------------------------------------

[ "$(scope 'pytest')" = "full" ] || fail "bare pytest is full"
[ "$(scope 'pytest tests/test_auth.py::test_login')" = "targeted" ] || fail ":: node id is targeted"
[ "$(scope 'dotnet test --filter FooTests')" = "targeted" ] || fail "--filter is targeted"
[ "$(scope 'pytest -k login')" = "targeted" ] || fail "-k is targeted"
[ "$(scope 'go test ./...')" = "full" ] || fail "go ./... is the whole module — full"
[ "$(scope 'bash scripts/validate-toolkit.sh')" = "full" ] || fail "runner path itself must not read as targeted"
[ "$(scope 'npm test')" = "full" ] || fail "npm test is full"
printf '  PASS  scope heuristics (incl. runner-path and ./... exceptions)\n'

# --- 5. verify-completion: targeted evidence cannot back an ALL-green claim ----

HOOK="$REPO_ROOT/hooks/verify-completion"
write_state() { # $1 status, $2 scope
  cat > "$SESSION_FILE" <<EOF
event_seq=5
last_edit_seq=3
last_verification_epoch=900
last_verification_seq=5
last_verification_command='pytest tests/test_x.py'
last_verification_status='$1'
last_verification_scope='$2'
EOF
}
run_stop() {
  python3 - "$1" <<'PY' | TMPDIR="$TMPDIR_OVERRIDE" bash "$HOOK" 2>&1 || true
import json, sys
print(json.dumps({"hook_event_name": "Stop", "last_assistant_message": sys.argv[1],
                  "stop_hook_active": False}))
PY
}

write_state pass targeted
out="$(run_stop 'All done. All tests pass — exit code 0.')"
case "$out" in *'TARGETED'*) : ;; *) fail "ALL-green claim over targeted evidence must block. Got: $out" ;; esac
printf '  PASS  all-green claim over targeted run blocks once\n'

write_state pass targeted
out="$(run_stop 'Task complete. Tests: 4 passed for the changed module, exit code 0.')"
[ -z "$out" ] || fail "honest targeted claim must not block. Got: $out"
printf '  PASS  honest targeted claim stays quiet\n'

write_state pass full
out="$(run_stop 'All done. All tests pass — 44 passed, exit code 0.')"
[ -z "$out" ] || fail "all-green claim over FULL run must not block. Got: $out"
printf '  PASS  all-green claim over full run stays quiet\n'

printf '\nAll verification-attributability checks passed.\n'
