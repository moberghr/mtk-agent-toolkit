#!/usr/bin/env bash
set -euo pipefail
# verify-claims.sh — Grep-verify factual claims in an MTK-generated doc.
#
# Reads a generated CLAUDE.md / architecture-principles.md / conventions.md.
# Parses claim lines that cite evidence (path:line, path globs, or symbol names)
# and runs a grep for each anchor. Lines with zero hits are downgraded:
#   [EXTRACTED]   -> [INFERRED:0.5]
#   [ENFORCED]    -> [ASPIRATIONAL]
# Other tags are left alone but recorded.
#
# Discrimination rules (round-1 eval fixes):
#   - LEGEND/DEFINITION lines are skipped. Real claims carry a BARE tag ([EXTRACTED]);
#     the confidence legend documents tags INSIDE backticks (`[EXTRACTED]`). We strip
#     inline-code spans before testing for a tag, so legend lines never get rewritten.
#   - ABSENCE claims ("no raw SQL", "0 hits", "never uses X") are NOT downgraded on zero
#     hits — zero hits is the confirmation, not a weakness.
#   - hit_count resolves bare filenames (find -name), `a|b` alternations (grep -E),
#     and real paths (test -e) before falling back to a content grep.
#
# Side effects:
#   - Rewrites the input file in place (atomic, via .tmp + mv).
#   - Writes per-doc reports: .claude/.mtk-cache/weak-claims-<doc>.json / -<doc>.md
#     (per-doc filenames prevent one doc's run from clobbering another's report).
#
# Exit codes:
#   0 — verified, may have downgrades (count printed)
#   2 — input file missing or not in a git repo
#
# Usage:
#   bash scripts/verify-claims.sh .claude/references/architecture-principles.md
#   bash scripts/verify-claims.sh CLAUDE.md
#
# Spec: docs/specs/2026-05-25-grounded-audit.md

INPUT="${1:-}"
if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
  echo "ERROR: pass a generated doc path (got: '${INPUT}')" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

CACHE_DIR=".claude/.mtk-cache"
mkdir -p "$CACHE_DIR"
DOC_SLUG="$(basename "$INPUT" | tr '/.' '__')"
WEAK_JSON="$CACHE_DIR/weak-claims-${DOC_SLUG}.json"
WEAK_MD="$CACHE_DIR/weak-claims-${DOC_SLUG}.md"

# --- Helpers ----------------------------------------------------------------

