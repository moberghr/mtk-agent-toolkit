#!/usr/bin/env bash
set -euo pipefail

# MTK tier-2 skill-invocation queue.
# Writers drop a single JSON entry under .claude/queue/; the UserPromptSubmit
# dispatcher drains entries into additionalContext for the next agent turn.
#
# Queue entries are advisory ("propose, never act") — the agent decides whether
# to invoke. Entries expire after 24h. The queue is workspace-local and
# gitignored. Safe for concurrent writers via atomic tmp-then-rename.

MTK_QUEUE_DIR=".claude/queue"
MTK_QUEUE_TTL_HOURS="${MTK_QUEUE_TTL_HOURS:-24}"

# Detect repo root and anchor the queue path there so hooks run from any cwd.
mtk_queue_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

mtk_queue_dir() {
  printf '%s/%s\n' "$(mtk_queue_root)" "$MTK_QUEUE_DIR"
}

# JSON-escape a value using bash parameter substitution only (S3.3).
mtk_queue_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Truncate a string to at most N characters (default 500).
mtk_queue_truncate() {
  local s="${1:-}"
  local max="${2:-500}"
  if [ "${#s}" -gt "$max" ]; then
    printf '%s…' "${s:0:$max}"
  else
    printf '%s' "$s"
  fi
}

# Honour the tier-2 kill-switch. Default ON (1); engineers flip to 0 locally.
mtk_queue_enabled() {
  [ "${MTK_HOOKS_TIER2:-1}" = "1" ]
}

# queue_skill <skill> <reason> <source_hook> [context_excerpt]
# Writes a gitignored JSON entry and exits 0. No-op when tier-2 is disabled.
queue_skill() {
  mtk_queue_enabled || return 0

  local skill="$1"
  local reason="$2"
  local source_hook="$3"
  local excerpt="${4:-}"

  local dir
  dir="$(mtk_queue_dir)"
  mkdir -p "$dir"

  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local epoch
  epoch="$(date +%s)"

  # Dedup key survives across hook fires: skill + source_hook.
  # Filename is <epoch>-<skill>-<hash>.json — hash keeps concurrent writers from colliding.
  local hash
  hash="$(printf '%s|%s' "$skill" "$source_hook" | cksum | cut -d' ' -f1)"
  local filename="${epoch}-${skill}-${hash}.json"
  local final="${dir}/${filename}"
  local tmp="${final}.tmp.$$"

  local excerpt_trunc reason_trunc
  excerpt_trunc="$(mtk_queue_truncate "$excerpt" 500)"
  reason_trunc="$(mtk_queue_truncate "$reason" 200)"

  local excerpt_esc reason_esc skill_esc source_esc
  excerpt_esc="$(mtk_queue_json_escape "$excerpt_trunc")"
  reason_esc="$(mtk_queue_json_escape "$reason_trunc")"
  skill_esc="$(mtk_queue_json_escape "$skill")"
  source_esc="$(mtk_queue_json_escape "$source_hook")"

  {
    printf '{\n'
    printf '  "queued_at": "%s",\n' "$now_iso"
    printf '  "queued_epoch": %s,\n' "$epoch"
    printf '  "skill": "%s",\n' "$skill_esc"
    printf '  "reason": "%s",\n' "$reason_esc"
    printf '  "context": { "excerpt": "%s" },\n' "$excerpt_esc"
    printf '  "ttl_hours": %s,\n' "$MTK_QUEUE_TTL_HOURS"
    printf '  "source_hook": "%s"\n' "$source_esc"
    printf '}\n'
  } > "$tmp"

  mv "$tmp" "$final"

  mtk_queue_record_write
}

# Read a JSON field from a queue entry file (string or number).
mtk_queue_read_field() {
  local file="$1"
  local key="$2"
  grep -E "\"$key\"[[:space:]]*:" "$file" \
    | head -1 \
    | sed -E "s/.*\"$key\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"?,?[[:space:]]*$//"
}

# Increment a queue-related counter in .claude/analytics.json if that file
# exists. No-op if analytics hasn't been initialized yet — session-analytics.sh
# handles first-run initialization.
mtk_queue_bump_counter() {
  local field="$1"
  local analytics
  analytics="$(mtk_queue_root)/.claude/analytics.json"
  [ -f "$analytics" ] || return 0

  local current
  current="$(grep -oE "\"$field\"[[:space:]]*:[[:space:]]*[0-9]+" "$analytics" | grep -oE '[0-9]+$' || true)"

  local tmp="${analytics}.tmp.$$"
  if [ -n "$current" ]; then
    local next=$((current + 1))
    sed "s/\"$field\"[[:space:]]*:[[:space:]]*${current}/\"$field\": ${next}/" "$analytics" > "$tmp"
    mv "$tmp" "$analytics"
  else
    # Field not present — insert before the closing brace.
    awk -v field="$field" '
      /^}[[:space:]]*$/ && !done {
        # Append a comma to the prior line if it doesn'\''t already end in one.
        if (prev !~ /,[[:space:]]*$/ && prev !~ /\{[[:space:]]*$/) {
          sub(/[[:space:]]*$/, ",", prev)
        }
        print prev
        printf "  \"%s\": 1\n", field
        print
        done = 1
        prev = ""
        next
      }
      { if (NR > 1) print prev; prev = $0 }
      END { if (!done && prev != "") print prev }
    ' "$analytics" > "$tmp" && mv "$tmp" "$analytics"
  fi
}

mtk_queue_record_write() {
  mtk_queue_bump_counter "queue_writes"
}

mtk_queue_record_drain() {
  mtk_queue_bump_counter "queue_drains"
}

mtk_queue_record_expired() {
  mtk_queue_bump_counter "queue_expired"
}
