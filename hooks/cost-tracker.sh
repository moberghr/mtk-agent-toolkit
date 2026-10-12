#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# The single async Stop recorder. It reads the Stop payload once and does two
# independent things, each failing silent (prints nothing, always exits 0):
#
#   1. Session analytics (formerly hooks/session-analytics.sh): accumulates the
#      session's counters from the evidence ledger into <project root>/.claude/
#      analytics.json, gitignored, so teams can track MTK adoption. Sessions with
#      fewer than 5 operations are skipped. Always on.
#
#   2. Session cost (kill-switch MTK_COST_TRACKER=0): records per-session token
#      usage deltas, with an API-equivalent cost estimate, to <project root>/.mtk/
#      metrics/costs.jsonl via `scripts/session-cost.sh record`. The transcript
#      format is internal to Claude Code and not a stable contract, so when
#      parsing fails session-cost.sh records nothing rather than zero-filled rows.
#      Silent is not invisible: when `record` exits non-zero the hook overwrites
#      <metrics dir>/.last-error with ONE line
#        <ISO-UTC ts>\t<rc>\t<first 200 chars of record's stderr, tabs/newlines -> spaces>
#      and `session-cost.sh window` prints it as a warning. A later successful
#      record removes the file. The metrics dir is resolved here exactly as
#      session-cost.sh defaults it (<project root>/.mtk/metrics, project root =
#      $CLAUDE_PROJECT_DIR -> git top-level -> pwd) and passed to `record`
#      explicitly, so the error file and the rows always share a directory.
#
# analytics.json schema:
#   { "first_session", "last_session", "sessions", "total_operations",
#     "total_modifications", "specs_created", "lessons_captured",
#     "scope_guard_warnings", "benchmarks_run", "benchmark_last_score" }
# Operations are the Edit/Write/Bash events the evidence ledger sees.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

# Bounded read: a stalled stdin must never wedge the Stop event. An interactive
# stdin is never waited on.
INPUT=""
if [ ! -t 0 ]; then
  INPUT="$(mtk_read_payload 2>/dev/null || true)"
fi

# --- 1. session analytics ---------------------------------------------------------
record_analytics() {
  # Anchor every path to the project root, never the process CWD: a bare
  # ".claude/analytics.json" mints a second file in any subtree the session ran
  # commands from, splitting the stats.
  local project_root analytics session_file
  project_root="$(mtk_repo_root)"
  analytics="${project_root}/.claude/analytics.json"
  mtk_session_bind "$INPUT"
  session_file="$(mtk_session_file)"
  [ -f "$session_file" ] || return 0
  mtk_load_session_state "$session_file"
  local session_ops="${ops:-0}" session_mods="${mods:-0}"
  local session_scope_warns="${scope_guard_warnings:-0}" session_benchmarks="${benchmarks_run:-0}"
  local session_bench_score="${benchmark_last_score:-}"
  [ "$session_ops" -lt 5 ] && return 0

  local today
  today=$(date +%Y-%m-%d)
  if [ ! -f "$analytics" ]; then
    mkdir -p "$(dirname "$analytics")"
    printf '{\n  "first_session": "%s",\n  "sessions": 0\n}\n' "$today" > "$analytics"
  fi

  read_field() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9]*" "$analytics" | grep -o '[0-9]*$' || echo "0"; }
  read_str() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$analytics" | sed 's/.*: *"//;s/"$//' || echo ""; }

  local sessions total_ops total_mods specs lessons scope_warns benchmarks bench_score first_session
  sessions=$(( $(read_field "sessions") + 1 ))
  total_ops=$(( $(read_field "total_operations") + session_ops ))
  total_mods=$(( $(read_field "total_modifications") + session_mods ))
  specs=$(read_field "specs_created")
  lessons=$(read_field "lessons_captured")
  scope_warns=$(( $(read_field "scope_guard_warnings") + session_scope_warns ))
  benchmarks=$(( $(read_field "benchmarks_run") + session_benchmarks ))
  bench_score=$(read_str "benchmark_last_score")
  [ -n "$session_bench_score" ] && bench_score="$session_bench_score"
  first_session=$(read_str "first_session")
  [ -n "$first_session" ] || first_session="$today"

  # Specs created since the last write, under the resolved artifact root — a
  # subtree that owns its own docs/specs still gets its work counted.
  local spec_dir new_specs current_lessons
  spec_dir="$(mtk_artifact_root "$project_root" 2>/dev/null || printf '%s' "$project_root")/docs/specs"
  if [ -d "$spec_dir" ]; then
    new_specs=$(find "$spec_dir" -name '*.json' -newer "$analytics" 2>/dev/null | wc -l | tr -d ' ')
    specs=$((specs + new_specs))
  fi
  if [ -f "${project_root}/tasks/lessons.md" ]; then
    current_lessons=$(grep -c '^## ' "${project_root}/tasks/lessons.md" 2>/dev/null || echo "0")
    [ "$current_lessons" -gt "$lessons" ] && lessons=$current_lessons
  fi

  # Unique temp file per run (mktemp): concurrent copies race harmlessly on the
  # final rename (last writer wins) instead of consuming each other's temp file.
  local tmp
  tmp="$(mktemp "${analytics}.XXXXXX")"
  cat > "$tmp" <<EOF
{
  "first_session": "$first_session",
  "last_session": "$today",
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
  mv "$tmp" "$analytics"
}
( record_analytics ) >/dev/null 2>&1 || true

