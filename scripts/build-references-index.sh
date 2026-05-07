#!/usr/bin/env bash
# build-references-index.sh — emit .claude/references.index from frontmatter.
set -euo pipefail

# shellcheck source=../hooks/lib/shrink-guard.sh
. "$(cd "$(dirname "$0")/../hooks/lib" && pwd)/shrink-guard.sh"

# Contract:
#   build-references-index.sh
#     Scans .claude/references/**/*.md for YAML frontmatter with
#     `description`, `globs`, `alwaysApply` and writes .claude/references.index.
#   build-references-index.sh --check
#     Exit 1 if on-disk index differs from freshly built index (used by validator).

# Operate on the caller's CWD (the project repo), not the script's location.
# When invoked via $CLAUDE_PLUGIN_ROOT/scripts/... from a project bootstrap,
# cd-ing to the script's parent would scan the plugin's references instead.
INDEX=.claude/references.index

extract_field() {
  # Read a scalar field from frontmatter (block between first two --- lines).
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { in_fm = 0 }
    /^---$/ { in_fm = !in_fm; next }
    in_fm && $1 == key":" {
      sub("^[^:]+:[[:space:]]*", "", $0)
      gsub(/^["'\''"]/, "", $0)
      gsub(/["'\''"]$/, "", $0)
      print
      exit
    }
  ' "$file"
}

build() {
  {
    printf "# path\talwaysApply\tdescription\tglobs\n"
    while IFS= read -r -d '' f; do
      desc=$(extract_field "$f" description)
      globs=$(extract_field "$f" globs)
      always=$(extract_field "$f" alwaysApply)
      # normalize: empty globs → "*"; empty alwaysApply → "false"
      [[ -n "$globs" ]] || globs='["*"]'
      [[ -n "$always" ]] || always="false"
      # strip brackets/quotes from globs array → comma-separated
      globs=$(printf '%s' "$globs" | sed -E 's/^\[//; s/\]$//; s/"//g; s/'"'"'//g; s/,[[:space:]]+/,/g')
      [[ -n "$desc" ]] || desc="(no description)"
      printf "%s\t%s\t%s\t%s\n" "$f" "$always" "$desc" "$globs"
    done < <(find .claude/references -name '*.md' -type f -print0 | LC_ALL=C sort -z)
  }
}

if [[ "${1:-}" == "--check" ]]; then
  actual=$(build)
  expected=$(cat "$INDEX" 2>/dev/null || true)
  if [[ "$actual" != "$expected" ]]; then
    echo "references.index out of sync. Run: bash scripts/build-references-index.sh" >&2
    exit 1
  fi
else
  TMP_INDEX="${INDEX}.tmp.$$"
  build > "$TMP_INDEX"
  if mtk_guarded_write "$INDEX" "$TMP_INDEX"; then
    echo "wrote $INDEX ($(wc -l < "$INDEX" | tr -d ' ') lines)"
  else
    rc=$?
    rm -f "$TMP_INDEX"
    exit "$rc"
  fi
fi
