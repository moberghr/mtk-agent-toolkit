#!/usr/bin/env bash
set -euo pipefail

# Behavioral diff advisory check
# Emits a warning when a recent spec exists but lacks a behavioral diff.
# Non-blocking — advisory only, per team adoption strategy.

SPECS_DIR="docs/specs"
[ -d "$SPECS_DIR" ] || exit 0

# Find specs modified in the last 24 hours
recent_spec=""
while IFS= read -r spec; do
  recent_spec="$spec"
  break
done < <(find "$SPECS_DIR" -name "*.json" -mtime -1 -type f 2>/dev/null | sort -r | head -1)

[ -n "$recent_spec" ] || exit 0

# Check if behavioral_diff exists and is non-empty in the spec JSON
if ! grep -q '"behavioral_diff"' "$recent_spec" 2>/dev/null; then
  echo "⚠ Advisory: Spec $(basename "$recent_spec") has no behavioral_diff field. Consider adding one before review — reviewers use it to verify implementation intent."
  exit 0
fi

# Check if the value is empty/null
bd_value="$(grep -o '"behavioral_diff"[[:space:]]*:[[:space:]]*"[^"]*"' "$recent_spec" 2>/dev/null || true)"
if [ -z "$bd_value" ] || echo "$bd_value" | grep -q '""'; then
  echo "⚠ Advisory: Spec $(basename "$recent_spec") has an empty behavioral_diff. Fill it in before review."
fi

exit 0
