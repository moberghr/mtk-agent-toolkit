#!/usr/bin/env bash
set -euo pipefail

# Stop hook: advisory nudge when a session ends with an active workflow that
# still has unfinished batches. It NEVER blocks and NEVER auto-continues work —
# it surfaces one line so the engineer (or next turn) decides: continue, hand
# off, or abandon.
#
# Tier-2 (skill-invoking class): respects MTK_HOOKS_TIER2. When 0, silent.
# Debounced: fires at most once per (workflow, batches_completed) so it does not
# repeat on every Stop in a burst, but re-notifies after real progress.

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# Tier-2 opt-out.
[ "${MTK_HOOKS_TIER2:-1}" = "0" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

REPO_ROOT="$(mtk_repo_root 2>/dev/null || pwd)"
WF_DIR="${REPO_ROOT}/.mtk/workflows"
[ -d "$WF_DIR" ] || exit 0

# Newest workflow JSON by mtime (portable stat, like scope-guard.sh).
NEWEST=""
NEWEST_MTIME=0
for f in "$WF_DIR"/*.json; do
  [ -f "$f" ] || continue
  m=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0)
  if [ "$m" -gt "$NEWEST_MTIME" ]; then NEWEST_MTIME=$m; NEWEST="$f"; fi
done
[ -n "$NEWEST" ] || exit 0

# Numeric/string field extraction without jq (S3.3). The trailing `|| true` is
# load-bearing: under `set -euo pipefail` a legitimate no-match (grep exits 1)
# would otherwise abort the whole hook via the assignment `VAR="$(json_num …)"`
# — before the `[ -n "$TOTAL" ] || exit 0` guard below could handle the absent
# field. An active workflow that has not yet recorded batch accounting is the
# common case early in a run, so this fired an exit-1 on every such Stop.
json_num() { grep -oE "\"$1\"[[:space:]]*:[[:space:]]*[0-9]+" "$2" 2>/dev/null | grep -oE '[0-9]+$' | head -1 || true; }
json_str() { grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" 2>/dev/null | sed 's/.*:[[:space:]]*"//;s/"$//' | head -1 || true; }

STATUS="$(json_str status "$NEWEST")"
[ "$STATUS" = "active" ] || exit 0

TOTAL="$(json_num batches_total "$NEWEST")"
DONE="$(json_num batches_completed "$NEWEST")"
# No batch accounting → nothing to nudge about.
[ -n "$TOTAL" ] || exit 0
DONE="${DONE:-0}"
[ "$DONE" -lt "$TOTAL" ] || exit 0

UUID="$(json_str workflow_uuid "$NEWEST")"
[ -n "$UUID" ] || UUID="$(basename "$NEWEST" .json)"

# Debounce on (uuid, done) so we don't repeat within a stop-burst but do
# re-notify after a batch actually completes.
MARKER="${TMPDIR:-/tmp}/mtk-wf-continuation-$(printf '%s' "$UUID" | cksum | cut -d' ' -f1)"
if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null || echo -1)" = "$DONE" ]; then
  exit 0
fi
printf '%s' "$DONE" > "$MARKER" 2>/dev/null || true

REMAINING=$((TOTAL - DONE))
# User-visible advisory (systemMessage): surfaces one line for the engineer to
# decide. Not model-visible — the only model-visible Stop channel forces the
# model to continue, which this hook explicitly must never do.
mtk_emit_system_message "WORKFLOW IN PROGRESS: ${UUID} has ${REMAINING} of ${TOTAL} batches unfinished (${DONE} done). Resume it (continue the next batch per tasks/todo.md), hand off (\`handoff\` skill), or close it: bash scripts/workflow-artifact.sh abandon ${UUID} --reason \"<why>\"."
exit 0
