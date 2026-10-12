#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PostToolUse hook: tracks session activity and warns when context is getting heavy.
# Maintains per-session counters in a temp file. Advisory only.
#
# Thresholds scale with the context window so a large-context model is not
# nagged on a 200k-calibrated budget, and a 200k model is not left silent on a
# 1M one. The window comes from the model id, with the same mapping as
# model_context_window in scripts/mtk-doctor.sh (Claude Code model-config docs,
# Oct 2026): Fable 5.x, Opus 4.7+, Sonnet 5+ and Haiku 5.5 run at 1M by default;
# Opus/Sonnet 4.6 only through their `[1m]` variant; Haiku 4.5, Opus/Sonnet 4.5
# and older at 200k; CLAUDE_CODE_DISABLE_1M_CONTEXT=1 caps every model at 200k;
# on Bedrock/Vertex the haiku/sonnet aliases are 4.5 (200k), on Foundry opus is
# 4.6 (200k). An unknown model is assumed to be 1M, matching mtk-doctor. The id
# is read from the SessionStart payload (session-start), $ANTHROPIC_MODEL or the
# transcript, then cached in the session ledger. At a 1M window the thresholds
# are 150 files / 200 modifications / 600 operations; at 200k, 30 / 40 / 120
# (overrides: MTK_CTX_FILES_WARN / MTK_CTX_MODS_WARN / MTK_CTX_OPS_WARN), plus
# the read-bytes estimate ≥ MTK_CONTEXT_BUDGET_PCT% of the window.
#
#   MTK_CONTEXT_WINDOW_TOKENS  usable context window in tokens; set it to override
#                              the model-derived value
#   MTK_CONTEXT_BUDGET_PCT     consumed-% at which to nudge a handoff (default 60)
# The bytes estimate is bytes_read/4 — a read-bytes FLOOR (it cannot see assistant
# output or non-read tool results), so it under-counts. Advisory only; never blocks.
#
# Verification ledger: when a Bash call is a verification command, the ledger
# records it together with a fingerprint of the working tree
# (mtk_tree_fingerprint), which verify-completion compares at Stop to tell
# whether files changed after the last verification — Bash-made and formatter
# edits included. The session's first tool call records a baseline fingerprint
# so verify-completion can tell whether the session changed anything at all.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

INPUT="$(mtk_read_payload)"

TOOL_NAME=$(mtk_extract_tool_name "$INPUT" 2>/dev/null || echo "")
[ -z "$TOOL_NAME" ] && exit 0
mtk_session_bind "$INPUT"

# Classify the Bash call and fingerprint the tree BEFORE taking the lock: git
# can take a while on a big tree and nobody should spin on the lock meanwhile.
COMMAND=""
IS_VERIFICATION=0
VERIFY_FP=""
if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(mtk_extract_command "$INPUT" 2>/dev/null || echo "")
  if [ -n "$COMMAND" ] && mtk_command_is_verification "$COMMAND"; then
    IS_VERIFICATION=1
    VERIFY_FP="$(mtk_tree_fingerprint 2>/dev/null)" || VERIFY_FP=""
  fi
fi

# Session-scoped state file (keyed on session_id, else per-project per-day).
# Hold the advisory lock for the full load→modify→save cycle so concurrent
# PreToolUse/PostToolUse firings don't lose counter updates through
# last-writer-wins races.
SESSION_FILE="$(mtk_session_file)"
mtk_session_lock_acquire "$SESSION_FILE"
mtk_load_session_state "$SESSION_FILE"

# Baseline for "did this session change anything" (verify-completion). It is
# recorded before the first tool runs — by session-start, or in PreToolUse by
# mtk_ensure_session_baseline (scope-guard, format-on-edit --flush-before-verify).
# Here, after the tool ran, it is only safe for a tool that cannot change files.
if [ "${event_seq:-0}" -eq 0 ] && [ -z "${session_start_tree:-}" ] \
  && { [ "$TOOL_NAME" = "Read" ] || [ "$TOOL_NAME" = "Grep" ] || [ "$TOOL_NAME" = "Glob" ]; }; then
  START_FP="$(mtk_tree_fingerprint 2>/dev/null)" || START_FP=""
  if [ -n "$START_FP" ]; then
    session_start_base="${START_FP%% *}"
    session_start_tree="${START_FP#* }"
  fi
