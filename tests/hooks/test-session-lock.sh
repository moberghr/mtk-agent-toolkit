#!/usr/bin/env bash
set -euo pipefail

# The advisory session lock in hooks/lib/hook-io.sh (mtk_session_lock_acquire /
# mtk_session_lock_release) guards the ledger's load-modify-save cycle:
#   - a normal acquire/release round trip leaves nothing behind;
#   - a live holder whose owner token is younger than MTK_SESSION_LOCK_MAX_AGE_SECS
#     is not stolen, and a waiter that cannot get the lock says so (non-zero)
#     after a bounded wait: at most MTK_SESSION_LOCK_TRIES (default 20) sleeps of
#     50 ms, and never more than ~2 s of wall clock when each try runs slow;
#   - a live-pid token older than MTK_SESSION_LOCK_MAX_AGE_SECS (a killed hook
#     whose pid was reused) is taken over;
#   - a waiter that did not get the lock cannot release the holder's lock, and a
#     holder whose token was reaped cannot release its successor's lock;
#   - a lock whose owner process is dead is taken over at once, and a lock with
#     no owner token (killed between mkdir and token write, or left by an older
#     version) is taken over once it is older than MTK_SESSION_LOCK_STALE_SECS;
#   - the reap primitive: of two reaps of one stale token exactly one succeeds,
#     and two waiters racing to take over the same dead lock: exactly one wins;
#   - the hooks that take the lock never exit non-zero or print because it is
#     busy, and each keeps its own fail-closed/fail-open choice explicit.
# Wait bounds are asserted by counting stubbed `sleep` calls, never by timing.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/hooks/lib/hook-io.sh"

STATE="$(mktemp -d)"
WORK="$(mktemp -d)"
HOLDERS=""
cleanup() {
  local p
  for p in $HOLDERS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$STATE" "$WORK"
}
trap cleanup EXIT
export TMPDIR="$STATE"
export CLAUDE_PROJECT_DIR="$WORK"
git -C "$WORK" init -q
cd "$WORK"

fails=0
expect() {
  if [ "$3" != "$2" ]; then
    printf 'FAIL: %s — expected [%s], got [%s]\n' "$1" "$2" "$3" >&2
    fails=$((fails + 1))
  else
    printf '  PASS  %s\n' "$1"
  fi
}

SF="$STATE/state-file"
LOCK="$SF.lock"

