#!/usr/bin/env bash
set -euo pipefail

# mutation-probe.sh — apply one boundary or negation mutation to a changed
# condition in a throwaway worktree and report whether the tests notice it.
# Used by the test-reviewer lane. The reviewed working tree is never written.
#
# Usage:
#   bash scripts/mutation-probe.sh --file <path> --line <n> --from <text> --to <text> --test <command>
#     --file   the file holding the condition (repo-relative, or absolute inside the repo)
#     --line   1-based line number of the condition
#     --from   exact original text on that line, a literal string (not a regex);
#              it must occur exactly once on that line
#     --to     its replacement, a literal string (may be empty, e.g. to drop a `!`)
#     --test   shell command run with `bash -c` from the copy's root; it should run
#              only the tests that cover the condition
#
# Steps: snapshot the reviewed tree (status, staged and unstaged diff, untracked
# file hashes); add a detached worktree of HEAD under $TMPDIR; apply
# `git diff HEAD --binary` and copy the untracked, non-ignored files into it; run
# --test once unmutated, which must exit 0; replace --from with --to on --line
# only; run --test again; remove the worktree and prune (on every exit path,
# signals included); confirm the snapshot is unchanged.
#
# Output: one JSON line on stdout,
#   {"verdict":"killed|survived|not_run","reason":"...","file":"...","line":N}
#   survived  the mutated run exited 0. This is the only verdict that becomes a finding.
#   killed    the mutated run exited non-zero.
#   not_run   the experiment could not run or cannot be trusted: baseline red,
#             --from not found exactly once on the line, a worktree, apply or copy
#             failure, or the reviewed tree changed while the probe ran.
# A mutated run that fails to build, or errors before any test runs, also exits
# non-zero and reads as `killed`; exit codes cannot tell it from a failing test.
# Where the stack allows, pass a test command whose non-zero exit means a failing
# test, and read the tail of the run printed on stderr. Ignored files (.env, local
# settings, restored packages, build output) are not copied, so tests that need
# them, or a service or database, give `not_run`.
#
# Exit: 0 killed or survived · 3 not_run · 2 usage error.
# Bash 3.2 and BSD tools. Cleanup is `git worktree remove --force`, never rm -r.

usage() { sed -n '4,40p' "$0" | sed 's/^# \{0,1\}//'; }
die_usage() {
  echo "mutation-probe: $1" >&2
  echo "usage: mutation-probe.sh --file <path> --line <n> --from <text> --to <text> --test <command>" >&2
  exit 2
}

file=""; line=""; from=""; to=""; to_set=0; test_cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file|--line|--from|--to|--test)
      [ $# -ge 2 ] || die_usage "$1 needs a value"
      case "$1" in
        --file) file="$2" ;;
        --line) line="$2" ;;
        --from) from="$2" ;;
        --to) to="$2"; to_set=1 ;;
        --test) test_cmd="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