# Run grep silently and return hit count for a single anchor.
# Resolution order: path:line · glob · alternation · real path · bare filename · content grep.
hit_count() {
  local anchor="$1"
  local count=0
  case "$anchor" in
    *:[0-9]*)
      local path="${anchor%%:*}"
      [[ -e "$path" ]] && count=1
      ;;
    *\**|*\?*)
      # glob — count files that match
      count=$(find . -path "./$anchor" -type f 2>/dev/null | wc -l | tr -d ' ')
      ;;
    *)
      if [[ "$anchor" == *"|"* && "$anchor" != *" "* ]]; then
        # alternation of symbols (e.g. IRequest|IMediator) — extended-regex grep
        count=$(git grep -lIE -- "$anchor" 2>/dev/null | wc -l | tr -d ' ')
      elif [[ "$anchor" == */* ]]; then
        # looks like a path (incl. dotted paths like .github/workflows/ci.yml)
        if [[ -e "$anchor" || -e "${anchor#./}" ]]; then
          count=1
        else
          count=$(git grep -lI --fixed-strings -- "$anchor" 2>/dev/null | wc -l | tr -d ' ')
        fi
      elif [[ "$anchor" == *.* && "$anchor" != *" "* ]]; then
        # bare filename (e.g. InventhorContext.cs) — resolve by name, else content grep
        if [[ -n "$(find . -name "$anchor" -not -path '*/.git/*' 2>/dev/null | head -1)" ]]; then
          count=1
        else
          count=$(git grep -lI --fixed-strings -- "$anchor" 2>/dev/null | wc -l | tr -d ' ')
        fi
      else
        # bare token — grep across tracked files
        count=$(git grep -lI --fixed-strings -- "$anchor" 2>/dev/null | wc -l | tr -d ' ')
      fi
      ;;
  esac
  echo "$count"
}

# Extract anchors from a claim line: backticked paths and symbols.
extract_anchors() {
  local line="$1"
  echo "$line" | grep -oE '`[^`]+`' | sed 's/^`//;s/`$//' || true
}

# Is this an absence/negative claim? Zero hits is confirmation, not weakness.
is_absence_claim() {
  local text="$1"
  local rc=0
  shopt -s nocasematch
  if [[ "$text" =~ (^|[^[:alnum:]])(no|not|never|without|absent|none|zero|n/a)([^[:alnum:]]|$) || "$text" == *"0 hit"* || "$text" == *"zero hit"* ]]; then
    rc=1
  fi
  shopt -u nocasematch
  echo "$rc"
}

# --- Parse + verify ---------------------------------------------------------

TMP_OUT="$(mktemp)"
WEAK_ENTRIES=()
DOWNGRADES=0
TOTAL_CLAIMS=0
TAG_RE='\[EXTRACTED\]|\[ENFORCED\]|\[INFERRED:[0-9.]+\]|\[CONVENTION\]|\[ASPIRATIONAL\]|\[AMBIGUOUS\]|\[MINED:feedback\]'

LINENO_=0
while IFS= read -r line || [[ -n "$line" ]]; do
  LINENO_=$((LINENO_ + 1))

  # Strip inline-code spans first: tag tokens used as literals (the confidence legend,
  # e.g. `[EXTRACTED]` = ...) must NOT be treated as claims or rewritten.
  stripped="$(printf '%s' "$line" | sed 's/`[^`]*`//g')"

  if [[ "$stripped" =~ $TAG_RE ]]; then
    TOTAL_CLAIMS=$((TOTAL_CLAIMS + 1))
    anchors=$(extract_anchors "$line")
    if [[ -z "$anchors" ]]; then
      WEAK_ENTRIES+=("{\"file\":\"$INPUT\",\"line\":$LINENO_,\"reason\":\"no-evidence-anchor\",\"hits\":0,\"text\":$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')}")
      echo "$line" >> "$TMP_OUT"
      continue
    fi

    total_hits=0
    failing_anchor=""
    while IFS= read -r a; do
      [[ -z "$a" ]] && continue
      h=$(hit_count "$a")
      total_hits=$((total_hits + h))
      [[ "$h" == "0" && -z "$failing_anchor" ]] && failing_anchor="$a"
    done <<< "$anchors"

    if [[ "$total_hits" == "0" ]]; then
      if [[ "$(is_absence_claim "$stripped")" == "1" ]]; then
        # Absence claim with zero hits — this is the evidence, not a weakness. Keep as-is.
        echo "$line" >> "$TMP_OUT"
      else
        DOWNGRADES=$((DOWNGRADES + 1))
        # Downgrade tags in the line itself (operate on $line; legend lines already excluded).
        new_line="$line"
        new_line="${new_line//\[EXTRACTED\]/[INFERRED:0.5 unverified]}"
        new_line="${new_line//\[ENFORCED\]/[ASPIRATIONAL unverified]}"
        echo "$new_line" >> "$TMP_OUT"
        WEAK_ENTRIES+=("{\"file\":\"$INPUT\",\"line\":$LINENO_,\"reason\":\"zero-hit-anchor\",\"hits\":0,\"anchor\":$(printf '%s' "$failing_anchor" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'),\"text\":$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')}")
      fi
    else
      echo "$line" >> "$TMP_OUT"
    fi
  else
    echo "$line" >> "$TMP_OUT"
  fi
done < "$INPUT"

# Atomic replace.
mv "$TMP_OUT" "$INPUT"

# --- Emit reports -----------------------------------------------------------

# JSON
python3 - <<PY > "$WEAK_JSON"
import json, sys
entries = [$(IFS=,; echo "${WEAK_ENTRIES[*]:-}")]
print(json.dumps({
    "input": "$INPUT",
    "total_claims": $TOTAL_CLAIMS,
    "downgrades": $DOWNGRADES,
    "weak": entries,
}, indent=2))
PY

# Markdown
{
  echo "# ⚠️ Weakest claims — verify first"
  echo
  echo "Generated by \`scripts/verify-claims.sh\` against \`$INPUT\`."
  echo "Total tagged claims: $TOTAL_CLAIMS · downgraded: $DOWNGRADES"
  echo
  if [[ ${#WEAK_ENTRIES[@]} -eq 0 ]]; then
    echo "_No weak claims detected — every tagged line has at least one evidence hit (or is a confirmed absence claim)._"
  else
    echo "| # | line | anchor | reason | claim |"
    echo "|---|------|--------|--------|-------|"
    i=0
    for e in "${WEAK_ENTRIES[@]}"; do
      i=$((i + 1))
      [[ $i -gt 5 ]] && break
      ln=$(printf '%s' "$e" | python3 -c 'import json,sys; print(json.load(sys.stdin)["line"])')
      reason=$(printf '%s' "$e" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])')
      anchor=$(printf '%s' "$e" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("anchor","—"))')
      text=$(printf '%s' "$e" | python3 -c 'import json,sys; t=json.load(sys.stdin)["text"]; print(t[:120].replace("|","\\|"))')
      echo "| $i | $ln | \`$anchor\` | $reason | $text |"
    done
  fi
} > "$WEAK_MD"

echo "verify-claims: $TOTAL_CLAIMS claim(s) checked · $DOWNGRADES downgrade(s) · report → $WEAK_MD"
exit 0
