#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# Fact-force guard: "search before you change a file's behaviour".
#
# The failure this nudges against: the model edits an existing source file — renames a
# method, changes a signature, alters a return shape — without ever looking up who calls
# it, and the break surfaces only in a later build or, worse, in production.
#
# Two modes, chosen from the payload's hook_event_name:
#   PostToolUse (Grep|Glob|Bash) — RECORD: append the search text, lowercased, to a
#     per-session file. Grep records pattern/path/glob; Glob records pattern/path; Bash
#     is recorded only when grep/egrep/fgrep/rg/ag/git grep/git log -S|-G/find runs at
#     command position (so `echo foo` is not a search).
#   PreToolUse (Edit|Write) — CHECK: for an EXISTING, IN-REPO file with a code extension
#     (not a test/doc/.mtk/tasks path), when its stem (basename minus last extension,
#     >= 3 chars) appears in no recorded search, emit one advisory additionalContext.
#
# Never loops the model: every file is nudged at most once per session — the file is
# marked BEFORE the nudge/deny is emitted, so the retry always passes. Advisory nudges are
# capped per session (MTK_FACT_FORCE_MAX_NUDGES, default 5); past the cap it goes silent.
# With MTK_FACT_FORCE_ENFORCE=1 the one nudge becomes a one-time deny (exit 2).
#
# Unwritable state (e.g. a read-only TMPDIR) never silences the guard: the nudge is
# still emitted, with "(fact-force state unwritable: <dir>; this nudge may repeat)"
# appended. Enforce mode never denies without having recorded the one-time mark —
# a deny whose retry cannot pass would loop — so when the mark write fails that call
# is downgraded to the advisory (exit 0) instead.
#
# State: $TMPDIR/mtk-factforce-<cksum(repo root)>-<session-key>.{search,nudged}, where
# the session key is the payload's session_id with [^A-Za-z0-9_-] stripped, falling back
# to today's date when absent. Search file capped at 2000 lines.
#
# Fails OPEN on empty, unparseable, or unrecognised payloads (exit 0, no output).
#
# Knobs: MTK_FACT_FORCE=0 (off) · MTK_FACT_FORCE_ENFORCE=1 (one-time deny) ·
#        MTK_FACT_FORCE_MAX_NUDGES (default 5)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

[ "${MTK_FACT_FORCE:-1}" = "0" ] && exit 0

INPUT="$(mtk_read_payload)"
[ -n "$INPUT" ] || exit 0

EVENT="$(mtk_extract_json_string "$INPUT" "hook_event_name" 2>/dev/null || true)"
TOOL_NAME="$(mtk_extract_tool_name "$INPUT" 2>/dev/null || true)"
[ -n "$EVENT" ] && [ -n "$TOOL_NAME" ] || exit 0

REPO_ROOT="$(mtk_repo_root)"
[ -n "$REPO_ROOT" ] || exit 0

PROJECT_ID="$(printf '%s' "$REPO_ROOT" | cksum | cut -d' ' -f1)"
SESSION_ID="$(mtk_extract_json_string "$INPUT" "session_id" 2>/dev/null || true)"
SESSION_KEY="${SESSION_ID//[^A-Za-z0-9_-]/}"
SESSION_KEY="${SESSION_KEY:0:64}"
[ -n "$SESSION_KEY" ] || SESSION_KEY="$(date +%Y%m%d)"
STATE_BASE="${TMPDIR:-/tmp}"
STATE_BASE="${STATE_BASE%/}/mtk-factforce-${PROJECT_ID}-${SESSION_KEY}"
SEARCH_FILE="${STATE_BASE}.search"
NUDGED_FILE="${STATE_BASE}.nudged"

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# Tool-input fields are extracted from the tool_input object onward so a same-named key
# earlier in the envelope can never be mistaken for a search argument.
TOOL_INPUT="$INPUT"
case "$INPUT" in
  *'"tool_input"'*) TOOL_INPUT="${INPUT#*\"tool_input\"}" ;;
esac

field() { mtk_extract_json_string "$TOOL_INPUT" "$1" 2>/dev/null || true; }

# --- RECORD ------------------------------------------------------------------
record_search() {
  local text="$1"
  [ -n "$text" ] || return 0
  # One line per search; newlines inside the text are folded to spaces.
  # Braces so the failed-open error of `>>` is silenced too (redirections
  # apply left to right; a bare `>>f 2>/dev/null` still prints it).
  { lower "$text" | tr '\n\r' '  ' >>"$SEARCH_FILE"; } 2>/dev/null || return 0
  { printf '\n' >>"$SEARCH_FILE"; } 2>/dev/null || return 0
  local n
  n="$(wc -l <"$SEARCH_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
  if [ "${n:-0}" -gt 2000 ] 2>/dev/null; then
    tail -n 2000 "$SEARCH_FILE" >"${SEARCH_FILE}.tmp.$$" 2>/dev/null \
      && mv -f "${SEARCH_FILE}.tmp.$$" "$SEARCH_FILE" 2>/dev/null \
      || rm -f "${SEARCH_FILE}.tmp.$$" 2>/dev/null || true
  fi
  return 0
}

