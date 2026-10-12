#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PostToolUse hook: tracks session activity and warns when context is getting heavy.
# Maintains per-session counters in a temp file. Advisory only.
#
# Thresholds scale with the declared context window so a large-context model is
# not nagged on a 200k-calibrated budget — following that advice (a mid-task
# handoff on a 1M-context model) is actively harmful. The default window is 1M,
# matching every current Claude Code model; at that window the thresholds are:
#   150+ unique files read → narrow your focus    (override: MTK_CTX_FILES_WARN)
#   200+ modifications     → commit a checkpoint   (override: MTK_CTX_MODS_WARN)
#   600+ total operations  → consider handoff      (override: MTK_CTX_OPS_WARN)
#   read bytes estimate ≥ MTK_CONTEXT_BUDGET_PCT% of window → reset before degradation
#
# One knob rescales all four: set MTK_CONTEXT_WINDOW_TOKENS to your real window
# (e.g. 200000 for Haiku 4.5) and the count thresholds scale linearly from the
# 200k calibration constants; a per-threshold MTK_CTX_*_WARN override wins outright.
#   MTK_CONTEXT_WINDOW_TOKENS  usable context window in tokens (default 1000000)
#   MTK_CONTEXT_BUDGET_PCT     consumed-% at which to nudge a handoff (default 60)
# The bytes estimate is bytes_read/4 — a read-bytes FLOOR (it cannot see assistant
# output or non-read tool results), so it under-counts. Advisory only; never blocks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

INPUT="$(mtk_read_payload)"

TOOL_NAME=$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")
[ -z "$TOOL_NAME" ] && exit 0

# Session-scoped state file (per-project, per-day). Hold the advisory lock for
# the full load→modify→save cycle so concurrent PreToolUse/PostToolUse firings
# don't lose counter updates through last-writer-wins races.
SESSION_FILE="$(mtk_session_file)"
mtk_session_lock_acquire "$SESSION_FILE"
mtk_load_session_state "$SESSION_FILE"

# Update counters based on tool type
case "$TOOL_NAME" in
  Read)
    event_seq=$((event_seq + 1))
    reads=$((reads + 1))
    ops=$((ops + 1))
    # Track unique file paths and accumulate bytes read (for context load estimator)
    FILE_PATH=$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "")
    if [ -n "$FILE_PATH" ]; then
      if ! echo "$files" | grep -qF "$FILE_PATH"; then
        files="${files:+$files|}$FILE_PATH"
        # Accumulate bytes only for new unique files; cap at 100k to avoid inflating on large incidental reads
        if [ -f "$FILE_PATH" ]; then
          file_bytes=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ' || echo 0)
          [ "$file_bytes" -gt 100000 ] && file_bytes=100000
          bytes_read=$((bytes_read + file_bytes))
        fi
      fi
    fi
    ;;
  Edit|Write)
    event_seq=$((event_seq + 1))
    mods=$((mods + 1))
    ops=$((ops + 1))
    last_edit_epoch=$(date +%s)
    last_edit_seq=$event_seq
    ;;
  Bash)
    event_seq=$((event_seq + 1))
    ops=$((ops + 1))
    COMMAND=$(mtk_extract_command "$INPUT" 2>/dev/null || echo "")
    if [ -n "$COMMAND" ] && mtk_command_is_verification "$COMMAND"; then
      last_verification_epoch=$(date +%s)
      last_verification_seq=$event_seq
      last_verification_command=$(mtk_trim_whitespace "$COMMAND")
      last_verification_summary="$last_verification_command"
      # Outcome column: classify the tool_response so verify-completion can
      # distinguish "verification ran" from "verification passed". Slice the
      # payload at the tool_response key so outcome markers in the command
      # text itself (tool_input) can't classify the run.
      RESPONSE=""
      case "$INPUT" in
        *'"tool_response"'*) RESPONSE="${INPUT#*\"tool_response\"}" ;;
      esac
      # Exit attributability gates the structured/exit tiers: shell operators
      # (`|| true`, `; echo done`, pipes) mask the exit, and the harness's
      # exit_code then describes the wrong command. Scope records whether the
      # run exercised the repo or a named slice — a targeted run must never
      # satisfy a repo-green claim.
      ATTR=$(mtk_verification_exit_attributable "$COMMAND")
      last_verification_status=$(mtk_classify_verification_outcome "$RESPONSE" "$ATTR")
      last_verification_scope=$(mtk_verification_scope "$COMMAND")
    fi
    ;;
  Glob|Grep)
    event_seq=$((event_seq + 1))
    ops=$((ops + 1))
    ;;
  *)
    event_seq=$((event_seq + 1))
    ops=$((ops + 1))
    ;;
