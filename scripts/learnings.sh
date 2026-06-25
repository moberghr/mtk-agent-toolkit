#!/usr/bin/env bash
set -euo pipefail
# scripts/learnings.sh — manage structured learnings under .mtk/learnings.jsonl
#
# Subcommands:
#   add [flags]                Append a structured entry. Flags below.
#   query [flags]              Print ranked entries via 5-layer retrieval filter.
#   regen-markdown             Regenerate tasks/lessons.md from .mtk/learnings.jsonl.
#   migrate                    Seed .mtk/learnings.jsonl from existing tasks/lessons.md.
#   list                       Plain newline-delimited dump (id + title), for diagnostics.
#
# Storage: JSON Lines (one entry per line) — chosen so pure-bash tooling can
# append and grep without an external JSON parser, per rule S3.3.
#
# See .claude/references/learnings-schema.md for full field reference.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LEARNINGS_PATH="${MTK_LEARNINGS_PATH:-.mtk/learnings.jsonl}"
LESSONS_MD="${MTK_LESSONS_MD:-tasks/lessons.md}"

ensure_store() {
  mkdir -p "$(dirname "$LEARNINGS_PATH")"
  [ -f "$LEARNINGS_PATH" ] || : > "$LEARNINGS_PATH"
}

# JSON string escape — escapes \ " and control chars. No jq.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Comma-separated list -> JSON array of strings
csv_to_json_array() {
  local csv="$1"
  if [ -z "$csv" ]; then
    printf '[]'
    return
  fi
  local IFS=','
  local first=1
  printf '['
  for item in $csv; do
    item="${item## }"
    item="${item%% }"
    [ -z "$item" ] && continue
    if [ $first -eq 1 ]; then first=0; else printf ','; fi
    printf '"%s"' "$(json_escape "$item")"
  done
  printf ']'
}

# Allocate next id for today: L-YYYY-MM-DD-NNN
next_id() {
  local today; today="$(date -u +%Y-%m-%d)"
  local prefix="L-${today}-"
  local max_n=0
  if [ -s "$LEARNINGS_PATH" ]; then
    while IFS= read -r line; do
      case "$line" in
        *"\"id\":\"${prefix}"*)
          local n; n="$(printf '%s\n' "$line" | sed -nE "s/.*\"id\":\"${prefix}([0-9]+)\".*/\1/p")"
          [ -n "$n" ] && [ "$n" -gt "$max_n" ] && max_n="$n"
          ;;
      esac
    done < "$LEARNINGS_PATH"
  fi
  printf '%s%03d' "$prefix" $((max_n + 1))
}

# Compute expires_at = now + 12 months (best-effort, GNU/BSD compatible)
expires_at_default() {
  if date -u -v+12m +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -v+12m +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "+12 months" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u +%Y-%m-%dT%H:%M:%SZ # fallback: same day
  fi
}

