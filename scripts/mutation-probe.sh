#!/usr/bin/env bash
set -euo pipefail

# mutation-probe.sh — apply one boundary or negation mutation to a changed
# condition in a throwaway worktree and report whether the tests notice it.
# Used by the test-reviewer lane. The reviewed working tree is never written.
#
# Usage:
#   bash scripts/mutation-probe.sh --file <path> --line <n> --from <text> --to <text> --test <command> [--timeout <s>]
#     --file     the file holding the condition (repo-relative, or absolute inside the repo)
#     --line     1-based line number of the condition, at most 9 digits
#     --from     exact original text on that line, a literal string (not a regex);
#                it must occur exactly once on that line
#     --to       its replacement, a literal string (may be empty, e.g. to drop a `!`)
#     --test     shell command run with `bash -c` from the copy's root; it should run
#                only the tests that cover the condition
#     --timeout  seconds each test run may take (default 300, at most 9 digits); the
#                probe counts 0.2 s polls, so a run always gets at least that long.
#                On expiry the run's process group is killed and the verdict is not_run
#
# Steps: snapshot the reviewed tree (status, staged and unstaged diff, untracked
# file hashes); add a detached worktree of HEAD under $TMPDIR (repo hooks off);
# apply `git diff-index -p --binary HEAD` and copy the untracked, non-ignored
# files into it; run --test once unmutated, which must exit 0; replace --from with --to on
# --line only (bytes, line endings, file mode and a missing final newline kept); run --test
# again; remove the worktree and prune (on every exit path, signals included);
# confirm the snapshot is unchanged.
#
# Background processes: each run of --test gets its own process group. When the
# run's first process exits, whatever is left of the group (a server or watcher
# the test command started in the background) gets TERM, then KILL, and the probe
# waits until the group is empty. This happens after every run, on every exit
# path. A run that leaves processes behind is not refused, because build tools
# often leave a build server or compiler daemon in the group and refusing would
# make the probe useless for them. Stopping them is enough: the mutated run starts
# only after every process of the unmutated run is gone, so it cannot get an
# answer from one (a server still holding a port and serving the unmutated code),
# and it sees only what the unmutated run left on disk, as with any test command.
# If they cannot be stopped, the verdict is not_run. A process that leaves the
# group (setsid, a daemon that detaches itself) is not tracked.
#
# Environment: GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY,
# GIT_COMMON_DIR, GIT_NAMESPACE and GIT_PREFIX are unset first (a git hook
# exports them), so the probe's git calls and --test see only the repository
# found from the working directory, or the copy. PYTHONDONTWRITEBYTECODE=1 is
# exported: a .pyc written by the unmutated run would otherwise be reused for a
# same-size mutant written in the same second, a false `survived`.
#
# Output: one JSON line on stdout,
#   {"verdict":"killed|survived|not_run","reason":"...","file":"...","line":N}
#   survived  the mutated run exited 0. This is the only verdict that becomes a finding.
#   killed    the mutated run exited non-zero.
#   not_run   the experiment could not run or cannot be trusted: baseline red, a
#             run past --timeout, --from not found exactly once on the line, --file
#             a symlink (or under a symlinked directory) in the copy, --file marked
#             assume-unchanged or skip-worktree, --file inside a submodule, TMPDIR
#             inside the repository, a worktree, apply or copy failure, background
#             processes of the unmutated run that could not be stopped, the
#             reviewed tree changed while the probe ran, or any other error after
#             the arguments were read (the probe still prints one not_run line).
# A mutated run that fails to build, or errors before any test runs, also exits
# non-zero and reads as `killed`; exit codes cannot tell it from a failing test.
# Where the stack allows, pass a test command whose non-zero exit means a failing
# test, and read the tail of the run printed on stderr.
#
# What the copy does not reproduce: ignored files (.env, local settings, restored
# packages, build output) are not copied, so tests that need them, or a service
# or database, give `not_run`. Files under a clean/smudge filter reach the copy
# in their cleaned form, not as they are on disk. Submodule contents are not
# copied (the copy has an empty directory), so a --file inside a submodule, or
# under any gitlink in the index or HEAD, gives not_run. Tracked files marked
# assume-unchanged or skip-worktree are copied at their HEAD content, because git
# reports no edit to them; a --file with either flag gives not_run.
#
# Exit: 0 killed or survived · 3 not_run · 2 usage error.
# Bash 3.2 and BSD tools. Cleanup is `git worktree remove --force`, never rm -r.

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX
export PYTHONDONTWRITEBYTECODE=1

