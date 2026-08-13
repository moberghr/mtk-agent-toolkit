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

# Script root — used ONLY to locate the toolkit's own libs (shrink-guard),
# which ship alongside this script and are NOT present in target repos.
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Store root — anchored to the INVOKING repo (git toplevel of cwd), falling back
# to cwd outside a repo. A plugin-path invocation must write into the caller's
# repo, never the shared plugin cache under SCRIPT_ROOT.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

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
          # Force base-10: ids are %03d zero-padded, so bare arithmetic parses
          # 008/009 as octal and aborts ("value too great for base").
          [ -n "$n" ] && n=$((10#$n)) && [ "$n" -gt "$max_n" ] && max_n="$n"
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

# Validate a JSON value and compact it to a single line so a multi-line or
# malformed contract value can never corrupt the JSONL store. Uses python3
# (baseline, S3.3) when present; degrades to an outer-shape glob that also
# rejects embedded newlines when python3 is absent. Returns non-zero on invalid
# input or wrong top-level type ($2 = object|array).
_contract_json() {
  local raw="$1" kind="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$raw" | python3 -c '
import json, sys
kind = sys.argv[1]
try:
    v = json.load(sys.stdin)
except Exception:
    sys.exit(3)
if kind == "object" and not isinstance(v, dict): sys.exit(4)
if kind == "array" and not isinstance(v, list): sys.exit(4)
sys.stdout.write(json.dumps(v, separators=(",", ":")))
' "$kind" || return 1
  else
    case "$raw" in *"
"*) return 1 ;; esac  # reject embedded newlines in the no-python3 fallback
    if [ "$kind" = "object" ]; then
      case "$raw" in "{"*"}") printf '%s' "$raw" ;; *) return 1 ;; esac
    else
      case "$raw" in "["*"]") printf '%s' "$raw" ;; *) return 1 ;; esac
    fi
  fi
}

