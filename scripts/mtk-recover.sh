#!/usr/bin/env bash
# Recover a PreCompact snapshot. Lists snapshots from the log, applies the
# selected one, and points the engineer at git stash for further inspection.
set -euo pipefail

LOG=".claude/observability/precompact-snapshots.log"

if [ ! -f "$LOG" ]; then
  printf 'No snapshots recorded (%s missing).\n' "$LOG" >&2
  exit 1
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  printf 'Not inside a git work tree.\n' >&2
  exit 1
}

# Filter to saved entries, newest first.
mapfile -t ENTRIES < <(grep -E $'\tsaved\t' "$LOG" | tac)
if [ "${#ENTRIES[@]}" -eq 0 ]; then
  printf 'No saved snapshots in %s.\n' "$LOG"
  exit 0
fi

printf 'PreCompact snapshots (newest first):\n\n'
i=0
for line in "${ENTRIES[@]}"; do
  i=$((i + 1))
  TS="$(printf '%s' "$line" | cut -f1)"
  BRANCH="$(printf '%s' "$line" | cut -f3)"
  MSG="$(printf '%s' "$line" | cut -f4)"
  # Check if the stash still exists.
  if git stash list 2>/dev/null | grep -q "$MSG"; then
    STATUS="present"
  else
    STATUS="dropped"
  fi
  printf '  [%d] %s  branch=%s  %s  (%s)\n' "$i" "$TS" "$BRANCH" "$MSG" "$STATUS"
done

printf '\nEnter number to apply (or q to quit): '
read -r CHOICE

if [ "$CHOICE" = "q" ] || [ -z "$CHOICE" ]; then
  exit 0
fi

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#ENTRIES[@]}" ]; then
  printf 'Invalid choice.\n' >&2
  exit 1
fi

LINE="${ENTRIES[$((CHOICE - 1))]}"
MSG="$(printf '%s' "$LINE" | cut -f4)"

# Find the stash by message.
STASH_REF="$(git stash list 2>/dev/null | grep -F "$MSG" | head -1 | cut -d: -f1 || true)"
if [ -z "$STASH_REF" ]; then
  printf 'Stash %s no longer exists. Inspect: git fsck --unreachable\n' "$MSG" >&2
  exit 1
fi

printf 'Applying %s (%s)...\n' "$STASH_REF" "$MSG"
git stash apply "$STASH_REF"
printf '\nApplied. The stash is still in the list — drop it after verifying with: git stash drop %s\n' "$STASH_REF"
