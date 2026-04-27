#!/usr/bin/env bash
set -euo pipefail
# post-commit-refresh.sh — opt-in git post-commit hook that rebuilds derived
# MTK artifacts when their inputs change.
#
# Enable per-repo:  git config core.hooksPath hooks/git-hooks
# Or copy to .git/hooks/post-commit and chmod +x.
#
# Triggers:
#   - .claude/references/   → rebuild references.index
#   - .claude/skills/**/SKILL.md → rebuild triggers.index
#   - .claude/manifest.json → run validator quick-check
# Silent on no-op. Always exits 0 (never blocks operations).

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# diff-tree against the empty tree on initial commit, otherwise HEAD~1.
if git rev-parse HEAD~1 >/dev/null 2>&1; then
  CHANGED=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null || true)
else
  CHANGED=$(git ls-tree --name-only -r HEAD 2>/dev/null || true)
fi

if [ -z "$CHANGED" ]; then
  exit 0
fi

reasons=()
if printf '%s\n' "$CHANGED" | grep -qE '^\.claude/references/'; then
  reasons+=("references")
fi
if printf '%s\n' "$CHANGED" | grep -qE '^\.claude/skills/.*/SKILL\.md$'; then
  reasons+=("triggers")
fi
if printf '%s\n' "$CHANGED" | grep -qE '^\.claude/manifest\.json$'; then
  reasons+=("manifest")
fi

if [ "${#reasons[@]}" -eq 0 ]; then
  exit 0
fi

bash "$REPO_ROOT/scripts/refresh-derived.sh" "${reasons[@]}" || true
exit 0
