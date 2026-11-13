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
#      fewer than 5 operations are skipped. A session is counted once, and each
#      Stop adds only what it did since the previous one. Always on.
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
mtk_hook_seen cost-tracker.sh

# Bounded read: a stalled stdin must never wedge the Stop event. An interactive
# stdin is never waited on.
INPUT=""
if [ ! -t 0 ]; then
  INPUT="$(mtk_read_payload 2>/dev/null || true)"
fi

# One-line failure marker "<ISO-UTC ts>\t<rc>\t<msg>" (msg: tabs/newlines ->
# spaces, first 200 chars), overwritten via tmp + mv, never appended.
# write_error_line FILE RC MSG; returns 1 when the line could not be written.
write_error_line() {
  local file="$1" rc="$2" msg="${3:0:4096}" tmp
  msg="${msg//$'\t'/ }"
  msg="${msg//$'\r'/ }"
  msg="${msg//$'\n'/ }"
  msg="${msg:0:200}"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  tmp="${file}.tmp.$$"
  if printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$msg" >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# --- 1. session analytics ---------------------------------------------------------
# Every Stop of a session runs this, so it adds only what the session did since
# its last recorded Stop and counts the session once. The per-session high-water
# mark (ops, mods, scope warnings, benchmarks already added) lives beside the
# session ledger in TMPDIR as "<ledger>.analytics" — not in analytics.json, which
# keeps its schema and does not grow per session; the mark's existence means the
# session is already counted. A ledger that went backwards (recreated) adds its
# whole count again. The read-modify-write of analytics.json and the mark runs
# under one project-wide lock in TMPDIR, keyed on the analytics path; when the
# lock stays busy the write is skipped and the next Stop adds the delta.
#
# A failed write loses nothing and is not silent: the mark advances only after
# analytics.json was replaced, so the next Stop adds the delta again, and the
# failure is written as one line to <project root>/.mtk/metrics/.analytics-error
# (the .last-error format, in a file of its own because a successful cost record
# clears .last-error). The next successful analytics write removes it. When even
# that line cannot be written, one line goes to the hook's stderr instead.
record_analytics() {
  # Anchor every path to the project root, never the process CWD: a bare
  # ".claude/analytics.json" mints a second file in any subtree the session ran
  # commands from, splitting the stats.
  local project_root analytics session_file analytics_err
  project_root="$(mtk_repo_root)"
  analytics="${project_root}/.claude/analytics.json"
  analytics_err="${project_root}/.mtk/metrics/.analytics-error"
  mtk_session_bind "$INPUT"
  session_file="$(mtk_session_file)"
  [ -f "$session_file" ] || return 0
  mtk_load_session_state "$session_file"
  local session_ops="${ops:-0}" session_mods="${mods:-0}"
  local session_scope_warns="${scope_guard_warnings:-0}" session_benchmarks="${benchmarks_run:-0}"
  local session_bench_score="${benchmark_last_score:-}"
  [ "$session_ops" -lt 5 ] && return 0

  local lock_key rc=0
  lock_key="${TMPDIR:-/tmp}/mtk-analytics-$(printf '%s' "$analytics" | cksum | cut -d' ' -f1)"
  mtk_session_lock_acquire "$lock_key" || return 0
  write_analytics "${session_file}.analytics" || rc=$?
  mtk_session_lock_release "$lock_key"
  return "$rc"
}

# The locked part of record_analytics; reads its locals (bash dynamic scope).
# $1 = the session's high-water mark file.
write_analytics() {
  local mark="$1" counted=0 rec_ops=0 rec_mods=0 rec_warns=0 rec_bench=0
  if [ -f "$mark" ]; then
    counted=1
    read -r rec_ops rec_mods rec_warns rec_bench < "$mark" 2>/dev/null || true
    case "${rec_ops:-}" in ''|*[!0-9]*) rec_ops=0 ;; esac
    case "${rec_mods:-}" in ''|*[!0-9]*) rec_mods=0 ;; esac
    case "${rec_warns:-}" in ''|*[!0-9]*) rec_warns=0 ;; esac
    case "${rec_bench:-}" in ''|*[!0-9]*) rec_bench=0 ;; esac
  fi
  local d_ops d_mods d_warns d_bench
  d_ops=$(( session_ops >= rec_ops ? session_ops - rec_ops : session_ops ))
  d_mods=$(( session_mods >= rec_mods ? session_mods - rec_mods : session_mods ))
  d_warns=$(( session_scope_warns >= rec_warns ? session_scope_warns - rec_warns : session_scope_warns ))
  d_bench=$(( session_benchmarks >= rec_bench ? session_benchmarks - rec_bench : session_benchmarks ))

  # Every failure below returns 1 with the mark unadvanced; this records why.
  analytics_failed() {
    write_error_line "$analytics_err" 1 "analytics not recorded: $1" \
      || printf 'mtk cost-tracker: analytics not recorded: %s\n' "$1" 2>/dev/null >&3
    return 1
  }
  # Lifetime totals are read back from analytics.json, and read_field's 0
  # default would restart them from this session's delta, so a file that exists
  # but cannot be read or does not parse (counters must be non-negative
  # integers) is left exactly as it is.
  analytics_parses() {
    [ -f "$analytics" ] && [ -r "$analytics" ] || return 1
    if command -v python3 >/dev/null 2>&1; then
      python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    sys.exit(1)
keys = ("sessions", "total_operations", "total_modifications", "specs_created",
        "lessons_captured", "scope_guard_warnings", "benchmarks_run")
sys.exit(0 if isinstance(d, dict) and all(
    type(d.get(k, 0)) is int and d.get(k, 0) >= 0 for k in keys) else 1)' "$analytics" 2>/dev/null
    else
      # No python3: an intact file holds a numeric "sessions" and ends in "}".
      grep -q '"sessions"[[:space:]]*:[[:space:]]*[0-9]' "$analytics" 2>/dev/null \
        && [ "$(tr -d ' \t\r\n' < "$analytics" 2>/dev/null | tail -c 1)" = "}" ]
    fi
  }

  local today
  today=$(date +%Y-%m-%d)
  if [ -e "$analytics" ] || [ -L "$analytics" ]; then
    analytics_parses \
      || { analytics_failed "$analytics cannot be read or parsed; left untouched"; return 1; }
  else
    mkdir -p "$(dirname "$analytics")" 2>/dev/null \
      || { analytics_failed "cannot create $(dirname "$analytics")"; return 1; }
    if ! { printf '{\n  "first_session": "%s",\n  "sessions": 0\n}\n' "$today" > "$analytics"; } 2>/dev/null; then
      rm -f "$analytics" 2>/dev/null || true
      analytics_failed "cannot write $analytics"
      return 1
    fi
  fi

  read_field() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9]*" "$analytics" | grep -o '[0-9]*$' || echo "0"; }
  read_str() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$analytics" | sed 's/.*: *"//;s/"$//' || echo ""; }

  local sessions total_ops total_mods specs lessons scope_warns benchmarks bench_score first_session
  sessions=$(( $(read_field "sessions") + (counted ? 0 : 1) ))
  total_ops=$(( $(read_field "total_operations") + d_ops ))
  total_mods=$(( $(read_field "total_modifications") + d_mods ))
  specs=$(read_field "specs_created")
  lessons=$(read_field "lessons_captured")
  scope_warns=$(( $(read_field "scope_guard_warnings") + d_warns ))
  benchmarks=$(( $(read_field "benchmarks_run") + d_bench ))
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

  # Stage the new mark, replace analytics.json, then commit the mark: the mark
  # advances only once analytics.json holds this delta, and staging it first
  # leaves only a rename inside TMPDIR after analytics.json has changed. (A Stop
  # killed between the two renames adds this delta once more at the next Stop.)
  local mark_tmp="${mark}.tmp.$$"
  { printf '%s %s %s %s\n' "$session_ops" "$session_mods" "$session_scope_warns" "$session_benchmarks" > "$mark_tmp"; } 2>/dev/null \
    || { rm -f "$mark_tmp" 2>/dev/null; analytics_failed "cannot stage the session mark in ${TMPDIR:-/tmp}"; return 1; }

  # Unique temp file per run (mktemp) and an atomic rename: a reader never sees
  # a half-written file. Concurrent writers are serialised by the analytics lock.
  local tmp written=0
  tmp="$(mktemp "${analytics}.XXXXXX" 2>/dev/null)" || tmp=""
  if [ -n "$tmp" ]; then
    { cat > "$tmp" <<EOF
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
    } 2>/dev/null && mv -f "$tmp" "$analytics" 2>/dev/null && written=1
  fi
  if [ "$written" -ne 1 ]; then
    rm -f "$mark_tmp" ${tmp:+"$tmp"} 2>/dev/null || true
    analytics_failed "cannot replace $analytics"
    return 1
  fi
  if ! mv -f "$mark_tmp" "$mark" 2>/dev/null; then
    rm -f "$mark_tmp" 2>/dev/null || true
    analytics_failed "analytics.json updated but the session mark was not; the next Stop adds this delta again"
    return 1
  fi
  rm -f "$analytics_err" 2>/dev/null || true
  return 0
}
# fd 3 keeps the hook's stderr for the one line analytics_failed falls back to.
( record_analytics ) 3>&2 >/dev/null 2>&1 || true

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

# Overwrite (tmp + mv), never append; any failure here stays silent — there is
# nowhere left to report it without breaking the fail-silent contract.
write_error_line "$ERR_FILE" "$rc" "$ERR_OUT" || true
exit 0
