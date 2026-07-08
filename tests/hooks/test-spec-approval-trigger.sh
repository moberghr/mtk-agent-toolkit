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

# Test the "already approved in HEAD" path. Commit ONLY the test spec (never the
# operator's staged changes) and undo it with `reset --soft` — NO branch switch,
# so this never collides with an uncommitted working tree. The previous approach
# created a throwaway branch and `git checkout`-ed back, which overwrote in-flight
# work when the test was run mid-edit with a dirty tree.
find "$QUEUE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
spec_committed=0
undo_spec_commit() {
  if [ "$spec_committed" = 1 ]; then
    git reset -q --soft HEAD~1                            # drop temp commit; keep index + worktree
    spec_committed=0
  fi
  # Unstage the test spec whether or not the commit landed (belt-and-suspenders).
  git restore --staged -- "$SPEC" 2>/dev/null || git reset -q -- "$SPEC" 2>/dev/null || true
}
trap 'undo_spec_commit; cleanup' EXIT

git add -- "$SPEC"
git -c user.email=test@mtk -c user.name=test commit -q --only -m "test: approved spec (temp, auto-undone)" -- "$SPEC"
spec_committed=1

# Trigger again after HEAD already has the approved marker
printf '%s' "$payload" | MTK_HOOKS_TIER2=1 "$TRIGGER"

queue_count=$(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [ "$queue_count" != "0" ]; then
  printf 'FAIL: trigger re-fired on already-approved spec (queue has %s entries)\n' "$queue_count" >&2
  exit 1
fi
printf '  PASS  re-edit of already-approved spec does NOT re-queue\n'

undo_spec_commit

# ── Stale approval-seal detection (v7.25) ──
# A sealed spec edited after approval must re-queue the approval step; an
# unsealed/unrelated edit must not.
SEAL_SPEC="docs/specs/__test-seal-$$.md"
UNRELATED="docs/specs/__test-unsealed-$$.md"
SEAL_WF=""
seal_cleanup() {
  undo_spec_commit
  cleanup
  [ -n "$SEAL_WF" ] && rm -f "$REPO_ROOT/.mtk/workflows/$SEAL_WF.json" "$REPO_ROOT/.mtk/workflows/$SEAL_WF.events.jsonl"
  rm -f "$SEAL_SPEC" "${UNRELATED:-}"
}
trap seal_cleanup EXIT
find "$QUEUE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true

printf -- '# Sealed Spec\n\napproved body v1\n' > "$SEAL_SPEC"
SEAL_WF="$(bash scripts/workflow-artifact.sh init BUILD --goal 'seal hook test')"
bash scripts/workflow-artifact.sh seal "$SEAL_WF" "$SEAL_SPEC" >/dev/null
printf 'EDITED body v2\n' >> "$SEAL_SPEC"   # edit after seal → stale

seal_payload=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$REPO_ROOT/$SEAL_SPEC")
printf '%s' "$seal_payload" | MTK_HOOKS_TIER2=1 "$TRIGGER"

if ! grep -rq "seal STALE" "$QUEUE_DIR" 2>/dev/null; then
  printf 'FAIL: stale-sealed spec edit did not re-queue approval\n' >&2
  exit 1
fi
printf '  PASS  stale-sealed spec edit re-queued approval\n'

# Negative: an unsealed spec edit must NOT raise a stale-seal advisory.
find "$QUEUE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
printf -- '# Unsealed\n' > "$UNRELATED"
unrel_payload=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$REPO_ROOT/$UNRELATED")
printf '%s' "$unrel_payload" | MTK_HOOKS_TIER2=1 "$TRIGGER" || true
if grep -rq "seal STALE" "$QUEUE_DIR" 2>/dev/null; then
  printf 'FAIL: unsealed spec edit falsely raised a stale-seal advisory\n' >&2
  exit 1
fi
printf '  PASS  unsealed spec edit does not trigger stale-seal advisory\n'

printf '\nAll spec-approval checks passed.\n'
