#!/usr/bin/env bash
set -euo pipefail

# scripts/mutation-probe.sh mutates one condition in a throwaway worktree and
# reports killed / survived / not_run. Covered here, in a mktemp -d sandbox repo:
# verdicts and JSON (a file name with a quote and a backslash), not_run cases, a
# CRLF file without a final newline under a path with spaces, a symlinked --file
# and a parent directory turned into a symlink, TMPDIR inside the repo, stale
# Python bytecode, git environment exported by a hook (GIT_INDEX_FILE, GIT_DIR +
# GIT_WORK_TREE), a repo hook that must not fire, staged + unstaged + deleted +
# untracked changes in the copy with the reviewed tree (files, index bytes, HEAD,
# stash, refs) unchanged, a run that edits the reviewed tree, --timeout (also on
# a command that ignores TERM), SIGTERM with a background grandchild, SIGHUP,
# SIGINT, and usage errors.

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX
unset PYTHONDONTWRITEBYTECODE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/mutation-probe.sh"
M="$$" # every sleep this test starts runs for NN.<this pid>, so a stray process from another run never matches

# pids_of <command line>: pids of the processes running exactly that command line.
pids_of() { ps -A -o pid= -o command= | awk -v m="$1" '{ p = $1; sub(/^ *[0-9]+ +/, ""); if ($0 == m) print p }'; }
running() { [ -n "$(pids_of "$1")" ]; }
kill_marker() { local p; for p in $(pids_of "$1"); do kill -KILL "$p" 2>/dev/null || true; done; }

SANDBOX="$(mktemp -d)"
trap 'for n in 51 52 53 54 55 56 57; do kill_marker "sleep $n.$M"; done; rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/proj" "$SANDBOX/tmp" "$SANDBOX/nogit"
PROJ="$SANDBOX/proj"
export TMPDIR="$SANDBOX/tmp"
cd "$PROJ"

g() { git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@"; }
g init -q .
printf 'ignored.log\n' > .gitignore
mkdir -p src tests real
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
printf 'g() { [ "$1" -gt 0 ]; }\n' > real/g.sh
ln -s "$PROJ/real/g.sh" link.sh
g add -A && g commit -q -m init

fails=0
pass() { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

# probe <args…>: run the probe, keep stdout in OUT and the exit code in RC.
probe() { RC=0; OUT="$(bash "$PROBE" "$@" 2>/dev/null)" || RC=$?; }
# penv <VAR=value…> bash "$PROBE" <args…>: the same, with extra environment.
penv() { RC=0; OUT="$(env "$@" 2>/dev/null)" || RC=$?; }
verdict() { local v; v="$(printf '%s' "$OUT" | sed -n 's/^{"verdict":"\([a-z_]*\)",.*/\1/p')"; printf '%s' "${v:-unparseable}"; }
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
# Fingerprint of everything the reviewed repo holds: file bytes, status, index
# entries and bytes, HEAD, stash and refs. Never refreshes the index itself.
tree_fp() {
  {
    find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done
    GIT_OPTIONAL_LOCKS=0 git status --porcelain=v1 -z --untracked-files=all | od -c
    g ls-files -s
    cksum < .git/index
    g rev-parse HEAD
    g stash list
    g for-each-ref
  } | cksum
}
same_tree() { [ "$(tree_fp)" = "$1" ] && pass "$2: reviewed tree unchanged" || bad "$2: reviewed tree changed"; }

# wait_until <tenths> <command…>: retry until it succeeds; fail after the limit.
wait_until() { local n="$1" i=0; shift; until "$@"; do i=$((i + 1)); [ "$i" -le "$n" ] || return 1; sleep 0.1; done; }
exited() { ! kill -0 "$1" 2>/dev/null; }
# start_probe <probe args…>: start it in the background in its own process
# group (so SIGINT is not ignored); BG is its pid, stdout goes to $SANDBOX/out.
start_probe() { set -m; bash "$PROBE" "$@" >"$SANDBOX/out" 2>/dev/null & BG=$!; set +m; }
# finish_probe <tenths>: wait for BG; RC is its exit code, or 124 when it was
# still running at the limit (it is then killed).
finish_probe() {
  RC=0
  if wait_until "$1" exited "$BG"; then wait "$BG" 2>/dev/null || RC=$?
  else kill -KILL -- "-$BG" 2>/dev/null || true; wait "$BG" 2>/dev/null || true; RC=124; fi
  OUT="$(cat "$SANDBOX/out")"
}
markers_stopped() { # <label> <command line>…
  local label="$1" m; shift
  for m; do
    if running "$m"; then bad "$label: '$m' still running"; kill_marker "$m"; else pass "$label: '$m' stopped"; fi
  done
}
signal_case() { # <signal> <label> <test command> <marker command line>…
  local sig="$1" label="$2" cmd="$3" m started=1 fp; shift 3
  fp="$(tree_fp)"
  start_probe --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --test "$cmd"
  for m; do wait_until 100 running "$m" || started=0; done
  [ "$started" -eq 1 ] && pass "$label: test command running before the signal" || bad "$label: test command never started"
  kill -"$sig" "$BG" 2>/dev/null || true
  finish_probe 100
  case "$RC" in
    0) bad "$label: probe exited 0" ;;
    124) bad "$label: probe still running 10s after SIG$sig" ;;
    *) pass "$label: probe exits $RC" ;;
  esac
  no_leftover "$label"
  markers_stopped "$label" "$@"
  same_tree "$fp" "$label"
}

