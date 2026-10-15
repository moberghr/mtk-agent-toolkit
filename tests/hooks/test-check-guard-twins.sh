#!/usr/bin/env bash
set -euo pipefail

# scripts/check-guard-twins.sh: every code a hook passes to mtk_deny_gated
# needs an `expect "deny:<code> …"` AND an `expect "allow:<code> …"` call in
# tests/hooks/test-*.sh. Comments, near-miss codes and non-literal codes never
# satisfy it. Each case builds a throwaway fixture tree under a mktemp -d.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$REPO_ROOT/scripts/check-guard-twins.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"

fails=0
expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected %s, got %s\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  else
    printf '  PASS  %s\n' "$label"
  fi
}

n=0
fixture() { # $1 = hook body, $2 = test body; prints the fixture root
  n=$((n + 1))
  local root="$SANDBOX/fx$n"
  mkdir -p "$root/hooks" "$root/tests/hooks"
  printf '%s\n' "$1" > "$root/hooks/fx-guard.sh"
  printf '%s\n' "$2" > "$root/tests/hooks/test-fx-guard.sh"
  printf '%s' "$root"
}
check_rc() { # $1 root — exit code of the checker
  local rc=0
  bash "$CHECK" --root "$1" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

HOOK_ONE='#!/usr/bin/env bash
set -euo pipefail
MODE="$(mtk_guard_mode FX advisory)"
mtk_deny_gated "$MODE" fx-guard FX-CODE "reason" "toggle" "$FILE"'

DENY_ONLY='expect "deny:FX-CODE out-of-scope write denies" 2 "$(run_guard a)"'
COMMENT_ALLOW='# expect "allow:FX-CODE in-scope write passes" 0 "$(run_guard b)"
# allow:FX-CODE is covered elsewhere'

r="$(fixture "$HOOK_ONE" "$DENY_ONLY
$COMMENT_ALLOW")"
expect "only a comment mentions allow:<code> → exit 1" 1 "$(check_rc "$r")"
msg="$(bash "$CHECK" --root "$r" 2>&1 >/dev/null || true)"
case "$msg" in *"allow twin for FX-CODE"*) a=named ;; *) a="$msg" ;; esac
expect "missing twin is named in the report" named "$a"

r="$(fixture "$HOOK_ONE" "$DENY_ONLY
expect \"allow:FX-CODE in-scope write passes\" 0 \"\$(run_guard b)\"")"
expect "deny and allow labelled expect calls → exit 0" 0 "$(check_rc "$r")"

r="$(fixture "$HOOK_ONE" "  expect 'deny:FX-CODE single-quoted, indented' 2 x
	expect 'allow:FX-CODE tab-indented' 0 y")"
expect "single-quoted, indented labels count" 0 "$(check_rc "$r")"

r="$(fixture "$HOOK_ONE" "expect \"allow:FX-CODE passes\" 0 x")"
expect "allow without deny → exit 1" 1 "$(check_rc "$r")"

r="$(fixture "$HOOK_ONE" "$DENY_ONLY
expect \"allow:FX-CODE-2 near-miss code\" 0 x")"
expect "near-miss code allow:<code>-2 does not count → exit 1" 1 "$(check_rc "$r")"

r="$(fixture "$HOOK_ONE" "$DENY_ONLY
echo expect \"allow:FX-CODE not a call\"
pass \"allow:FX-CODE a different helper\"")"
expect "labels outside an expect call do not count → exit 1" 1 "$(check_rc "$r")"

r="$(fixture '#!/usr/bin/env bash
# mtk_deny_gated "$MODE" fx-guard FX-COMMENTED "a commented-out call"
mtk_deny "plain floor deny" ""' "")"
expect "commented-out call and plain mtk_deny are not collected → exit 0" 0 "$(check_rc "$r")"

r="$(fixture '#!/usr/bin/env bash
mtk_deny_gated "$MODE" fx-guard \
  FX-SPLIT "reason across lines"' "expect \"deny:FX-SPLIT d\" 2 x")"
expect "call split by a backslash continuation is collected → exit 1 without allow" 1 "$(check_rc "$r")"
msg="$(bash "$CHECK" --root "$r" 2>&1 >/dev/null || true)"
case "$msg" in *"allow twin for FX-SPLIT (hooks/fx-guard.sh:2)"*) a=ok ;; *) a="$msg" ;; esac
expect "split call reports its code and the line the call starts on" ok "$a"

r="$(fixture '#!/usr/bin/env bash
mtk_deny_gated "$MODE" fx-guard "$CODE" "dynamic code"' "")"
expect "non-literal code → exit 1" 1 "$(check_rc "$r")"

r="$(fixture '#!/usr/bin/env bash
mtk_deny_gated "$MODE" fx-guard FX-A "a"
mtk_deny_gated "$MODE" fx-guard FX-B "b"' 'expect "deny:FX-A" 2 x
expect "allow:FX-A" 0 x
expect "deny:FX-B" 2 x')"
expect "one twinned and one untwinned code → exit 1" 1 "$(check_rc "$r")"
msg="$(bash "$CHECK" --root "$r" 2>&1 >/dev/null || true)"
case "$msg" in *"FX-A"*) a="FX-A wrongly reported" ;; *"allow twin for FX-B"*) a=ok ;; *) a="$msg" ;; esac
expect "only the untwinned code is reported" ok "$a"

r="$(fixture '#!/usr/bin/env bash
true' "")"
expect "no gated codes at all → exit 0" 0 "$(check_rc "$r")"

# Parser self-check: calls the code parser cannot read (bare name at end of
# line, name followed by `;`) yield 0 codes; that must fail, not pass as
# "0 codes, all twinned".
r="$(fixture '#!/usr/bin/env bash
[ -n "$X" ] && mtk_deny_gated
mtk_deny_gated;' "")"
expect "0 codes parsed but mtk_deny_gated is called → exit 1" 1 "$(check_rc "$r")"
msg="$(bash "$CHECK" --root "$r" 2>&1 >/dev/null || true)"
case "$msg" in *"parsed 0 codes but 2 hook line(s) call mtk_deny_gated"*) a=named ;; *) a="$msg" ;; esac
expect "0-codes parser failure is reported with the call count" named "$a"

# The definition in hooks/lib/hook-io.sh (and its own body) is not a hook call;
# a longer identifier that merely starts with the name is not one either.
r="$(fixture '#!/usr/bin/env bash
mtk_deny_gated_helper "x"
# mtk_deny_gated "$MODE" fx-guard FX-C "commented"' "")"
mkdir -p "$r/hooks/lib"
printf '%s\n' 'mtk_deny_gated() {' '  local mode="${1:-}"  # mtk_deny_gated body' '}' > "$r/hooks/lib/hook-io.sh"
expect "definition in hooks/lib, comments and look-alike names only → exit 0" 0 "$(check_rc "$r")"

expect "unknown argument → exit 2" 2 "$(bash "$CHECK" --bogus >/dev/null 2>&1 && echo 0 || echo $?)"
expect "--root without hooks/ → exit 2" 2 "$(check_rc "$SANDBOX/does-not-exist")"

expect "the real repository passes" 0 "$(bash "$CHECK" >/dev/null 2>&1 && echo 0 || echo $?)"

echo
if [ "$fails" -eq 0 ]; then
  echo "=== check-guard-twins: ALL PASS ==="
fi
exit "$fails"
