#!/usr/bin/env bash
set -euo pipefail

# Re-export shrink-guard helpers so any hook sourcing hook-io gets mtk_guarded_write.
# shellcheck source=shrink-guard.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shrink-guard.sh"

# Shared helpers for Claude Code hook payload parsing and session-scoped state.
# Supports both legacy flat payloads ({"command": ...}) and nested tool_input
# payloads ({"tool_input": {"command": ...}}) using only the portable tools
# allowed by MTK's bash rules (coreutils, grep, sed, awk, find, git — S3.3).
#
# Parsing is escape-aware: JSON string escapes (\", \\, \n, etc.) are decoded
# so downstream security checks see the real command, not a truncated prefix.

# Resolve the repo/project root — memoized per process and keyed by PWD, so a
# script that cd's between calls still resolves correctly while a hook (one
# short-lived process) pays the cost once. Prefers $CLAUDE_PROJECT_DIR: the
# harness sets it per session and it is cwd-independent, so a hook whose cwd is
# a subdirectory (or outside the repo) still resolves the project. It is also
# ~20ms cheaper per call than spawning `git rev-parse`, which multiplied across
# every hook on every tool call was the single largest avoidable latency in
# the PreToolUse path. Physicalized via pwd -P (symlink/case lessons, S1.17).
mtk_repo_root() {
  if [ -n "${_MTK_REPO_ROOT:-}" ] && [ "${_MTK_REPO_ROOT_PWD:-}" = "$PWD" ]; then
    printf '%s\n' "$_MTK_REPO_ROOT"
    return 0
  fi
  local root=""
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}" ]; then
    root="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)" || root=""
  fi
  [ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  _MTK_REPO_ROOT="$root"
  _MTK_REPO_ROOT_PWD="$PWD"
  printf '%s\n' "$root"
}

# --- Hook payload read ------------------------------------------------------
# Read the hook payload from stdin under a wall-clock bound.
#
# WHY BOUNDED
#   A bare `INPUT=$(cat)` blocks until stdin closes. When it does not close the
#   hook never exits, and Claude Code holds the tool call behind it: two hooks
#   were observed alive for 235s and 182s against `"timeout": 5` in hooks.json,
#   so the declared per-hook timeout cannot be relied on to break the wait.
#   `2>/dev/null || true` does not help here — that handles a read that fails,
#   not a read that never returns.
#
# S3.3 GRACEFUL DEGRADATION
#   Prefer GNU-style `timeout`, fall back to `gtimeout` (Homebrew coreutils
#   without unprefixed shims), and read unbounded when neither exists. A missing
#   `timeout` binary must never turn into a failed hook. Same probe as
#   scripts/verify-commands.sh.
#
# CALLERS STILL HANDLE EMPTY INPUT
#   On timeout the payload is empty, which is indistinguishable from "no
#   payload". Fail-open hooks exit 0; security-gate.sh deliberately fails closed
#   and blocks. That trade is intended — a visible block beats a silent
#   multi-minute hang.
# Stock macOS ships neither timeout nor gtimeout, so the third tier is a
# python3 select() loop with the same deadline (python3 is S3.3 baseline). Only
# with none of the three does the read go unbounded.
mtk_read_payload() {
  local secs="${1:-4}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" cat 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" cat 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import os, select, sys, time
deadline = time.time() + float(sys.argv[1])
out = []
while True:
    left = deadline - time.time()
    if left <= 0:
        break
    ready, _, _ = select.select([0], [], [], left)
    if not ready:
        break
    chunk = os.read(0, 65536)
    if not chunk:
        break
    out.append(chunk)
sys.stdout.buffer.write(b"".join(out))
' "$secs" 2>/dev/null || true
  else
    cat 2>/dev/null || true
  fi
}

# --- Hook output envelope helpers (Claude Code hooks contract) --------------
# Model/user-visible output must use the documented JSON envelopes, not plain
# stdout (which reaches neither on exit 0). See code.claude.com/docs/en/hooks.

