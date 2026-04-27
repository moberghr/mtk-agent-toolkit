#!/usr/bin/env bash
set -euo pipefail

# SC2: editing a spec to include `- **Status:** approved` queues a
# planning-and-task-breakdown invocation. Editing an already-approved spec
# does not re-queue.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRIGGER="$REPO_ROOT/hooks/spec-approval-trigger.sh"
DISPATCH="$REPO_ROOT/hooks/userprompt-dispatch.sh"
QUEUE_DIR="$REPO_ROOT/.claude/queue"

cd "$REPO_ROOT"

# Clean queue
find "$QUEUE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true

# Create a temp spec that does NOT exist in HEAD — fresh transition path.
SPEC="docs/specs/__test-spec-approval-$$.md"
cleanup() {
  rm -f "$SPEC"
  find "$QUEUE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
}
trap cleanup EXIT

printf -- '# Test Spec\n\n- **Status:** approved\n' > "$SPEC"

# Simulate a PostToolUse Edit|Write payload referencing this file
payload=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$REPO_ROOT/$SPEC")

printf '%s' "$payload" | MTK_HOOKS_TIER2=1 "$TRIGGER"

if ! ls "$QUEUE_DIR"/*.json >/dev/null 2>&1; then
  printf 'FAIL: trigger did not queue entry for new approved spec\n' >&2
  exit 1
fi
printf '  PASS  newly-approved spec queued planning-and-task-breakdown\n'

# Drain and check content
drain_out="$(printf '{"prompt":"what next?"}' | MTK_HOOKS_TIER2=1 "$DISPATCH")"
if ! printf '%s' "$drain_out" | grep -q 'planning-and-task-breakdown'; then
  printf 'FAIL: drain did not surface planning-and-task-breakdown — got: %s\n' "$drain_out" >&2
  exit 1
fi
if ! printf '%s' "$drain_out" | grep -q "$SPEC"; then
  printf 'FAIL: drain did not include spec path — got: %s\n' "$drain_out" >&2
  exit 1
fi
printf '  PASS  drain surfaced skill + spec path\n'

# Second write (queue is now empty post-drain). Since this file never had HEAD
# version with approved, the trigger would fire again if it naively re-read
# current content. But we're simulating a realistic flow: the file is still
# un-committed, so HEAD has no approved marker — the trigger WILL fire again.
# This is expected for un-committed specs; dedup by (skill + source_hook+slug)
# collapses repeats in the same drain cycle.
#
# Test the "already approved in HEAD" path separately by staging.
find "$QUEUE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
git add "$SPEC"
# Commit on a throwaway branch to avoid polluting history
original_branch="$(git rev-parse --abbrev-ref HEAD)"
tmp_branch="__mtk-test-$$"
git checkout -q -b "$tmp_branch"
git -c user.email=test@mtk -c user.name=test commit -q -m "test: approved spec"

# Trigger again after HEAD already has approved marker
printf '%s' "$payload" | MTK_HOOKS_TIER2=1 "$TRIGGER"

queue_count=$(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [ "$queue_count" != "0" ]; then
  printf 'FAIL: trigger re-fired on already-approved spec (queue has %s entries)\n' "$queue_count" >&2
  # Cleanup before exiting
  git checkout -q "$original_branch"
  git branch -D "$tmp_branch" -q
  exit 1
fi
printf '  PASS  re-edit of already-approved spec does NOT re-queue\n'

# Cleanup the throwaway branch
git checkout -q "$original_branch"
git branch -D "$tmp_branch" -q 2>/dev/null || true

printf '\nAll spec-approval checks passed.\n'
