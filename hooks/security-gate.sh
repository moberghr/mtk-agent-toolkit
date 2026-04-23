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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

INPUT=$(cat)

TOOL_NAME=$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")
COMMAND=$(mtk_extract_command "$INPUT" 2>/dev/null || echo "")

# If this is not a Bash payload, ignore it.
if [ -n "$TOOL_NAME" ] && [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

# Fail closed for Bash payloads we cannot parse.
if [ -z "$COMMAND" ]; then
  echo "BLOCKED: Unable to parse Bash command from hook payload. Re-run the command after fixing the hook payload shape." >&2
  exit 2
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