cmd_add() {
  ensure_store
  local spec_id="" workflow_uuid="manual" scope="personal" source_kind="correction"
  local files_csv="" dirs_csv="" phase="any" severity="warn"
  local title="" body="" rule="" applies_when=""
  local decision_origin=""
  local wrong_turns_csv="" time_cost="" evolution_actions=""
  local dry_run=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --spec) spec_id="$2"; shift 2 ;;
      --workflow) workflow_uuid="$2"; shift 2 ;;
      --scope) scope="$2"; shift 2 ;;
      --source) source_kind="$2"; shift 2 ;;
      --files) files_csv="$2"; shift 2 ;;
      --dirs) dirs_csv="$2"; shift 2 ;;
      --phase) phase="$2"; shift 2 ;;
      --severity) severity="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      --rule) rule="$2"; shift 2 ;;
      --applies-when) applies_when="$2"; shift 2 ;;
      --decision-origin) decision_origin="$2"; shift 2 ;;
      # v7.14 optional enrichment fields (pass-through; query parser ignores them)
      --wrong-turns) wrong_turns_csv="$2"; shift 2 ;;
      --time-cost) time_cost="$2"; shift 2 ;;
      --evolution-actions) evolution_actions="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  # Validate evolution_actions enum when supplied.
  if [ -n "$evolution_actions" ]; then
    case "$evolution_actions" in
      routing|claude_md|reference|hook|none) ;;
      *) printf 'add: invalid --evolution-actions "%s" (one of: routing | claude_md | reference | hook | none)\n' "$evolution_actions" >&2; exit 2 ;;
    esac
  fi

  [ -n "$title" ] || { printf 'add requires --title\n' >&2; exit 2; }
  [ -n "$body" ] || body="$title"

  # Decision-origin: required for capture sources that imply a decision,
  # auto-classified for deterministic sources.
  case "$source_kind" in
    manual|migrate) [ -n "$decision_origin" ] || decision_origin="system-inferred" ;;
    incident)       [ -n "$decision_origin" ] || decision_origin="system-inferred" ;;
    *)
      if [ -z "$decision_origin" ]; then
        printf 'add: --decision-origin is required for source=%s (one of: user-directed | claude-recommended-approved | claude-recommended-modified | claude-recommended-rejected | system-inferred)\n' "$source_kind" >&2
        exit 2
      fi
      ;;
  esac
  case "$decision_origin" in
    user-directed|claude-recommended-approved|claude-recommended-modified|claude-recommended-rejected|system-inferred) ;;
    *) printf 'add: invalid --decision-origin "%s"\n' "$decision_origin" >&2; exit 2 ;;
  esac

  local id; id="$(next_id)"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local exp; exp="$(expires_at_default)"

  # Optional v7.14 enrichment fragment, appended only when at least one field
  # is set. Trailing keys are invisible to the key-specific query parser.
  local extra=""
  if [ -n "$wrong_turns_csv" ]; then
    extra="${extra},\"wrong_turns\":$(csv_to_json_array "$wrong_turns_csv")"
  fi
  if [ -n "$time_cost" ]; then
    case "$time_cost" in
      ''|*[!0-9]*) printf 'add: --time-cost must be an integer (minutes)\n' >&2; exit 2 ;;
      *) extra="${extra},\"time_cost\":${time_cost}" ;;
    esac
  fi
  if [ -n "$evolution_actions" ]; then
    extra="${extra},\"evolution_actions\":\"${evolution_actions}\""
  fi

  local entry
  entry="$(printf '{"id":"%s","spec_id":"%s","workflow_uuid":"%s","scope":"%s","source":"%s","decision_origin":"%s","captured_at":"%s","files":%s,"directories":%s,"phase":"%s","severity":"%s","validity":{"expires_at":"%s","reconfirmed_at":null,"expired":false},"recurrence":{"count":1,"last_seen_at":"%s","related_ids":[]},"title":"%s","body":"%s","rule":"%s","applies_when":"%s"%s}' \
    "$id" \
    "$(json_escape "$spec_id")" \
    "$(json_escape "$workflow_uuid")" \
    "$scope" \
    "$source_kind" \
    "$decision_origin" \
    "$now" \
    "$(csv_to_json_array "$files_csv")" \
    "$(csv_to_json_array "$dirs_csv")" \
    "$phase" \
    "$severity" \
    "$exp" \
    "$now" \
    "$(json_escape "$title")" \
    "$(json_escape "$body")" \
    "$(json_escape "$rule")" \
    "$(json_escape "$applies_when")" \
    "$extra" \
  )"

  if [ "$dry_run" -eq 1 ]; then
    printf '%s\n' "$entry"
    return 0
  fi

  printf '%s\n' "$entry" >> "$LEARNINGS_PATH"
  printf '%s\n' "$id"
}

# Extract a top-level string field from a JSONL line. Best-effort, no jq.
# Usage: jl_field "$line" id
jl_field() {
  local line="$1" key="$2"
  printf '%s\n' "$line" | sed -nE "s/.*\"${key}\":\"([^\"]*)\".*/\1/p" | head -1
}

# Extract a JSON array of strings as a comma-separated list.
jl_array_csv() {
  local line="$1" key="$2"
  printf '%s\n' "$line" | sed -nE "s/.*\"${key}\":\[([^]]*)\].*/\1/p" \
    | tr -d '"' | head -1
}