cmd_add() {
  ensure_store
  local spec_id="" workflow_uuid="manual" scope="personal" source_kind="correction"
  local files_csv="" dirs_csv="" phase="any" severity="warn"
  local title="" body="" rule="" applies_when=""
  local decision_origin=""
  local wrong_turns_csv="" time_cost="" evolution_actions=""
  local memory_type="" supersedes=""
  # v7.25 optional executable lesson-contract fields (all optional, back-compat)
  local output_contract="" prefinal_checklist="" confidence="" source_evidence_refs_csv=""
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
      # content-type tag + conflict-superseding (pass-through; query derives supersession)
      --memory-type) memory_type="$2"; shift 2 ;;
      --supersedes) supersedes="$2"; shift 2 ;;
      # v7.25 executable lesson-contract (pass-through; validated by mtk-doctor lint)
      --output-contract) output_contract="$2"; shift 2 ;;
      --prefinal-checklist) prefinal_checklist="$2"; shift 2 ;;
      --confidence) confidence="$2"; shift 2 ;;
      --source-evidence-refs) source_evidence_refs_csv="$2"; shift 2 ;;
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
  if [ -n "$memory_type" ]; then
    case "$memory_type" in
      episodic|semantic|procedural) ;;
      *) printf 'add: invalid --memory-type "%s" (one of: episodic | semantic | procedural)\n' "$memory_type" >&2; exit 2 ;;
    esac
    extra="${extra},\"memory_type\":\"${memory_type}\""
  fi
  if [ -n "$supersedes" ]; then
    extra="${extra},\"supersedes\":\"$(json_escape "$supersedes")\""
  fi

  # v7.25 executable lesson-contract fields. output_contract / prefinal_checklist
  # are caller-authored JSON (the golden-path-capture / promote-lesson skills build
  # them); embedded verbatim with a light brace/bracket guard. mtk-doctor runs the
  # deep well-formedness lint. Keeps learnings.sh JSON-parser-free (S3.3).
  if [ -n "$confidence" ]; then
    case "$confidence" in
      low|medium|high) extra="${extra},\"confidence\":\"${confidence}\"" ;;
      *) printf 'add: invalid --confidence "%s" (one of: low | medium | high)\n' "$confidence" >&2; exit 2 ;;
    esac
  fi
  if [ -n "$output_contract" ]; then
    local oc_json
    oc_json="$(_contract_json "$output_contract" object)" || { printf 'add: --output-contract must be a valid JSON object ({...}), single logical value\n' >&2; exit 2; }
    extra="${extra},\"output_contract\":${oc_json}"
  fi
  if [ -n "$prefinal_checklist" ]; then
    local pc_json
    pc_json="$(_contract_json "$prefinal_checklist" array)" || { printf 'add: --prefinal-checklist must be a valid JSON array ([...]), single logical value\n' >&2; exit 2; }
    extra="${extra},\"prefinal_verification_checklist\":${pc_json}"
  fi
  if [ -n "$source_evidence_refs_csv" ]; then
    extra="${extra},\"source_evidence_refs\":$(csv_to_json_array "$source_evidence_refs_csv")"
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
# Extract a JSON string value and reverse json_escape (unescape \" \\ \n \r \t).
# A plain "key":"([^"]*)" regex is wrong: it stops at the first quote inside an
# escaped value (a title containing \") and never unescapes, so the round-trip is
# lossy — which broke migrate's title-hash dedup. Walk the value honoring escapes
# and stop only at an unescaped closing quote.
jl_field() {
  local line="$1" key="$2"
  printf '%s\n' "$line" | awk -v k="$key" '
    {
      needle = "\"" k "\":\""
      idx = index($0, needle)
      if (idx == 0) next
      s = substr($0, idx + length(needle))
      out = ""; i = 1; n = length(s)
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") {
          nc = substr(s, i + 1, 1)
          if (nc == "n") out = out "\n"
          else if (nc == "r") out = out "\r"
          else if (nc == "t") out = out "\t"
          else out = out nc
          i += 2
        } else if (c == "\"") {
          break
        } else {
          out = out c
          i += 1
        }
      }
      print out
      exit
    }
  '
}

# Extract a JSON array of strings as a comma-separated list.
jl_array_csv() {
  local line="$1" key="$2"
  printf '%s\n' "$line" | sed -nE "s/.*\"${key}\":\[([^]]*)\].*/\1/p" \
    | tr -d '"' | head -1
}

# Stable hash of a lesson title, for idempotent migrate dedup. cksum is POSIX
# (present on BSD/macOS and coreutils) so this needs no md5/shasum probe.
title_hash() {
  printf '%s' "$1" | cksum | awk '{print $1}'
}

