#!/usr/bin/env bash
set -euo pipefail

# Tier-1 prompt nudges sourced by userprompt-dispatch.sh.
# Each nudge function inspects the user prompt and returns a one-line advisory
# string on stdout (empty string = no nudge). Nudges are plain text appended
# to additionalContext alongside any tier-2 queue drains.

# Case-insensitive match against correction keywords. Tight on purpose: the
# prompt must open with an explicit redirection ("no,", "stop —", "don't ...")
# or contain an unambiguous corrective phrase. Casual "no" inside a longer
# sentence must NOT trigger.
mtk_nudge_correction_match() {
  local prompt_lc="$1"
  local re

  # Agreement filter: if the prompt opens with "no," but the first ~100 chars
  # contain agreement language, treat as agreeing-not-correcting. Reduces the
  # "No, I think the original is correct" false positive.
  local head="${prompt_lc:0:100}"
  local agree_re='(correct|keep going|keep it|keep doing|that.?s fine|that.?s right|still good|looks right|sounds right|agree)'
  if [[ "$head" =~ $agree_re ]]; then
    # But don't suppress when a concrete corrective phrase is also present.
    local strong_re='(not like (that|this)|that.?s wrong|that.?s not (what|right)|wrong approach|scrap (that|this)|roll back)'
    if ! [[ "$prompt_lc" =~ $strong_re ]]; then
      return 1
    fi
  fi

  # Opening redirection: first non-whitespace token is a correction verb,
  # followed by punctuation or a space-plus-word (not a full stop alone).
  re='^[[:space:]]*(no|stop|don.?t|undo|revert|wait)[[:space:]]*[,.!:;-]'
  if [[ "$prompt_lc" =~ $re ]]; then return 0; fi

  # Unambiguous corrective phrases anywhere.
  local phrases=(
    'not like (that|this)'
    'that.?s wrong'
    'that.?s not (what|right)'
    'you (got|have) it wrong'
    'wrong approach'
    'that.?s out of scope'
    'back (up|out)'
    'roll back'
    'scrap (that|this)'
  )
  local p
  for p in "${phrases[@]}"; do
    if [[ "$prompt_lc" =~ $p ]]; then return 0; fi
  done

  return 1
}

# Main entry point called by the dispatcher. Outputs zero or more nudge lines
# separated by newlines. Dispatcher prefixes "MTK-NUDGE:" once on the whole block.
mtk_collect_prompt_nudges() {
  local prompt="${1:-}"
  [ -z "$prompt" ] && return 0

  local prompt_lc
  prompt_lc="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"

  local out=""
  if mtk_nudge_correction_match "$prompt_lc"; then
    out="${out}- the user just corrected you; consider invoking the correction-capture skill to record the lesson before continuing."$'\n'
  fi

  [ -n "$out" ] && printf '%s' "$out"
  return 0
}
