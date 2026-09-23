#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# Stop hook (async): records per-session token usage deltas, with an
# API-equivalent cost estimate, to <project root>/.mtk/metrics/costs.jsonl via
# `scripts/session-cost.sh record`.
#
# The transcript format is internal to Claude Code and not a stable contract, so
# this hook FAILS SILENT: it prints nothing, always exits 0, and when parsing
# fails session-cost.sh records nothing rather than zero-filled rows.
#
# Silent is not the same as invisible: when `record` exits non-zero the hook
# overwrites <metrics dir>/.last-error with ONE line
#   <ISO-UTC ts>\t<rc>\t<first 200 chars of record's stderr, tabs/newlines -> spaces>
# and `session-cost.sh window` prints it as a warning (rows after that point may
# be missing). A later successful record removes the file. The metrics dir is
# resolved here exactly as session-cost.sh defaults it (<project root>/.mtk/metrics,
# project root = $CLAUDE_PROJECT_DIR -> git top-level -> pwd) and passed to
# `record` explicitly, so the error file and the rows always share a directory.
#
# Kill-switch: MTK_COST_TRACKER=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

[ "${MTK_COST_TRACKER:-1}" = "0" ] && exit 0

# Bounded read: a stalled stdin must never wedge the Stop event.
INPUT=$(mtk_read_payload)
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