# JSON-escape a string using bash parameter substitution only (no jq).
mtk_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Model-visible advisory context for events that support it (PreToolUse,
# PostToolUse, UserPromptSubmit, SessionStart, Stop). Non-blocking.
mtk_emit_additional_context() {
  local event="$1" text="$2" esc
  esc="$(mtk_json_escape "$text")"
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$event" "$esc"
}

# Stop-hook gate: block the stop and hand `reason` to the model, which then
# continues. Caller must have already honored stop_hook_active to avoid loops.
mtk_emit_stop_block() {
  local esc
  esc="$(mtk_json_escape "${1:-}")"
  printf '{"decision":"block","reason":"%s"}\n' "$esc"
}

# User-visible, non-blocking warning. Used by advisory Stop hooks where forcing
# the model to continue (the only model-visible Stop channel) would be wrong.
mtk_emit_system_message() {
  local esc
  esc="$(mtk_json_escape "${1:-}")"
  printf '{"systemMessage":"%s"}\n' "$esc"
}

# Is `dir` at or below `root`? Compares by device+inode (`-ef`), so the answer
# does not depend on how either path is *spelled*. A string-prefix test is not
# safe here: `pwd -P` resolves symlinks but does NOT canonicalise case, so on a
# case-insensitive filesystem the same directory can present as both
# `/Users/x/Dev/repo` and `/Users/x/dev/repo` depending on the casing the parent
# process was launched with. A prefix test then reports "outside the project",
# which reads a path inside the project as outside it.
# Fork-free: inputs are absolute normalised paths, so the parent is a suffix strip.
# --- Deny ergonomics --------------------------------------------------------
# Field-observed failure modes after a hard deny (exit 2): the agent treats
# the block as a stop signal and abandons the task, or silently loses tool
# calls that were batched with the denied one, or treats one denial as a rule
# and refuses everything after (cascade). Every deny therefore carries a
# continuation suffix; an optional toggle hint teaches the off-switch at the
# moment of friction. Pass an empty toggle when the guard has no self-service
# off-switch by design (security-gate, read-guard's human-granted approval).
#
# Usage:  mtk_deny "reason text" ["toggle hint"]
#         mtk_deny - ["toggle hint"] <<EOF   (reason on stdin, e.g. heredoc)
mtk_deny() {
  local reason="${1:-}" toggle="${2:-}"
  if [ "$reason" = "-" ]; then
    reason="$(cat 2>/dev/null || true)"
  fi
  # Cap + sanitize: deny reasons echo tool input (command text, paths, rule
  # bodies), so a huge or ANSI-laced tool_input must not bloat or corrupt the
  # message. Control bytes stripped (newline/tab kept); length bounded high
  # enough that a full rule-file delivery is never truncated.
  reason="$(printf '%s' "$reason" | tr -d '\000-\010\013\014\016-\037\177' | head -c "${MTK_DENY_MAX_CHARS:-20000}")"
  printf '%s\n' "$reason" >&2
  {
    printf '⚠ This denial applies to THIS call only. Any tool calls batched with it were CANCELLED — re-issue them separately.\n'
    printf 'A denial is a correction, not a stop signal: adapt this action and continue the task. Earlier denials this session are past verdicts about those calls, not rules against future ones.\n'
    if [ -n "$toggle" ]; then
      printf '(disable this guard: %s)\n' "$toggle"
    fi
  } >&2
  exit 2
}

mtk_path_is_within() {
  local dir="${1:-}" root="${2:-}" parent depth=0
  [ -n "$dir" ] && [ -n "$root" ] || return 1
  while [ "$depth" -lt 64 ]; do
    [ "$dir" -ef "$root" ] && return 0
    parent="${dir%/*}"
    [ -n "$parent" ] || parent="/"
    [ "$parent" = "$dir" ] && return 1
    dir="$parent"
    depth=$((depth + 1))
  done
  return 1
}

# Repo-relative path for `file` under `root`, robust to how either is SPELLED.
#
# The naive `"${file#"$root"/}"` strip is a string operation, so it silently
# no-ops whenever the two disagree in spelling even though they name the same
# directory: a case-insensitive filesystem serves the same repo as both
# `/Users/x/Dev/repo` and `/Users/x/dev/repo` depending on how the session was
# launched, and `pwd -P` does not canonicalise case. When the strip no-ops the
# caller keeps an ABSOLUTE path, its `case "$REL_PATH" in docs/specs/*)`-style
# match misses, and the hook exits 0 — the guard is silently off rather than
# loudly broken. Same failure for a symlinked root (/var -> /private/var).
#
# Walks up from the file comparing by device+inode (`-ef`), accumulating the
# tail, so the answer never depends on spelling. Falls back to the fast string
# strip first (the common exact-spelling case, no forks). Prints nothing and
# returns 1 when `file` is genuinely not under `root`.
mtk_repo_relative_path() { # $1=absolute file path  $2=repo root
  local file="${1:-}" root="${2:-}" dir parent tail depth=0
  [ -n "$file" ] && [ -n "$root" ] || return 1
  case "$file" in
    "$root"/*) printf '%s' "${file#"$root"/}"; return 0 ;;
  esac
  dir="${file%/*}"; tail="${file##*/}"
  [ "$dir" = "$file" ] && return 1   # not an absolute/─slashed path
  while [ "$depth" -lt 64 ]; do
    if [ -d "$dir" ] && [ "$dir" -ef "$root" ]; then
      printf '%s' "$tail"; return 0
    fi
    parent="${dir%/*}"
    [ -n "$parent" ] || parent="/"
    [ "$parent" = "$dir" ] && return 1
    tail="${dir##*/}/$tail"
    dir="$parent"
    depth=$((depth + 1))
  done
  return 1
}

# Absolute artifact root (where docs/specs and docs/plans live) for `path`,
# defaulting to $PWD. Delegates to scripts/resolve-artifact-root.sh so the
# resolution order lives in exactly one place; degrades to the repo root when
# the resolver is absent (pre-resolver installs), which is the old behavior.
mtk_artifact_root() {
  local target="${1:-$PWD}" script here out
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)" || here=""
  script="${here:-.}/scripts/resolve-artifact-root.sh"
  [ -f "$script" ] || script="${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-artifact-root.sh"
  if [ -f "$script" ]; then
    out="$(bash "$script" "$target" 2>/dev/null || true)"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  fi
  mtk_repo_root
}

# Bind this hook process to the payload's session_id, so the session ledger
# below is keyed on the session rather than on project+date. Without it, two
# sessions open in the same repo on the same day share one ledger, and a
# verification run in one satisfies the completion check of the other. Call it
# once, right after reading the payload and before the first mtk_session_file.
# A payload without session_id leaves the process unbound (project+date key).
mtk_session_bind() {
  local sid
  sid="$(mtk_extract_json_string "${1:-}" "session_id" 2>/dev/null || true)"
  sid="${sid//[^A-Za-z0-9._-]/_}"
  _MTK_SESSION_ID="${sid:0:64}"
}