TEST='sh tests/run.sh'

echo "=== mutation-probe ==="

echo ""
echo "--- verdicts ---"
probe --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --test "$TEST"
expect 0 killed "boundary shift the tests cover is killed"
probe --file src/calc.sh --line 2 --from '-ge' --to '-gt' --test "$TEST"
expect 0 survived "boundary shift no test covers survives"
case "$OUT" in *'"file":"src/calc.sh","line":2}'*) pass "JSON names file and line" ;; *) bad "JSON file/line: $OUT" ;; esac
probe --file "$PROJ/src/calc.sh" --line 2 --from '-ge' --to '-gt' --test "$TEST"
expect 0 survived "absolute --file inside the repo"
mkdir -p 'q"b\s' && printf 'x -gt 0\n' > 'q"b\s/f.txt'
probe --file 'q"b\s/f.txt' --line 1 --from '-gt' --to '-ge' --test true
case "$OUT" in *'"file":"q\"b\\s/f.txt"'*) pass "JSON escapes a quote and a backslash in the file name" ;; *) bad "JSON escaping: $OUT" ;; esac

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
mkdir tmpin
penv TMPDIR="$PROJ/tmpin" bash "$PROBE" --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --test "$TEST"
expect 3 not_run "TMPDIR inside the repository"
case "$OUT" in *'is inside the repository; point it outside'*) up_front=1 ;; *) up_front=0 ;; esac
[ "$up_front" -eq 1 ] && [ -z "$(ls -A tmpin)" ] && [ "$(worktrees)" -eq 1 ] && pass "in-repo TMPDIR rejected up front, nothing created" \
  || bad "in-repo TMPDIR not rejected up front: $OUT"
rmdir tmpin

echo ""
echo "--- the mutant write stays in the copy ---"
fp="$(tree_fp)"
probe --file link.sh --line 1 --from '-gt' --to '-lt' --test true
expect 3 not_run "--file is a symlink to an absolute path in the reviewed repo"
probe --file real/g.sh --line 1 --from '-gt' --to '-lt' \
  --test "if [ ! -L real ]; then mv real real.orig && ln -s '$PROJ/real' real; fi"
expect 3 not_run "baseline turned the parent directory into a symlink to the reviewed repo"
grep -q -- '-gt 0' real/g.sh && pass "real/g.sh not mutated through a symlink" || bad "real/g.sh was mutated in the reviewed tree"
same_tree "$fp" "symlinks"
mkdir -p 'sp ace' && printf 'a\r\nif [ 1 -gt 0 ]; then :; fi\r\nlast -gt 0' > 'sp ace/u x.txt'
probe --file 'sp ace/u x.txt' --line 2 --from '-gt 0' --to '-lt 0' --test "cp 'sp ace/u x.txt' '$SANDBOX/copy.bin'"
expect 0 survived "untracked file under a path with spaces"
printf 'a\r\nif [ 1 -lt 0 ]; then :; fi\r\nlast -gt 0' > "$SANDBOX/want.bin"
cmp -s "$SANDBOX/copy.bin" "$SANDBOX/want.bin" && pass "only --from changed: CRLF and the missing final newline kept" \
  || bad "mutant bytes differ: $(od -c "$SANDBOX/copy.bin" | tr -s ' ' | tr '\n' ' ')"
if command -v python3 >/dev/null 2>&1; then
  mkdir -p pkg
  printf 'def ok(x):\n    return x > 0\n' > pkg/m.py
  printf 'from m import ok\nassert ok(1)\nassert not ok(-1)\nassert not ok(0)\n' > pkg/test_m.py
  g add pkg && g commit -q -m py
  k=0
  for _ in 1 2 3; do
    probe --file pkg/m.py --line 2 --from 'x > 0' --to 'x < 0' --test 'python3 pkg/test_m.py'
    [ "$(verdict)" = killed ] && k=$((k + 1))
  done
  [ "$k" -eq 3 ] && pass "same-size Python mutant killed 3/3 (no stale bytecode)" || bad "same-size Python mutant killed only $k/3"