esac

# Count unique files
unique_files=0
if [ -n "$files" ]; then
  unique_files=$(echo "$files" | tr '|' '\n' | wc -l | tr -d ' ')
fi

mtk_save_session_state "$SESSION_FILE"
mtk_session_lock_release "$SESSION_FILE"

# Check thresholds (warn once per threshold). Advisories are accumulated and
# emitted once as a PostToolUse additionalContext envelope — plain stdout on
# exit 0 is invisible to the model.
ADVISORY=""
append_advisory() { ADVISORY="${ADVISORY:+$ADVISORY }$1"; }

# Context-window-scaled thresholds. One knob (MTK_CONTEXT_WINDOW_TOKENS, default
# 1000000) governs the whole hook so the 200k-era calibration only applies when a
# 200k model is declared. Count thresholds scale linearly with the window and
# reproduce the historical 30/40/120 at a 200k window; per-threshold env overrides win outright.
ctx_window="${MTK_CONTEXT_WINDOW_TOKENS:-1000000}"
files_warn="${MTK_CTX_FILES_WARN:-$(( 30 * ctx_window / 200000 ))}"
mods_warn="${MTK_CTX_MODS_WARN:-$(( 40 * ctx_window / 200000 ))}"
ops_warn="${MTK_CTX_OPS_WARN:-$(( 120 * ctx_window / 200000 ))}"
[ "$files_warn" -lt 1 ] && files_warn=1
[ "$mods_warn" -lt 1 ] && mods_warn=1
[ "$ops_warn" -lt 1 ] && ops_warn=1

if [ "$unique_files" -ge "$files_warn" ] && [ "$warned_files" -eq 0 ]; then
  sed -i.bak 's/warned_files=0/warned_files=1/' "$SESSION_FILE" && rm -f "${SESSION_FILE}.bak"
  append_advisory "CONTEXT BUDGET: ${unique_files} unique files read this session. Consider narrowing focus to the files that matter for your current task. Use context-engineering to load only relevant references."
fi

if [ "$mods" -ge "$mods_warn" ] && [ "$warned_mods" -eq 0 ]; then
  sed -i.bak 's/warned_mods=0/warned_mods=1/' "$SESSION_FILE" && rm -f "${SESSION_FILE}.bak"
  append_advisory "CONTEXT BUDGET: ${mods} file modifications this session. Consider committing a checkpoint to preserve work. Long uncommitted sessions risk losing state on compaction."
fi

if [ "$ops" -ge "$ops_warn" ] && [ "$warned_ops" -eq 0 ]; then
  sed -i.bak 's/warned_ops=0/warned_ops=1/' "$SESSION_FILE" && rm -f "${SESSION_FILE}.bak"
  append_advisory "CONTEXT BUDGET: ${ops} total operations this session. Context window may be approaching limits. If switching tasks, capture state with the handoff skill first."
fi

# Context-budget checkpoint: nudge a deliberate reset/handoff before quality degrades.
# Estimate is a read-bytes floor (bytes_read/4); fires once per session.
# ctx_window resolved above with the count thresholds.
ctx_pct="${MTK_CONTEXT_BUDGET_PCT:-60}"
if [ "$warned_ctxpct" -eq 0 ] && [ "${bytes_read:-0}" -gt 0 ]; then
  est_tokens=$((bytes_read / 4))
  budget_tokens=$((ctx_window * ctx_pct / 100))
  if [ "$budget_tokens" -gt 0 ] && [ "$est_tokens" -ge "$budget_tokens" ]; then
    sed -i.bak 's/warned_ctxpct=0/warned_ctxpct=1/' "$SESSION_FILE" && rm -f "${SESSION_FILE}.bak"
    append_advisory "CONTEXT BUDGET: estimated ~${est_tokens} context tokens consumed (read-bytes floor) — past ${ctx_pct}% of the ${ctx_window}-token window. Reset deliberately before quality degrades: capture state with the handoff skill and start a fresh session. (Estimate under-counts; tune via MTK_CONTEXT_WINDOW_TOKENS / MTK_CONTEXT_BUDGET_PCT.)"
  fi
fi

[ -n "$ADVISORY" ] && mtk_emit_additional_context "PostToolUse" "$ADVISORY"

exit 0