cmd_query() {
  # Record store presence BEFORE ensure_store creates it, so "never seeded" stays
  # distinguishable from "seeded but empty" in the diagnostic below.
  local store_existed=1
  [ -f "$LEARNINGS_PATH" ] || store_existed=0
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

  # A bare empty stdout is ambiguous: "no lessons stored" and "lessons stored,
  # none matched" look identical to a caller, so a skill cannot tell whether it
  # legitimately skipped the lessons pass or silently lost it. Diagnose on
  # stderr — stdout stays a clean result list and the exit code stays 0, so
  # existing callers are unaffected.
  if [ "$store_existed" -eq 0 ]; then
    if [ -f "$LESSONS_MD" ]; then
      printf 'learnings query: no store at %s, but %s exists — run `learnings.sh migrate` to make those lessons queryable.\n' \
        "$LEARNINGS_PATH" "$LESSONS_MD" >&2
    else
      printf 'learnings query: no store at %s and no %s — nothing captured yet.\n' \
        "$LEARNINGS_PATH" "$LESSONS_MD" >&2
    fi
    return 0
  fi
  if [ ! -s "$LEARNINGS_PATH" ]; then
    printf 'learnings query: store %s exists but holds 0 entries.\n' "$LEARNINGS_PATH" >&2
    return 0
  fi

  # Conflict-superseding: collect ids that a newer entry supersedes, then drop
  # them from results. Derived from the forward `supersedes` ref — no line rewrite.
  local superseded_ids=","
  while IFS= read -r sline; do
    [ -z "$sline" ] && continue
    local sup; sup="$(jl_field "$sline" supersedes)"
    [ -n "$sup" ] && superseded_ids="${superseded_ids}${sup},"
  done < "$LEARNINGS_PATH"

  # Score each line; emit "score\tline"; sort -nr; head -max; print formatted.
  local now_epoch; now_epoch="$(date -u +%s)"

  # Scored rows go to a temp file rather than straight down a pipe: a `while |
  # sort` pipeline runs the loop in a subshell, and the scanned/matched counters
  # the diagnostic needs would not survive it.
  local scored_file; scored_file="$(mktemp)"
  local scanned=0 matched=0

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    scanned=$((scanned + 1))
    local this_id; this_id="$(jl_field "$line" id)"
    case "$superseded_ids" in *",${this_id},"*) continue ;; esac
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

    matched=$((matched + 1))
    printf '%d\t%s\n' "$score" "$line" >> "$scored_file"
  done < "$LEARNINGS_PATH"

  if [ "$matched" -gt 0 ]; then
    sort -t $'\t' -k1,1 -nr "$scored_file" \
      | head -n "$max" \
      | while IFS=$'\t' read -r s l; do
          printf '[%s] %s — %s\n' "$(jl_field "$l" id)" "$(jl_field "$l" severity)" "$(jl_field "$l" title)"
        done
  else
    printf 'learnings query: scanned %d stored entr%s, 0 matched (phase=%s, scope=%s, files=%s). No stored lesson applies here — this is a clean miss, not a lookup failure.\n' \
      "$scanned" "$([ "$scanned" -eq 1 ] && printf 'y' || printf 'ies')" \
      "$phase" "$scope_filter" "${files_csv:-<none>}" >&2
  fi
  rm -f "$scored_file"
}