else
  echo "  SKIP  python3 not found: stale-bytecode case"
fi

echo ""
echo "--- environment a git hook passes down; repo hooks ---"
printf 'new\n' > staged.txt && g add staged.txt
fp="$(tree_fp)"
penv GIT_INDEX_FILE="$PROJ/.git/index" bash "$PROBE" --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --test "$TEST"
expect 0 killed "GIT_INDEX_FILE exported"
same_tree "$fp" "GIT_INDEX_FILE (staged entry kept)"
penv GIT_DIR="$PROJ/.git" GIT_WORK_TREE="$PROJ" bash "$PROBE" --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' \
  --test 'test -z "${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_INDEX_FILE:-}" && test "$(git rev-parse --show-toplevel)" = "$(pwd -P)" && sh tests/run.sh'
expect 0 killed "GIT_DIR and GIT_WORK_TREE exported (--test sees only the copy)"
same_tree "$fp" "GIT_DIR and GIT_WORK_TREE"
g reset -q staged.txt && rm staged.txt
mkdir -p "$SANDBOX/hooks"
printf '#!/bin/sh\necho fired > "%s/hook-fired"\n' "$SANDBOX" > "$SANDBOX/hooks/post-checkout"
chmod +x "$SANDBOX/hooks/post-checkout"
g config core.hooksPath "$SANDBOX/hooks"
probe --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --test "$TEST"
expect 0 killed "with a post-checkout hook configured"
[ ! -e "$SANDBOX/hook-fired" ] && pass "repo hooks do not run for the copy" || bad "post-checkout hook fired"
g config --unset core.hooksPath

echo ""
echo "--- uncommitted changes reach the copy; the reviewed tree does not move ---"
printf 'staged\n' > a.txt && g add a.txt
printf 'unstaged\n' > b.txt
rm gone.txt
mkdir -p newdir/sub && printf 'untracked\n' > newdir/sub/c.txt
printf 'ignored\n' > ignored.log
touch -t 202001010000 tests/run.sh # stat-dirty: a `git status` that refreshes would rewrite the index
fp_before="$(tree_fp)"
probe --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' \
  --test 'grep -qx staged a.txt && grep -qx unstaged b.txt && grep -qx untracked newdir/sub/c.txt && test ! -e gone.txt && test ! -e ignored.log && sh tests/run.sh'
expect 0 killed "staged, unstaged, deleted and untracked-in-subdir changes present; ignored file absent"
same_tree "$fp_before" "uncommitted changes (index bytes included)"
grep -q -- '-gt 0' src/calc.sh && pass "mutated file untouched in the reviewed tree" || bad "src/calc.sh was mutated in place"
no_leftover "after killed"
probe --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --test "sh tests/run.sh && printf x >> '$PROJ/drift.txt'"
expect 3 not_run "a run that edits the reviewed tree"
rm -f drift.txt

echo ""
echo "--- --timeout ---"
start_probe --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --timeout 1 --test "sleep 51.$M"
finish_probe 100
expect 3 not_run "run past --timeout"
markers_stopped "timeout" "sleep 51.$M"
no_leftover "timeout"
start_probe --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --timeout 1 --test "trap '' TERM; sleep 52.$M"
finish_probe 150
expect 3 not_run "run past --timeout that ignores SIGTERM"
markers_stopped "timeout, TERM ignored" "sleep 52.$M"
no_leftover "timeout, TERM ignored"
start_probe --file src/calc.sh --line 1 --from '-gt 0' --to '-ge 0' --timeout 2 \
  --test "if grep -q -- '-ge 0' src/calc.sh; then sleep 57.$M; fi; sh tests/run.sh"
finish_probe 150
expect 3 not_run "mutated run past --timeout (neither killed nor survived)"
markers_stopped "mutant timeout" "sleep 57.$M"

echo ""
echo "--- a signal mid-run stops the whole test run and cleans up ---"
signal_case TERM "SIGTERM, background grandchild" "sleep 53.$M & sleep 54.$M; wait" "sleep 53.$M" "sleep 54.$M"
signal_case HUP "SIGHUP" "sleep 55.$M" "sleep 55.$M"
signal_case INT "SIGINT" "sleep 56.$M" "sleep 56.$M"

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
u "--timeout 0" --file src/calc.sh --line 1 --from a --to b --test true --timeout 0
u "non-numeric --timeout" --file src/calc.sh --line 1 --from a --to b --test true --timeout 5s

echo ""
if [ "$fails" -eq 0 ]; then echo "test-mutation-probe: all checks passed"; else echo "test-mutation-probe: $fails failure(s)" >&2; exit 1; fi