[ -n "$file" ] || die_usage "--file is required"
case "$line" in ''|*[!0-9]*) die_usage "--line must be a positive integer" ;; esac
line=$((10#$line))
[ "$line" -ge 1 ] || die_usage "--line must be a positive integer"
[ -n "$from" ] || die_usage "--from must not be empty"
[ "$to_set" -eq 1 ] || die_usage "--to is required (it may be empty)"
[ "$from" != "$to" ] || die_usage "--from and --to are identical"
[ -n "$test_cmd" ] || die_usage "--test is required"

json_str() { printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
rel="$file"
emit() { printf '{"verdict":"%s","reason":"%s","file":"%s","line":%s}\n' "$1" "$(json_str "$2")" "$(json_str "$rel")" "$line"; }
not_run() { emit not_run "$1"; exit 3; }

root="$(git rev-parse --show-toplevel 2>/dev/null)" || not_run "not inside a git work tree"
rootp="$(cd "$root" && pwd -P)"
case "$file" in /*) abs="$file" ;; *) abs="$PWD/$file" ;; esac
dir="$(cd "$(dirname "$abs")" 2>/dev/null && pwd -P)" || die_usage "--file not found: $file"
case "$dir" in
  "$rootp") rel="$(basename "$abs")" ;;
  "$rootp"/*) rel="${dir#"$rootp"/}/$(basename "$abs")" ;;
  *) die_usage "--file is outside the repository: $file" ;;
esac
cd "$rootp"
[ -f "$rel" ] || die_usage "--file not found in the working tree: $rel"
git rev-parse --verify -q HEAD >/dev/null || not_run "the repository has no commit to check out"

# Everything that would show an edit to the reviewed tree, hashed into one id.
snapshot() {
  {
    git status --porcelain=v1 -z --untracked-files=all
    git --no-pager diff --no-color --no-ext-diff --binary --src-prefix=a/ --dst-prefix=b/ HEAD
    git --no-pager diff --no-color --no-ext-diff --binary --src-prefix=a/ --dst-prefix=b/ --cached
    git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
      printf '%s\0' "$f"; git hash-object -- "$f" 2>/dev/null || echo unreadable
    done
  } | git hash-object --stdin
}

parent=""; wt=""; child=""; cleaned=0
stop_child() {
  [ -n "$child" ] || return 0
  kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
  i=0
  while kill -0 "$child" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL -- "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  child=""
}
cleanup() {
  [ "$cleaned" -eq 0 ] || return 0
  cleaned=1
  stop_child
  if [ -n "$wt" ] && [ -e "$wt" ]; then
    git -C "$rootp" worktree remove --force "$wt" >/dev/null 2>&1 \
      || echo "mutation-probe: could not remove worktree $wt" >&2
  fi
  git -C "$rootp" worktree prune >/dev/null 2>&1 || true
  if [ -n "$parent" ]; then
    rm -f "$parent/change.patch" "$parent/run.log" "$parent/mutant.tmp"
    rmdir "$parent" 2>/dev/null || echo "mutation-probe: left $parent" >&2
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Runs --test from the copy's root in its own process group (so a signal can
# stop the whole test run); sets rc.
run_tests() {
  rc=0
  set -m
  ( cd "$wt" && exec bash -c "$test_cmd" ) </dev/null >"$parent/run.log" 2>&1 &
  child=$!
  set +m
  wait "$child" 2>/dev/null || rc=$?
  child=""
}
show_tail() { echo "mutation-probe: $1; last lines of the run:" >&2; tail -n 15 "$parent/run.log" >&2 || true; }

before="$(snapshot)"
tmp_base="${TMPDIR:-/tmp}"
parent="$(mktemp -d "${tmp_base%/}/mtk-mutation.XXXXXX")" || not_run "could not create a temporary directory"
wt="$parent/wt"
git -c core.hooksPath=/dev/null worktree add --quiet --detach "$wt" HEAD >"$parent/run.log" 2>&1 \
  || not_run "could not add a temporary worktree of HEAD"

git --no-pager diff --no-color --no-ext-diff --binary --src-prefix=a/ --dst-prefix=b/ HEAD >"$parent/change.patch"
if [ -s "$parent/change.patch" ]; then
  git -C "$wt" apply --whitespace=nowarn "$parent/change.patch" >"$parent/run.log" 2>&1 \
    || not_run "could not apply the uncommitted changes to the copy"
fi
while IFS= read -r -d '' f; do
  case "$f" in */) not_run "cannot copy the untracked repository $f" ;; esac
  d="$(dirname "$f")"
  [ "$d" = "." ] || mkdir -p "$wt/$d" || not_run "could not create $d in the copy"
  if [ -L "$f" ]; then
    ln -s "$(readlink "$f")" "$wt/$f" || not_run "could not copy the untracked symlink $f"
  else
    cp -p "$f" "$wt/$f" || not_run "could not copy the untracked file $f"
  fi
done < <(git ls-files --others --exclude-standard -z)

run_tests
if [ "$rc" -ne 0 ]; then
  show_tail "unmutated run exited $rc"
  not_run "the test command fails before any mutation (exit $rc)"
fi

target="$wt/$rel"
[ -f "$target" ] || not_run "$rel is missing from the copy"
count="$(MP_FROM="$from" awk -v n="$line" '
  NR == n { s = $0; f = ENVIRON["MP_FROM"]; c = 0
            while ((i = index(s, f)) > 0) { c++; s = substr(s, i + length(f)) }
            print c; found = 1; exit }
  END { if (!found) print "eof" }' "$target")"
case "$count" in
  1) ;;
  eof) not_run "line $line is past the end of $rel" ;;
  *) not_run "the --from text occurs $count times on line $line (needs exactly 1)" ;;
esac
MP_FROM="$from" MP_TO="$to" awk -v n="$line" '
  NR == n { s = $0; f = ENVIRON["MP_FROM"]; i = index(s, f)
            print substr(s, 1, i - 1) ENVIRON["MP_TO"] substr(s, i + length(f)); next }
  { print }' "$target" >"$parent/mutant.tmp"
cat "$parent/mutant.tmp" >"$target"

run_tests
if [ "$rc" -eq 0 ]; then
  verdict=survived; reason="the tests still pass with the mutation applied"
else
  verdict=killed; reason="the mutated run exited $rc"
  show_tail "mutated run exited $rc (a build error also reads as killed)"
fi

cleanup
[ ! -e "$wt" ] || not_run "the temporary worktree could not be removed: $wt"
[ "$(snapshot)" = "$before" ] || not_run "the reviewed working tree changed while the probe ran"
emit "$verdict" "$reason"
exit 0