# Memoized per process: hooks call this repeatedly (lock acquire/release each
# recompute it) and every call used to spawn a cksum|cut pipeline plus date.
# Keyed by TMPDIR and session id so tests that re-point TMPDIR within one
# process stay correct. The key is the bound session id when there is one
# (mtk_session_bind), otherwise the project+date key.
mtk_session_file() {
  local tmpdir="${TMPDIR:-/tmp}" sid="${_MTK_SESSION_ID:-}"
  if [ -n "${_MTK_SESSION_FILE:-}" ] && [ "${_MTK_SESSION_FILE_TMPDIR:-}" = "$tmpdir" ] \
    && [ "${_MTK_SESSION_FILE_SID-unset}" = "$sid" ]; then
    printf '%s\n' "$_MTK_SESSION_FILE"
    return 0
  fi
  local project_id
  project_id=$(mtk_repo_root | cksum | cut -d' ' -f1)
  if [ -n "$sid" ]; then
    _MTK_SESSION_FILE="$(printf '%s/mtk-context-budget-%s-s-%s' "$tmpdir" "$project_id" "$sid")"
  else
    _MTK_SESSION_FILE="$(printf '%s/mtk-context-budget-%s-%s' "$tmpdir" "$project_id" "$(date +%Y%m%d)")"
  fi
  _MTK_SESSION_FILE_TMPDIR="$tmpdir"
  _MTK_SESSION_FILE_SID="$sid"
  printf '%s\n' "$_MTK_SESSION_FILE"
}

# Content fingerprint of the working tree relative to commit `base` (default
# HEAD; the empty tree in a repo with no commits). Prints "<base> <hash>", or
# returns 1 outside a git work tree.
#
# It hashes every path that differs from `base` (tracked changes, deletions and
# untracked, non-ignored files) together with the blob hash of its current
# content. Pass the base recorded with an earlier fingerprint to compare the
# two: committing exactly the verified changes moves HEAD but keeps the working
# tree, so diffing against the recorded base still yields the same hash, while
# any content change (an Edit, a sed -i, a formatter pass) yields a new one.
# GIT_OPTIONAL_LOCKS=0 keeps the index refresh from taking index.lock.
mtk_tree_fingerprint() {
  local root base path h i=0
  root="$(mtk_repo_root)"
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  base="${1:-}"
  if [ -z "$base" ] || ! git -C "$root" cat-file -e "${base}^{tree}" 2>/dev/null; then
    base="$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null || true)"
    [ -n "$base" ] || base="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  fi
  local -a paths=() present=() lines=()
  while IFS= read -r -d '' path; do
    paths+=("$path")
  done < <(
    {
      GIT_OPTIONAL_LOCKS=0 git -C "$root" diff --no-renames --name-only -z "$base" -- 2>/dev/null || true
      GIT_OPTIONAL_LOCKS=0 git -C "$root" ls-files -o --exclude-standard -z 2>/dev/null || true
    } | LC_ALL=C sort -zu
  )
  for path in ${paths[@]+"${paths[@]}"}; do
    if [ -f "$root/$path" ]; then
      present+=("$path")
    elif [ -e "$root/$path" ]; then
      lines+=("$path	nonfile")
    else
      lines+=("$path	deleted")
    fi
  done
  # One batched hash-object call. `--stdin-paths` stops at the first file it
  # cannot read, so every later path would silently go unhashed: when the hash
  # count does not match the path count, hash file by file, and record an
  # unreadable file as a marker plus a non-zero return so callers fall back to
  # the edit/verification seq comparison instead of trusting a blind hash.
  local failed=0
  if [ "${#present[@]}" -gt 0 ]; then
    local -a hashes=()
    while IFS= read -r h; do hashes+=("$h"); done < <(
      cd "$root" && printf '%s\n' "${present[@]}" | git hash-object --stdin-paths 2>/dev/null || true
    )
    if [ "${#hashes[@]}" -ne "${#present[@]}" ]; then
      hashes=()
      for path in "${present[@]}"; do
        h="$(cd "$root" && git hash-object -- "$path" 2>/dev/null)" || h=""
        [ -n "$h" ] || { h="unreadable"; failed=1; }
        hashes+=("$h")
      done
    fi
    for path in "${present[@]}"; do
      lines+=("$path	${hashes[$i]}")
      i=$((i + 1))
    done
  fi
  h="$(printf '%s\n' ${lines[@]+"${lines[@]}"} | LC_ALL=C sort | git hash-object --stdin 2>/dev/null)" || return 1
  [ "$failed" -eq 0 ] || h="${h}-unreadable"
  printf '%s %s\n' "$base" "$h"
  return "$failed"
}

# Record the session's baseline fingerprint before its first tool runs.
# Called from PreToolUse hooks (scope-guard for Edit|Write, format-on-edit
# --flush-before-verify for Bash) so the baseline is the tree BEFORE the first
# change; a PostToolUse baseline already contains the first tool's effect.
# Only records when the ledger has no baseline and no event yet; otherwise a
# mid-session baseline would read earlier Bash-made changes as "unchanged".
# Fast path (baseline present): one grep of the ledger, no git.
mtk_ensure_session_baseline() {
  [ -n "${1:-}" ] && mtk_session_bind "$1"
  local sf fp
  sf="$(mtk_session_file)"
  if [ -f "$sf" ] && grep -q "^session_start_tree='[0-9a-f]" "$sf" 2>/dev/null; then
    return 0
  fi
  if [ -f "$sf" ] && ! grep -q '^event_seq=0$' "$sf" 2>/dev/null; then
    return 0
  fi
  fp="$(mtk_tree_fingerprint 2>/dev/null)" || return 0
  mtk_session_lock_acquire "$sf"
  mtk_load_session_state "$sf"
  if [ -z "${session_start_tree:-}" ] && [ "${event_seq:-0}" -eq 0 ]; then
    session_start_base="${fp%% *}"
    session_start_tree="${fp#* }"
    mtk_save_session_state "$sf"
  fi
  mtk_session_lock_release "$sf"
}

