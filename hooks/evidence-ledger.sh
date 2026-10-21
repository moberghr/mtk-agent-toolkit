#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# PostToolUse hook (Edit|Write|Bash): the session evidence ledger that
# verify-completion reads at Stop. Formerly context-budget.sh; the file/operation/
# byte thresholds and their CONTEXT BUDGET nudges are gone — current models and
# the harness's own /context track that — so this hook never prints anything.
#
# What it records, per session (keyed on session_id, else project + date):
#   - every event bumps event_seq; Edit/Write bump the edit sequence, and so does
#     a Bash command that writes files (mtk_command_writes_files) — the seq
#     fallback for trees git cannot fingerprint
#   - a verification command (mtk_command_is_verification) is recorded with its
#     outcome, scope and a fingerprint of the working tree (mtk_tree_fingerprint);
#     verify-completion compares that fingerprint at Stop to tell whether files
#     changed after the last verification — Bash-made and formatter edits included
#   - ops/mods counters for the Stop recorder's .claude/analytics.json

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"
mtk_hook_seen evidence-ledger.sh

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

# The session baseline ("did this session change anything") is not recorded
# here: after a tool ran it already contains that tool's effect, and every tool
# this hook sees (Edit|Write|Bash) can change files. session-start and the
# PreToolUse hooks (scope-guard, format-on-edit --flush-before-verify) record it.

# Update counters based on tool type
case "$TOOL_NAME" in
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
  *)
    event_seq=$((event_seq + 1))
    ops=$((ops + 1))
    ;;
esac

mtk_save_session_state "$SESSION_FILE"
mtk_session_lock_release "$SESSION_FILE"

exit 0
