#!/usr/bin/env bash
set -euo pipefail
#
# CI status helper — wraps gh CLI to fetch CI run status and build diagnostics.
# Outputs structured JSON for consumption by code-review-and-quality skill.
# If gh is not available or not authenticated, exits cleanly with empty result.

set -euo pipefail

# Check for gh CLI
if ! command -v gh &>/dev/null; then
  echo '{"available":false,"reason":"gh CLI not installed"}'
  exit 0
fi

# Check for gh auth
if ! gh auth status &>/dev/null 2>&1; then
  echo '{"available":false,"reason":"gh not authenticated"}'
  exit 0
fi

BRANCH="${1:-$(git branch --show-current 2>/dev/null || echo "")}"
[ -n "$BRANCH" ] || { echo '{"available":false,"reason":"not in a git repo or no branch"}'; exit 0; }

# Get PR number for current branch
PR_NUM="$(gh pr view "$BRANCH" --json number --jq '.number' 2>/dev/null || true)"

# Get check runs
if [ -n "$PR_NUM" ]; then
  CHECKS="$(gh pr checks "$PR_NUM" --json name,status,conclusion 2>/dev/null || echo '[]')"
  echo "{\"available\":true,\"branch\":\"$BRANCH\",\"pr\":$PR_NUM,\"checks\":$CHECKS}"
else
  # No PR — check latest run on branch
  RUN_STATUS="$(gh run list --branch "$BRANCH" --limit 1 --json status,conclusion,name,headSha 2>/dev/null || echo '[]')"
  echo "{\"available\":true,\"branch\":\"$BRANCH\",\"pr\":null,\"runs\":$RUN_STATUS}"
fi
