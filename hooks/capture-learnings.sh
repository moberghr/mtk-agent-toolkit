#!/usr/bin/env bash
set -euo pipefail

# Diagnostic: emit hook name + exit code on non-zero exit (silent on success).
_mtk_hook_diag() { local c=$?; [[ $c -ne 0 ]] && echo "[mtk-hook:$(basename "$0")] exit $c" >&2 2>/dev/null || true; return 0; }
trap _mtk_hook_diag EXIT

# Stop hook: reminds the agent to capture learnings after substantial sessions.
# Checks if corrections were captured in tasks/lessons.md. If the session was
# substantial but no lessons were recorded, prompts the agent.
# Also detects when 3+ lessons share a keyword, suggesting CLAUDE.md promotion.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

mtk_is_redundant_plugin_invocation "$0" && exit 0

# Per-session nag budget. This advisory is worth one read per session; re-firing
# it on every Stop past the substantial-session threshold is how a session ends
# up with 63 copies of the same paragraph (~9k tokens) and how a reader learns to
# tune out every hook. Same shape as compress-monitor.sh: keyed on the payload's
# session_id (NOT mtk_session_file, which is project+date and so would collapse
# every session in a repo on one day into a single budget), stored in TMPDIR,
# default 1, `MTK_LEARNING_MAX_NAGS=0` silences without unwiring the hook.
MAX_NAGS="${MTK_LEARNING_MAX_NAGS:-1}"
case "$MAX_NAGS" in
  ''|*[!0-9]*) MAX_NAGS=1 ;;
esac
[ "$MAX_NAGS" -le 0 ] && exit 0

PAYLOAD="$(mtk_read_payload 2>/dev/null || true)"
NAG_SESSION="$(mtk_extract_json_string "$PAYLOAD" "session_id" 2>/dev/null || true)"
[ -n "$NAG_SESSION" ] || NAG_SESSION="nosession"
NAG_SESSION="$(printf '%s' "$NAG_SESSION" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)"
NAG_STATE="${TMPDIR:-/tmp}/mtk-learning-nag-${NAG_SESSION}"

NAG_SEEN=0
if [ -f "$NAG_STATE" ]; then
  NAG_SEEN="$(tr -cd '0-9' < "$NAG_STATE" 2>/dev/null || echo 0)"
  [ -n "$NAG_SEEN" ] || NAG_SEEN=0
fi
# Budget spent — exit before any filesystem work, so a spent budget costs
# nothing rather than re-running the lessons scan on every Stop.
[ "$NAG_SEEN" -ge "$MAX_NAGS" ] && exit 0

# Check if the session was substantial (context-budget tracks this). Resolve the
# session file via mtk_session_file so this hook keys off the same project root
# (git toplevel) that context-budget.sh writes under — a bare `pwd` disagrees
# when Claude is launched from a subdirectory.
SESSION_FILE="$(mtk_session_file)"

ops=0
mods=0
files=''
if [ -f "$SESSION_FILE" ]; then
  # shellcheck disable=SC1090
  . "$SESSION_FILE"
fi

# Only trigger for substantial sessions (20+ operations or 5+ modifications)
if [ "$ops" -lt 20 ] && [ "$mods" -lt 5 ]; then
  exit 0
fi

# Resolve lessons.md against the project root, not cwd (subdirectory-safe).
REPO_ROOT="$(mtk_repo_root)"
# Check if tasks/lessons.md exists and was modified recently (within last 2 hours)
LESSONS_FILE="${REPO_ROOT}/tasks/lessons.md"
LESSONS_MODIFIED=0

if [ -f "$LESSONS_FILE" ]; then
  # Check if lessons.md was modified in the last 2 hours
  if find "$LESSONS_FILE" -mmin -120 -print -quit 2>/dev/null | grep -q .; then
    LESSONS_MODIFIED=1
  fi
fi

# Advisory Stop nudges are user-visible (systemMessage) rather than model-visible:
# the only model-visible Stop channel forces the model to keep going, which is
# wrong for a "consider capturing lessons" reminder (and would loop until
# lessons.md is touched). Accumulate and emit once at the end.
ADVISORY=""
append_advisory() { ADVISORY="${ADVISORY:+$ADVISORY }$1"; }

# If substantial session but no lessons captured, remind
if [ "$LESSONS_MODIFIED" -eq 0 ]; then
  append_advisory "LEARNING CHECK: Substantial session (${ops} operations, ${mods} modifications) with no lessons captured. If the engineer corrected your approach, redirected you, or a non-obvious pattern emerged, capture it in tasks/lessons.md using the correction-capture workflow; if YOU struggled 2+ times with the same sub-problem and then found a working approach, use golden-path-capture. Lessons compound across sessions — without them, the same mistakes repeat."
fi

# If lessons exist, check for promotion candidates (3+ lessons with shared keywords)
if [ -f "$LESSONS_FILE" ] && [ -s "$LESSONS_FILE" ]; then
  # Count lessons by extracting ## headers
  LESSON_COUNT=$(grep -c '^## ' "$LESSONS_FILE" 2>/dev/null || echo "0")

  if [ "$LESSON_COUNT" -ge 3 ]; then
    # Extract Rule: lines and find repeated keywords (2+ word tokens appearing 3+ times)
    # `|| true` is load-bearing: under `set -euo pipefail`, a lessons.md with
    # 3+ `## ` headers but no `Rule:` lines makes grep exit 1, which (via
    # pipefail) would abort the whole hook at this assignment before the
    # `[ -n "$REPEATED" ]` guard below. Empty-on-no-match is the intended result.
    REPEATED=$(grep -i '^[*]*Rule:[*]*' "$LESSONS_FILE" 2>/dev/null \
      | tr '[:upper:]' '[:lower:]' \
      | tr -cs '[:alpha:]' '\n' \
      | sort \
      | uniq -c \
      | sort -rn \
      | awk '$1 >= 3 && length($2) > 4 { print $2 }' \
      | head -3 || true)

    if [ -n "$REPEATED" ]; then
      KEYWORDS=$(echo "$REPEATED" | tr '\n' ', ' | sed 's/, $//')
      append_advisory "PROMOTION CANDIDATE: ${LESSON_COUNT} lessons in tasks/lessons.md with recurring themes: ${KEYWORDS}. Consider promoting the pattern to a permanent rule in CLAUDE.md or .claude/rules/. Repeated corrections that stay in lessons.md don't compound — they just accumulate."
    fi
  fi
fi

# Spend one unit of the budget only when something is actually emitted; a Stop
# with nothing to say must not burn the session's single advisory. An unwritable
# TMPDIR degrades to "advise every time" rather than to silence — losing the
# reminder is worse than repeating it.
if [ -n "$ADVISORY" ]; then
  printf '%s' "$((NAG_SEEN + 1))" > "$NAG_STATE" 2>/dev/null || true
  mtk_emit_system_message "$ADVISORY"
fi

exit 0