# Extract the first string value for `key` from a JSON payload.
# The parser walks the string body character-by-character so that escaped quotes
# (\") no longer terminate the value prematurely — that bug let destructive
# commands slip past the security gate.
# Exits non-zero if the key is not present.
mtk_extract_json_string() {
  local payload="$1"
  local key="$2"
  local output

  output=$(printf '%s' "$payload" | awk -v key="$key" '
    { buf = (NR == 1 ? $0 : buf "\n" $0) }
    END {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
      if (!match(buf, pattern)) exit 1
      start = RSTART + RLENGTH
      out = ""
      esc = 0
      len = length(buf)
      for (i = start; i <= len; i++) {
        c = substr(buf, i, 1)
        if (esc) {
          if (c == "n") out = out "\n"
          else if (c == "t") out = out "\t"
          else if (c == "r") out = out "\r"
          else if (c == "\"") out = out "\""
          else if (c == "\\") out = out "\\"
          else if (c == "/") out = out "/"
          else if (c == "b") out = out "\b"
          else if (c == "f") out = out "\f"
          else out = out "\\" c
          esc = 0
          continue
        }
        if (c == "\\") { esc = 1; continue }
        if (c == "\"") { print out; exit 0 }
        out = out c
      }
      print out
      exit 0
    }
  ') || return 1

  printf '%s\n' "$output"
}

mtk_extract_tool_field() {
  local payload="$1"
  local key="$2"
  local value

  if value=$(mtk_extract_json_string "$payload" "$key"); then
    printf '%s\n' "$value"
    return 0
  fi

  return 1
}

mtk_extract_tool_name() {
  local payload="$1"
  mtk_extract_tool_field "$payload" "tool_name"
}

mtk_extract_command() {
  local payload="$1"
  mtk_extract_tool_field "$payload" "command"
}

mtk_extract_file_path() {
  local payload="$1"
  local key

  for key in file_path filePath path; do
    if mtk_extract_tool_field "$payload" "$key"; then
      return 0
    fi
  done

  return 1
}

# Escape a value so it can be placed inside a bash single-quoted string.
# Turns `pytest -k 'foo'` into `pytest -k '\''foo'\''`, which when wrapped as
# '<escaped>' round-trips exactly back to the original under `. file`.
mtk_sq_escape() {
  printf '%s' "${1:-}" | sed "s/'/'\\\\''/g"
}

# Advisory session-file lock using atomic mkdir (portable; no flock dependency).
# Best-effort: after ~5s of contention we continue anyway to avoid stalling
# interactive hooks. Paired with atomic-rename writes in mtk_save_session_state
# so a dropped lock never leaves a half-written state file visible to readers.
# Both lock helpers accept the session-file path as $1 so callers that already
# computed it don't pay the cksum|cut + date pipeline again (memoization inside
# mtk_session_file cannot help here — `$(...)` runs it in a subshell, so the
# memo never reaches the parent). No-arg calls keep the old behavior.
mtk_session_lock_acquire() {
  local lock
  lock="${1:-$(mtk_session_file)}.lock"
  local tries=0
  # A live holder keeps this lock for single-digit milliseconds (load state →
  # update counters → save). So a lock older than a couple of seconds is not
  # contention, it is a corpse: the harness SIGTERMs a hook that overruns its
  # `timeout` (context-budget.sh runs under `timeout: 3`), and SIGTERM does not
  # run the EXIT trap, so the directory outlives the process that made it.
  # Without stealing it, every later hook pays the full spin below — 100 × 50ms
  # of dead wall-clock on the next tool call, for a counter nobody blocks on.
  local stale_secs="${MTK_SESSION_LOCK_STALE_SECS:-2}"
  local mtime now
  while ! mkdir "$lock" 2>/dev/null; do
    # Increment first: every path through this loop must advance the counter, or
    # a lock we can see but cannot rmdir spins forever.
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ]; then
      return 0
    fi
    mtime=$(stat -c '%Y' "$lock" 2>/dev/null || stat -f '%m' "$lock" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ "$mtime" -gt 0 ] && [ "$((now - mtime))" -ge "$stale_secs" ]; then
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
}

mtk_session_lock_release() {
  local lock
  lock="${1:-$(mtk_session_file)}.lock"
  rmdir "$lock" 2>/dev/null || true
}

mtk_init_session_state() {
  local session_file="$1"
  [ -f "$session_file" ] && return 0

  cat > "$session_file" <<'EOF'
reads=0
files=''
mods=0
ops=0
warned_files=0
warned_mods=0
warned_ops=0
scope_guard_warnings=0
benchmarks_run=0
benchmark_last_score=''
event_seq=0
last_edit_epoch=0
last_edit_seq=0
last_verification_epoch=0
last_verification_seq=0
last_verification_command=''
last_verification_summary=''
last_verification_status='unknown'
last_verification_scope='full'
last_verification_base=''
last_verification_tree=''
session_start_base=''
session_start_tree=''
model_id=''
bytes_read=0
warned_ctxpct=0
EOF
}

