#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook for Edit|Write tools.
# When a markdown spec under docs/specs/ transitions to "status: approved",
# queue a tier-2 suggestion for planning-and-task-breakdown to run on the
# next user prompt.
#
# "Transition" = approved in the new content but NOT in the prior (HEAD)
# version of the same file. This avoids re-firing on every subsequent edit
# of an already-approved spec.
#
# Advisory only (exit 0). No-op if the spec path doesn't match, the marker
# is absent, the file was already approved, or the tier-2 kill-switch is off.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/skill-queue.sh"

mtk_queue_enabled || exit 0

INPUT="$(cat)"
FILE_PATH="$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "")"
[ -z "$FILE_PATH" ] && exit 0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REL_PATH="${FILE_PATH#"$REPO_ROOT"/}"

# Only fire for docs/specs/*.md
case "$REL_PATH" in
  docs/specs/*.md) ;;
  *) exit 0 ;;
esac

[ -f "$FILE_PATH" ] || exit 0

# Regex for the approved marker: matches bold list ("- **Status:** approved")
# or YAML frontmatter ("status: approved"). Case-insensitive on the value.
approved_in_content() {
  local file="$1"
  grep -qiE '^[[:space:]]*-[[:space:]]*\*\*[Ss]tatus:\*\*[[:space:]]*approved[[:space:]]*$' "$file" && return 0
  grep -qiE '^[[:space:]]*status:[[:space:]]*approved[[:space:]]*$' "$file" && return 0
  return 1
}

approved_in_content "$FILE_PATH" || exit 0

# Compare against the HEAD version to detect actual transition.
# If the file is brand-new (no HEAD version), treat as a transition.
prior_content=""
if git -C "$REPO_ROOT" cat-file -e "HEAD:$REL_PATH" 2>/dev/null; then
  prior_content="$(git -C "$REPO_ROOT" show "HEAD:$REL_PATH" 2>/dev/null || printf '')"
fi

if [ -n "$prior_content" ]; then
  # If HEAD already said approved, this is a no-op edit on an approved spec.
  if printf '%s\n' "$prior_content" | grep -qiE '^[[:space:]]*-[[:space:]]*\*\*[Ss]tatus:\*\*[[:space:]]*approved[[:space:]]*$' \
     || printf '%s\n' "$prior_content" | grep -qiE '^[[:space:]]*status:[[:space:]]*approved[[:space:]]*$'; then
    exit 0
  fi
fi

SLUG="$(basename "$REL_PATH" .md)"
REASON="spec ${REL_PATH} transitioned to status: approved"
EXCERPT="spec=${SLUG}"

# Dedup key: skill + source_hook means repeat approvals of different specs
# collapse to one line. That's acceptable for Phase 1 — the drain line names
# the spec in `reason`. If we need per-spec dedup later, encode slug in source_hook.
queue_skill "planning-and-task-breakdown" "$REASON" "spec-approval-trigger-${SLUG}" "$EXCERPT"

exit 0
