#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

# Anchor every path to the project root, never the process CWD. A bare
# ".claude/analytics.json" mints a SECOND analytics file in any subtree the
# session happens to run commands from (e.g. a SPA subproject under a .NET
# root), splitting adoption stats across two untracked files. The counted
# inputs below are anchored for the same reason: a root-anchored analytics
# file populated from subtree-relative counts is worse than either alone.
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(mtk_repo_root)}"
ANALYTICS="${PROJECT_ROOT}/.claude/analytics.json"

# Read session counters from context-budget temp file
SESSION_FILE="$(mtk_session_file)"

session_ops=0
session_mods=0
session_scope_warns=0
session_benchmarks=0
session_bench_score=""
session_bytes_read=0
if [ -f "$SESSION_FILE" ]; then
  mtk_load_session_state "$SESSION_FILE"
  session_ops=$ops
  session_mods=$mods
  session_scope_warns=${scope_guard_warnings:-0}
  session_benchmarks=${benchmarks_run:-0}
  session_bench_score=${benchmark_last_score:-}
  session_bytes_read=${bytes_read:-0}
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
  "benchmark_last_score": "",
  "queue_writes": 0,
  "queue_drains": 0,
  "queue_expired": 0,
  "bytes_read": 0,
  "estimated_context_tokens": 0
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
queue_writes=$(read_field "queue_writes")
queue_drains=$(read_field "queue_drains")
queue_expired=$(read_field "queue_expired")
total_bytes_read=$(read_field "bytes_read")
total_estimated_tokens=$(read_field "estimated_context_tokens")

# Update counters
sessions=$((sessions + 1))
total_ops=$((total_ops + session_ops))
total_mods=$((total_mods + session_mods))
scope_warns=$((scope_warns + session_scope_warns))
benchmarks=$((benchmarks + session_benchmarks))
if [ -n "$session_bench_score" ]; then
  bench_score="$session_bench_score"
fi
total_bytes_read=$((total_bytes_read + session_bytes_read))
total_estimated_tokens=$((total_bytes_read / 4))

# Count specs created today, under the resolved artifact root — a subtree that
# owns its own docs/specs still gets its work counted.
SPEC_COUNT_DIR="$(mtk_artifact_root "$PROJECT_ROOT" 2>/dev/null || printf '%s' "$PROJECT_ROOT")/docs/specs"
if [ -d "$SPEC_COUNT_DIR" ]; then
  new_specs=$(find "$SPEC_COUNT_DIR" -name '*.json' -newer "$ANALYTICS" 2>/dev/null | wc -l | tr -d ' ')
  specs=$((specs + new_specs))
fi

# Count lessons captured (compare line count)
if [ -f "${PROJECT_ROOT}/tasks/lessons.md" ]; then
  current_lessons=$(grep -c '^## ' "${PROJECT_ROOT}/tasks/lessons.md" 2>/dev/null || echo "0")
  if [ "$current_lessons" -gt "$lessons" ]; then
    lessons=$current_lessons
  fi
fi

# Read first_session before overwriting
first_session=$(read_str "first_session")
[ -z "$first_session" ] && first_session="$TODAY"

# Write updated analytics via a UNIQUE temp file. A fixed "${ANALYTICS}.tmp"
# collided across invocations: several copies of this Stop hook fire per session
# (plugin-cache versions + settings wiring), and with one shared temp name the
# first copy's `mv` consumed the file a later copy was about to `mv`, surfacing
# `mv: .claude/analytics.json.tmp: No such file or directory` on Stop. A per-run
# mktemp gives each copy its own source, so concurrent copies race harmlessly on
# the final rename (last writer wins) instead of erroring. mktemp is coreutils
# (S3.3); .claude/ is guaranteed to exist by the init block above.
ANALYTICS_TMP="$(mktemp "${ANALYTICS}.XXXXXX")"
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
  "benchmark_last_score": "$bench_score",
  "queue_writes": $queue_writes,
  "queue_drains": $queue_drains,
  "queue_expired": $queue_expired,
  "bytes_read": $total_bytes_read,
  "estimated_context_tokens": $total_estimated_tokens
}
EOF
mv "$ANALYTICS_TMP" "$ANALYTICS"

exit 0
