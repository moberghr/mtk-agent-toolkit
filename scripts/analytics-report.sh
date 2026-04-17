#!/usr/bin/env bash
set -euo pipefail

# analytics-report.sh — Print a summary of MTK usage stats from .claude/analytics.json.
# Usage: bash scripts/analytics-report.sh

ANALYTICS=".claude/analytics.json"

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

# Calculate averages
avg_ops=0
avg_mods=0
if [ "$sessions" -gt 0 ]; then
  avg_ops=$((total_ops / sessions))
  avg_mods=$((total_mods / sessions))
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
├─────────────────────────────────────────┤
│ Benchmarks run:       %-18s│
│ Last benchmark score: %-18s│
└─────────────────────────────────────────┘
' "$first" "$last" "$sessions" \
  "$total_ops" "$total_mods" "$avg_ops" "$avg_mods" \
  "$specs" "$lessons" "$scope_warns" \
  "$benchmarks" "${bench_score:-n/a}"
