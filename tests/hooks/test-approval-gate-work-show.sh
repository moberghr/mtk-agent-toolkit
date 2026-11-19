#!/usr/bin/env bash
set -euo pipefail

# The approval gate opens the spec beside the terminal with `work show`, best
# effort. This test runs the exact line the gate reference ships (read out of
# .claude/references/implement-approval-gate.md, not a copy) against stub `work`
# commands and checks the promises the reference makes:
#
#   1. No `work` on PATH: exit 0, no output, so the gate asks as before.
#   2. A `work` that fails (an older work without `show`, not a work session,
#      dashboard not running): exit 0, no output, called once (no retry).
#   3. A `work` that has `show`: called once as `work show <spec>.md`, exit 0,
#      no output.
#   4. The line runs before the question is asked, names the spec .md and not
#      the .json sidecar, and the `Show full plan & spec in terminal` option is
#      still offered.
#   5. implement and spec-driven-development point at the step.
#   6. security-gate.sh allows the line, so it is a read-only Bash call the
#      open gate permits.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REF="$REPO_ROOT/.claude/references/implement-approval-gate.md"
IMPLEMENT="$REPO_ROOT/.claude/skills/implement/SKILL.md"
SDD="$REPO_ROOT/.claude/skills/spec-driven-development/SKILL.md"
HOOK="$REPO_ROOT/hooks/security-gate.sh"
BASH_BIN="$(command -v bash)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

SPEC="docs/specs/2026-11-19-example.md"

# --- the shipped line --------------------------------------------------------
LINES="$(grep -c '^command -v work .*work show' "$REF" || true)"
if [ "$LINES" = 1 ]; then
  pass "the reference ships exactly one work show line"
else
  fail "the reference must ship exactly one 'command -v work ... work show' line, found $LINES"
  exit 1
fi
SNIPPET="$(grep '^command -v work .*work show' "$REF")"
case "$SNIPPET" in
  *'"<spec-md-path>"'*) pass "the line takes the spec path as <spec-md-path>" ;;
  *) fail "the line must quote the <spec-md-path> placeholder: $SNIPPET"; exit 1 ;;
esac
CMD="${SNIPPET//<spec-md-path>/$SPEC}"

# run_line <PATH> -> sets RC, OUT, ERR; runs the line with errexit and pipefail
# on, the strictest shell an agent's Bash call could have.
run_line() {
  RC=0
  env PATH="$1" "$BASH_BIN" -c "set -euo pipefail; $CMD" >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"
  ERR="$(cat "$TMP/err")"
}

# make_work <dir> <exit code> -> a stub `work` that logs its arguments, prints
# to both streams (as an older work prints its help) and exits with the code.
make_work() {
  mkdir -p "$1"
  cat >"$1/work" <<EOF
#!$BASH_BIN
printf '%s\n' "\$*" >>"$TMP/calls"
echo "work <command> [options]"
echo "Unknown argument: show" >&2
exit $2
EOF
  chmod +x "$1/work"
}

quiet_ok() { # $1 = case name
  if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
    pass "$1: exit 0, no output"
  else
    fail "$1: want exit 0 and no output, got exit $RC, out: $OUT, err: $ERR"
  fi
}

# --- 1. work not installed ---------------------------------------------------
mkdir -p "$TMP/empty"
rm -f "$TMP/calls"
run_line "$TMP/empty"
quiet_ok "work not installed"

# --- 2. work fails, for each reason it can ------------------------------------
for code in 1 2 127; do
  make_work "$TMP/fail-$code" "$code"
  rm -f "$TMP/calls"
  run_line "$TMP/fail-$code"
  quiet_ok "work exits $code"
  CALLS="$(wc -l <"$TMP/calls" | tr -d ' ')"
  if [ "$CALLS" = 1 ]; then pass "work exits $code: called once, no retry"; else fail "work exits $code: want 1 call, got $CALLS"; fi
done

# --- 3. work has show ---------------------------------------------------------
make_work "$TMP/ok" 0
rm -f "$TMP/calls"
run_line "$TMP/ok"
quiet_ok "work show succeeds"
if [ "$(cat "$TMP/calls")" = "show $SPEC" ]; then
  pass "work is called as: work show <spec>.md"
else
  fail "want 'show $SPEC', got: $(cat "$TMP/calls")"
fi

# --- 4. place in the gate -----------------------------------------------------
LINE_SHOW="$(grep -n '^command -v work .*work show' "$REF" | cut -d: -f1)"
LINE_ASK="$(grep -n '^Then invoke `AskUserQuestion` with:' "$REF" | cut -d: -f1)"
if [ -n "$LINE_ASK" ] && [ "$LINE_SHOW" -lt "$LINE_ASK" ]; then
  pass "the line comes before the question is asked"
