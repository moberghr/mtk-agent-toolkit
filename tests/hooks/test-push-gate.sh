#!/usr/bin/env bash
set -euo pipefail

# hooks/push-gate.sh — advisory push gate over review receipts (R10, R11).
#
# The mode-gated code is labelled deny:PUSH-UNREVIEWED / allow:PUSH-UNREVIEWED
# so scripts/check-guard-twins.sh pairs it with both a deny and an allow case.
#
# Every case runs in a mktemp -d sandbox: HOME (receipts), TMPDIR (session
# dedup store), CLAUDE_PROJECT_DIR and the git global config point into it.
# The hook only reads command text — no case runs a push; the receipts come
# from scripts/review-receipt.sh against a sandbox clone of a local bare repo.
#
# Text that merely mentions a push (`echo git push`, `grep -r "git push" .`) is
# not an invocation: the hook splits the command into segments and only a
# segment whose command word is git with subcommand push counts, so those pass
# silently.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/hooks/push-gate.sh"
RECEIPT="$REPO_ROOT/scripts/review-receipt.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
mkdir -p "$SANDBOX/home" "$SANDBOX/tmp"
export HOME="$SANDBOX/home"
export TMPDIR="$SANDBOX/tmp"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
export GIT_TERMINAL_PROMPT=0
export GIT_PAGER=cat
cat >"$GIT_CONFIG_GLOBAL" <<'CFG'
[user]
	name = MTK Test
	email = mtk-test@example.invalid
[init]
	defaultBranch = main
[commit]
	gpgsign = false
CFG
unset MTK_PUSH_GATE MTK_PUSH_GATE_ENFORCE CLAUDE_PLUGIN_ROOT 2>/dev/null || true

commit() { # $1 file  $2 content  $3 message
  printf '%s\n' "$2" >"$1"
  git add "$1"
  git commit -q -m "$3"
}

mkdir "$SANDBOX/seed"
cd "$SANDBOX/seed"
git init -q
commit README.md "seed" "seed commit"
git clone -q --bare "$SANDBOX/seed" "$SANDBOX/remote.git"
git clone -q "$SANDBOX/remote.git" "$SANDBOX/work"
WORK="$SANDBOX/work"
export CLAUDE_PROJECT_DIR="$WORK"
cd "$WORK"
git checkout -q -b feature
commit a.txt "alpha" "feat: alpha unreviewed"

fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# payload <command> [session_id] [tool_name] [cwd]
payload() {
  python3 - "$1" "${2:-}" "${3:-Bash}" "${4:-$WORK}" <<'PY'
import json, sys
cmd, sid, tool, cwd = sys.argv[1:5]
p = {"hook_event_name": "PreToolUse", "tool_name": tool, "cwd": cwd,
     "tool_input": {"command": cmd}}
if sid:
    p["session_id"] = sid
print(json.dumps(p))
PY
}

# gate <payload> [VAR=value …]: run the hook; stdout → $OUT, stderr → $ERR,
# exit code echoed. Here-string, not a pipe: the hook may exit before reading.
OUT_F="$SANDBOX/out" ERR_F="$SANDBOX/err"
gate() {
  local p="$1"
  shift
  env ${1+"$@"} "$GATE" <<<"$p" >"$OUT_F" 2>"$ERR_F" && echo 0 || echo $?
}
out() { cat "$OUT_F"; }

# expect <label> <want-exit> <got-exit>. A "deny:<CODE> …" label expecting exit
# 2 also requires <CODE> in the hook's stderr (the deny reason).
expect() {
  local label="$1" want="$2" got="$3" code=""
  case "$label" in deny:*) code="${label#deny:}"; code="${code%% *}" ;; esac
  if [ "$got" != "$want" ]; then
    fail "$label — expected exit $want, got $got (stderr: $(cat "$ERR_F"))"
  elif [ -n "$code" ] && [ "$want" = 2 ] && ! grep -qF -- "$code" "$ERR_F"; then
    fail "$label — denied, but not with $code. Stderr: $(cat "$ERR_F")"
  else
    pass "$label"
  fi
}
# out_has <label> <needle> / out_empty <label>: assertions on the last stdout.
out_has() {
  if grep -qF -- "$2" "$OUT_F"; then pass "$1"; else fail "$1 — stdout lacks [$2]: $(out)"; fi
}
out_empty() {
  if [ ! -s "$OUT_F" ]; then pass "$1"; else fail "$1 — expected no stdout, got: $(out)"; fi
}

