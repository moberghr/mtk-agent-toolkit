#!/usr/bin/env bash
#
# CI wrapper for the deterministic linter. Runs pre-commit-linters.sh on the
# PR diff and formats output for GitHub Actions (annotations + summary).
#
# Usage:
#   scripts/ci-lint.sh [--base <ref>]
#
# Defaults --base to origin/main. Emits GitHub Actions annotations for each
# finding and writes a markdown summary to $GITHUB_STEP_SUMMARY.

set -euo pipefail

# Resolve the toolkit root from THIS script's real location so a checkout of the
# toolkit into a subdirectory (see templates/ci/pr-lint.yml) can lint the target
# repo in the current working directory. Do NOT cd — the linter diffs cwd (the
# PR checkout) while loading pattern packs from the toolkit checkout.
mtk_realpath() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
    return
  fi
  local p="$1" target
  while [ -L "$p" ]; do
    target="$(readlink "$p")"
    case "$target" in
      /*) p="$target" ;;
      *)  p="$(cd "$(dirname "$p")" && pwd)/$target" ;;
    esac
  done
  printf '%s/%s\n' "$(cd "$(dirname "$p")" && pwd)" "$(basename "$p")"
}

SELF="$(mtk_realpath "$0")"
TOOLKIT_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
LINTER="$TOOLKIT_ROOT/hooks/pre-commit-linters.sh"

BASE_REF="origin/main"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF="${2:-origin/main}"; shift 2 ;;
    *) printf 'Unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# Lint the diff between the base ref and HEAD. Three-dot range = changes on the
# PR branch since it diverged from base (git diff base...HEAD), which matches
# what a reviewer sees — a plain HEAD diff is empty on a clean CI checkout.
LINTER_OUTPUT=$(bash "$LINTER" --range "${BASE_REF}...HEAD" 2>/dev/null || true)

if [ -z "$LINTER_OUTPUT" ]; then
  echo "Linter produced no output."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Lint Check: PASS\nNo findings.\n' >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

# Parse JSON output
VERDICT=$(echo "$LINTER_OUTPUT" | grep -o '"verdict":"[^"]*"' | head -1 | cut -d'"' -f4)
CRITICAL=$(echo "$LINTER_OUTPUT" | grep -o '"critical":[0-9]*' | head -1 | cut -d: -f2)
WARNING=$(echo "$LINTER_OUTPUT" | grep -o '"warning":[0-9]*' | head -1 | cut -d: -f2)
SUGGESTION=$(echo "$LINTER_OUTPUT" | grep -o '"suggestion":[0-9]*' | head -1 | cut -d: -f2)

CRITICAL="${CRITICAL:-0}"
WARNING="${WARNING:-0}"
SUGGESTION="${SUGGESTION:-0}"

# Extract findings into temp file (grep returns 1 on no matches — safe with || true)
FINDINGS_FILE="$(mktemp)"
trap 'rm -f "$FINDINGS_FILE"' EXIT
echo "$LINTER_OUTPUT" | grep -o '{"id":"[^}]*}' > "$FINDINGS_FILE" 2>/dev/null || true

# Emit GitHub Actions annotations for each finding
while IFS= read -r finding; do
  file=$(echo "$finding" | grep -o '"file":"[^"]*"' | cut -d'"' -f4)
  line=$(echo "$finding" | grep -o '"line":[0-9]*' | cut -d: -f2)
  severity=$(echo "$finding" | grep -o '"severity":"[^"]*"' | cut -d'"' -f4)
  rule=$(echo "$finding" | grep -o '"rule":"[^"]*"' | cut -d'"' -f4)
  rationale=$(echo "$finding" | grep -o '"rationale":"[^"]*"' | cut -d'"' -f4)
  fix=$(echo "$finding" | grep -o '"suggested_fix":"[^"]*"' | cut -d'"' -f4)

  # Map severity to GitHub annotation level
  case "$severity" in
    critical) level="error" ;;
    warning)  level="warning" ;;
    *)        level="notice" ;;
  esac

  echo "::${level} file=${file},line=${line},title=${rule}::${rationale}. Fix: ${fix}"
done < "$FINDINGS_FILE"

# Write step summary
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### Lint Check: %s\n\n' "$VERDICT"
    printf '| Severity | Count |\n|---|---|\n'
    printf '| Critical | %d |\n' "$CRITICAL"
    printf '| Warning | %d |\n' "$WARNING"
    printf '| Suggestion | %d |\n\n' "$SUGGESTION"

    if [ "$CRITICAL" -gt 0 ] || [ "$WARNING" -gt 0 ]; then
      printf '#### Findings\n\n'
      printf '| Rule | File | Line | Severity | Issue |\n|---|---|---|---|---|\n'
      while IFS= read -r finding; do
        file=$(echo "$finding" | grep -o '"file":"[^"]*"' | cut -d'"' -f4)
        line=$(echo "$finding" | grep -o '"line":[0-9]*' | cut -d: -f2)
        severity=$(echo "$finding" | grep -o '"severity":"[^"]*"' | cut -d'"' -f4)
        rule=$(echo "$finding" | grep -o '"rule":"[^"]*"' | cut -d'"' -f4)
        rationale=$(echo "$finding" | grep -o '"rationale":"[^"]*"' | cut -d'"' -f4)
        printf '| %s | `%s` | %s | %s | %s |\n' "$rule" "$file" "$line" "$severity" "$rationale"
      done < "$FINDINGS_FILE"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

# Exit with failure if critical findings
if [ "$CRITICAL" -gt 0 ]; then
  printf 'FAIL: %d critical finding(s)\n' "$CRITICAL" >&2
  exit 1
fi

printf 'PASS: %d warning(s), %d suggestion(s)\n' "$WARNING" "$SUGGESTION"
exit 0