cmd_query() {
  ensure_store
  local files_csv="" phase="any" max=10 scope_filter="all"
  while [ $# -gt 0 ]; do
    case "$1" in
      --files) files_csv="$2"; shift 2 ;;
      --phase) phase="$2"; shift 2 ;;
      --max) max="$2"; shift 2 ;;
      --scope) scope_filter="$2"; shift 2 ;;
      *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  [ -s "$LEARNINGS_PATH" ] || return 0

  # Score each line; emit "score\tline"; sort -nr; head -max; print formatted.
  local now_epoch; now_epoch="$(date -u +%s)"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local sev; sev="$(jl_field "$line" severity)"
    local ph; ph="$(jl_field "$line" phase)"
    local sc; sc="$(jl_field "$line" scope)"
    local exp; exp="$(jl_field "$line" expires_at)"
    local files; files="$(jl_array_csv "$line" files)"
    local dirs; dirs="$(jl_array_csv "$line" directories)"

    # Layer 5: phase
    if [ "$ph" != "any" ] && [ "$phase" != "any" ] && [ "$ph" != "$phase" ]; then
      continue
    fi
    # Layer 4: validity (drop if expired). Compare ISO strings lexically (UTC, fixed format).
    if [ -n "$exp" ]; then
      local now_iso; now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      [ "$exp" \< "$now_iso" ] && continue
    fi
    # Scope filter
    case "$scope_filter" in
      team)     [ "$sc" = "team" ] || continue ;;
      personal) [ "$sc" = "personal" ] || continue ;;
      all|"")   : ;;
    esac

    local score=0
    # Layer 3: severity
    case "$sev" in
      incident) score=$((score + 40)) ;;
      block)    score=$((score + 25)) ;;
      warn)     score=$((score + 10)) ;;
      info)     score=$((score + 5))  ;;
    esac
    # Layer 2: recurrence (count >= 2)
    local rcount; rcount="$(printf '%s\n' "$line" | sed -nE 's/.*"count":([0-9]+).*/\1/p' | head -1)"
    [ -n "$rcount" ] && [ "$rcount" -ge 2 ] && score=$((score + 20))
    # Layer 1: proximity
    if [ -n "$files_csv" ] && { [ -n "$files" ] || [ -n "$dirs" ]; }; then
      local IFS_OLD=$IFS
      IFS=','
      local hit=0
      for f in $files_csv; do
        f="${f## }"; f="${f%% }"
        [ -z "$f" ] && continue
        case ",$files," in *",$f,"*) hit=1 ;; esac
        if [ $hit -eq 0 ] && [ -n "$dirs" ]; then
          for d in $(echo "$dirs" | tr ',' ' '); do
            [ -z "$d" ] && continue
            case "$f" in "$d"*) hit=1 ;; esac
            [ $hit -eq 1 ] && break
          done
        fi
        [ $hit -eq 1 ] && break
      done
      IFS=$IFS_OLD
      [ $hit -eq 1 ] && score=$((score + 30))
    fi

    printf '%d\t%s\n' "$score" "$line"
  done < "$LEARNINGS_PATH" \
    | sort -t $'\t' -k1,1 -nr \
    | head -n "$max" \
    | while IFS=$'\t' read -r s l; do
        printf '[%s] %s — %s\n' "$(jl_field "$l" id)" "$(jl_field "$l" severity)" "$(jl_field "$l" title)"
      done
}

cmd_regen_markdown() {
  ensure_store
  local tmp; tmp="$(mktemp)"
  {
    printf '# Lessons\n\n'
    printf '<!-- Auto-generated below — managed by scripts/learnings.sh. Edit the "Manual additions" section freely. -->\n\n'
    printf '## Auto-generated (do not edit by hand)\n\n'
    if [ -s "$LEARNINGS_PATH" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        local id title sev ph files rule
        id="$(jl_field "$line" id)"
        title="$(jl_field "$line" title)"
        sev="$(jl_field "$line" severity)"
        ph="$(jl_field "$line" phase)"
        files="$(jl_array_csv "$line" files)"
        rule="$(jl_field "$line" rule)"
        printf -- '- **%s** [%s, phase=%s] %s\n' "$id" "$sev" "$ph" "$title"
        [ -n "$files" ] && printf -- '  - *Files:* `%s`\n' "$files"
        [ -n "$rule" ] && printf -- '  - *Rule:* %s\n' "$rule"
      done < "$LEARNINGS_PATH"
    else
      printf '_(no entries yet)_\n'
    fi
    printf '\n## Manual additions (preserved across regen)\n\n'
    printf '<!-- Anything below this marker is read on `learnings.sh migrate` and re-emitted as source="manual" entries. -->\n'
    # Preserve existing manual section if present
    if [ -f "$LESSONS_MD" ] && grep -q '^## Manual additions' "$LESSONS_MD"; then
      sed -n '/^## Manual additions/,$ p' "$LESSONS_MD" \
        | sed '1,/<!-- Anything below this marker/d'
    fi
  } > "$tmp"

  # Use shrink-guard if available; otherwise plain mv.
  if [ -f hooks/lib/shrink-guard.sh ]; then
    # shellcheck disable=SC1091
    . hooks/lib/shrink-guard.sh
    mtk_guarded_write "$LESSONS_MD" "$(cat "$tmp")"
  else
    mv "$tmp" "$LESSONS_MD"
  fi
  rm -f "$tmp"
  printf 'Regenerated %s\n' "$LESSONS_MD"
}

cmd_migrate() {
  ensure_store
  [ -f "$LESSONS_MD" ] || { printf 'No %s — nothing to migrate.\n' "$LESSONS_MD"; return 0; }

  # Skip if already migrated (auto-generated header present and store non-empty)
  if grep -q '<!-- Auto-generated below' "$LESSONS_MD" && [ -s "$LEARNINGS_PATH" ]; then
    printf 'Already migrated. Use regen-markdown to refresh tasks/lessons.md.\n'
    return 0
  fi

  # Parse: every bullet line "- ..." or "* ..." becomes one entry.
  # Heading-only sections are skipped (no body).
  local count=0
  while IFS= read -r line; do
    case "$line" in
      "- "*|"* "*)
        local title="${line#* }"
        # Truncate to ~120 chars for title; full text in body.
        local short_title="${title:0:120}"
        cmd_add --source manual --scope team --severity warn --phase any \
          --title "$short_title" --body "$title" >/dev/null
        count=$((count + 1))
        ;;
    esac
  done < "$LESSONS_MD"

  printf 'Migrated %d entries to %s\n' "$count" "$LEARNINGS_PATH"
  cmd_regen_markdown
}

