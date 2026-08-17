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

mtk_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
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
mtk_read_payload() {
  local secs="${1:-4}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" cat 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" cat 2>/dev/null || true
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
# which flips the redundancy guard below into skipping the project's own hook.
# Fork-free: inputs are absolute normalised paths, so the parent is a suffix strip.
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

# Promotion guard: when this hook is a plugin-install copy (its own directory is
# outside the current project) AND the project also wires a hook of the same
# basename in its .claude/settings.json, the plugin copy is redundant and must
# not run — otherwise the hook fires twice. Returns 0 when the caller should
# exit early. Cheap: git toplevel + one grep of settings.json.
mtk_is_redundant_plugin_invocation() {
  local self="${1:-}"
  [ -n "$self" ] || return 1
  local self_dir project_root base settings
  self_dir="$(cd "$(dirname "$self")" 2>/dev/null && pwd -P)" || return 1
  # Prefer $CLAUDE_PROJECT_DIR over the git toplevel of cwd. A hook process is
  # not guaranteed to run with cwd inside the repo; when it doesn't, the git
  # probe falls back to `pwd`, the settings.json lookup below misses, the guard
  # fails open, and BOTH the plugin and project copies fire — the hook runs
  # twice. $CLAUDE_PROJECT_DIR is set by the harness and is cwd-independent.
  project_root="$(cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" 2>/dev/null && pwd -P)" || return 1
  # Physically inside the project → this IS the project copy; never skip. The
  # string-prefix test is only the fast path for the common exact-spelling case;
  # `mtk_path_is_within` is authoritative when the spellings differ.
  case "$self_dir/" in
    "$project_root"/*) return 1 ;;
  esac
  mtk_path_is_within "$self_dir" "$project_root" && return 1
  base="$(basename "$self")"
  settings="$project_root/.claude/settings.json"
  [ -f "$settings" ] || return 1
  grep -qF "hooks/$base" "$settings" 2>/dev/null || return 1
  # Skip only when the project-wired copy actually resolves — a dangling
  # settings entry (legacy bootstrap, no hooks/ dir) must not silence the
  # plugin copy too, or the hook fires from neither place.
  [ -f "$project_root/hooks/$base" ] && return 0
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

mtk_session_file() {
  local project_id
  project_id=$(mtk_repo_root | cksum | cut -d' ' -f1)
  printf '%s/mtk-context-budget-%s-%s\n' "${TMPDIR:-/tmp}" "$project_id" "$(date +%Y%m%d)"
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
mtk_session_lock_acquire() {
  local lock
  lock="$(mtk_session_file).lock"
  local tries=0
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ]; then
      return 0
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
}

mtk_session_lock_release() {
  local lock
  lock="$(mtk_session_file).lock"
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
  bytes_read=${bytes_read:-0}
  warned_ctxpct=${warned_ctxpct:-0}
}

# Write the session state via escaped-single-quoted values and an atomic
# temp-file rename. Every string field is passed through mtk_sq_escape so that
# embedded single quotes survive the round-trip through `. $session_file`.
mtk_save_session_state() {
  local session_file="$1"
  local tmp="${session_file}.tmp.$$"
  local files_esc bench_esc cmd_esc sum_esc
  files_esc=$(mtk_sq_escape "${files:-}")
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

# Recognise common build/test/validate invocations as "verification commands".
# Matches tokens anywhere in the command so real-world shapes like
# `cd services/api && dotnet test`, `env CI=1 pytest`, or `docker compose run
# --rm tests pytest` register correctly. Without this, the fresh-evidence check
# fired VERIFICATION GAP on commands that were clearly verifying.
mtk_command_is_verification() {
  local command
  command=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

  local pattern='(^|[[:space:]|&;(`])('
  pattern+='dotnet[[:space:]]+(build|test)'
  pattern+='|pytest'
  pattern+='|ruff[[:space:]]+check'
  pattern+='|mypy'
  pattern+='|tsc'
  pattern+='|npm[[:space:]]+(test|run[[:space:]]+(test|build))'
  pattern+='|pnpm[[:space:]]+(test|run[[:space:]]+(test|build))'
  pattern+='|yarn[[:space:]]+(test|build|run[[:space:]]+(test|build))'
  pattern+='|bun[[:space:]]+(test|run[[:space:]]+(test|build))'
  pattern+='|make[[:space:]]+(test|check)'
  pattern+='|go[[:space:]]+test'
  pattern+='|cargo[[:space:]]+(test|build|check)'
  pattern+='|bash[[:space:]]+scripts/(validate-toolkit|run-benchmarks)\.sh'
  pattern+=')'

  printf '%s' "$command" | grep -qE "$pattern"
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
  [ -n "$output" ] || { printf 'unknown\n'; return 0; }

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

  if printf '%s' "$output" | grep -qE "$fail_pattern"; then
    printf 'fail\n'
  elif printf '%s' "$output" | grep -qE "$pass_pattern"; then
    printf 'pass\n'
  else
    printf 'unknown\n'
  fi
}

mtk_record_scope_guard_warning() {
  local session_file
  session_file="$(mtk_session_file)"
  mtk_session_lock_acquire
  mtk_load_session_state "$session_file"
  scope_guard_warnings=$((scope_guard_warnings + 1))
  mtk_save_session_state "$session_file"
  mtk_session_lock_release
}

mtk_record_benchmark_run() {
  local score="$1"
  local session_file
  session_file="$(mtk_session_file)"
  mtk_session_lock_acquire
  mtk_load_session_state "$session_file"
  benchmarks_run=$((benchmarks_run + 1))
  benchmark_last_score="$score"
  mtk_save_session_state "$session_file"
  mtk_session_lock_release
}
