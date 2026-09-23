#!/usr/bin/env bash
set -euo pipefail

# fact-force-guard.sh nudges once before the first Edit/Write of an existing in-repo code
# file whose stem no search this session mentioned (SC4), and under
# MTK_FACT_FORCE_ENFORCE=1 denies once with a retry that passes (SC5).
#
# Sandbox: TMPDIR points at a mktemp -d (session state never leaks into the real session
# or between cases), and the "project" is a real mktemp -d git repo with real files, so
# the guard's exists / in-repo checks run against genuine paths.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$REPO_ROOT/hooks/fact-force-guard.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
PROJ="$SANDBOX/proj"
OUTSIDE="$SANDBOX/outside"
mkdir -p "$PROJ/src" "$PROJ/tests" "$PROJ/docs" "$PROJ/.mtk" "$OUTSIDE"
git -C "$PROJ" init -q
PROJ="$(cd "$PROJ" && pwd -P)"
OUTSIDE="$(cd "$OUTSIDE" && pwd -P)"
for f in src/OrderService.cs src/billing.py src/Invoice.ts src/deploy.sh src/Ab.cs \
  src/FooTests.cs tests/test_x.py docs/x.md src/Aaa1.cs src/Aaa2.cs src/Aaa3.cs \
  src/Aaa4.cs src/Aaa5.cs src/Aaa6.cs src/Ledger.cs src/Account.cs; do
  printf 'x\n' >"$PROJ/$f"
done
printf 'x\n' >"$OUTSIDE/Outside.cs"

fails=0
CASE_N=0

# Fresh TMPDIR per case so state is isolated unless a case deliberately shares it.
new_state() {
  CASE_N=$((CASE_N + 1))
  STATE="$SANDBOX/tmp-$CASE_N"
  mkdir -p "$STATE"
}

# run_hook <payload> [ENV=VAL ...] — sets GOT (exit), OUT (stdout), ERR (stderr).
run_hook() {
  local payload="$1"; shift
  local rc=0
  # shellcheck disable=SC2016  # $0/$CLAUDE_PROJECT_DIR expand in the child shell, by design
  printf '%s' "$payload" | env TMPDIR="$STATE" CLAUDE_PROJECT_DIR="$PROJ" "$@" \
    bash -c 'cd "$CLAUDE_PROJECT_DIR" && exec "$0"' "$GUARD" \
    >"$SANDBOX/out" 2>"$SANDBOX/err" || rc=$?
  GOT="$rc"
  OUT="$(cat "$SANDBOX/out")"
  ERR="$(cat "$SANDBOX/err")"
}

pre_edit() { # <abs path> [session_id]
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' \
    "${2:-sess-1}" "$1"
}
pre_write() {
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"b"}}' \
    "${2:-sess-1}" "$1"
}
post_grep() { # <pattern> [session]
  printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Grep","tool_input":{"pattern":"%s","path":"src"},"tool_response":{}}' \
    "${2:-sess-1}" "$1"
}
post_glob() {
  printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Glob","tool_input":{"pattern":"%s"},"tool_response":{}}' \
    "${2:-sess-1}" "$1"
}
post_bash() { # <json-escaped command> [session]
  printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{}}' \
    "${2:-sess-1}" "$1"
}

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# expect_advisory <label> — exit 0 and an additionalContext FACT-FORCE nudge.
expect_advisory() {
  if [ "$GOT" = "0" ] && has "$OUT" '"additionalContext"' && has "$OUT" 'FACT-FORCE' \
    && has "$OUT" '"hookEventName":"PreToolUse"'; then
    pass "$1"
  else
    fail "$1 — expected advisory (exit 0 + FACT-FORCE context), got exit=$GOT out=[$OUT] err=[$ERR]"
  fi
}
# expect_silent <label> — exit 0 and no output at all.
expect_silent() {
  if [ "$GOT" = "0" ] && [ -z "$OUT" ]; then
    pass "$1"
  else
    fail "$1 — expected silent exit 0, got exit=$GOT out=[$OUT] err=[$ERR]"
  fi
}

# --- SC4: advisory once, then silent ------------------------------------------
new_state
run_hook "$(pre_edit "$PROJ/src/OrderService.cs")"
expect_advisory "first Edit of existing .cs with no search → advisory"
if has "$OUT" 'src/OrderService.cs' && has "$OUT" 'grep -rn' && has "$OUT" 'orderservice'; then
  pass "advisory names the repo-relative file, the stem and the grep to run"
else
  fail "advisory text missing file/stem/grep: [$OUT]"
fi
run_hook "$(pre_edit "$PROJ/src/OrderService.cs")"
expect_silent "second Edit of the same file → silent"