SHADOW_LOG="$WORK/.mtk/metrics/enforcement-shadow.jsonl"
shadow_lines() { if [ -f "$SHADOW_LOG" ]; then wc -l <"$SHADOW_LOG" | tr -d ' '; else echo 0; fi; }

# --- No receipt: advisory (default mode) ------------------------------------
expect "no receipt → advisory, allowed" 0 "$(gate "$(payload 'git push' s1)")"
out_has "advisory is additionalContext" '"additionalContext"'
out_has "advisory names the uncovered commit" "feat: alpha unreviewed"
out_has "advisory says how to get a receipt" "code-review-and-quality"
if grep -qF "review-receipt.sh write" "$OUT_F"; then
  fail "advisory must not print the receipt-write command"
else
  pass "advisory does not teach the receipt-write command"
fi

expect "same push again in the same session → allowed" 0 "$(gate "$(payload 'git push' s1)")"
out_empty "second identical push in the same session is deduped"
expect "same push in another session" 0 "$(gate "$(payload 'git push' s2)")"
out_has "another session gets the advisory again" "feat: alpha unreviewed"
expect "no session id (1st)" 0 "$(gate "$(payload 'git push')")"
out_has "no session id → advisory" "additionalContext"
expect "no session id (2nd)" 0 "$(gate "$(payload 'git push')")"
out_has "no session id → advisory every call (nothing to scope dedup to)" "additionalContext"

# Mapped forms are all checked.
n=10
for cmd in 'git push origin' 'git push -u origin feature' 'git push origin HEAD' \
  'git push --set-upstream origin refs/heads/feature' 'git push origin HEAD:feature' \
  'git add a.txt && git push' 'GIT_TRACE=0 git push -q origin feature 2>&1' \
  'git push --force-with-lease origin feature'; do
  n=$((n + 1))
  expect "mapped: $cmd → allowed" 0 "$(gate "$(payload "$cmd" "s$n")")"
  out_has "mapped: $cmd → receipt checked (advisory)" "no review receipt covers"
done

# --- Unmapped targets: one line, allowed, receipt not checked ----------------
for cmd in 'git push origin HEAD:other' 'git push origin other' 'git push origin feature other' \
  'git push --all origin' 'git push --tags' 'git -C /elsewhere push' 'cd sub && git push' \
  'git push --delete origin feature' 'git push origin feature && git push upstream feature'; do
  n=$((n + 1))
  expect "unmapped: $cmd → allowed" 0 "$(gate "$(payload "$cmd" "s$n")")"
  out_has "unmapped: $cmd → not-mapped line" "push target not mapped — receipt not checked"
done
n=$((n + 1))
expect "unmapped in active mode is still allowed" 0 \
  "$(gate "$(payload 'git push origin HEAD:other' "s$n")" MTK_PUSH_GATE_ENFORCE=active)"
out_has "unmapped in active mode → not-mapped line" "push target not mapped"

# --- Not a push: silent ------------------------------------------------------
for cmd in 'ls -la' 'echo git push' 'grep -rn "git push" .' 'git status' 'git log --oneline'; do
  n=$((n + 1))
  expect "not a push: $cmd → allowed" 0 "$(gate "$(payload "$cmd" "s$n")")"
  out_empty "not a push: $cmd → silent"
done
n=$((n + 1))
expect "non-Bash tool → allowed" 0 "$(gate "$(payload 'git push' "s$n" Edit)")"
out_empty "non-Bash tool → silent"
expect "garbage payload → allowed" 0 "$(gate 'not json at all {')"
out_empty "garbage payload → silent"

# --- Kill switch and off -----------------------------------------------------
n=$((n + 1))
expect "MTK_PUSH_GATE=0 → allowed even in active mode" 0 \
  "$(gate "$(payload 'git push' "s$n")" MTK_PUSH_GATE=0 MTK_PUSH_GATE_ENFORCE=active)"
out_empty "MTK_PUSH_GATE=0 → silent"
n=$((n + 1))
expect "MTK_PUSH_GATE_ENFORCE=off → allowed" 0 "$(gate "$(payload 'git push' "s$n")" MTK_PUSH_GATE_ENFORCE=off)"
out_empty "MTK_PUSH_GATE_ENFORCE=off → silent"

