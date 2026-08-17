#!/usr/bin/env bash
set -euo pipefail

# Deny ergonomics: every hard deny (exit 2) carries the continuation suffix
# (batched calls cancelled + a denial is a correction, not a stop signal +
# anti-cascade) and, where a self-service off-switch exists, a toggle hint.
# Guards without a self-service switch (security-gate, read-guard) must NOT
# teach one. Allowed calls carry no suffix.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"
export CLAUDE_PROJECT_DIR="$REPO_ROOT"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SUFFIX_MARK='batched with it were CANCELLED'
CASCADE_MARK='past verdicts about those calls'

bash_payload() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[1]}}))
PY
}

run_hook() {
  # $1 = hook, $2 = payload; echoes "rc<TAB>stderr"
  local rc=0 err
  err="$(printf '%s' "$2" | bash "hooks/$1" 2>&1 >/dev/null)" || rc=$?
  printf '%s\t%s' "$rc" "$err"
}

check() {
  # $1 label, $2 rc+err, $3 want_rc, $4 must-contain, $5 must-NOT-contain
  local rc="${2%%	*}" err="${2#*	}"
  [ "$rc" = "$3" ] || fail "$1: want exit $3, got $rc. Stderr: $err"
  if [ -n "$4" ]; then
    case "$err" in *"$4"*) : ;; *) fail "$1: stderr missing '$4'. Got: $err" ;; esac
  fi
  if [ -n "$5" ]; then
    case "$err" in *"$5"*) fail "$1: stderr must NOT contain '$5'. Got: $err" ;; esac
  fi
}

# --- security-gate: deny carries suffix, no toggle hint -----------------------

out="$(run_hook security-gate.sh "$(bash_payload 'rm -rf /')")"
check "security-gate deny" "$out" 2 "$SUFFIX_MARK" "disable this guard"
out="$(run_hook security-gate.sh "$(bash_payload 'rm -rf /')")"
check "security-gate anti-cascade" "$out" 2 "$CASCADE_MARK" ""
printf '  PASS  security-gate: suffix + anti-cascade, no toggle taught\n'

out="$(run_hook security-gate.sh "$(bash_payload 'git status')")"
check "security-gate allow" "$out" 0 "" "$SUFFIX_MARK"
printf '  PASS  security-gate: allowed call carries no suffix\n'

# --- interactive-guard: deny carries suffix + its toggle ----------------------

out="$(run_hook interactive-guard.sh "$(bash_payload 'gh pr merge 5 --squash')")"
check "interactive-guard deny" "$out" 2 "$SUFFIX_MARK" ""
check "interactive-guard toggle" "$out" 2 "disable this guard: MTK_INTERACTIVE_GUARD=0" ""
printf '  PASS  interactive-guard: suffix + toggle hint\n'

# --- read-guard: deny carries suffix but must NOT teach a toggle --------------

edit_payload="$(python3 - <<PY
import json
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Read",
                  "tool_input": {"file_path": "$REPO_ROOT/.env"}}))
PY
)"
rc=0
err="$(printf '%s' "$edit_payload" | bash hooks/read-guard.sh 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "read-guard must deny a .env read (got $rc). Stderr: $err"
case "$err" in *"$SUFFIX_MARK"*) : ;; *) fail "read-guard deny missing suffix. Got: $err" ;; esac
case "$err" in *"disable this guard"*) fail "read-guard must not teach a self-service toggle. Got: $err" ;; esac
printf '  PASS  read-guard: suffix present, off-switch not taught\n'

# --- mtk_deny sanitizes and caps reasons that echo tool input ------------------

rc=0
err="$( (source hooks/lib/hook-io.sh; mtk_deny "$(printf 'bad \033[31mANSI\033[0m text')" "") 2>&1 )" || rc=$?
[ "$rc" -eq 2 ] || fail "mtk_deny must exit 2 (got $rc)"
case "$err" in *$'\033'*) fail "mtk_deny must strip ESC/control bytes from the reason" ;; esac
case "$err" in *"bad "*"ANSI"*) : ;; *) fail "sanitized reason must keep the text. Got: $err" ;; esac
printf '  PASS  mtk_deny strips control bytes from echoed input\n'

big="$(printf 'x%.0s' $(seq 1 500))"
err="$( (source hooks/lib/hook-io.sh; MTK_DENY_MAX_CHARS=100 mtk_deny "$big" "") 2>&1 || true)"
reason_line="$(printf '%s\n' "$err" | head -1)"
[ "${#reason_line}" -le 100 ] || fail "mtk_deny must cap the reason at MTK_DENY_MAX_CHARS (got ${#reason_line})"
printf '  PASS  mtk_deny caps oversized reasons\n'

printf '\nAll deny-ergonomics checks passed.\n'