cmd_regen_markdown() {
  ensure_store
  local force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  local tmp; tmp="$(mktemp)"
  local rendered=0
  {
    printf '# Lessons\n\n'
    printf '<!-- Auto-generated below — managed by scripts/learnings.sh. Edit the "Manual additions" section freely. -->\n\n'
    printf '## Auto-generated (do not edit by hand)\n\n'
    if [ -s "$LEARNINGS_PATH" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Team-scope only: personal entries stay in the gitignored store and
        # never render into the committed team file (lessons-split S1).
        local sc; sc="$(jl_field "$line" scope)"
        [ "$sc" = "team" ] || continue
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
        # v7.25 executable contract (rendered only when present — prose lessons unchanged)
        local conf evrefs parts
        conf="$(jl_field "$line" confidence)"
        evrefs="$(jl_array_csv "$line" source_evidence_refs)"
        parts=""
        [ -n "$conf" ] && parts="confidence=$conf"
        case "$line" in *'"output_contract"'*) parts="${parts:+$parts, }output_contract" ;; esac
        case "$line" in *'"prefinal_verification_checklist"'*) parts="${parts:+$parts, }prefinal_checklist" ;; esac
        [ -n "$parts" ] && printf -- '  - *Contract:* %s\n' "$parts"
        [ -n "$evrefs" ] && printf -- '  - *Evidence:* `%s`\n' "$evrefs"
        rendered=$((rendered + 1))
      done < "$LEARNINGS_PATH"
    fi
    [ "$rendered" -eq 0 ] && printf '_(no entries yet)_\n'
    printf '\n## Manual additions (preserved across regen)\n\n'
    printf '<!-- Anything below this marker is read on `learnings.sh migrate` and re-emitted as source="manual" entries. -->\n'
    # Preserve existing manual section if present
    if [ -f "$LESSONS_MD" ] && grep -q '^## Manual additions' "$LESSONS_MD"; then
      sed -n '/^## Manual additions/,$ p' "$LESSONS_MD" \
        | sed '1,/<!-- Anything below this marker/d'
    fi
  } > "$tmp"

  # Refuse to clobber a legacy, hand-written lessons.md that predates the
  # structured store (no auto-generated marker) — the same marker-refusal
  # convention as scripts/generate-agents-md.sh. `migrate` passes --force after
  # it has already ingested the legacy content into the store.
  if [ "$force" -ne 1 ] && [ -f "$LESSONS_MD" ] \
     && ! grep -q '<!-- Auto-generated below' "$LESSONS_MD"; then
    rm -f "$tmp"
    printf 'regen-markdown: refusing to overwrite %s — no MTK auto-generated marker (looks hand-written). Run `learnings.sh migrate` first to ingest it, or pass --force.\n' "$LESSONS_MD" >&2
    return 1
  fi

  mkdir -p "$(dirname "$LESSONS_MD")"

  # Use shrink-guard if available (resolved from the script root, not the
  # invoking repo — target repos have no hooks/lib/); otherwise plain mv.
  if [ -f "$SCRIPT_ROOT/hooks/lib/shrink-guard.sh" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_ROOT/hooks/lib/shrink-guard.sh"
    if [ "$force" -eq 1 ]; then
      # --force (migrate) is an intentional prose->summary rewrite: full bodies
      # live in the JSONL store, so a large byte/line shrink of the markdown
      # view is expected and the shrink-guard must not block it.
      MTK_SHRINK_GUARD_OVERRIDE=1 mtk_guarded_write "$LESSONS_MD" "$tmp"
    else
      mtk_guarded_write "$LESSONS_MD" "$tmp"
    fi
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

  # Idempotency: collect title hashes already in the store so re-running migrate
  # over the same legacy content adds nothing (schema: matched by title hash).
  local existing_hashes=" "
  if [ -s "$LEARNINGS_PATH" ]; then
    while IFS= read -r sline; do
      [ -z "$sline" ] && continue
      local st; st="$(jl_field "$sline" title)"
      [ -n "$st" ] && existing_hashes="${existing_hashes}$(title_hash "$st") "
    done < "$LEARNINGS_PATH"
  fi

  # Parse "## <heading>" blocks: title from the heading line, body from the
  # lines beneath it up to the next heading. The toolkit's own tasks/lessons.md
  # uses heading blocks, not bullets — bullet-only parsing shredded each lesson
  # into fragments and dropped the heading-titled ones entirely.
  local count=0 title="" body=""
  _flush_block() {
    [ -n "$title" ] || return 0
    local short_title="${title:0:120}"
    local h; h="$(title_hash "$short_title")"
    case "$existing_hashes" in
      *" $h "*) title=""; body=""; return 0 ;;
    esac
    local b="${body%$'\n'}"
    [ -n "$b" ] || b="$title"
    cmd_add --source manual --scope team --severity warn --phase any \
      --title "$short_title" --body "$b" >/dev/null
    existing_hashes="${existing_hashes}${h} "
    count=$((count + 1))
    title=""; body=""
  }
  while IFS= read -r line; do
    case "$line" in
      "## "*)
        _flush_block
        title="${line#"## "}"
        body=""
        ;;
      "# "*)
        _flush_block
        title=""; body=""
        ;;
      *)
        [ -n "$title" ] && body="${body}${line}"$'\n'
        ;;
    esac
  done < "$LESSONS_MD"
  _flush_block

  printf 'Migrated %d entries to %s\n' "$count" "$LEARNINGS_PATH"
  cmd_regen_markdown --force
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
    regen-markdown) cmd_regen_markdown "$@" ;;
    migrate) cmd_migrate ;;
    list) cmd_list ;;
    -h|--help|help|"")
      sed -n '2,16p' "$0" | sed 's/^# //; s/^#$//'
      ;;
    *) printf 'unknown subcommand: %s\n' "$sub" >&2; exit 2 ;;
  esac
}

main "$@"
