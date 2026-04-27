#!/usr/bin/env bash
set -euo pipefail

# SC4: queue entries older than ttl_hours are skipped by the drain and
# deleted. The queue_expired counter is tracked.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCH="$REPO_ROOT/hooks/userprompt-dispatch.sh"
QUEUE_DIR="$REPO_ROOT/.claude/queue"

cd "$REPO_ROOT"

find "$QUEUE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
mkdir -p "$QUEUE_DIR"

# Write a synthetic entry with queued_epoch 48h in the past and ttl_hours=24.
past_epoch=$(($(date +%s) - 48 * 3600))
cat > "$QUEUE_DIR/stale.json" <<EOF
{
  "queued_at": "1970-01-01T00:00:00Z",
  "queued_epoch": $past_epoch,
  "skill": "planning-and-task-breakdown",
  "reason": "stale test entry",
  "context": { "excerpt": "x" },
  "ttl_hours": 24,
  "source_hook": "spec-approval-trigger-test"
}
EOF

out="$(printf '{"prompt":"hi"}' | MTK_HOOKS_TIER2=1 "$DISPATCH")"
if [ -n "$out" ]; then
  printf 'FAIL: expired entry was surfaced — got: %s\n' "$out" >&2
  exit 1
fi
if [ -f "$QUEUE_DIR/stale.json" ]; then
  printf 'FAIL: expired entry was not deleted\n' >&2
  exit 1
fi
printf '  PASS  expired entry skipped and removed\n'

# Fresh entry (ttl_hours=24, written now) must be surfaced.
now_epoch=$(date +%s)
cat > "$QUEUE_DIR/fresh.json" <<EOF
{
  "queued_at": "now",
  "queued_epoch": $now_epoch,
  "skill": "planning-and-task-breakdown",
  "reason": "fresh test entry",
  "context": { "excerpt": "x" },
  "ttl_hours": 24,
  "source_hook": "spec-approval-trigger-test"
}
EOF

out2="$(printf '{"prompt":"hi"}' | MTK_HOOKS_TIER2=1 "$DISPATCH")"
if ! printf '%s' "$out2" | grep -q 'planning-and-task-breakdown'; then
  printf 'FAIL: fresh entry was not surfaced — got: %s\n' "$out2" >&2
  exit 1
fi
printf '  PASS  fresh entry surfaced normally\n'

find "$QUEUE_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true

printf '\nAll queue-expiry checks passed.\n'