cmd_list() {
  ensure_store
  [ -s "$LEARNINGS_PATH" ] || return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\t%s\n' "$(jl_field "$line" id)" "$(jl_field "$line" title)"
  done < "$LEARNINGS_PATH"
}

# metrics — sycophancy index (π) plus decision_origin totals over a rolling window.
# Default window = 30 days. Override with --window-days N.
# Threshold read from .claude/review-config.json (sycophancy_index.warn_threshold), default 0.70.
cmd_metrics() {
  ensure_store
  local window_days=30
  while [ $# -gt 0 ]; do
    case "$1" in
      --window-days) window_days="$2"; shift 2 ;;
      *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  local threshold="0.70"
  if [ -f .claude/review-config.json ]; then
    # Best-effort extraction; tolerate missing key.
    local extracted
    extracted="$(sed -nE 's/.*"warn_threshold"[[:space:]]*:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' .claude/review-config.json | head -1)"
    [ -n "$extracted" ] && threshold="$extracted"
  fi

  local cutoff_epoch
  cutoff_epoch="$(date -u -v -"${window_days}"d +%s 2>/dev/null || date -u -d "${window_days} days ago" +%s)"

  local ud=0 cra=0 crm=0 crr=0 si=0
  if [ -s "$LEARNINGS_PATH" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local captured_at; captured_at="$(jl_field "$line" captured_at)"
      [ -z "$captured_at" ] && continue
      local entry_epoch
      entry_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$captured_at" +%s 2>/dev/null || date -u -d "$captured_at" +%s 2>/dev/null || echo 0)"
      [ "$entry_epoch" -lt "$cutoff_epoch" ] && continue
      local origin; origin="$(jl_field "$line" decision_origin)"
      case "$origin" in
        user-directed) ud=$((ud+1)) ;;
        claude-recommended-approved) cra=$((cra+1)) ;;
        claude-recommended-modified) crm=$((crm+1)) ;;
        claude-recommended-rejected) crr=$((crr+1)) ;;
        system-inferred) si=$((si+1)) ;;
      esac
    done < "$LEARNINGS_PATH"
  fi

  local denom=$((cra + crm + crr))
  local pi="0.000"
  if [ "$denom" -gt 0 ]; then
    pi="$(awk -v a="$cra" -v d="$denom" 'BEGIN { printf("%.3f", a / d) }')"
  fi
  local status="ok"
  if awk -v p="$pi" -v t="$threshold" 'BEGIN { exit (p >= t ? 0 : 1) }'; then
    [ "$denom" -gt 0 ] && status="warn"
  fi

  printf '{"window_days":%d,"totals":{"user-directed":%d,"claude-recommended-approved":%d,"claude-recommended-modified":%d,"claude-recommended-rejected":%d,"system-inferred":%d},"pi":%s,"warn_threshold":%s,"status":"%s"}\n' \
    "$window_days" "$ud" "$cra" "$crm" "$crr" "$si" "$pi" "$threshold" "$status"
}

main() {
  local sub="${1:-}"; [ $# -gt 0 ] && shift
  case "$sub" in
    add) cmd_add "$@" ;;
    query) cmd_query "$@" ;;
    metrics) cmd_metrics "$@" ;;
    regen-markdown) cmd_regen_markdown ;;
    migrate) cmd_migrate ;;
    list) cmd_list ;;
    -h|--help|help|"")
      sed -n '2,16p' "$0" | sed 's/^# //; s/^#$//'
      ;;
    *) printf 'unknown subcommand: %s\n' "$sub" >&2; exit 2 ;;
  esac
}

main "$@"
