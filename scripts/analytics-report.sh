#!/usr/bin/env bash
set -euo pipefail

# analytics-report.sh — Print a summary of MTK usage stats from .claude/analytics.json.
# Usage: bash scripts/analytics-report.sh

# Anchor to the project root so the report reads the same file the Stop hook
# writes, regardless of the CWD it is invoked from (S3.3: git only).
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ANALYTICS="${PROJECT_ROOT}/.claude/analytics.json"

if [ ! -f "$ANALYTICS" ]; then
  echo "No analytics data yet. Run a session with MTK first."
  exit 0
fi

# Read fields (no jq dependency)
read_field() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9]*" "$ANALYTICS" | grep -o '[0-9]*$' || echo "0"
}
read_str() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$ANALYTICS" | sed 's/.*: *"//;s/"$//' || echo ""
}

first=$(read_str "first_session")
last=$(read_str "last_session")
sessions=$(read_field "sessions")
total_ops=$(read_field "total_operations")
total_mods=$(read_field "total_modifications")
specs=$(read_field "specs_created")
lessons=$(read_field "lessons_captured")
scope_warns=$(read_field "scope_guard_warnings")
benchmarks=$(read_field "benchmarks_run")
bench_score=$(read_str "benchmark_last_score")
estimated_tokens=$(read_field "estimated_context_tokens")

# Calculate averages
avg_ops=0
avg_mods=0
scope_warn_rate="n/a"
avg_tokens="n/a"
if [ "$sessions" -gt 0 ]; then
  avg_ops=$((total_ops / sessions))
  avg_mods=$((total_mods / sessions))
  scope_warn_rate=$(awk "BEGIN { printf \"%.2f\", $scope_warns / $sessions }")
  avg_tokens=$((estimated_tokens / sessions))
fi

# Format token count for display
tokens_display="n/a"
if [ "$estimated_tokens" -gt 0 ]; then
  tokens_display="${estimated_tokens} (~${avg_tokens}/session)"
fi

printf '
┌─────────────────────────────────────────┐
│         MTK Analytics Report            │
├─────────────────────────────────────────┤
│ Period:     %s → %s     │
│ Sessions:   %-30s│
├─────────────────────────────────────────┤
│ Total operations:     %-18s│
│ Total modifications:  %-18s│
│ Avg ops/session:      %-18s│
│ Avg mods/session:     %-18s│
├─────────────────────────────────────────┤
│ Specs created:        %-18s│
│ Lessons captured:     %-18s│
│ Scope guard warnings: %-18s│
│ Scope warn/session:   %-18s│
├─────────────────────────────────────────┤
│ Benchmarks run:       %-18s│
│ Last benchmark score: %-18s│
├─────────────────────────────────────────┤
│ Est. context tokens:  %-18s│
└─────────────────────────────────────────┘
' "$first" "$last" "$sessions" \
  "$total_ops" "$total_mods" "$avg_ops" "$avg_mods" \
  "$specs" "$lessons" "$scope_warns" "$scope_warn_rate" \
  "$benchmarks" "${bench_score:-n/a}" \
  "$tokens_display"

# Always-on context cost (skill descriptions load into every session).
if ls .claude/skills/*/SKILL.md >/dev/null 2>&1; then
  desc_chars=0
  for skill in .claude/skills/*/SKILL.md; do
    desc="$(awk '/^description:/ { sub(/^description:[[:space:]]*/, ""); print; exit }' "$skill")"
    desc_chars=$((desc_chars + ${#desc}))
  done
  printf 'Always-on skill descriptions: %d chars (~%d tokens) across %d skills.\n' \
    "$desc_chars" "$((desc_chars / 4))" "$(ls .claude/skills/*/SKILL.md | wc -l | tr -d ' ')"
fi
printf 'Full context footprint & savings: bash scripts/mtk-savings.sh\n'
