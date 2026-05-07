#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PostToolUse hook: tracks session activity and warns when context is getting heavy.
# Maintains per-session counters in a temp file. Advisory only.
#
# Thresholds (tuned for Claude Code's ~200k usable context):
#   30+ unique files read  → narrow your focus
#   40+ modifications      → commit a checkpoint
#   120+ total operations  → consider handoff

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

INPUT=$(cat)

TOOL_NAME=$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")
[ -z "$TOOL_NAME" ] && exit 0

# Session-scoped state file (per-project, per-day). Hold the advisory lock for
# the full load→modify→save cycle so concurrent PreToolUse/PostToolUse firings
# don't lose counter updates through last-writer-wins races.
SESSION_FILE="$(mtk_session_file)"
mtk_session_lock_acquire
mtk_load_session_state "$SESSION_FILE"

# Update counters based on tool type
case "$TOOL_NAME" in
  Read)
    event_seq=$((event_seq + 1))
    reads=$((reads + 1))
    ops=$((ops + 1))
    # Track unique file paths and accumulate bytes read (for context load estimator)
    FILE_PATH=$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "")
    if [ -n "$FILE_PATH" ]; then
      if ! echo "$files" | grep -qF "$FILE_PATH"; then
        files="${files:+$files|}$FILE_PATH"
        # Accumulate bytes only for new unique files; cap at 100k to avoid inflating on large incidental reads
        if [ -f "$FILE_PATH" ]; then
          file_bytes=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ' || echo 0)
          [ "$file_bytes" -gt 100000 ] && file_bytes=100000
          bytes_read=$((bytes_read + file_bytes))
        fi
      fi
    fi
    ;;
  Edit|Write)
    event_seq=$((event_seq + 1))
    mods=$((mods + 1))
    ops=$((ops + 1))
    last_edit_epoch=$(date +%s)
    last_edit_seq=$event_seq
    ;;
  Bash)
    event_seq=$((event_seq + 1))
    ops=$((ops + 1))
    COMMAND=$(mtk_extract_command "$INPUT" 2>/dev/null || echo "")
    if [ -n "$COMMAND" ] && mtk_command_is_verification "$COMMAND"; then
      last_verification_epoch=$(date +%s)
      last_verification_seq=$event_seq
      last_verification_command=$(mtk_trim_whitespace "$COMMAND")
      last_verification_summary="$last_verification_command"
    fi
    ;;
  Glob|Grep)
    event_seq=$((event_seq + 1))
    ops=$((ops + 1))
    ;;
  *)
    event_seq=$((event_seq + 1))
    ops=$((ops + 1))
    ;;
esac

# Count unique files
unique_files=0
if [ -n "$files" ]; then
  unique_files=$(echo "$files" | tr '|' '\n' | wc -l | tr -d ' ')
fi

mtk_save_session_state "$SESSION_FILE"
mtk_session_lock_release

# Check thresholds (warn once per threshold)
if [ "$unique_files" -ge 30 ] && [ "$warned_files" -eq 0 ]; then
  sed -i.bak 's/warned_files=0/warned_files=1/' "$SESSION_FILE" && rm -f "${SESSION_FILE}.bak"
  echo "CONTEXT BUDGET: ${unique_files} unique files read this session. Consider narrowing focus to the files that matter for your current task. Use context-engineering to load only relevant references."
fi

if [ "$mods" -ge 40 ] && [ "$warned_mods" -eq 0 ]; then
  sed -i.bak 's/warned_mods=0/warned_mods=1/' "$SESSION_FILE" && rm -f "${SESSION_FILE}.bak"
  echo "CONTEXT BUDGET: ${mods} file modifications this session. Consider committing a checkpoint to preserve work. Long uncommitted sessions risk losing state on compaction."
fi

if [ "$ops" -ge 120 ] && [ "$warned_ops" -eq 0 ]; then
  sed -i.bak 's/warned_ops=0/warned_ops=1/' "$SESSION_FILE" && rm -f "${SESSION_FILE}.bak"
  echo "CONTEXT BUDGET: ${ops} total operations this session. Context window may be approaching limits. If switching tasks, capture state with the handoff skill first."
fi

exit 0
