#!/usr/bin/env bash
set -euo pipefail

# scripts/mutation-probe.sh mutates one condition in a throwaway worktree and
# reports killed / survived / not_run. Covered here, in a mktemp -d sandbox repo:
# killed, survived, a red baseline, --from text not found exactly once, staged +
# unstaged + deleted + untracked-in-subdirectory changes all present in the copy
# (ignored files absent), the reviewed tree byte-identical afterwards, no
# worktree registration or temp dir left after a failing test command or a
# signal, a non-git directory, and usage errors.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/mutation-probe.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/proj" "$SANDBOX/tmp" "$SANDBOX/nogit"
PROJ="$SANDBOX/proj"
export TMPDIR="$SANDBOX/tmp"
cd "$PROJ"

g() { git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@"; }
g init -q .
printf 'ignored.log\n' > .gitignore
mkdir -p src tests
cat > src/calc.sh <<'EOF'
is_positive() { [ "$1" -gt 0 ]; }
can_withdraw() { [ "$1" -ge "$2" ]; }
EOF
cat > tests/run.sh <<'EOF'
. src/calc.sh
is_positive 1 || exit 1
if is_positive 0; then exit 1; fi
can_withdraw 10 5 || exit 1
exit 0
EOF
printf 'base\n' > a.txt
printf 'base\n' > b.txt
printf 'x\n' > gone.txt
g add -A && g commit -q -m init

fails=0
pass() { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

# probe <args…>: run the probe, keep stdout in OUT and the exit code in RC.
probe() { RC=0; OUT="$(bash "$PROBE" "$@" 2>/dev/null)" || RC=$?; }
verdict() { printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["verdict"])' 2>/dev/null || echo "unparseable"; }
expect() { # <exit> <verdict> <label>
  local v; v="$(verdict)"
  if [ "$RC" -eq "$1" ] && [ "$v" = "$2" ]; then pass "$3 (exit $RC, $v)"; else bad "$3: expected exit $1 / $2, got $RC / $v — $OUT"; fi
}
worktrees() { g worktree list --porcelain | grep -c '^worktree ' || true; }
leftovers() { find "$SANDBOX/tmp" -maxdepth 1 -name 'mtk-mutation.*' | wc -l | tr -d ' '; }
no_leftover() { # <label>
  local n t; n="$(worktrees)"; t="$(leftovers)"
  if [ "$n" -eq 1 ] && [ "$t" -eq 0 ]; then pass "$1: no worktree or temp dir left"; else bad "$1: $n worktrees registered, $t temp dirs left"; fi
}
# Fingerprint of everything the reviewed tree holds: file bytes, status, index.
tree_fp() {
  {
    find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done
    g status --porcelain=v1 -z --untracked-files=all | od -c
    g ls-files -s
  } | cksum
}

TEST='sh tests/run.sh'

echo "=== mutation-probe ==="

echo ""
echo "--- verdicts ---"
probe --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --test "$TEST"
expect 0 killed "boundary shift the tests cover is killed"
probe --file src/calc.sh --line 2 --from '-ge' --to '-gt' --test "$TEST"
expect 0 survived "boundary shift no test covers survives"
printf '%s' "$OUT" | grep -q '"file":"src/calc.sh","line":2' && pass "JSON names file and line" || bad "JSON file/line: $OUT"
probe --file "$PROJ/src/calc.sh" --line 2 --from '-ge' --to '-gt' --test "$TEST"
expect 0 survived "absolute --file inside the repo"

echo ""
echo "--- not_run ---"
probe --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --test 'exit 1'
expect 3 not_run "red baseline"
no_leftover "after a failing test command"
probe --file src/calc.sh --line 1 --from 'nope' --to 'x' --test "$TEST"
expect 3 not_run "--from text absent from the line"
probe --file src/calc.sh --line 2 --from '"$' --to '"' --test "$TEST"
expect 3 not_run "--from text twice on the line"
probe --file src/calc.sh --line 99 --from '-gt' --to '-ge' --test "$TEST"
expect 3 not_run "line past the end of the file"
cp src/calc.sh "$SANDBOX/nogit/calc.sh"
RC=0; OUT="$(cd "$SANDBOX/nogit" && bash "$PROBE" --file calc.sh --line 1 --from '-gt' --to '-ge' --test true 2>/dev/null)" || RC=$?
expect 3 not_run "outside a git work tree"

echo ""
echo "--- uncommitted changes reach the copy; the reviewed tree does not move ---"
printf 'staged\n' > a.txt && g add a.txt
printf 'unstaged\n' > b.txt
rm gone.txt
mkdir -p newdir/sub && printf 'untracked\n' > newdir/sub/c.txt
printf 'ignored\n' > ignored.log
fp_before="$(tree_fp)"
probe --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' \
  --test 'grep -qx staged a.txt && grep -qx unstaged b.txt && grep -qx untracked newdir/sub/c.txt && test ! -e gone.txt && test ! -e ignored.log && sh tests/run.sh'
expect 0 killed "staged, unstaged, deleted and untracked-in-subdir changes present; ignored file absent"
[ "$(tree_fp)" = "$fp_before" ] && pass "reviewed tree byte-identical, index unchanged" || bad "reviewed tree changed"
grep -q -- '-gt 0' src/calc.sh && pass "mutated file untouched in the reviewed tree" || bad "src/calc.sh was mutated in place"
no_leftover "after killed"

echo ""
echo "--- a signal mid-run cleans up ---"
bash "$PROBE" --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --test 'sleep 47.25' >/dev/null 2>&1 &
pid=$!
i=0; while [ "$(worktrees)" -lt 2 ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.3
kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
[ "$rc" -ne 0 ] && pass "interrupted probe exits non-zero ($rc)" || bad "interrupted probe exited 0"
no_leftover "after SIGTERM"
running="$(ps -A -o command= | grep -c '^sleep 47.25$' || true)"
[ "$running" -eq 0 ] && pass "test command stopped with the probe" || bad "test command still running after SIGTERM"
[ "$(tree_fp)" = "$fp_before" ] && pass "reviewed tree unchanged after SIGTERM" || bad "reviewed tree changed after SIGTERM"

echo ""
echo "--- usage errors exit 2 ---"
u() { local label="$1"; shift; probe "$@"; [ "$RC" -eq 2 ] && pass "$label" || bad "$label: expected exit 2, got $RC — $OUT"; }
u "no arguments"
u "missing --test" --file src/calc.sh --line 1 --from a --to b
u "missing --to" --file src/calc.sh --line 1 --from a --test true
u "non-numeric --line" --file src/calc.sh --line x --from a --to b --test true
u "--line 0" --file src/calc.sh --line 0 --from a --to b --test true
u "empty --from" --file src/calc.sh --line 1 --from '' --to b --test true
u "identical --from and --to" --file src/calc.sh --line 1 --from a --to a --test true
u "unknown flag" --file src/calc.sh --bogus
u "flag without a value" --file
u "missing file" --file src/none.sh --line 1 --from a --to b --test true
u "file outside the repo" --file "$SANDBOX/nogit/calc.sh" --line 1 --from a --to b --test true

echo ""
if [ "$fails" -eq 0 ]; then echo "test-mutation-probe: all checks passed"; else echo "test-mutation-probe: $fails failure(s)" >&2; exit 1; fi