# --- Shadow: one log line plus the advisory ---------------------------------
before="$(shadow_lines)"
n=$((n + 1))
expect "shadow without receipt → allowed" 0 "$(gate "$(payload 'git push' "s$n")" MTK_PUSH_GATE_ENFORCE=shadow)"
after="$(shadow_lines)"
[ "$after" = "$((before + 1))" ] && pass "shadow → exactly one enforcement-shadow.jsonl line" \
  || fail "shadow log lines $before → $after"
last="$(tail -n 1 "$SHADOW_LOG" 2>/dev/null || true)"
case "$last" in
  *'"hook":"push-gate"'*'"code":"PUSH-UNREVIEWED"'*) pass "shadow line names push-gate and PUSH-UNREVIEWED" ;;
  *) fail "shadow line: $last" ;;
esac
out_has "shadow → advisory too" "no review receipt covers"

# --- Active: deny without a receipt, allow with one --------------------------
n=$((n + 1))
expect "deny:PUSH-UNREVIEWED active mode, no receipt → exit 2" 2 \
  "$(gate "$(payload 'git push -u origin feature' "s$n")" MTK_PUSH_GATE_ENFORCE=active)"
if grep -qF "MTK_PUSH_GATE_ENFORCE" "$ERR_F" && grep -qF "feat: alpha unreviewed" "$ERR_F"; then
  pass "deny names the uncovered commit and the toggle"
else
  fail "deny text: $(cat "$ERR_F")"
fi

bash "$RECEIPT" write --lanes compliance,test,architecture --rigor HIGH >/dev/null
n=$((n + 1))
expect "allow:PUSH-UNREVIEWED active mode with a receipt → exit 0" 0 \
  "$(gate "$(payload 'git push -u origin feature' "s$n")" MTK_PUSH_GATE_ENFORCE=active)"
out_empty "active with a receipt → silent"

# --- With a receipt: silent ---------------------------------------------------
n=$((n + 1))
expect "receipt covers the range → allowed" 0 "$(gate "$(payload 'git push' "s$n")")"
out_empty "receipt covers the range → silent"

# A new commit is not covered by the old receipt.
commit b.txt "beta" "feat: beta after review"
n=$((n + 1))
expect "commit after the receipt → allowed (advisory)" 0 "$(gate "$(payload 'git push' "s$n")")"
out_has "commit after the receipt → advisory names it" "feat: beta after review"

# --- Fail open ---------------------------------------------------------------
# review-receipt.sh absent: a copy of the hook with no scripts/ beside it.
mkdir -p "$SANDBOX/plugin/hooks"
cp "$GATE" "$SANDBOX/plugin/hooks/"
cp -R "$REPO_ROOT/hooks/lib" "$SANDBOX/plugin/hooks/lib"
n=$((n + 1))
p="$(payload 'git push' "s$n")"
rc=0
MTK_PUSH_GATE_ENFORCE=active "$SANDBOX/plugin/hooks/push-gate.sh" <<<"$p" >"$OUT_F" 2>"$ERR_F" || rc=$?
expect "review-receipt.sh absent → allowed even in active mode" 0 "$rc"
out_empty "review-receipt.sh absent → no model-visible output"
n=$((n + 1))
expect "absent locally, found via CLAUDE_PLUGIN_ROOT → checked" 0 \
  "$(p="$(payload 'git push' "s$n")"; CLAUDE_PLUGIN_ROOT="$REPO_ROOT" "$SANDBOX/plugin/hooks/push-gate.sh" <<<"$p" >"$OUT_F" 2>"$ERR_F" && echo 0 || echo $?)"
out_has "CLAUDE_PLUGIN_ROOT fallback → advisory" "no review receipt covers"

# Receipt check errors (no base: no upstream, no origin/HEAD, no main).
mkdir "$SANDBOX/nobase"
cd "$SANDBOX/nobase"
git init -q -b trunk
commit x.txt "x" "x"
n=$((n + 1))
expect "receipt check error → allowed even in active mode" 0 \
  "$(gate "$(payload 'git push' "s$n" Bash "$SANDBOX/nobase")" MTK_PUSH_GATE_ENFORCE=active CLAUDE_PROJECT_DIR="$SANDBOX/nobase")"
out_has "receipt check error → one note" "receipt not checked"
cd "$WORK"

if [ "$fails" -ne 0 ]; then
  printf '\n%s assertion(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\npush-gate: all assertions passed\n'