# A search command at command position: after start-of-text or a separator, never
# merely after a space, so `echo "grep foo"` and `cat rg.txt` are not searches.
# `git log -S/-G` is its own alternative: the flag, not a word boundary, ends the match
# (`-Sfoo` and `-S foo` are both valid spellings).
MTK_SEARCH_CMD='(^|[;&|(`])[[:space:]]*((grep|egrep|fgrep|rg|ag|find|git[[:space:]]+grep)([[:space:]]|$)|git[[:space:]]+log([[:space:]]+[^;&|]*)?[[:space:]]-[SG])'

if [ "$EVENT" = "PostToolUse" ]; then
  case "$TOOL_NAME" in
    Grep)
      record_search "$(field pattern) $(field path) $(field glob)"
      ;;
    Glob)
      record_search "$(field pattern) $(field path)"
      ;;
    Bash)
      CMD="$(mtk_extract_command "$TOOL_INPUT" 2>/dev/null || true)"
      [ -n "$CMD" ] || exit 0
      if grep -qE "$MTK_SEARCH_CMD" <<<"$CMD"; then
        record_search "$CMD"
      fi
      ;;
  esac
  exit 0
fi

[ "$EVENT" = "PreToolUse" ] || exit 0

# --- CHECK -------------------------------------------------------------------
case "$TOOL_NAME" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

FILE_PATH="$(mtk_extract_file_path "$TOOL_INPUT" 2>/dev/null || true)"
[ -n "$FILE_PATH" ] || exit 0
case "$FILE_PATH" in
  /*) ;;
  *) FILE_PATH="${REPO_ROOT}/${FILE_PATH}" ;;
esac

# A new file has no dependents yet — nothing to search for.
[ -f "$FILE_PATH" ] || exit 0

# Out-of-repo paths (scratchpads, /tmp) are never nudged. Spelling-robust (S1.17).
REL_PATH="$(mtk_repo_relative_path "$FILE_PATH" "$REPO_ROOT" 2>/dev/null || true)"
[ -n "$REL_PATH" ] || exit 0
case "$REL_PATH" in
  /*) exit 0 ;;
esac

BASE="${REL_PATH##*/}"
BASE_LC="$(lower "$BASE")"
REL_LC="$(lower "$REL_PATH")"

case "$BASE_LC" in
  *.cs|*.fs|*.vb|*.py|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.go|*.rs|*.java|*.kt|*.swift|*.rb|*.php|*.sh) ;;
  *) exit 0 ;;
esac

# Exempt: tests (their dependents are nobody), docs, workflow state, task lists.
case "$REL_LC" in
  .mtk/*|tasks/*|docs/*) exit 0 ;;
  test/*|tests/*|*/test/*|*/tests/*) exit 0 ;;
esac
case "$BASE_LC" in
  *tests.cs|*.test.*|*.spec.*|test_*.py|*_test.*) exit 0 ;;
esac

STEM="${BASE_LC%.*}"
[ "${#STEM}" -ge 3 ] || exit 0

# Evidence: the stem appears in any recorded search this session.
if [ -f "$SEARCH_FILE" ] && grep -qiF -- "$STEM" "$SEARCH_FILE" 2>/dev/null; then
  exit 0
fi

# Already nudged for this file this session → the retry passes, never a loop.
if [ -f "$NUDGED_FILE" ] && grep -qxF -- "$REL_PATH" "$NUDGED_FILE" 2>/dev/null; then
  exit 0
fi

MAX_NUDGES="${MTK_FACT_FORCE_MAX_NUDGES:-5}"
case "$MAX_NUDGES" in
  ''|*[!0-9]*) MAX_NUDGES=5 ;;
esac
NUDGE_COUNT=0
if [ -f "$NUDGED_FILE" ]; then
  NUDGE_COUNT="$(wc -l <"$NUDGED_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
  case "$NUDGE_COUNT" in ''|*[!0-9]*) NUDGE_COUNT=0 ;; esac
fi
[ "$NUDGE_COUNT" -lt "$MAX_NUDGES" ] || exit 0

# Mark BEFORE emitting: mtk_deny exits, and the retry must find the mark. The group
# redirect silences the shell's own "Permission denied" for a failed >> open.
MARKED=1
{ printf '%s\n' "$REL_PATH" >>"$NUDGED_FILE"; } 2>/dev/null || MARKED=0
STATE_NOTE=""
if [ "$MARKED" = "0" ]; then
  STATE_NOTE=" (fact-force state unwritable: ${NUDGED_FILE%/*}; this nudge may repeat)"
fi

# Enforce only with the mark recorded: without it the retry would be denied again.
if [ "${MTK_FACT_FORCE_ENFORCE:-0}" = "1" ] && [ "$MARKED" = "1" ]; then
  mtk_deny "FACT-FORCE: first edit of ${REL_PATH} this session and no search mentioned \"${STEM}\". Before changing its behaviour or signature, find its dependents — e.g. grep -rn \"${STEM}\" . — then retry this edit (one-time deny; the retry passes)." \
    'MTK_FACT_FORCE_ENFORCE=0 (or MTK_FACT_FORCE=0)'
fi

mtk_emit_additional_context PreToolUse "FACT-FORCE: first edit of ${REL_PATH} this session and no search mentioned \"${STEM}\". Before changing its behaviour or signature, find its dependents — e.g. grep -rn \"${STEM}\" . — then continue. (advisory; MTK_FACT_FORCE_ENFORCE=1 makes this a one-time deny)${STATE_NOTE}"
exit 0