mtk_load_session_state() {
  local session_file="$1"
  mtk_init_session_state "$session_file"
  # shellcheck disable=SC1090
  . "$session_file"

  reads=${reads:-0}
  files=${files:-}
  mods=${mods:-0}
  ops=${ops:-0}
  warned_files=${warned_files:-0}
  warned_mods=${warned_mods:-0}
  warned_ops=${warned_ops:-0}
  scope_guard_warnings=${scope_guard_warnings:-0}
  benchmarks_run=${benchmarks_run:-0}
  benchmark_last_score=${benchmark_last_score:-}
  event_seq=${event_seq:-0}
  last_edit_epoch=${last_edit_epoch:-0}
  last_edit_seq=${last_edit_seq:-0}
  last_verification_epoch=${last_verification_epoch:-0}
  last_verification_seq=${last_verification_seq:-0}
  last_verification_command=${last_verification_command:-}
  last_verification_summary=${last_verification_summary:-}
  last_verification_status=${last_verification_status:-unknown}
  last_verification_scope=${last_verification_scope:-full}
  last_verification_base=${last_verification_base:-}
  last_verification_tree=${last_verification_tree:-}
  session_start_base=${session_start_base:-}
  session_start_tree=${session_start_tree:-}
  model_id=${model_id:-}
  bytes_read=${bytes_read:-0}
  warned_ctxpct=${warned_ctxpct:-0}
}

# Write the session state via escaped-single-quoted values and an atomic
# temp-file rename. Every string field is passed through mtk_sq_escape so that
# embedded single quotes survive the round-trip through `. $session_file`.
mtk_save_session_state() {
  local session_file="$1"
  local tmp="${session_file}.tmp.$$"
  local files_esc bench_esc cmd_esc sum_esc model_esc
  files_esc=$(mtk_sq_escape "${files:-}")
  model_esc=$(mtk_sq_escape "${model_id:-}")
  bench_esc=$(mtk_sq_escape "${benchmark_last_score:-}")
  cmd_esc=$(mtk_sq_escape "${last_verification_command:-}")
  sum_esc=$(mtk_sq_escape "${last_verification_summary:-}")

  {
    printf "reads=%s\n" "${reads:-0}"
    printf "files='%s'\n" "$files_esc"
    printf "mods=%s\n" "${mods:-0}"
    printf "ops=%s\n" "${ops:-0}"
    printf "warned_files=%s\n" "${warned_files:-0}"
    printf "warned_mods=%s\n" "${warned_mods:-0}"
    printf "warned_ops=%s\n" "${warned_ops:-0}"
    printf "scope_guard_warnings=%s\n" "${scope_guard_warnings:-0}"
    printf "benchmarks_run=%s\n" "${benchmarks_run:-0}"
    printf "benchmark_last_score='%s'\n" "$bench_esc"
    printf "event_seq=%s\n" "${event_seq:-0}"
    printf "last_edit_epoch=%s\n" "${last_edit_epoch:-0}"
    printf "last_edit_seq=%s\n" "${last_edit_seq:-0}"
    printf "last_verification_epoch=%s\n" "${last_verification_epoch:-0}"
    printf "last_verification_seq=%s\n" "${last_verification_seq:-0}"
    printf "last_verification_command='%s'\n" "$cmd_esc"
    printf "last_verification_summary='%s'\n" "$sum_esc"
    printf "last_verification_status='%s'\n" "${last_verification_status:-unknown}"
    printf "last_verification_scope='%s'\n" "${last_verification_scope:-full}"
    # Base commit and tree hash from mtk_tree_fingerprint: hex, no escaping needed.
    printf "last_verification_base='%s'\n" "${last_verification_base:-}"
    printf "last_verification_tree='%s'\n" "${last_verification_tree:-}"
    printf "session_start_base='%s'\n" "${session_start_base:-}"
    printf "session_start_tree='%s'\n" "${session_start_tree:-}"
    printf "model_id='%s'\n" "$model_esc"
    printf "bytes_read=%s\n" "${bytes_read:-0}"
    printf "warned_ctxpct=%s\n" "${warned_ctxpct:-0}"
  } > "$tmp"
  mv "$tmp" "$session_file"
}

mtk_trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

