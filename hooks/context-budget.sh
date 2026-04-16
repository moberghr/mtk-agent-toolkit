#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook: tracks session activity and warns when context is getting heavy.
# Maintains per-session counters in a temp file. Advisory only.
#
# Thresholds (tuned for Claude Code's ~200k usable context):
#   30+ unique files read  → narrow your focus
#   40+ modifications      → commit a checkpoint
#   120+ total operations  → consider handoff

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//' 2>/dev/null || echo "")
[ -z "$TOOL_NAME" ] && exit 0

# Session-scoped state file (per-project, per-day)
PROJECT_ID=$(pwd | cksum | cut -d' ' -f1)
SESSION_FILE="${TMPDIR:-/tmp}/mtk-context-budget-${PROJECT_ID}-$(date +%Y%m%d)"

# Initialize if missing
if [ ! -f "$SESSION_FILE" ]; then
  printf "reads=0\nfiles=''\nmods=0\nops=0\nwarned_files=0\nwarned_mods=0\nwarned_ops=0\n" > "$SESSION_FILE"
fi

# Source current counters (files field is single-quoted to protect | separators)
# shellcheck disable=SC1090
. "$SESSION_FILE"

# Update counters based on tool type
case "$TOOL_NAME" in
  Read)
    reads=$((reads + 1))
    ops=$((ops + 1))
    # Track unique file paths
    FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//' 2>/dev/null || echo "")
    if [ -n "$FILE_PATH" ]; then
      if ! echo "$files" | grep -qF "$FILE_PATH"; then
        files="${files:+$files|}$FILE_PATH"
      fi
    fi
    ;;
  Edit|Write)
    mods=$((mods + 1))
    ops=$((ops + 1))
    ;;
  Glob|Grep|Bash)
    ops=$((ops + 1))
    ;;
  *)
    ops=$((ops + 1))
    ;;
esac

# Count unique files
unique_files=0
if [ -n "$files" ]; then
  unique_files=$(echo "$files" | tr '|' '\n' | wc -l | tr -d ' ')
fi

# Save state (single-quote the files field to protect | separators)
cat > "$SESSION_FILE" <<EOF
reads=$reads
files='$files'
mods=$mods
ops=$ops
warned_files=$warned_files
warned_mods=$warned_mods
warned_ops=$warned_ops
EOF

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
