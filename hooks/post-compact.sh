#!/usr/bin/env bash
# PostCompact hook: re-inject key context after auto-compaction.
# Ensures the session doesn't lose awareness of tech stack, in-progress work,
# or active artifacts that were in the pre-compaction conversation.
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

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

# Active workflow artifact (durable orchestration state — survives compaction)
# Surfaces workflow type, phase, and last gate decision so the orchestrator
# resumes mid-flow without re-deriving state from chat history.
if [ -d .mtk/workflows ]; then
  ACTIVE_WF=$(grep -l '"status"[[:space:]]*:[[:space:]]*"active"' .mtk/workflows/*.json 2>/dev/null | head -1 || true)
  if [ -n "${ACTIVE_WF:-}" ]; then
    WF_BASENAME=$(basename "$ACTIVE_WF" .json)
    WF_TYPE=$(grep -o '"workflow_type"[[:space:]]*:[[:space:]]*"[^"]*"' "$ACTIVE_WF" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' || true)
    WF_PHASE=$(grep -o '"phase_cursor"[[:space:]]*:[[:space:]]*"[^"]*"' "$ACTIVE_WF" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' || true)
    WF_EVENTS=".mtk/workflows/${WF_BASENAME}.events.jsonl"
    LAST_EVENT=""
    if [ -f "$WF_EVENTS" ]; then
      LAST_EVENT=$(tail -1 "$WF_EVENTS" 2>/dev/null | grep -o '"event_type"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true)
    fi
    WF_MSG="Active workflow: ${WF_BASENAME} (type=${WF_TYPE:-?}, phase=${WF_PHASE:-?}"
    [ -n "${LAST_EVENT:-}" ] && WF_MSG="${WF_MSG}, last_event=${LAST_EVENT}"
    WF_MSG="${WF_MSG}) — read ${ACTIVE_WF} before advancing; do not re-init."
    CONTEXT="${CONTEXT} ${WF_MSG}"
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