# Every covered sample extension nudges on first edit (.py/.ts/.sh), via Write too.
new_state
run_hook "$(pre_edit "$PROJ/src/billing.py")"
expect_advisory "first Edit of .py → advisory"
run_hook "$(pre_write "$PROJ/src/Invoice.ts")"
expect_advisory "first Write of existing .ts → advisory"
run_hook "$(pre_edit "$PROJ/src/deploy.sh")"
expect_advisory "first Edit of .sh → advisory"

# --- SC4: evidence from searches ----------------------------------------------
new_state
run_hook "$(post_grep 'OrderService')"
expect_silent "Grep PostToolUse record emits nothing"
run_hook "$(pre_edit "$PROJ/src/OrderService.cs")"
expect_silent "Edit after Grep mentioning the stem (case-insensitive) → silent"

new_state
run_hook "$(post_glob '**/Invoice*.ts')"
run_hook "$(pre_edit "$PROJ/src/Invoice.ts")"
expect_silent "Edit after Glob mentioning the stem → silent"

new_state
run_hook "$(post_bash 'rg Billing src/')"
run_hook "$(pre_edit "$PROJ/src/billing.py")"
expect_silent "Edit after Bash 'rg Billing' → silent"

new_state
run_hook "$(post_bash 'cd src && grep -rn \"OrderService\" .')"
run_hook "$(pre_edit "$PROJ/src/OrderService.cs")"
expect_silent "Edit after Bash 'cd && grep' (command position after &&) → silent"

new_state
run_hook "$(post_bash 'git log -SLedger --oneline')"
run_hook "$(pre_edit "$PROJ/src/Ledger.cs")"
expect_silent "Edit after Bash 'git log -S<stem>' → silent"

new_state
run_hook "$(post_bash 'echo orderservice')"
run_hook "$(pre_edit "$PROJ/src/OrderService.cs")"
expect_advisory "Bash 'echo <stem>' is NOT recorded → still advisory"

new_state
run_hook "$(post_bash 'echo \"grep account\" > notes.txt')"
run_hook "$(pre_edit "$PROJ/src/Account.cs")"
expect_advisory "grep inside an echo string is not at command position → not recorded"

# --- SC4: exemptions ----------------------------------------------------------
new_state
run_hook "$(pre_write "$PROJ/src/BrandNew.cs")"
expect_silent "Write of a new (missing) file → silent"
run_hook "$(pre_edit "$PROJ/docs/x.md")"
expect_silent "docs/x.md → silent"
run_hook "$(pre_edit "$PROJ/tests/test_x.py")"
expect_silent "tests/test_x.py → silent"
run_hook "$(pre_edit "$PROJ/src/FooTests.cs")"
expect_silent "FooTests.cs → silent"
run_hook "$(pre_edit "$OUTSIDE/Outside.cs")"
expect_silent "path outside the repo → silent"
run_hook "$(pre_edit "$PROJ/src/Ab.cs")"
expect_silent "stem shorter than 3 chars → silent"
run_hook "$(pre_edit "$PROJ/src/OrderService.cs")" MTK_FACT_FORCE=0
expect_silent "MTK_FACT_FORCE=0 → silent"
# The kill-switch case must not have consumed the file's one nudge.
run_hook "$(pre_edit "$PROJ/src/OrderService.cs")"
expect_advisory "after kill-switched call, the file still gets its first nudge"

# --- Fail open ----------------------------------------------------------------
new_state
run_hook ''
expect_silent "empty payload → silent"
run_hook 'not json at all'
expect_silent "garbage payload → silent"
run_hook '{"tool_name":"Edit","tool_input":{"file_path":"'"$PROJ"'/src/OrderService.cs"}}'
expect_silent "payload without hook_event_name → silent"
run_hook '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$PROJ"'/src/OrderService.cs"}}'
expect_silent "PreToolUse for a non-Edit/Write tool → silent"

# --- Nudge cap ----------------------------------------------------------------
new_state
for i in 1 2 3 4 5; do
  run_hook "$(pre_edit "$PROJ/src/Aaa$i.cs")"
  expect_advisory "cap 5: distinct file $i → advisory"
done
run_hook "$(pre_edit "$PROJ/src/Aaa6.cs")"
expect_silent "cap 5: 6th distinct file → silent"

new_state
run_hook "$(pre_edit "$PROJ/src/Aaa1.cs")" MTK_FACT_FORCE_MAX_NUDGES=1
expect_advisory "cap 1: first file → advisory"
run_hook "$(pre_edit "$PROJ/src/Aaa2.cs")" MTK_FACT_FORCE_MAX_NUDGES=1
expect_silent "cap 1: second file → silent"

# --- SC5: enforce is a one-time deny ------------------------------------------
new_state
run_hook "$(pre_edit "$PROJ/src/OrderService.cs")" MTK_FACT_FORCE_ENFORCE=1
if [ "$GOT" = "2" ] && has "$ERR" 'FACT-FORCE' && has "$ERR" 'This denial applies to THIS call only' \
  && has "$ERR" 'disable this guard: MTK_FACT_FORCE_ENFORCE=0'; then
  pass "enforce: first edit exits 2 with deny suffix and toggle hint"