# --- 2. session cost ----------------------------------------------------------------
[ "${MTK_COST_TRACKER:-1}" = "0" ] && exit 0
[ -n "$INPUT" ] || exit 0

TRANSCRIPT=$(mtk_extract_json_string "$INPUT" "transcript_path" 2>/dev/null || true)
SESSION=$(mtk_extract_json_string "$INPUT" "session_id" 2>/dev/null || true)
[ -n "$TRANSCRIPT" ] && [ -n "$SESSION" ] || exit 0

SC=""
for cand in \
  "${MTK_HELPER_ROOT:+${MTK_HELPER_ROOT}/scripts/session-cost.sh}" \
  "${SCRIPT_DIR}/../scripts/session-cost.sh" \
  "${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/scripts/session-cost.sh}"; do
  if [ -n "$cand" ] && [ -f "$cand" ]; then
    SC="$cand"
    break
  fi
done
[ -n "$SC" ] || exit 0

ROOT=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}" ]; then
  ROOT="$CLAUDE_PROJECT_DIR"
fi
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
METRICS_DIR="${ROOT}/.mtk/metrics"
ERR_FILE="${METRICS_DIR}/.last-error"

# stderr captured (stdout discarded); rc captured outside the substitution.
rc=0
ERR_OUT="$(bash "$SC" record --transcript "$TRANSCRIPT" --session "$SESSION" \
  --metrics-dir "$METRICS_DIR" 2>&1 >/dev/null)" || rc=$?

if [ "$rc" -eq 0 ]; then
  rm -f "$ERR_FILE" 2>/dev/null || true
  exit 0
fi

MSG="${ERR_OUT:0:4096}"
MSG="${MSG//$'\t'/ }"
MSG="${MSG//$'\r'/ }"
MSG="${MSG//$'\n'/ }"
MSG="${MSG:0:200}"
# Overwrite (tmp + mv), never append; any failure here stays silent — there is
# nowhere left to report it without breaking the fail-silent contract.
if mkdir -p "$METRICS_DIR" 2>/dev/null; then
  TMP_ERR="${ERR_FILE}.tmp.$$"
  if printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$MSG" >"$TMP_ERR" 2>/dev/null; then
    mv -f "$TMP_ERR" "$ERR_FILE" 2>/dev/null || rm -f "$TMP_ERR" 2>/dev/null || true
  else
    rm -f "$TMP_ERR" 2>/dev/null || true
  fi
fi
exit 0