else
  fail "the line (line $LINE_SHOW) must come before 'Then invoke \`AskUserQuestion\` with:' (line ${LINE_ASK:-missing})"
fi
case "$SNIPPET" in
  *.json*) fail "the line must not name the .json sidecar: $SNIPPET" ;;
  *) pass "the line does not name the .json sidecar" ;;
esac
if grep -q '^  - `Show full plan & spec in terminal`' "$REF"; then
  pass "the Show full plan & spec in terminal option is still offered"
else
  fail "the 'Show full plan & spec in terminal' option is gone from the gate's options"
fi

# --- 5. the skills point at it ------------------------------------------------
for f in "$IMPLEMENT" "$SDD"; do
  name="$(basename "$(dirname "$f")")"
  if grep -q '`work show`' "$f"; then pass "$name points at the work show step"; else fail "$name does not mention the work show step"; fi
done

# --- 6. the security gate lets it through ------------------------------------
PAYLOAD="$(python3 -c 'import json,sys;print(json.dumps({"session_id":"t","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$CMD")"
RC=0
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO_ROOT" bash "$HOOK" >/dev/null 2>"$TMP/gate.err" || RC=$?
if [ "$RC" = 0 ]; then
  pass "security-gate.sh allows the line"
else
  fail "security-gate.sh must allow the line, exit $RC: $(cat "$TMP/gate.err")"
fi

# --- 7. session-start: the step is offered only in a work session -------------
# Without the WORK SESSION: line the agent makes no call at all, so a session
# without `work` sees no extra Bash call and no permission prompt. PATH keeps
# everything the hook needs, minus any directory holding a real `work`.
SS_HOOK="$REPO_ROOT/hooks/session-start"
NO_WORK_PATH=""
IFS=: read -r -a PATH_DIRS <<<"$PATH"
for d in "${PATH_DIRS[@]}"; do
  [ -n "$d" ] && [ -x "$d/work" ] && continue
  NO_WORK_PATH="${NO_WORK_PATH:+$NO_WORK_PATH:}$d"
done
PROJ="$TMP/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
make_work "$TMP/ss-work" 0

# ss_run <PATH> <WORK_SESSION value or "-" for unset> -> the hook's stdout
ss_run() {
  local ws=(env -u WORK_SESSION)
  [ "$2" = "-" ] || ws=(env WORK_SESSION="$2")
  (cd "$PROJ" && "${ws[@]}" PATH="$1" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$PROJ" \
    bash "$SS_HOOK" <<<'{"hook_event_name":"SessionStart","source":"startup","session_id":"s-work"}' 2>/dev/null || true)
}

case "$(ss_run "$TMP/ss-work:$NO_WORK_PATH" 1)" in
  *'WORK SESSION:'*'work show'*) pass "session-start: WORK_SESSION set and work installed -> WORK SESSION: line" ;;
  *) fail "session-start must emit the WORK SESSION: line when WORK_SESSION is set and work is installed" ;;
esac
case "$(ss_run "$TMP/ss-work:$NO_WORK_PATH" -)" in
  *'WORK SESSION:'*) fail "session-start must not emit the WORK SESSION: line without WORK_SESSION" ;;
  *) pass "session-start: no WORK_SESSION -> no line" ;;
esac
case "$(ss_run "$NO_WORK_PATH" 1)" in
  *'WORK SESSION:'*) fail "session-start must not emit the WORK SESSION: line when work is not installed" ;;
  *) pass "session-start: WORK_SESSION set but no work -> no line" ;;
esac
case "$(ss_run "$TMP/ss-work:$NO_WORK_PATH" "")" in
  *'WORK SESSION:'*) fail "session-start must treat an empty WORK_SESSION as unset" ;;
  *) pass "session-start: empty WORK_SESSION -> no line" ;;
esac

# The gate and both skills condition the step on the marker the hook emits.
for f in "$REF" "$IMPLEMENT" "$SDD"; do
  name="$(basename "$f")"
  [ "$name" = SKILL.md ] && name="$(basename "$(dirname "$f")")"
  if grep -q '`WORK SESSION:`' "$f"; then pass "$name conditions the step on the WORK SESSION: line"; else fail "$name must condition the work show step on the \`WORK SESSION:\` line"; fi
done
if grep -q 'WORK_MSG="WORK SESSION:' "$SS_HOOK"; then
  pass "session-start emits the marker the docs name"
else
  fail "session-start no longer emits a line starting 'WORK SESSION:'"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
