#!/usr/bin/env bash
set -euo pipefail

# Stop hook: persists session stats to .claude/analytics.json.
# Accumulates across sessions so teams can track MTK adoption and effectiveness.
# The file is gitignored (added to .gitignore by setup-bootstrap).
#
# Schema:
# {
#   "first_session": "2026-04-16",
#   "last_session": "2026-04-16",
#   "sessions": 42,
#   "total_operations": 1234,
#   "total_modifications": 567,
#   "specs_created": 5,
#   "lessons_captured": 12,
#   "scope_guard_warnings": 3,
#   "benchmarks_run": 2,
#   "benchmark_last_score": "21/21"
# }

ANALYTICS=".claude/analytics.json"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

# Read session counters from context-budget temp file
SESSION_FILE="$(mtk_session_file)"

session_ops=0
session_mods=0
session_scope_warns=0
session_benchmarks=0
session_bench_score=""
if [ -f "$SESSION_FILE" ]; then
  mtk_load_session_state "$SESSION_FILE"
  session_ops=$ops
  session_mods=$mods
  session_scope_warns=${scope_guard_warnings:-0}
  session_benchmarks=${benchmarks_run:-0}
  session_bench_score=${benchmark_last_score:-}
fi

# Skip trivial sessions (< 5 operations)
[ "$session_ops" -lt 5 ] && exit 0

TODAY=$(date +%Y-%m-%d)

# Initialize analytics file if missing
if [ ! -f "$ANALYTICS" ]; then
  mkdir -p "$(dirname "$ANALYTICS")"
  cat > "$ANALYTICS" <<EOF
{
  "first_session": "$TODAY",
  "last_session": "$TODAY",
  "sessions": 0,
  "total_operations": 0,
  "total_modifications": 0,
  "specs_created": 0,
  "lessons_captured": 0,
  "scope_guard_warnings": 0,
  "benchmarks_run": 0,
  "benchmark_last_score": ""
}
EOF
fi

# Read current values (portable — no jq dependency)
read_field() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9]*" "$ANALYTICS" | grep -o '[0-9]*$' || echo "0"
}
read_str() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$ANALYTICS" | sed 's/.*: *"//;s/"$//' || echo ""
}

sessions=$(read_field "sessions")
total_ops=$(read_field "total_operations")
total_mods=$(read_field "total_modifications")
specs=$(read_field "specs_created")
lessons=$(read_field "lessons_captured")
scope_warns=$(read_field "scope_guard_warnings")
benchmarks=$(read_field "benchmarks_run")
bench_score=$(read_str "benchmark_last_score")

# Update counters
sessions=$((sessions + 1))
total_ops=$((total_ops + session_ops))
total_mods=$((total_mods + session_mods))
scope_warns=$((scope_warns + session_scope_warns))
benchmarks=$((benchmarks + session_benchmarks))
if [ -n "$session_bench_score" ]; then
  bench_score="$session_bench_score"
fi

# Count specs created today
if [ -d docs/specs ]; then
  new_specs=$(find docs/specs -name '*.json' -newer "$ANALYTICS" 2>/dev/null | wc -l | tr -d ' ')
  specs=$((specs + new_specs))
fi

# Count lessons captured (compare line count)
if [ -f tasks/lessons.md ]; then
  current_lessons=$(grep -c '^## ' tasks/lessons.md 2>/dev/null || echo "0")
  if [ "$current_lessons" -gt "$lessons" ]; then
    lessons=$current_lessons
  fi
fi

# Read first_session before overwriting
first_session=$(read_str "first_session")
[ -z "$first_session" ] && first_session="$TODAY"

# Write updated analytics (temp file to avoid truncation race)
ANALYTICS_TMP="${ANALYTICS}.tmp"
cat > "$ANALYTICS_TMP" <<EOF
{
  "first_session": "$first_session",
  "last_session": "$TODAY",
  "sessions": $sessions,
  "total_operations": $total_ops,
  "total_modifications": $total_mods,
  "specs_created": $specs,
  "lessons_captured": $lessons,
  "scope_guard_warnings": $scope_warns,
  "benchmarks_run": $benchmarks,
  "benchmark_last_score": "$bench_score"
}
EOF
mv "$ANALYTICS_TMP" "$ANALYTICS"

exit 0
