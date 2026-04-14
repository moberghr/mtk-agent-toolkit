#!/usr/bin/env bash
#
# Pre-commit deterministic lint pass. Emits findings in the review-finding
# schema shape (see .claude/references/review-finding-schema.md) with
# source: "linter" and confidence: 100. Feeds into the AI review pass;
# does not replace it.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PATTERNS_DIR="$ROOT_DIR/hooks/linter-patterns"

# --- Options ---
DIFF_SOURCE="cached"          # cached | head
STACK=""                      # auto-detect if empty
OUTPUT="json"                 # json | human

while [ $# -gt 0 ]; do
  case "$1" in
    --cached)  DIFF_SOURCE="cached"; shift ;;
    --head)    DIFF_SOURCE="head"; shift ;;
    --stack)   STACK="${2:-}"; shift 2 ;;
    --human)   OUTPUT="human"; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: hooks/pre-commit-linters.sh [--cached | --head] [--stack <name>] [--human]

Scans staged changes (--cached, default) or HEAD changes (--head) with
deterministic patterns. Emits JSON findings on stdout.

--cached     Scan staged changes (default)
--stack      Override tech stack detection (default reads .claude/tech-stack)
--human      Human-readable output instead of JSON
EOF
      exit 0
      ;;
    *) printf 'Unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# --- Stack detection ---
if [ -z "$STACK" ] && [ -f .claude/tech-stack ]; then
  STACK="$(tr -d '[:space:]' < .claude/tech-stack)"
fi

# --- Build pattern list ---
PATTERN_FILES=("$PATTERNS_DIR/shared.txt")
# Slopwatch patterns apply to all stacks (LLM reward hacking is language-agnostic)
if [ -f "$PATTERNS_DIR/slopwatch.txt" ]; then
  PATTERN_FILES+=("$PATTERNS_DIR/slopwatch.txt")
fi
if [ -n "$STACK" ] && [ -f "$PATTERNS_DIR/$STACK.txt" ]; then
  PATTERN_FILES+=("$PATTERNS_DIR/$STACK.txt")
fi

# --- Get diff ---
if [ "$DIFF_SOURCE" = "cached" ]; then
  DIFF_CMD=(git diff --cached -U0 --no-color)
else
  DIFF_CMD=(git diff HEAD -U0 --no-color)
fi

# --- Extract file:line:content for added lines ---
# awk walks the unified diff. Hunk header @@ -a,b +c,d @@ gives new-side
# starting line c. We increment for each +line and each context-but-we-skip
# line (but -U0 means zero context; only +, -, and @@ lines appear).
added_lines() {
  "${DIFF_CMD[@]}" | awk '
    /^\+\+\+ b\// { file=substr($0, 7); next }
    /^\+\+\+ \/dev\/null/ { file=""; next }
    /^@@ / {
      # Parse +c,d — the part after the space-plus
      if (match($0, /\+[0-9]+/)) {
        line = substr($0, RSTART+1, RLENGTH-1) + 0 - 1
      } else { line = 0 }
      next
    }
    /^\+[^+]/ {
      line++
      if (file != "") {
        # Strip the leading +
        content = substr($0, 2)
        # Skip binary markers
        if (content !~ /^Binary files /) {
          printf "%s\t%d\t%s\n", file, line, content
        }
      }
      next
    }
  '
}

# --- Scan added lines against patterns ---
# Each pattern file line: RULE_ID|severity|regex|rationale|suggested_fix
finding_index=0
findings=()

scan() {
  local rule_id="$1" severity="$2" regex="$3" rationale="$4" fix="$5"
  # Use grep -E (ERE) against the tab-separated added-lines output
  # Field 3 is content; grep runs against the whole line but we match on
  # content boundaries by design.
  while IFS=$'\t' read -r file line content; do
    if printf '%s' "$content" | grep -qEi -- "$regex"; then
      finding_index=$((finding_index + 1))
      local fid
      fid=$(printf 'L%03d' "$finding_index")
      # JSON-escape content preview for rationale
      local preview
      preview=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-120)
      findings+=("{\"id\":\"$fid\",\"severity\":\"$severity\",\"confidence\":100,\"source\":\"linter\",\"rule\":\"$rule_id\",\"file\":\"$file\",\"line\":$line,\"rationale\":\"$rationale\",\"suggested_fix\":\"$fix\",\"evidence\":\"$preview\"}")
    fi
  done < <(added_lines)
}

# --- Buffer added lines once (scanning multiple patterns would otherwise
# re-run git diff). ---
ADDED_LINES_CACHE="$(mktemp)"
trap 'rm -f "$ADDED_LINES_CACHE"' EXIT
added_lines > "$ADDED_LINES_CACHE"

scan_cached() {
  local rule_id="$1" severity="$2" regex="$3" rationale="$4" fix="$5"
  while IFS=$'\t' read -r file line content; do
    if printf '%s' "$content" | grep -qEi -- "$regex"; then
      finding_index=$((finding_index + 1))
      local fid
      fid=$(printf 'L%03d' "$finding_index")
      local preview
      preview=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-120)
      findings+=("{\"id\":\"$fid\",\"severity\":\"$severity\",\"confidence\":100,\"source\":\"linter\",\"rule\":\"$rule_id\",\"file\":\"$file\",\"line\":$line,\"rationale\":\"$rationale\",\"suggested_fix\":\"$fix\",\"evidence\":\"$preview\"}")
    fi
  done < "$ADDED_LINES_CACHE"
}

for pattern_file in "${PATTERN_FILES[@]}"; do
  while IFS=$'\t' read -r rule_id severity regex rationale fix; do
    case "$rule_id" in
      \#*|"") continue ;;
    esac
    scan_cached "$rule_id" "$severity" "$regex" "$rationale" "$fix"
  done < "$pattern_file"
done

# --- Emit output ---
critical=0; warning=0; suggestion=0
for f in ${findings[@]+"${findings[@]}"}; do
  case "$f" in
    *'"severity":"critical"'*)   critical=$((critical + 1)) ;;
    *'"severity":"warning"'*)    warning=$((warning + 1)) ;;
    *'"severity":"suggestion"'*) suggestion=$((suggestion + 1)) ;;
  esac
done

verdict="PASS"
[ "$critical" -gt 0 ] && verdict="NEEDS_CHANGES"

if [ "$OUTPUT" = "human" ]; then
  printf 'Linter verdict: %s  (critical=%d warning=%d suggestion=%d)\n' \
    "$verdict" "$critical" "$warning" "$suggestion"
  for f in ${findings[@]+"${findings[@]}"}; do
    printf '%s\n' "$f"
  done
else
  joined=""
  first=1
  for f in ${findings[@]+"${findings[@]}"}; do
    if [ "$first" = 1 ]; then
      joined="$f"; first=0
    else
      joined="$joined,$f"
    fi
  done
  printf '{"source":"linter","verdict":"%s","summary":{"critical":%d,"warning":%d,"suggestion":%d},"findings":[%s]}\n' \
    "$verdict" "$critical" "$warning" "$suggestion" "$joined"
fi