# Recognise build/test/validate invocations as "verification commands".
#
# A runner counts only in COMMAND POSITION: at the start of the command or of a
# segment after && || ; | ( or a backtick, behind the wrappers a real
# invocation uses — `VAR=x`, `env [-i] [-u N] VAR=x`, `time`, `timeout <dur>`,
# `docker compose run|exec [flags] <svc>`, `uv/poetry run`, `npx`,
# `python -m`, `bash <script>`. `cd <dir> && …` needs no special case: `&&`
# starts a new segment. As an argument (`echo dotnet test`, `grep dotnet test
# README`), inside a quoted string (`git commit -m "run pytest"`) or in a
# heredoc body it never counts — matching it anywhere stamped the ledger as
# verified on commands that ran nothing.
#
# Quoted text is kept as a single opaque word (marked with \002) so a quoted
# script path still resolves (`bash "${CLAUDE_PLUGIN_ROOT}/scripts/
# mtk-verify-run.sh" -- …`) while a quoted runner name never matches.
# POSIX awk only (macOS awk has no gawk extensions).
mtk_command_is_verification() {
  awk '
    function clean(t) { gsub(/\002/, "", t); return t }
    function base(t,   b) { b = clean(t); sub(/^.*\//, "", b); return b }
    function is_flag(t) { return substr(t, 1, 1) == "-" }
    function runner(w, a1, a2,   b) {
      if (index(w, "\002") == 0) {
        b = base(w)
        if (b == "pytest" || b == "py.test" || b == "mypy" || b == "tsc") return 1
        if (b == "ruff" && a1 == "check") return 1
        if (b == "dotnet" && (a1 == "build" || a1 == "test")) return 1
        if ((b == "npm" || b == "pnpm" || b == "bun") && (a1 == "test" || (a1 == "run" && a2 ~ /^(test|build)/))) return 1
        if (b == "yarn" && (a1 == "test" || a1 == "build" || (a1 == "run" && a2 ~ /^(test|build)/))) return 1
        if (b == "make" && a1 ~ /^(test|check)/) return 1
        if (b == "go" && a1 == "test") return 1
        if (b == "cargo" && (a1 == "test" || a1 == "build" || a1 == "check")) return 1
      }
      if (clean(w) ~ /(^|\/)scripts\/(validate-toolkit|run-benchmarks|mtk-verify-run)\.sh$/) return 1
      return 0
    }
    function judge(seg,   n, t, k, w) {
      n = split(seg, t, /[ \t]+/)
      k = 1
      while (k <= n && t[k] == "") k++
      while (k <= n) {
        w = t[k]
        if (w ~ /^[a-z_][a-z0-9_]*=/ || w == "time" || w == "command" || w == "exec" || w == "nice" || w == "nohup" || w == "then" || w == "do" || w == "else" || w == "elif" || w == "if" || w == "while" || w == "until" || w == "!" || w == "sudo") { k++; continue }
        if (w == "env") {
          k++
          while (k <= n && (is_flag(t[k]) || t[k] ~ /^[a-z_][a-z0-9_]*=/)) { if (t[k] == "-u") k++; k++ }
          continue
        }
        if (w == "timeout" || w == "gtimeout") {
          k++
          while (k <= n && is_flag(t[k])) { if (t[k] == "-k" || t[k] == "-s") k++; k++ }
          k++
          continue
        }
        if ((w == "docker" && t[k+1] == "compose") || w == "docker-compose") {
          k += (w == "docker") ? 2 : 1
          if (t[k] != "run" && t[k] != "exec") return 0
          k++
          while (k <= n && is_flag(t[k])) {
            if (t[k] ~ /^(-e|--env|-w|--workdir|-u|--user|-v|--volume|--entrypoint|--name|-p|--publish|-l|--label)$/) k++
            k++
          }
          k++
          continue
        }
        if ((w == "uv" || w == "poetry" || w == "pipenv" || w == "pdm" || w == "hatch") && t[k+1] == "run") {
          k += 2
          while (k <= n && is_flag(t[k])) k++
          continue
        }
        if (w == "npx" || w == "bunx" || w == "pnpx") {
          k++
          while (k <= n && is_flag(t[k])) k++
          continue
        }
        if ((w == "pnpm" && (t[k+1] == "exec" || t[k+1] == "dlx")) || (w == "yarn" && t[k+1] == "dlx")) { k += 2; continue }
        if ((w ~ /^python[0-9.]*$/ || w == "py") && t[k+1] == "-m") { k += 2; continue }
        if (w == "bash" || w == "sh" || w == "zsh") {
          k++
          while (k <= n && is_flag(t[k]) && t[k] != "-c") k++
          if (t[k] == "-c") return 0
          continue
        }
        break
      }
      if (k > n) return 0
      if (!runner(t[k], t[k+1], t[k+2])) return 0
      # A runner asked to list, describe or print its version runs no test:
      # `pytest --collect-only`, `dotnet test --list-tests`, `--help`, `--version`.
      for (x = k + 1; x <= n; x++)
        if (t[x] ~ /^(--collect-only|--co|--help|-h|--version|--list-tests)(=.*)?$/) return 0
      return 1
    }
    {
      line = tolower($0)
      if (hd != "") {
        tl = line; gsub(/^[ \t]+|[ \t]+$/, "", tl)
        if (tl == hd) { hd = ""; hbody = "" } else hbody = hbody "\n" line
        next
      }
      if (match(line, /<<-?[ \t]*["\047]?[a-z0-9_]+["\047]?/) && substr(line, RSTART - 1, 1) != "<") {
        w = substr(line, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", w); gsub(/["\047]/, "", w)
        hd = w
        line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
      }
      buf = buf "\n" line
    }
    END {
      # An unterminated delimiter is not a heredoc: its "body" is still command
      # text, so it is judged like any other line (same rule as security-gate).
      if (hd != "") buf = buf hbody
      out = ""; q = ""; n = length(buf)
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (q == "") {
          if (c == "\\") { out = out "_"; i++; continue }
          if (c == "\047" || c == "\"") { q = c; out = out "\002"; continue }
          out = out c
        } else {
          if (q == "\"" && c == "\\") { out = out "_"; i++; continue }
          if (c == q) { q = ""; continue }
          if (c ~ /[a-z0-9_.\/$:+-]/) out = out c; else out = out "_"
        }
      }
      gsub(/\$\{[a-z0-9_]*\}/, "$v", out)
      gsub(/&&|\|\|/, "\n", out)
      gsub(/[;|&(){}`]/, "\n", out)
      m = split(out, segs, "\n")
      for (s = 1; s <= m; s++) if (judge(segs[s])) exit 0
      exit 1
    }
  ' <<<"${1:-}"
}

# Can this command's exit status be attributed to the verification command
# inside it? Shell operators can mask the exit: `pytest || true` always exits
# 0, `pytest; echo done` exits with echo's status, `pytest | tee log` exits
# with tee's, `pytest &` detaches. Echoes one of:
#   yes        exit status is the verification command's
#   pass-only  `&&` chain — exit 0 proves the verification passed, but a
#              non-zero exit may belong to an earlier link, so only a pass
#              is attributable
#   no         operators mask the exit; trust output text only
# Does a (non-verification) Bash command write files? Used only for the
# edit-seq fallback, which decides staleness when no tree fingerprint is
# available (outside git, or an unreadable file), so a Bash-made edit after the
# last verification re-arms the gap there too. Deliberately broad: a false
# "wrote" only asks for one more verification run. Matches sed -i, perl -i,
# `>`/`>>` to anything but /dev/*, tee to a file, mv, cp, rm, patch, git apply,
# git checkout -- …, git restore.
mtk_command_writes_files() {
  local c="${1:-}"
  [ -n "$c" ] || return 1
  grep -qE '(^|[;&|(`[:space:]])(mv|cp|rm|patch)([[:space:]]|$)' <<<"$c" && return 0
  grep -qE '(^|[;&|(`[:space:]])sed[[:space:]]+([^|;&]*[[:space:]])?(-[A-Za-z]*i|--in-place)' <<<"$c" && return 0
  grep -qE '(^|[;&|(`[:space:]])perl[[:space:]]+([^|;&]*[[:space:]])?-[A-Za-z]*i' <<<"$c" && return 0
  grep -qE '(^|[;&|(`[:space:]])git[[:space:]]+([^|;&]*[[:space:]])?(apply|restore)([[:space:]]|$)' <<<"$c" && return 0
  grep -qE '(^|[;&|(`[:space:]])git[[:space:]]+([^|;&]*[[:space:]])?checkout[[:space:]]([^|;&]*[[:space:]])?--([[:space:]]|$)' <<<"$c" && return 0
  grep -qE '(^|[;&|(`[:space:]])tee[[:space:]]+(-[a-z]+[[:space:]]+)*[^-/[:space:]]' <<<"$c" && return 0
  grep -qE '(^|[;&|(`[:space:]])tee[[:space:]]+(-[a-z]+[[:space:]]+)*/([^d]|d[^e]|de[^v])' <<<"$c" && return 0
  # A redirect to a path: `>`/`>>` not part of `2>&1`/`>&2`, and not to /dev/*.
  grep -qE '(^|[^0-9&<>])>>?[[:space:]]*([^&[:space:]/>]|/([^d[:space:]]|d[^e]|de[^v]))' <<<"$c" && return 0
  return 1
}

mtk_verification_exit_attributable() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || { printf 'no\n'; return 0; }

  # `||` masks the exit outright.
  case "$cmd" in *'||'*) printf 'no\n'; return 0 ;; esac

  # Pipes: the pipeline exits with the LAST segment's status, so a piped
  # verification command's exit is not observable (matches the S4.12 rule
  # that verification output must not be piped anyway).
  local stripped="${cmd//||/}"
  case "$stripped" in *'|'*) printf 'no\n'; return 0 ;; esac

  # Backgrounding detaches the exit. Strip `&&` and fd-redirect forms
  # (2>&1, >&2, &>, <&) first — those are redirects, not backgrounding.
  local bg="${cmd//&&/}"
  bg="$(printf '%s' "$bg" | sed -E 's/[0-9]*>&[0-9]*//g; s/&>>?//g; s/<&[0-9-]*//g')"
  case "$bg" in *'&'*) printf 'no\n'; return 0 ;; esac

  # `;` sequences: the line exits with the LAST segment's status, so the
  # verification command must BE the last segment.
  case "$cmd" in
    *';'*)
      local last="${cmd##*;}"
      if mtk_command_is_verification "$last"; then
        case "$cmd" in *'&&'*) printf 'pass-only\n' ;; *) printf 'yes\n' ;; esac
      else
        printf 'no\n'
      fi
      return 0
      ;;
  esac

  # `&&` chain: exit 0 proves every link (incl. the verification) succeeded;
  # a non-zero exit may be an earlier link's, so attribute passes only.
  case "$cmd" in *'&&'*) printf 'pass-only\n'; return 0 ;; esac

  printf 'yes\n'
}