usage() { awk 'NR < 4 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
usage_err=0
die_usage() {
  usage_err=1
  echo "mutation-probe: $1" >&2
  echo "usage: mutation-probe.sh --file <path> --line <n> --from <text> --to <text> --test <command> [--timeout <s>]" >&2
  exit 2
}

file=""; line=""; from=""; to=""; to_set=0; test_cmd=""; timeout=300
while [ $# -gt 0 ]; do
  case "$1" in
    --file|--line|--from|--to|--test|--timeout)
      [ $# -ge 2 ] || die_usage "$1 needs a value"
      case "$1" in
        --file) file="$2" ;;
        --line) line="$2" ;;
        --from) from="$2" ;;
        --to) to="$2"; to_set=1 ;;
        --test) test_cmd="$2" ;;
        --timeout) timeout="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
[ -n "$file" ] || die_usage "--file is required"
case "$line" in ''|*[!0-9]*) die_usage "--line must be a positive integer" ;; esac
# More digits would wrap in shell arithmetic and point at another line.
[ "${#line}" -le 9 ] || die_usage "--line must have at most 9 digits"
line=$((10#$line))
[ "$line" -ge 1 ] || die_usage "--line must be a positive integer"
[ -n "$from" ] || die_usage "--from must not be empty"
[ "$to_set" -eq 1 ] || die_usage "--to is required (it may be empty)"
[ "$from" != "$to" ] || die_usage "--from and --to are identical"
[ -n "$test_cmd" ] || die_usage "--test is required"
case "$timeout" in ''|*[!0-9]*) die_usage "--timeout must be a positive number of seconds" ;; esac
[ "${#timeout}" -le 9 ] || die_usage "--timeout must have at most 9 digits"
timeout=$((10#$timeout))
[ "$timeout" -ge 1 ] || die_usage "--timeout must be a positive number of seconds"
poll_limit=$((timeout * 5)) # 0.2 s polls

json_str() { printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
rel="$file"
emitted=0
emit() { emitted=1; printf '{"verdict":"%s","reason":"%s","file":"%s","line":%s}\n' "$1" "$(json_str "$2")" "$(json_str "$rel")" "$line"; }
not_run() { emit not_run "$1"; exit 3; }

parent=""; wt=""; child=""; cleaned=0; signalled=0; stray=0
group_alive() { kill -0 -- "-$child" 2>/dev/null; }
# stop_group: TERM, then KILL, whatever is left of the run's process group and
# wait until the group is empty; sets stray=1 when it cannot be emptied.
stop_group() {
  kill -TERM -- "-$child" 2>/dev/null || true
  i=0
  while group_alive && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL -- "-$child" 2>/dev/null || true
  i=0
  while group_alive && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  if group_alive; then stray=1; fi
}
# stop_child: stop a run whose first process may still be running (timeout, signal).
stop_child() {
  [ -n "$child" ] || return 0
  kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
  i=0
  while kill -0 "$child" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL -- "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  stop_group
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
  [ -z "$wt" ] || git -C "$rootp" worktree prune >/dev/null 2>&1 || true
  if [ -n "$parent" ]; then
    rm -f "$parent/change.patch" "$parent/untracked.list" "$parent/run.log" "$parent/mutant.tmp" || true
    rmdir "$parent" 2>/dev/null || echo "mutation-probe: left $parent" >&2
  fi
}
# Any exit after the arguments were read that printed no verdict (a command that
# failed under set -e) still ends in one not_run line. Usage errors and signals
# keep their own exit codes.
# shellcheck disable=SC2329  # invoked indirectly via `trap ... EXIT` below
on_exit() {
  st=$?
  set +e
  cleanup
  if [ "$emitted" -eq 0 ] && [ "$usage_err" -eq 0 ] && [ "$signalled" -eq 0 ]; then
    [ -n "$rel" ] || rel="$file"
    emit not_run "the probe stopped on an unexpected error (exit $st); see stderr"
    exit 3
  fi
}
trap on_exit EXIT
trap 'signalled=1; exit 129' HUP
trap 'signalled=1; exit 130' INT
trap 'signalled=1; exit 143' TERM

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
tmp_base="${TMPDIR:-/tmp}"
tmpp="$(cd "$tmp_base" 2>/dev/null && pwd -P)" || not_run "TMPDIR is not a directory: $tmp_base"
case "$tmpp/" in "$rootp"/*) not_run "TMPDIR ($tmp_base) is inside the repository; point it outside" ;; esac

# Submodule contents are not copied: refuse --file under a directory holding its
# own .git, or under a gitlink (mode 160000) in the index or HEAD. The walk goes
# from the top down, because git refuses a pathspec inside a submodule.
p=""; rest="$rel"
while :; do
  case "$rest" in */*) p="${p:+$p/}${rest%%/*}"; rest="${rest#*/}" ;; *) p="${p:+$p/}$rest"; rest="" ;; esac
  if [ -n "$rest" ] && { [ -e "$p/.git" ] || [ -L "$p/.git" ]; }; then
    not_run "$rel is inside the submodule or nested repository $p, whose contents are not copied"
  fi
  link="$({ GIT_LITERAL_PATHSPECS=1 git ls-files -s -z -- "$p" && GIT_LITERAL_PATHSPECS=1 git ls-tree -z HEAD -- "$p"; } \
    | tr '\000' '\n' \
    | MP_P="$p" awk 'index($0, "160000 ") == 1 { s = $0; sub(/^[^\t]*\t/, "", s); if (s == ENVIRON["MP_P"]) f = 1 }
                     END { print f + 0 }')" || not_run "could not look for a submodule above $rel"
  [ "$link" = 0 ] || not_run "$rel is inside the submodule $p, whose contents are not copied"
  [ -n "$rest" ] || break
done
# git reports no edit to a file marked assume-unchanged (lowercase tag) or
# skip-worktree (S), so the copy would hold HEAD's content of --file.
tag="$(GIT_LITERAL_PATHSPECS=1 git ls-files -v -- "$rel")" || not_run "could not read the index entry of $rel"
case "$tag" in
  [[:lower:]]\ *|S\ *) not_run "$rel is marked assume-unchanged or skip-worktree; git reports no edit to it, so the copy would hold HEAD's content" ;;
esac

# Everything that would show an edit to the reviewed tree, hashed into one id.
# Nothing here rewrites the reviewed index: `git status` runs with
# GIT_OPTIONAL_LOCKS=0, and the diffs use plumbing `diff-index`, which never
# refreshes the index (porcelain `git diff` does) and applies no textconv.
snapshot() {
  {
    GIT_OPTIONAL_LOCKS=0 git status --porcelain=v1 -z --untracked-files=all
    git diff-index -p --binary HEAD
    git diff-index -p --binary --cached HEAD
    git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
      printf '%s\0' "$f"; git hash-object -- "$f" 2>/dev/null || echo unreadable
    done
  } | git hash-object --stdin
}

# Runs --test from the copy's root in its own process group, so a signal or the
# timeout stops the whole test run, and stops what the run left in the group;
# sets rc, timed_out and leftover (1 when the run left processes behind).
run_tests() {
  rc=0; timed_out=0; leftover=0
  set -m
  ( cd "$wt" && exec bash -c "$test_cmd" ) </dev/null >"$parent/run.log" 2>&1 &
  child=$!
  set +m
  polls=0
  while kill -0 "$child" 2>/dev/null; do
    if [ "$polls" -ge "$poll_limit" ]; then timed_out=1; stop_child; return 0; fi
    sleep 0.2
    polls=$((polls + 1))
  done
  wait "$child" 2>/dev/null || rc=$?
  if group_alive; then leftover=1; stop_group; fi
  child=""
}
show_tail() { echo "mutation-probe: $1; last lines of the run:" >&2; tail -n 15 "$parent/run.log" >&2 || true; }

before="$(snapshot)" || not_run "could not read the state of the working tree"
parent="$(mktemp -d "${tmpp%/}/mtk-mutation.XXXXXX")" || not_run "could not create a temporary directory"
wt="$parent/wt"
git -c core.hooksPath=/dev/null worktree add --quiet --detach "$wt" HEAD >"$parent/run.log" 2>&1 \
  || not_run "could not add a temporary worktree of HEAD"

git diff-index -p --binary HEAD >"$parent/change.patch" || not_run "could not diff the working tree against HEAD"
if [ -s "$parent/change.patch" ]; then
  git -C "$wt" apply --whitespace=nowarn "$parent/change.patch" >"$parent/run.log" 2>&1 \
    || not_run "could not apply the uncommitted changes to the copy"
fi
git ls-files --others --exclude-standard -z >"$parent/untracked.list" \
  || not_run "could not list the untracked files"
# Sources are read as ./<name>, so a name starting with - is not taken as an option.
while IFS= read -r -d '' f; do
  case "$f" in */) not_run "cannot copy the untracked repository $f" ;; esac
  d="$(dirname "./$f")" || not_run "could not copy the untracked file $f"
  [ "$d" = "." ] || mkdir -p "$wt/$d" || not_run "could not create $d in the copy"
  if [ -L "./$f" ]; then
    lt="$(readlink "./$f")" || not_run "could not read the untracked symlink $f"
    ln -s -- "$lt" "$wt/$f" || not_run "could not copy the untracked symlink $f"
  else
    cp -p "./$f" "$wt/$f" || not_run "could not copy the untracked file $f"
  fi