fi

# Model id for the context-window size (cached; resolved once per session).
if [ -z "${model_id:-}" ]; then
  model_id="${ANTHROPIC_MODEL:-}"
  if [ -z "$model_id" ]; then
    TRANSCRIPT="$(mtk_extract_json_string "$INPUT" "transcript_path" 2>/dev/null || true)"
    if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
      model_id="$(tail -c 200000 "$TRANSCRIPT" 2>/dev/null \
        | grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]+"' | tail -n 1 \
        | sed -E 's/.*"([^"]+)"$/\1/' || true)"
    fi
  fi
  [ -n "$model_id" ] || model_id="unknown"
fi

# Update counters based on tool type
case "$TOOL_NAME" in
  Read)
    event_seq=$((event_seq + 1))
    reads=$((reads + 1))
    ops=$((ops + 1))
    # Track unique file paths and accumulate bytes read (for context load estimator)
    FILE_PATH=$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "")
    if [ -n "$FILE_PATH" ]; then
      if ! grep -qF -- "$FILE_PATH" <<<"$files"; then
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
    # A Bash command that writes files counts as an edit for the seq fallback
    # (outside git, or when the fingerprint cannot be computed).
    if [ "$IS_VERIFICATION" -eq 0 ] && [ -n "$COMMAND" ] && mtk_command_writes_files "$COMMAND"; then
      last_edit_epoch=$(date +%s)
      last_edit_seq=$event_seq
    fi
    if [ "$IS_VERIFICATION" -eq 1 ]; then
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
      # The tree this verification ran against; empty outside git, where
      # verify-completion falls back to the edit/verification seq comparison.
      if [ -n "$VERIFY_FP" ]; then
        last_verification_base="${VERIFY_FP%% *}"
        last_verification_tree="${VERIFY_FP#* }"
      else
        last_verification_base=""
        last_verification_tree=""
      fi
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

# Context-window-scaled thresholds. MTK_CONTEXT_WINDOW_TOKENS wins; otherwise
# the window follows the model id (mapping above; unknown -> 1M).
# Count thresholds scale linearly with the window and reproduce the historical
# 30/40/120 at a 200k window; per-threshold env overrides win outright.
model_window() { # $1 = model id -> 200000 | 1000000
  local m provider="anthropic"
  m="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [ "${CLAUDE_CODE_DISABLE_1M_CONTEXT:-}" = "1" ] && { printf '200000'; return 0; }
  case "$m" in *'[1m]'*) printf '1000000'; return 0 ;; esac
  [ "${CLAUDE_CODE_USE_BEDROCK:-}" = "1" ] && provider="cloud"
  [ "${CLAUDE_CODE_USE_VERTEX:-}" = "1" ] && provider="cloud"
  [ "${CLAUDE_CODE_USE_FOUNDRY:-}" = "1" ] && provider="foundry"
  case "$m" in
    haiku|sonnet) [ "$provider" = "anthropic" ] && printf '1000000' || printf '200000' ;;
    opus) [ "$provider" = "foundry" ] && printf '200000' || printf '1000000' ;;
    *opus-4-6*|*sonnet-4-6*) printf '200000' ;;
    *haiku-4*|*sonnet-4*|*opus-4-5*|*opus-4-1*|*opus-4-0*|*opus-4-2025*|*claude-3*|*claude-2*) printf '200000' ;;
    *) printf '1000000' ;;
  esac
}
ctx_window="${MTK_CONTEXT_WINDOW_TOKENS:-$(model_window "${model_id:-}")}"
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
