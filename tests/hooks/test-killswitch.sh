#!/usr/bin/env bash
set -euo pipefail

# SC3: MTK_HOOKS_TIER2=0 silences everything — tier-1 nudges AND tier-2 drains.
# When re-enabled, the dispatcher resumes normal behaviour.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCH="$REPO_ROOT/hooks/userprompt-dispatch.sh"
QUEUE_DIR="$REPO_ROOT/.claude/queue"

cd "$REPO_ROOT"

# Clean slate
find "$QUEUE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true

# Write a queue entry directly
# shellcheck disable=SC1091
source "$REPO_ROOT/hooks/lib/skill-queue.sh"
MTK_HOOKS_TIER2=1 queue_skill "planning-and-task-breakdown" "test reason" "spec-approval-trigger" "excerpt"

correction_prompt='{"prompt":"no, not like that — do the other thing"}'

# With kill-switch OFF: no output, queue preserved
out_off="$(printf '%s' "$correction_prompt" | MTK_HOOKS_TIER2=0 "$DISPATCH")"
if [ -n "$out_off" ]; then
  printf 'FAIL: dispatcher emitted output with MTK_HOOKS_TIER2=0: %s\n' "$out_off" >&2
  exit 1
fi
if ! ls "$QUEUE_DIR"/*.json >/dev/null 2>&1; then
  printf 'FAIL: queue was drained even though kill-switch was off\n' >&2
  exit 1
fi
printf '  PASS  kill-switch silences dispatch and preserves queue\n'

# With kill-switch ON: nudge + drain both fire
out_on="$(printf '%s' "$correction_prompt" | MTK_HOOKS_TIER2=1 "$DISPATCH")"
if ! printf '%s' "$out_on" | grep -q 'MTK-NUDGE'; then
  printf 'FAIL: expected MTK-NUDGE after re-enable, got: %s\n' "$out_on" >&2
  exit 1
fi
if ! printf '%s' "$out_on" | grep -q 'MTK-QUEUED'; then
  printf 'FAIL: expected MTK-QUEUED after re-enable, got: %s\n' "$out_on" >&2
  exit 1
fi
printf '  PASS  re-enable surfaces both tier-1 nudge and tier-2 drain\n'

# Verify queue write is blocked while kill-switch is off
find "$QUEUE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
MTK_HOOKS_TIER2=0 queue_skill "planning-and-task-breakdown" "blocked" "spec-approval-trigger" "x"
if ls "$QUEUE_DIR"/*.json >/dev/null 2>&1; then
  printf 'FAIL: queue_skill wrote an entry with kill-switch off\n' >&2
  exit 1
fi
printf '  PASS  queue_skill respects kill-switch (no write)\n'

printf '\nAll killswitch checks passed.\n'