else
  fail "enforce: expected exit 2 + suffix + toggle, got exit=$GOT err=[$ERR]"
fi
run_hook "$(pre_edit "$PROJ/src/OrderService.cs")" MTK_FACT_FORCE_ENFORCE=1
expect_silent "enforce: retry of the same file exits 0 (never looped)"

new_state
run_hook "$(post_grep 'orderservice')"
run_hook "$(pre_edit "$PROJ/src/OrderService.cs")" MTK_FACT_FORCE_ENFORCE=1
expect_silent "enforce: with search evidence → allowed"

# --- Independent sessions -----------------------------------------------------
new_state
run_hook "$(pre_edit "$PROJ/src/OrderService.cs" sess-A)"
expect_advisory "session A: first edit → advisory"
run_hook "$(pre_edit "$PROJ/src/OrderService.cs" sess-B)"
expect_advisory "session B: same file is a first edit in its own session → advisory"
run_hook "$(post_grep 'account' sess-A)"
run_hook "$(pre_edit "$PROJ/src/Account.cs" sess-B)"
expect_advisory "session A's search is not evidence for session B"
run_hook "$(pre_edit "$PROJ/src/Account.cs" sess-A)"
expect_silent "session A's search is evidence for session A"
# session_id is sanitized before it becomes part of a state path.
run_hook "$(pre_edit "$PROJ/src/Ledger.cs" '../../evil')"
expect_advisory "path-like session_id is sanitized and still works"
state_escape="$(find "$SANDBOX" -maxdepth 1 -name 'mtk-factforce-*' 2>/dev/null)"
if [ -z "$state_escape" ]; then
  pass "sanitized session_id keeps state files inside TMPDIR"
else
  fail "state file escaped TMPDIR: $state_escape"
fi

# --- SF2: unwritable state never silences the guard, never loops a deny --------
if [ "$(id -u)" != "0" ]; then
  new_state
  chmod 500 "$STATE"
  run_hook "$(pre_edit "$PROJ/src/OrderService.cs")"
  expect_advisory "unwritable TMPDIR: advisory still emitted"
  if has "$OUT" 'fact-force state unwritable' && has "$OUT" 'this nudge may repeat'; then
    pass "unwritable TMPDIR: advisory carries the state-unwritable note"
  else
    fail "unwritable TMPDIR: advisory missing the state-unwritable note: [$OUT]"
  fi
  run_hook "$(pre_edit "$PROJ/src/OrderService.cs")" MTK_FACT_FORCE_ENFORCE=1
  expect_advisory "unwritable TMPDIR + enforce: downgraded to advisory (exit 0, not silent)"
  if has "$OUT" 'fact-force state unwritable'; then
    pass "unwritable TMPDIR + enforce: advisory carries the note"
  else
    fail "unwritable TMPDIR + enforce: note missing: [$OUT] err=[$ERR]"
  fi
  chmod 700 "$STATE"
else
  printf '  SKIP  unwritable-TMPDIR cases (running as root)\n'
fi

# --- T4: wiring (hooks.json + .claude/settings.json) --------------------------
# Parsed as JSON, exact event key + matcher: a typo'd event key must fail this.
if command -v python3 >/dev/null 2>&1; then
  wiring() { # $1=file $2=event $3=matcher $4=hook basename
    python3 - "$@" <<'PY'
import json, sys
path, event, matcher, base = sys.argv[1:5]
try:
    hooks = json.load(open(path)).get("hooks", {})
except (OSError, ValueError) as exc:
    print("unparseable: %s" % exc); sys.exit(0)
for m in hooks.get(event, []) or []:
    if (m.get("matcher") or "") == matcher and any(
            h.get("command", "").rstrip().endswith("/hooks/" + base) for h in m.get("hooks", []) or []):
        print("wired"); sys.exit(0)
print("missing")
PY
  }
  for wf in hooks/hooks.json .claude/settings.json; do
    for ev_m in "PreToolUse|Edit|Write" "PostToolUse|Grep|Glob|Bash"; do
      ev="${ev_m%%|*}"; mt="${ev_m#*|}"
      got="$(wiring "$REPO_ROOT/$wf" "$ev" "$mt" fact-force-guard.sh)"
      if [ "$got" = "wired" ]; then
        pass "$wf wires fact-force-guard.sh under $ev \"$mt\""
      else
        fail "$wf: fact-force-guard.sh not wired under $ev \"$mt\" ($got)"
      fi
    done
  done
else
  printf '  SKIP  wiring assertions (python3 not available)\n'
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%s assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nfact-force-guard: all assertions passed\n'
