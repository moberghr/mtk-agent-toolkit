#!/usr/bin/env bash
set -euo pipefail

# Stop hook: reminds the agent to capture learnings after substantial sessions.
# Checks if corrections were captured in tasks/lessons.md. If the session was
# substantial but no lessons were recorded, prompts the agent.
# Also detects when 3+ lessons share a keyword, suggesting CLAUDE.md promotion.

# Check if the session was substantial (context-budget tracks this)
PROJECT_ID=$(pwd | cksum | cut -d' ' -f1)
SESSION_FILE="${TMPDIR:-/tmp}/mtk-context-budget-${PROJECT_ID}-$(date +%Y%m%d)"

ops=0
mods=0
files=''
if [ -f "$SESSION_FILE" ]; then
  # shellcheck disable=SC1090
  . "$SESSION_FILE"
fi

# Only trigger for substantial sessions (20+ operations or 5+ modifications)
if [ "$ops" -lt 20 ] && [ "$mods" -lt 5 ]; then
  exit 0
fi

# Check if tasks/lessons.md exists and was modified recently (within last 2 hours)
LESSONS_FILE="tasks/lessons.md"
LESSONS_MODIFIED=0

if [ -f "$LESSONS_FILE" ]; then
  # Check if lessons.md was modified in the last 2 hours
  if find "$LESSONS_FILE" -mmin -120 -print -quit 2>/dev/null | grep -q .; then
    LESSONS_MODIFIED=1
  fi
fi

# If substantial session but no lessons captured, remind
if [ "$LESSONS_MODIFIED" -eq 0 ]; then
  echo "LEARNING CHECK: Substantial session (${ops} operations, ${mods} modifications) with no lessons captured. If the engineer corrected your approach, redirected you, or a non-obvious pattern emerged, capture it in tasks/lessons.md using the correction-capture workflow. Lessons compound across sessions — without them, the same mistakes repeat."
fi

# If lessons exist, check for promotion candidates (3+ lessons with shared keywords)
if [ -f "$LESSONS_FILE" ] && [ -s "$LESSONS_FILE" ]; then
  # Count lessons by extracting ## headers
  LESSON_COUNT=$(grep -c '^## ' "$LESSONS_FILE" 2>/dev/null || echo "0")

  if [ "$LESSON_COUNT" -ge 3 ]; then
    # Extract Rule: lines and find repeated keywords (2+ word tokens appearing 3+ times)
    REPEATED=$(grep -i '^[*]*Rule:[*]*' "$LESSONS_FILE" 2>/dev/null \
      | tr '[:upper:]' '[:lower:]' \
      | tr -cs '[:alpha:]' '\n' \
      | sort \
      | uniq -c \
      | sort -rn \
      | awk '$1 >= 3 && length($2) > 4 { print $2 }' \
      | head -3)

    if [ -n "$REPEATED" ]; then
      KEYWORDS=$(echo "$REPEATED" | tr '\n' ', ' | sed 's/, $//')
      echo "PROMOTION CANDIDATE: ${LESSON_COUNT} lessons in tasks/lessons.md with recurring themes: ${KEYWORDS}. Consider promoting the pattern to a permanent rule in CLAUDE.md or .claude/rules/. Repeated corrections that stay in lessons.md don't compound — they just accumulate."
    fi
  fi
fi

exit 0
