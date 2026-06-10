#!/usr/bin/env bash
# lint-skill-bash.sh — deterministic lint for fenced ```bash blocks inside skills.
# Catches three bug classes that have shipped in skill files before:
#   1. grep-brace-glob   --include= with {a,b} braces (grep does not expand braces)
#   2. path-clobber      PATH used as a loop/assignment variable (breaks executable lookup)
#   3. find-ungrouped-or find with -o and no \( \) grouping (operator-precedence bug)
# Plain awk only — no shellcheck dependency. Exit 1 on any finding.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

findings=0
for skill in .claude/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  out="$(awk -v file="$skill" '
    !inblock && /^```bash/ { inblock = 1; next }
    inblock && /^```/      { inblock = 0; next }
    !inblock               { next }
    {
      line = $0
      if (line ~ /--include=[^[:space:]]*\{/)
        printf "%s:%d: grep-brace-glob: %s\n", file, FNR, line
      if (line ~ /for[[:space:]]+PATH[[:space:]]/)
        printf "%s:%d: path-clobber: %s\n", file, FNR, line
      else if (line ~ /^[[:space:]]*(export[[:space:]]+)?PATH=/ && line !~ /PATH="?\$PATH/)
        printf "%s:%d: path-clobber: %s\n", file, FNR, line
      if (line ~ /(^|[;&|[:space:]])find[[:space:]]/ && line ~ /[[:space:]]-o[[:space:]]/ && line !~ /\\\(/)
        printf "%s:%d: find-ungrouped-or: %s\n", file, FNR, line
    }
  ' "$skill")"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    findings=1
  fi
done

if [ "$findings" -ne 0 ]; then
  exit 1
fi
printf 'skill bash lint passed\n'
