#!/usr/bin/env bash
set -euo pipefail

# lesson-anchors.sh — deterministic stale-anchor check for the lessons stores.
#
# A lesson that cites a file or symbol which no longer exists rots silently:
# the citation reads as authority while pointing at nothing, and nothing
# audits it between manual rewrites. This script parses backtick-quoted
# anchors out of lesson markdown and verifies them against the repo — pure
# bash/awk/grep, sub-second, no model call.
#
# CONSERVATIVE BY DESIGN. Lessons legitimately cite files from OTHER repos
# (borrow notes, external examples). A checker that flags those would train
# people to ignore it (the flaky-gate lesson). Rules:
#   - only backtick tokens containing '/' are candidates;
#   - the first path segment must exist as a directory in this repo —
#     otherwise the token is treated as an example, not an anchor, and
#     counted as skipped (reported in the summary, never warned about);
#   - `path:symbol` anchors additionally grep the symbol inside the file;
#     `path:123` line anchors check only the file.
#
# Output: one line per stale anchor, with the nearest lesson heading and a
# same-basename rename suggestion when one exists. WARN-only posture: exit 0
# regardless of findings unless --strict. Retirement is a human decision —
# this tool locates candidates, it never decides.
#
# Usage:
#   bash scripts/lesson-anchors.sh [--strict] [file ...]
#   (default files: tasks/lessons.md and .claude/lessons/personal.md if present)

ROOT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT_DIR"

STRICT=0
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    -h|--help) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) FILES+=("$1"); shift ;;
  esac
done
if [ "${#FILES[@]}" -eq 0 ]; then
  [ -f tasks/lessons.md ] && FILES+=("tasks/lessons.md")
  [ -f .claude/lessons/personal.md ] && FILES+=(".claude/lessons/personal.md")
fi
[ "${#FILES[@]}" -gt 0 ] || { echo "lesson-anchors: no lesson files found"; exit 0; }

checked=0
stale=0
skipped=0

# Extract "<line>\t<heading>\t<token>" triples: every backtick token paired
# with the nearest preceding ##/### heading for context.
extract_anchors() { # $1 = file
  awk '
    /^##/ { heading = $0; sub(/^#+[[:space:]]*/, "", heading) }
    {
      line = $0
      while (match(line, /`[^`]+`/)) {
        token = substr(line, RSTART + 1, RLENGTH - 2)
        printf "%d\t%s\t%s\n", NR, heading, token
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

suggest_rename() { # $1 = missing path -> prints " [did you mean: ...?]" or ""
  # Unique-match-or-unresolvable: suggest only when exactly one same-basename
  # candidate exists; several candidates are named as ambiguous, never picked.
  local base cands n
  base="${1##*/}"
  [ -n "$base" ] || return 0
  cands="$(git ls-files 2>/dev/null | grep -F -e "/$base" -e "$base" | grep -E "(^|/)$(printf '%s' "$base" | sed 's/[][\.*^$]/\\&/g')$" || true)"
  [ -n "$cands" ] || return 0
  n="$(printf '%s\n' "$cands" | grep -c . || true)"
  if [ "$n" -eq 1 ]; then
    printf ' [did you mean: %s?]' "$cands"
  else
    printf ' [%s same-named candidates — ambiguous, resolve by hand]' "$n"
  fi
}

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  while IFS="$(printf '\t')" read -r lineno heading token; do
    # Candidate filter: must contain a slash, no spaces, not a URL/env/glob.
    case "$token" in
      *' '*|http://*|https://*|'$'*|~*|*'*'*|*'{'*) continue ;;
      */*) : ;;
      *) continue ;;
    esac

    path="$token"
    symbol=""
    # path:symbol / path:lineno split (last colon; only when prefix has a slash)
    case "$token" in
      */*:*)
        path="${token%:*}"
        symbol="${token##*:}"
        ;;
    esac

    # First segment must be a directory in THIS repo, else it is an external
    # example — skipped, never warned about.
    first="${path%%/*}"
    if [ ! -d "$first" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    checked=$((checked + 1))
    if [ ! -e "$path" ]; then
      stale=$((stale + 1))
      printf '%s:%s: STALE-PATH `%s` (lesson: %s)%s\n' \
        "$f" "$lineno" "$path" "${heading:-?}" "$(suggest_rename "$path")"
      continue
    fi

    # Symbol check: skip pure line-number anchors; grep the rest as a fixed
    # string so regex metachars in signatures cannot false-match.
    if [ -n "$symbol" ] && [ -f "$path" ]; then
      case "$symbol" in
        ''|*[!0-9]*)
          if ! grep -qF "$symbol" "$path" 2>/dev/null; then
            stale=$((stale + 1))
            printf '%s:%s: STALE-SYMBOL `%s` — not found in %s (lesson: %s)\n' \
              "$f" "$lineno" "$symbol" "$path" "${heading:-?}"
          fi
          ;;
      esac
    fi
  done < <(extract_anchors "$f")
done

echo "lesson-anchors: $checked anchor(s) checked, $stale stale, $skipped external-looking token(s) skipped"
if [ "$STRICT" -eq 1 ] && [ "$stale" -gt 0 ]; then
  exit 1
fi
exit 0