# Classify the verification command's scope: did it exercise the whole repo
# (full) or a named slice (targeted)? A targeted run must never satisfy a
# repo-green claim ("all tests pass") — one test file is not the suite.
# Heuristic per the trailing args AFTER the runner token: selector flags
# (-k/--filter/--grep/--tests), `::` node ids, path-shaped args, and
# test-file-shaped names mark the run targeted. `./...` (Go's all-packages)
# stays full. Unknown shapes default to full — the nag must not flake.
mtk_verification_scope() {
  local cmd="${1:-}"
  [ -n "$cmd" ] || { printf 'full\n'; return 0; }
  local tok seen_runner=0
  for tok in $cmd; do
    if [ "$seen_runner" -eq 0 ]; then
      case "$tok" in
        *pytest*|*mypy*|*tsc*|*ruff*|*vitest*|*jest*|test|tests|check|*validate-toolkit.sh|*run-benchmarks.sh|*mtk-verify-run.sh)
          seen_runner=1 ;;
      esac
      continue
    fi
    case "$tok" in
      './...'|'...') continue ;;                       # Go all-packages: full
      -k|--filter|--filter=*|--grep|--grep=*|--tests|--tests=*|-k=*)
        printf 'targeted\n'; return 0 ;;
      --) continue ;;
      -*) continue ;;                                   # other flags: neutral
      *::*) printf 'targeted\n'; return 0 ;;            # pytest/jest node id
      */*) printf 'targeted\n'; return 0 ;;             # path argument
      test_*|*_test.*|*.test.*|*.spec.*|*Tests.*|spec_*)
        printf 'targeted\n'; return 0 ;;
    esac
  done
  printf 'full\n'
}

# Classify a verification command's observed output as pass|fail|unknown.
#
# A verification that RAN is not a verification that PASSED: without this, a
# pytest run with 12 failures still stamps the session ledger as "verified" and
# verify-completion accepts it as fresh evidence for a completion claim.
#
# Deliberately conservative in both directions — only unambiguous runner
# summary shapes classify; everything else is `unknown`, and `unknown` never
# blocks (a gate that flakes on innocent output is a gate people learn to
# skip). Fail shapes are checked first so "1 failed, 3 passed" reads as fail.
# Patterns avoid \b and line anchors: BSD grep lacks \b, and hook payloads
# carry JSON-escaped output where newlines are the two characters `\n`.
mtk_classify_verification_outcome() {
  local output="${1:-}"
  # $2: exit attributability from mtk_verification_exit_attributable
  # (yes|pass-only|no; default yes for back-compat). When shell operators
  # mask the exit (`pytest || true`, `pytest; echo done`), the harness's
  # structured exit fields describe the WHOLE line, not the verification
  # command — trusting them stamps PASS on a failing suite. With
  # attributability "no" the exit tiers are skipped and only the runner's
  # own output text classifies; with "pass-only" (&& chains) a zero exit
  # attributes but a non-zero exit may belong to an earlier link.
  local attr="${2:-yes}"
  [ -n "$output" ] || { printf 'unknown\n'; return 0; }

  # Structured fields outrank everything: some harnesses embed the exit code
  # in tool_response itself ("exit_code"/"returncode"/"success") — read the
  # harness's own verdict before trusting any text. Fail is checked before
  # pass at every tier.
  if [ "$attr" = "yes" ]; then
    if grep -qE '"(exit_code|returncode)"[[:space:]]*:[[:space:]]*[1-9][0-9]*' <<<"$output"; then
      printf 'fail\n'; return 0
    fi
    if grep -qE '"success"[[:space:]]*:[[:space:]]*false' <<<"$output"; then
      printf 'fail\n'; return 0
    fi
  fi
  if [ "$attr" != "no" ]; then
    if grep -qE '"(exit_code|returncode)"[[:space:]]*:[[:space:]]*0([^0-9]|$)' <<<"$output"; then
      printf 'pass\n'; return 0
    fi
  fi

  # Next: the scripts/mtk-verify-run.sh wrapper emits a machine-readable
  # `exit=N` line (verification-evidence-contract.md). The wrapper composes
  # the line itself, so it stays trustworthy regardless of surrounding
  # operators — but a masked non-zero line exit still gates the fail side.
  if [ "$attr" = "yes" ]; then
    if grep -qE '(^|[^A-Za-z0-9_])exit=[1-9][0-9]*([^0-9]|$)' <<<"$output"; then
      printf 'fail\n'; return 0
    fi
  fi
  if [ "$attr" != "no" ]; then
    if grep -qE '(^|[^A-Za-z0-9_])exit=0([^0-9]|$)' <<<"$output"; then
      printf 'pass\n'; return 0
    fi
  fi

  local fail_pattern='(Build FAILED'
  fail_pattern+='|Failed!'
  fail_pattern+='|[1-9][0-9]* (failed|failing)'
  fail_pattern+='|Failed:[[:space:]]*[1-9]'
  fail_pattern+='|FAILED \(failures='
  fail_pattern+='|error (CS|MSB)[0-9]+'
  fail_pattern+='|npm ERR!'
  fail_pattern+='|Traceback \(most recent call last\)'
  fail_pattern+='|(^|[^A-Za-z_])FAIL([^A-Za-z_]|$)'
  fail_pattern+=')'

  local pass_pattern='(Build succeeded'
  pass_pattern+='|Passed!'
  pass_pattern+='|Toolkit validation passed'
  pass_pattern+='|[1-9][0-9]* passed'
  pass_pattern+='|OK \([0-9]+ test'
  pass_pattern+='|All checks passed'
  pass_pattern+='|Success: no issues found'
  pass_pattern+=')'

  if grep -qE "$fail_pattern" <<<"$output"; then
    printf 'fail\n'
  elif grep -qE "$pass_pattern" <<<"$output"; then
    printf 'pass\n'
  else
    printf 'unknown\n'
  fi
}

mtk_record_scope_guard_warning() {
  local session_file
  session_file="$(mtk_session_file)"
  mtk_session_lock_acquire "$session_file"
  mtk_load_session_state "$session_file"
  scope_guard_warnings=$((scope_guard_warnings + 1))
  mtk_save_session_state "$session_file"
  mtk_session_lock_release "$session_file"
}

mtk_record_benchmark_run() {
  local score="$1"
  local session_file
  session_file="$(mtk_session_file)"
  mtk_session_lock_acquire "$session_file"
  mtk_load_session_state "$session_file"
  benchmarks_run=$((benchmarks_run + 1))
  benchmark_last_score="$score"
  mtk_save_session_state "$session_file"
  mtk_session_lock_release "$session_file"
}
