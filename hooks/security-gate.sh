#!/usr/bin/env bash
set -euo pipefail

# PreToolUse security gate for Bash commands.
# Receives JSON on stdin with tool_name, tool_input, etc.
# Exit 0 = allow, exit 2 = block.
#
# The deny list in settings.json handles exact pattern matches.
# This script catches nuanced destructive patterns that deny rules miss:
# - Force pushes with alternate syntax (--force-with-lease to protected branches)
# - Destructive operations disguised with flags or pipes
# - Database drop/truncate commands

INPUT=$(cat)

# Extract the command from the JSON input
COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//' 2>/dev/null || echo "")

# If we can't parse the command, allow it (fail-open for usability)
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Block: database destructive operations
if echo "$COMMAND" | grep -qiE '(DROP\s+(TABLE|DATABASE|SCHEMA)|TRUNCATE\s+TABLE|DELETE\s+FROM\s+\S+\s*;?\s*$)'; then
  echo "BLOCKED: Destructive database operation detected. Use a migration instead." >&2
  exit 2
fi

# Block: force push to main/master
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--(force|force-with-lease)\s+.*\b(main|master)\b'; then
  echo "BLOCKED: Force push to main/master is not allowed." >&2
  exit 2
fi

# Block: rm -rf on project root or broad paths
if echo "$COMMAND" | grep -qE 'rm\s+-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+(\.|/|~|\$HOME)'; then
  echo "BLOCKED: Recursive force-delete on broad path. Be more specific." >&2
  exit 2
fi

# Allow everything else
exit 0