# lib FN ARGS... — call a library function in a fresh bash that sourced the library.
lib() { bash -c 'source "$1"; shift; "$@"' _ "$LIB" "$@"; }
# libsh SCRIPT ARGS... — run SCRIPT in a fresh bash that sourced the library ($1.. = ARGS).
libsh() { local s="$1"; shift; bash -c "source \"\$0\"; $s" "$LIB" "$@"; }
tokens() { # entries inside the lock dir (sorted, space-joined), or "NO-LOCK"
  if [ -d "$LOCK" ]; then
    (cd "$LOCK" && ls -A | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  else
    printf 'NO-LOCK'
  fi
}
clear_lock() { rm -f "$LOCK"/* 2>/dev/null || true; rmdir "$LOCK" 2>/dev/null || true; }
age_lock() { touch -t 202001010000 "$LOCK"; }
dead_pid() { bash -c 'exit 0' & local p=$!; wait "$p" 2>/dev/null || true; printf '%s' "$p"; }

# start_holder — a live background process that takes the lock and keeps it.
start_holder() {
  rm -f "$STATE/held"
  # exec keeps the pid recorded in the token alive and makes `kill` end the sleep.
  libsh 'mtk_session_lock_acquire "$1" || exit 3; : > "$2"; exec sleep 60' "$SF" "$STATE/held" >/dev/null 2>&1 &
  HOLDER=$!
  HOLDERS="$HOLDERS $HOLDER"
  local i=0
  while [ ! -f "$STATE/held" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
}
stop_holder() { kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true; }

# --- 1. round trip -----------------------------------------------------------------
rc=0; lib mtk_session_lock_acquire "$SF" || rc=$?
expect "uncontended acquire returns 0" 0 "$rc"
clear_lock
rc=0
out="$(libsh 'mtk_session_lock_acquire "$1" && ls -A "$1.lock" | wc -l | tr -d " "; mtk_session_lock_release "$1"' "$SF")" || rc=$?
expect "the holder records exactly one owner token in the lock dir" "0:1" "$rc:$out"
expect "release leaves no lock directory behind" NO-LOCK "$(tokens)"
leftover="$(ls -A "$STATE" | grep -c 'lock\|reaped' || true)"
expect "round trip leaves no lock or reaped entries in TMPDIR" 0 "$leftover"
rc=0
libsh 'for i in 1 2 3; do mtk_session_lock_acquire "$1" || exit 1; mtk_session_lock_release "$1"; done' "$SF" || rc=$?
expect "three sequential round trips in one process all succeed" "0:NO-LOCK" "$rc:$(tokens)"

# --- 2. a live holder with a young token is not stolen ------------------------------
start_holder
held_tokens="$(tokens)"
case "$held_tokens" in o.*) k=token ;; *) k="$held_tokens" ;; esac
expect "a live holder's lock carries an owner token" token "$k"
# An old lock directory does not age the holder: the owner token's age counts.
age_lock
rc=0
MTK_SESSION_LOCK_STALE_SECS=1 MTK_SESSION_LOCK_TRIES=6 lib mtk_session_lock_acquire "$SF" || rc=$?
[ "$rc" -ne 0 ] && k=failed || k=acquired
expect "acquire against a live holder with a young token fails visibly after the bound" failed "$k"
expect "the live holder's token is untouched" "$held_tokens" "$(tokens)"

# The wait bound, counted rather than timed: a stub `sleep` records each wait.
# Default tries: at most 20 sleeps of 50 ms (~1 s), well under the 3 s timeout
# of evidence-ledger.sh, the shortest-lived hook that takes this lock.
got="$(unset MTK_SESSION_LOCK_TRIES; libsh 'n=0; sleep() { n=$((n + 1)); }
  if mtk_session_lock_acquire "$1"; then echo acquired; else echo "failed $n"; fi' "$SF")"
case "$got" in "failed "*) n="${got#failed }"; [ "$n" -le 20 ] && k=bounded || k="failed after $n sleeps" ;; *) k="$got" ;; esac
expect "default acquire against a young live holder gives up within 20 sleeps" bounded "$k"
# Slow tries (a loaded host: each try costs a second here, via SECONDS) are cut
# off by wall clock too: at most ~2 s for the default 20 tries.
got="$(unset MTK_SESSION_LOCK_TRIES; libsh 'n=0; sleep() { n=$((n + 1)); SECONDS=$((SECONDS + 1)); }
  if mtk_session_lock_acquire "$1"; then echo acquired; else echo "failed $n"; fi' "$SF")"
case "$got" in "failed "*) n="${got#failed }"; [ "$n" -le 3 ] && k=bounded || k="failed after $n slow sleeps" ;; *) k="$got" ;; esac
expect "slow tries give up on wall clock (~2 s), not after all 20" bounded "$k"
expect "the live holder's token survived the bounded waits" "$held_tokens" "$(tokens)"

# --- 3. a failed acquirer's release leaves the holder's lock ------------------------
rc=0
MTK_SESSION_LOCK_TRIES=3 libsh 'mtk_session_lock_acquire "$1" && exit 9; mtk_session_lock_release "$1"' "$SF" || rc=$?
expect "failed acquirer: release returns 0" 0 "$rc"
expect "failed acquirer's release leaves the holder's lock in place" "$held_tokens" "$(tokens)"

# --- 3b. a live pid holding a token older than MTK_SESSION_LOCK_MAX_AGE_SECS --------
# A hook SIGTERMed at its timeout leaves its token; once that pid is reused by a
# long-lived process the token looks live forever. Legitimate holds last
# milliseconds, so a live token past the bound (default 30 s) is reaped.
touch -t 202001010000 "$LOCK/$held_tokens"
rc=0
got="$(MTK_SESSION_LOCK_TRIES=10 libsh 'mtk_session_lock_acquire "$1" || exit 1; ls -A "$1.lock"' "$SF")" || rc=$?
case "$got" in "$held_tokens") k=old-owner ;; o.*) k=new-owner ;; *) k="$got" ;; esac
expect "a live pid's token older than the bound is taken over" "0:new-owner" "$rc:$k"
stop_holder
clear_lock
# MTK_SESSION_LOCK_MAX_AGE_SECS sets the bound: 0 makes any live token over-age.
start_holder
rc=0
MTK_SESSION_LOCK_MAX_AGE_SECS=0 MTK_SESSION_LOCK_TRIES=10 lib mtk_session_lock_acquire "$SF" || rc=$?
expect "MTK_SESSION_LOCK_MAX_AGE_SECS=0 takes a fresh live token" 0 "$rc"
stop_holder
clear_lock

# --- 3c. a holder whose token was reaped cannot release its successor's lock --------
# A acquires and waits; its token is reaped (as an over-age reap does) and B
# takes the lock; A then releases. Release is by token, so B keeps its lock.
rm -f "$STATE/a-held" "$STATE/a-go" "$STATE/a-done"
libsh 'mtk_session_lock_acquire "$1" || exit 3; : > "$2"
  i=0; while [ ! -f "$3" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  mtk_session_lock_release "$1"; : > "$4"' "$SF" "$STATE/a-held" "$STATE/a-go" "$STATE/a-done" >/dev/null 2>&1 &
A_PID=$!
HOLDERS="$HOLDERS $A_PID"
i=0; while [ ! -f "$STATE/a-held" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
a_tok="$(tokens)"
rm -f "$LOCK/$a_tok"; rmdir "$LOCK"
start_holder
b_tok="$(tokens)"
case "$b_tok" in "$a_tok"|NO-LOCK|"") k="$b_tok" ;; o.*) k=b-holds ;; *) k="$b_tok" ;; esac
expect "B takes the lock after A's token is reaped" b-holds "$k"
: > "$STATE/a-go"
wait "$A_PID" 2>/dev/null || true
[ -f "$STATE/a-done" ] && k=released || k=no-release
expect "A ran its release" released "$k"
expect "A's release leaves B's lock and token in place" "$b_tok" "$(tokens)"
stop_holder
clear_lock

# --- 4. a dead owner's lock is taken over at once -----------------------------------
clear_lock
DEAD="$(dead_pid)"
mkdir "$LOCK"; : > "$LOCK/o.$DEAD.12345"
rc=0
got="$(MTK_SESSION_LOCK_TRIES=10 libsh 'mtk_session_lock_acquire "$1" || exit 1; ls -A "$1.lock"' "$SF")" || rc=$?
case "$got" in "o.$DEAD."*|"") k="$got" ;; o.*) k=new-owner ;; *) k="$got" ;; esac
expect "dead owner's (fresh) lock is taken over with a new owner token" "0:new-owner" "$rc:$k"
clear_lock

# A lock with no owner token at all (old version, or killed between mkdir and
# token write): taken over once older than MTK_SESSION_LOCK_STALE_SECS ...
mkdir "$LOCK"; age_lock
rc=0
MTK_SESSION_LOCK_TRIES=5 lib mtk_session_lock_acquire "$SF" || rc=$?
expect "an old token-less lock is taken over" 0 "$rc"
clear_lock
# ... but a fresh token-less lock (a holder between mkdir and token write) is not.
mkdir "$LOCK"
rc=0
MTK_SESSION_LOCK_STALE_SECS=30 MTK_SESSION_LOCK_TRIES=3 lib mtk_session_lock_acquire "$SF" || rc=$?
[ "$rc" -ne 0 ] && k=waited || k=stolen
expect "a fresh token-less lock is waited on, not stolen" waited "$k"
clear_lock

# --- 5. the reap primitive, then two waiters racing for one dead lock ---------------
# Deterministic: two reaps of the same stale token — exactly one succeeds.
DEAD="$(dead_pid)"
mkdir "$LOCK"; : > "$LOCK/o.$DEAD.777"
r1=0; lib _mtk_session_lock_reap "$LOCK" "$LOCK/o.$DEAD.777" || r1=$?
r2=0; lib _mtk_session_lock_reap "$LOCK" "$LOCK/o.$DEAD.777" || r2=$?
expect "two reaps of one stale token: the first succeeds, the second fails" "0:1" "$r1:$r2"
expect "the successful reap removed the lock" NO-LOCK "$(tokens)"
# A late reaper still naming the old token cannot remove a lock re-taken since.
clear_lock; mkdir "$LOCK"; : > "$LOCK/o.$DEAD.888"
r1=0; lib _mtk_session_lock_reap "$LOCK" "$LOCK/o.$DEAD.777" || r1=$?
expect "a late reap of a superseded token fails and leaves the new lock" "1:o.$DEAD.888" "$r1:$(tokens)"
clear_lock
leftover="$(ls -A "$STATE" | grep -c 'reaped' || true)"
expect "reaps leave no reaped token files in TMPDIR" 0 "$leftover"

race_ok=0
for it in 1 2 3 4 5; do
  clear_lock
  DEAD="$(dead_pid)"
  mkdir "$LOCK"; : > "$LOCK/o.$DEAD.999"
  rm -f "$STATE/r1" "$STATE/r2"
  # A winner keeps the lock until the other racer has reported (capped at 10 s),
  # so a correct loser must run out its bound — no timing assumption.
  for w in 1 2; do
    MTK_SESSION_LOCK_TRIES=15 libsh '
      if mtk_session_lock_acquire "$1"; then
        n=$(ls -A "$1.lock" | wc -l | tr -d " ")
        printf "won:%s\n" "$n" > "$2"
        i=0
        while [ ! -s "$3" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
        mtk_session_lock_release "$1"
      else
        printf "lost\n" > "$2"
      fi' "$SF" "$STATE/r$w" "$STATE/r$((3 - w))" &
  done
  wait
  r="$(cat "$STATE/r1") $(cat "$STATE/r2")"
  case "$r" in
    "won:1 lost"|"lost won:1") race_ok=$((race_ok + 1)) ;;
    *) printf '    iteration %s: %s\n' "$it" "$r" >&2 ;;
  esac
done
expect "two concurrent stealers: exactly one wins (5 iterations)" 5 "$race_ok"
expect "the race leaves no lock behind" NO-LOCK "$(tokens)"
leftover="$(ls -A "$STATE" | grep -c 'reaped' || true)"
expect "no reaped token files are left in TMPDIR" 0 "$leftover"

# --- 6. the hooks that take the lock degrade explicitly, never by exiting -----------
# Hold the real session lock of session "busy" with a live process.
SF="$(libsh 'mtk_session_bind "{\"session_id\":\"busy\"}"; mtk_session_file')"
LOCK="$SF.lock"
start_holder
held_tokens="$(tokens)"
export MTK_SESSION_LOCK_TRIES=3

# Session baseline (session-start, and scope-guard / format-on-edit through
# mtk_ensure_session_baseline): skipped on a busy lock. No baseline means
# verify-completion runs its gap checks — the fail-closed direction.
rc=0
out="$(printf '{"session_id":"busy","source":"resume"}' | bash "$REPO_ROOT/hooks/session-start" 2>&1 >/dev/null)" || rc=$?
expect "session-start with a busy lock: exit 0, nothing on stderr" "0:" "$rc:$out"
expect "session-start with a busy lock records no baseline" "" "$(grep "^session_start_tree='[0-9a-f]" "$SF" 2>/dev/null || true)"
rc=0
lib mtk_ensure_session_baseline '{"session_id":"busy"}' || rc=$?
expect "mtk_ensure_session_baseline with a busy lock returns 0" 0 "$rc"
expect "mtk_ensure_session_baseline with a busy lock records no baseline" "" "$(grep "^session_start_tree='[0-9a-f]" "$SF" 2>/dev/null || true)"

# Best-effort counters: the write is skipped, never fatal.
rc=0
libsh 'mtk_session_bind "{\"session_id\":\"busy\"}"; mtk_record_scope_guard_warning; mtk_record_benchmark_run 1/2' || rc=$?
expect "counter writers with a busy lock return 0" 0 "$rc"
expect "a busy lock skips the scope-guard counter" "none" "$(grep '^scope_guard_warnings=[1-9]' "$SF" 2>/dev/null || echo none)"
expect "a busy lock skips the benchmark counter" "none" "$(grep '^benchmarks_run=[1-9]' "$SF" 2>/dev/null || echo none)"

# evidence-ledger: evidence is never dropped — the event is recorded without the
# lock (the pre-existing behavior on a timed-out wait) and the holder's lock is
# left alone.
rc=0
out="$(printf '{"session_id":"busy","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":""}}' \
  | bash "$REPO_ROOT/hooks/evidence-ledger.sh" 2>&1)" || rc=$?
expect "evidence-ledger with a busy lock: exit 0, silent" "0:" "$rc:$out"
expect "evidence-ledger with a busy lock still records the event" "ops=1" "$(grep '^ops=' "$SF" 2>/dev/null || echo none)"
expect "the holder's lock survived every caller" "$held_tokens" "$(tokens)"
stop_holder
unset MTK_SESSION_LOCK_TRIES

# With the lock free again the counters record normally.
clear_lock
libsh 'mtk_session_bind "{\"session_id\":\"busy\"}"; mtk_record_scope_guard_warning'
expect "a free lock records the counter" "scope_guard_warnings=1" "$(grep '^scope_guard_warnings=' "$SF")"
expect "and releases it" NO-LOCK "$(tokens)"

if [ "$fails" -gt 0 ]; then
  printf '%d session-lock case(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'All session-lock cases passed\n'
