#!/usr/bin/env bash
# PostCompact hook: re-inject key context after auto-compaction.
# Ensures the session doesn't lose awareness of tech stack, in-progress work,
# or active artifacts that were in the pre-compaction conversation.
set -euo pipefail

CONTEXT=""

# Tech stack context
if [ -f .claude/tech-stack ]; then
  STACK=$(cat .claude/tech-stack)
  CONTEXT="Active tech stack: ${STACK}."
  if [ -f .claude/tech-stack-pm ]; then
    PM=$(cat .claude/tech-stack-pm)
    CONTEXT="${CONTEXT} Package manager: ${PM}."
  fi
fi

# In-progress spec (JSON sidecar — critical for drift detection)
if [ -d docs/specs ]; then
  RECENT_SPEC=$(find docs/specs -name '*.json' -mtime -1 2>/dev/null | head -1 || true)
  if [ -n "${RECENT_SPEC:-}" ]; then
    CONTEXT="${CONTEXT} Active spec: ${RECENT_SPEC} — read before resuming implementation or review."
  fi
fi

# In-progress plan
if [ -d docs/plans ]; then
  RECENT_PLAN=$(find docs/plans -name '*.md' -mtime -1 2>/dev/null | head -1 || true)
  if [ -n "${RECENT_PLAN:-}" ]; then
    CONTEXT="${CONTEXT} Active plan: ${RECENT_PLAN} — check tasks/todo.md for batch progress."
  fi
fi

# Incomplete tasks
if [ -f tasks/todo.md ] && grep -q '\[ \]' tasks/todo.md 2>/dev/null; then
  CONTEXT="${CONTEXT} Incomplete tasks in tasks/todo.md — check before starting new work."
fi

# Handoff artifact (session recovery)
if [ -d docs/handoffs ]; then
  RECENT_HANDOFF=$(find docs/handoffs -name '*.md' -mtime -1 2>/dev/null | head -1 || true)
  if [ -n "${RECENT_HANDOFF:-}" ]; then
    CONTEXT="${CONTEXT} Recent handoff: ${RECENT_HANDOFF} — read to resume previous session state."
  fi
fi

if [ -n "$CONTEXT" ]; then
  # Escape for JSON (no external deps — bash parameter substitution only)
  ESCAPED="${CONTEXT//\\/\\\\}"
  ESCAPED="${ESCAPED//\"/\\\"}"
  ESCAPED="${ESCAPED//$'\n'/\\n}"
  ESCAPED="${ESCAPED//$'\t'/\\t}"
  printf '{"context": "POST-COMPACTION RECOVERY: %s"}\n' "$ESCAPED"
fi
