#!/usr/bin/env bash
set -euo pipefail

# MTK keyword-triggered skill hints (OpenHands microagents pattern).
# Reads .claude/triggers.index (keyword<TAB>skill-name) and surfaces
# "consider skill X" nudges when the input text contains a keyword.
#
# Source this file from hooks/userprompt-dispatch.sh; it exposes:
#   mtk_collect_trigger_hints "$text" → prints one line per matched skill
#
# Matches are case-insensitive, whole-word-ish (requires word-boundary on
# either side so `auth` matches `auth` or `AuthService` but not `author`).
# Dedupes so each skill surfaces at most once per invocation, capped at 3.

MTK_TRIGGERS_INDEX="${MTK_TRIGGERS_INDEX:-.claude/triggers.index}"
MTK_TRIGGERS_CAP="${MTK_TRIGGERS_CAP:-3}"

mtk_triggers_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

mtk_collect_trigger_hints() {
  local text="${1:-}"
  [ -z "$text" ] && return 0

  local root
  root="$(mtk_triggers_root)"
  local index="${root}/${MTK_TRIGGERS_INDEX}"
  [ -f "$index" ] || return 0

  local lc_text
  lc_text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

  local surfaced=""
  local count=0

  while IFS=$'\t' read -r keyword skill; do
    [ -n "$keyword" ] || continue
    [ -n "$skill" ] || continue
    case "$keyword" in '#'*) continue ;; esac

    local lc_kw
    lc_kw="$(printf '%s' "$keyword" | tr '[:upper:]' '[:lower:]')"

    # Word-boundary match: keyword surrounded by non-alphanumerics (or string edges).
    # grep -wE handles ASCII word boundaries on both sides.
    if printf '%s\n' "$lc_text" | grep -wqE -- "$lc_kw" 2>/dev/null; then
      case " $surfaced " in
        *" $skill "*) continue ;;
      esac
      surfaced="$surfaced $skill"
      count=$((count + 1))
      printf '💡 consider skill: %s (matched: %s)\n' "$skill" "$keyword"
      [ "$count" -ge "$MTK_TRIGGERS_CAP" ] && break
    fi
  done < "$index"
}
