#!/usr/bin/env bash
set -euo pipefail

# UserPromptSubmit dispatcher.
# Runs every user prompt. Responsibilities in order:
#   1. Read the prompt from stdin (JSON with "prompt" field).
#   2. Emit tier-1 nudges inline (e.g. correction detection — no queue).
#   3. Drain tier-2 queue entries (e.g. spec-approval → planning) written by
#      other hooks since the last prompt.
#   4. Merge both into a single additionalContext payload.
#
# Merging into one script sidesteps the unguaranteed ordering of multiple
# UserPromptSubmit hook entries in settings.json.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/skill-queue.sh"
# prompt-nudges.sh is optional — may not exist yet in Batch 1. Sourced
# defensively so the dispatcher works with drain-only behaviour first.
if [ -f "${SCRIPT_DIR}/lib/prompt-nudges.sh" ]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/prompt-nudges.sh"
fi
# trigger-hints.sh (S2.22) — keyword-triggered skill hints; optional.
if [ -f "${SCRIPT_DIR}/lib/trigger-hints.sh" ]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/trigger-hints.sh"
fi

# Kill-switch short-circuits the whole dispatcher.
mtk_queue_enabled || exit 0

INPUT="$(cat)"

# Extract prompt text. Prefer hook-io's escape-aware extractor when available.
PROMPT=""
if [ -f "${SCRIPT_DIR}/lib/hook-io.sh" ]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/hook-io.sh"
  PROMPT="$(mtk_extract_json_string "$INPUT" "prompt" 2>/dev/null || printf '')"
fi

# Collect tier-1 nudges (plain text lines, each standalone).
NUDGES=""
if declare -F mtk_collect_prompt_nudges >/dev/null 2>&1; then
  NUDGES="$(mtk_collect_prompt_nudges "$PROMPT" 2>/dev/null || printf '')"
fi

# Collect keyword-triggered skill hints (S2.22).
TRIGGER_HINTS=""
if declare -F mtk_collect_trigger_hints >/dev/null 2>&1; then
  TRIGGER_HINTS="$(mtk_collect_trigger_hints "$PROMPT" 2>/dev/null || printf '')"
fi

# Drain tier-2 queue.
DRAIN_LINES=""
DRAIN_COUNT=0
EXPIRED_COUNT=0
QUEUE_DIR="$(mtk_queue_dir)"
if [ -d "$QUEUE_DIR" ]; then
  NOW_EPOCH="$(date +%s)"
  TTL_SECONDS=$((MTK_QUEUE_TTL_HOURS * 3600))

  # Sort newest-first so the 3-entry cap surfaces the most relevant work.
  declare -a SEEN_KEYS=()
  # shellcheck disable=SC2012
  while IFS= read -r entry; do
    [ -f "$entry" ] || continue

    queued_epoch="$(mtk_queue_read_field "$entry" "queued_epoch" || echo 0)"
    skill="$(mtk_queue_read_field "$entry" "skill" || echo "")"
    reason="$(mtk_queue_read_field "$entry" "reason" || echo "")"
    source_hook="$(mtk_queue_read_field "$entry" "source_hook" || echo "")"
    ttl_hours="$(mtk_queue_read_field "$entry" "ttl_hours" || echo "$MTK_QUEUE_TTL_HOURS")"

    # Per-entry TTL (falls back to global).
    entry_ttl_seconds=$((ttl_hours * 3600))
    age=$((NOW_EPOCH - queued_epoch))
    if [ "$age" -gt "$entry_ttl_seconds" ]; then
      rm -f "$entry"
      EXPIRED_COUNT=$((EXPIRED_COUNT + 1))
      mtk_queue_record_expired
      continue
    fi

    # Dedup: same skill + source_hook → collapse.
    key="${skill}|${source_hook}"
    already_seen=0
    for seen in "${SEEN_KEYS[@]+"${SEEN_KEYS[@]}"}"; do
      [ "$seen" = "$key" ] && already_seen=1 && break
    done
    if [ "$already_seen" = "1" ]; then
      rm -f "$entry"
      continue
    fi
    SEEN_KEYS+=("$key")

    # Cap at 3 surfaced entries per drain.
    if [ "$DRAIN_COUNT" -ge 3 ]; then
      # Leave extras on disk; next drain will pick them up (or TTL expires them).
      continue
    fi

    line="- ${skill} — ${reason}. Consider: invoke the ${skill} skill now."
    DRAIN_LINES="${DRAIN_LINES}${line}"$'\n'
    DRAIN_COUNT=$((DRAIN_COUNT + 1))
    mtk_queue_record_drain
    rm -f "$entry"
  done < <(ls -1t "$QUEUE_DIR"/*.json 2>/dev/null || true)
fi

# Build combined additionalContext.
OUTPUT=""
if [ -n "$NUDGES" ]; then
  OUTPUT="MTK-NUDGE:"$'\n'"${NUDGES}"
fi
if [ -n "$TRIGGER_HINTS" ]; then
  [ -n "$OUTPUT" ] && OUTPUT="${OUTPUT}"$'\n'
  OUTPUT="${OUTPUT}MTK-TRIGGERS:"$'\n'"${TRIGGER_HINTS}"
fi
if [ -n "$DRAIN_LINES" ]; then
  [ -n "$OUTPUT" ] && OUTPUT="${OUTPUT}"$'\n'
  OUTPUT="${OUTPUT}MTK-QUEUED (${DRAIN_COUNT} pending):"$'\n'"${DRAIN_LINES}"
fi

[ -z "$OUTPUT" ] && exit 0

# JSON-escape the combined payload.
ESCAPED="$(mtk_queue_json_escape "$OUTPUT")"

# UserPromptSubmit hook contract: emit hookSpecificOutput with additionalContext.
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$ESCAPED"
