#!/usr/bin/env bash
set -euo pipefail

# capture-learnings.sh (Stop hook): the LEARNING CHECK advisory is worth one
# read per session. Without a budget it re-fires on EVERY Stop past the
# substantial-session threshold — measured at up to 63 injections in a single
# session (~9k tokens of identical repeated text), which trains the reader to
# tune out every hook. Budget mirrors compress-monitor.sh: keyed on the payload
# session_id, stored in TMPDIR, default 1, MTK_LEARNING_MAX_NAGS overrides.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/capture-learnings.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# A throwaway project whose session counters look "substantial" and whose
# tasks/lessons.md is absent, so the advisory is due.
setup_project() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/tasks"
  ( cd "$d" && git init -q . )
  printf '%s' "$d"
}

# Ask hook-io.sh itself for the session-file path, so the test cannot drift from
# the hook's own project-id derivation (pwd -P resolution, trailing newline).
session_file_for() {
  # $1 = project dir, $2 = TMPDIR
  CLAUDE_PROJECT_DIR="$1" TMPDIR="$2" bash -c \
    'source "$0/hooks/lib/hook-io.sh"; mtk_session_file' "$REPO_ROOT"
}

seed_substantial() {
  # $1 = project dir, $2 = TMPDIR
  printf 'ops=40\nmods=9\nfiles=""\n' > "$(session_file_for "$1" "$2")"
}

run_stop() {
  # $1 = project dir, $2 = TMPDIR, $3 = session id
  local proj="$1" tmp="$2" sid="$3"
  seed_substantial "$proj" "$tmp"
  printf '{"session_id":"%s","hook_event_name":"Stop"}' "$sid" \
    | CLAUDE_PROJECT_DIR="$proj" TMPDIR="$tmp" MTK_LEARNING_MAX_NAGS=1 bash "$HOOK" 2>&1 || true
}

PROJ="$(setup_project)"; TMP="$(mktemp -d)"
trap 'rm -rf "$PROJ" "$TMP"' EXIT

# --- Case 1: first Stop of the session emits the advisory --------------------
out="$(run_stop "$PROJ" "$TMP" sess-A)"
echo "$out" | grep -q 'LEARNING CHECK' \
  || fail "case 1: first Stop should emit LEARNING CHECK, got: $out"

# --- Case 2: second Stop, same session → silent (the regression) ------------
out="$(run_stop "$PROJ" "$TMP" sess-A)"
echo "$out" | grep -q 'LEARNING CHECK' \
  && fail "case 2: LEARNING CHECK re-fired on the same session — budget not held"

# --- Case 3: third Stop, same session → still silent ------------------------
out="$(run_stop "$PROJ" "$TMP" sess-A)"
echo "$out" | grep -q 'LEARNING CHECK' \
  && fail "case 3: LEARNING CHECK fired a third time on the same session"

# --- Case 4: a DIFFERENT session gets its own budget ------------------------
out="$(run_stop "$PROJ" "$TMP" sess-B)"
echo "$out" | grep -q 'LEARNING CHECK' \
  || fail "case 4: a new session must get its own advisory, got: $out"

# --- Case 5: MTK_LEARNING_MAX_NAGS=0 silences it entirely -------------------
TMP2="$(mktemp -d)"
seed_substantial "$PROJ" "$TMP2"
out="$(printf '{"session_id":"sess-C","hook_event_name":"Stop"}' \
  | CLAUDE_PROJECT_DIR="$PROJ" TMPDIR="$TMP2" MTK_LEARNING_MAX_NAGS=0 bash "$HOOK" 2>&1 || true)"
rm -rf "$TMP2"
echo "$out" | grep -q 'LEARNING CHECK' \
  && fail "case 5: MTK_LEARNING_MAX_NAGS=0 must silence the advisory"

printf 'PASS: capture-learnings per-session nag budget\n'
