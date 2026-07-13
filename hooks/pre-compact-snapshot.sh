#!/usr/bin/env bash
# PreCompact hook: stash uncommitted work before auto-compaction so context loss
# never costs the engineer in-flight changes. Stash is applied immediately so
# the working tree is unchanged. Recover via scripts/mtk-recover.sh.
set -euo pipefail

# Never block compaction.
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

# Stash push/apply mutates git state — opt-in for plugin installs so team
# repos never get surprise stash entries. Project-local wiring (the toolkit's
# own settings.json) keeps the original always-on behavior.
SELF_DIR_P="$(cd "$(dirname "$0")" && pwd -P)"
PROJ_ROOT_P="$(cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" && pwd -P)"
case "$SELF_DIR_P/" in
  "$PROJ_ROOT_P"/*) : ;;
  *) [ "${MTK_COMPACT_SNAPSHOT:-0}" = "1" ] || exit 0 ;;
esac

# Read JSON payload (advisory; may be empty in some harnesses).
INPUT="$(cat 2>/dev/null || true)"

# Only act on auto-compaction. Manual /compact is user-initiated; respect that.
if [ -n "$INPUT" ]; then
  TRIGGER="$(printf '%s' "$INPUT" | grep -o '"trigger"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  if [ -n "$TRIGGER" ] && [ "$TRIGGER" != "auto" ]; then
    exit 0
  fi
fi

# Must be inside a git work tree.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Skip when a rebase/merge/cherry-pick is in flight — never interfere.
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null || true)"
if [ -n "$GIT_DIR" ]; then
  for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    if [ -e "$GIT_DIR/$marker" ]; then
      mkdir -p .claude/observability 2>/dev/null || true
      printf '%s\tskipped\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$marker" \
        >> .claude/observability/precompact-snapshots.log 2>/dev/null || true
      exit 0
    fi
  done
fi

# Skip clean trees.
if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
  # Also check for untracked files.
  if [ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    exit 0
  fi
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo DETACHED)"
MSG="mtk-precompact-${TS}"

# Stash with untracked files; do not keep index dirty for the user.
if ! git stash push --include-untracked --quiet -m "$MSG" >/dev/null 2>&1; then
  mkdir -p .claude/observability 2>/dev/null || true
  printf '%s\tfailed\tstash-push\t%s\n' "$TS" "$BRANCH" \
    >> .claude/observability/precompact-snapshots.log 2>/dev/null || true
  exit 0
fi

# Re-apply so the working tree is unchanged. Apply with --index first so a
# carefully staged index is restored exactly; a plain apply would flatten
# staged hunks back into the working tree. Fall back to plain apply if the
# index cannot be reinstated (e.g. conflicting staged/unstaged states).
if ! git stash apply --index --quiet stash@\{0\} >/dev/null 2>&1; then
  if ! git stash apply --quiet stash@\{0\} >/dev/null 2>&1; then
    printf '[mtk] precompact: stash created (%s) but apply failed — recover via: git stash apply\n' "$MSG" >&2
  fi
fi

mkdir -p .claude/observability 2>/dev/null || true
printf '%s\tsaved\t%s\t%s\n' "$TS" "$BRANCH" "$MSG" \
  >> .claude/observability/precompact-snapshots.log 2>/dev/null || true

printf '[mtk] precompact snapshot saved → %s (branch=%s)\n' "$MSG" "$BRANCH" >&2

exit 0
