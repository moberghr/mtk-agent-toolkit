#!/usr/bin/env bash
set -euo pipefail

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
