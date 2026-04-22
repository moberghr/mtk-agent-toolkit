#!/usr/bin/env bash
set -euo pipefail

# Shared helpers for Claude Code hook payload parsing and session-scoped state.
# Supports both legacy flat payloads ({"command": ...}) and nested tool_input
# payloads ({"tool_input": {"command": ...}}) using only the portable tools
# allowed by MTK's bash rules.

mtk_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

mtk_session_file() {
  local project_id
  project_id=$(mtk_repo_root | cksum | cut -d' ' -f1)
  printf '%s/mtk-context-budget-%s-%s\n' "${TMPDIR:-/tmp}" "$project_id" "$(date +%Y%m%d)"
}

mtk_extract_json_string() {
  local payload="$1"
  local key="$2"
  local match

  match=$(printf '%s' "$payload" | awk -v key="$key" '
    {
      while (match($0, "\"" key "\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"")) {
        print substr($0, RSTART, RLENGTH)
        exit
      }
    }
  ' 2>/dev/null || true)

  [ -n "$match" ] || return 1
  printf '%s\n' "$match" | sed 's/.*:[[:space:]]*"//;s/"$//'
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
}

mtk_save_session_state() {
  local session_file="$1"

  cat > "$session_file" <<EOF
reads=$reads
files='$files'
mods=$mods
ops=$ops
warned_files=$warned_files
warned_mods=$warned_mods
warned_ops=$warned_ops
event_seq=${event_seq:-0}
last_edit_epoch=${last_edit_epoch:-0}
last_edit_seq=${last_edit_seq:-0}
last_verification_epoch=${last_verification_epoch:-0}
last_verification_seq=${last_verification_seq:-0}
last_verification_command='${last_verification_command:-}'
last_verification_summary='${last_verification_summary:-}'
EOF
}

mtk_trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

mtk_command_is_verification() {
  local command
  command=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

  case "$command" in
    dotnet\ build*|dotnet\ test*|pytest*|ruff\ check*|mypy*|tsc\ --noemit*|tsc*|npm\ test*|npm\ run\ test*|npm\ run\ build*|pnpm\ test*|pnpm\ run\ test*|pnpm\ run\ build*|yarn\ test*|yarn\ run\ test*|yarn\ build*|yarn\ run\ build*|bun\ test*|bun\ run\ test*|bun\ run\ build*|bash\ scripts/validate-toolkit.sh*|bash\ scripts/run-benchmarks.sh*)
      return 0
      ;;
  esac

  return 1
}

mtk_verification_summary_for_command() {
  local command
  command=$(mtk_trim_whitespace "$1")
  printf '%s\n' "$command"
}