done <"$parent/untracked.list"

run_tests
[ "$timed_out" -eq 0 ] || not_run "the unmutated run did not finish within ${timeout}s"
if [ "$rc" -ne 0 ]; then
  show_tail "unmutated run exited $rc"
  not_run "the test command fails before any mutation (exit $rc)"
fi
[ "$stray" -eq 0 ] || not_run "processes the unmutated run left in the background could not be stopped"
[ "$leftover" -eq 0 ] \
  || echo "mutation-probe: the unmutated run left processes in the background; they were stopped before the mutated run" >&2

# The write below must land in the copy: refuse a symlink, or a parent
# directory that resolves outside the copy.
wtp="$(cd "$wt" && pwd -P)" || not_run "the copy is missing"
target="$wt/$rel"
[ ! -L "$target" ] || not_run "$rel is a symlink in the copy; mutate the file it points to"
tdir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || not_run "$rel is missing from the copy"
case "$tdir/" in "$wtp"/*) ;; *) not_run "$rel resolves outside the copy through a symlinked directory" ;; esac
[ -f "$target" ] || not_run "$rel is missing from the copy"
count="$(MP_FROM="$from" LC_ALL=C awk -v n="$line" '
  NR == n { s = $0; f = ENVIRON["MP_FROM"]; c = 0
            while ((i = index(s, f)) > 0) { c++; s = substr(s, i + length(f)) }
            print c; found = 1; exit }
  END { if (!found) print "eof" }' "$target")" || not_run "could not read $rel in the copy"
case "$count" in
  1) ;;
  eof) not_run "line $line is past the end of $rel" ;;
  *) not_run "the --from text occurs $count times on line $line (needs exactly 1)" ;;
esac
final_nl="$(tail -c 1 "$target" | wc -l | tr -d ' ')" || not_run "could not read $rel in the copy"
MP_FROM="$from" MP_TO="$to" LC_ALL=C awk -v n="$line" -v nl="$final_nl" '
  NR > 1 { printf "\n" }
  NR == n { s = $0; f = ENVIRON["MP_FROM"]; i = index(s, f)
            printf "%s", substr(s, 1, i - 1) ENVIRON["MP_TO"] substr(s, i + length(f)); next }
  { printf "%s", $0 }
  END { if (nl == 1) printf "\n" }' "$target" >"$parent/mutant.tmp" || not_run "could not build the mutated $rel"
# An untracked --file can be read-only (cp -p keeps its mode): lift the owner's
# write bit for the write only, so the mutated run sees the same mode.
ro=0
if [ ! -w "$target" ]; then ro=1; chmod u+w "$target" || not_run "could not make $rel writable in the copy"; fi
cat "$parent/mutant.tmp" >"$target" || not_run "could not write the mutation to $rel in the copy"
[ "$ro" -eq 0 ] || chmod u-w "$target" || not_run "could not restore the mode of $rel in the copy"

run_tests
[ "$timed_out" -eq 0 ] || not_run "the mutated run did not finish within ${timeout}s"
[ "$stray" -eq 0 ] || echo "mutation-probe: processes the mutated run left in the background could not be stopped" >&2
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
