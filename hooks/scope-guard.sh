#!/usr/bin/env bash
set -euo pipefail

# PreToolUse hook for Edit and Write tools.
# Detects scope creep by checking if the file being modified is listed in the
# active spec's change_manifest or test_manifest.
#
# Advisory only (exit 0) — prints a warning, never blocks.
# No-op when there is no active spec JSON sidecar.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/hook-io.sh"

INPUT=$(cat)

# Extract file_path from the tool input JSON
FILE_PATH=$(mtk_extract_file_path "$INPUT" 2>/dev/null || echo "")
[ -z "$FILE_PATH" ] && exit 0

# Make the path relative to the repo root for comparison
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REL_PATH="${FILE_PATH#"$REPO_ROOT"/}"

# Find the active spec JSON sidecar (most recently modified, within 7 days)
SPEC_JSON=""
if [ -d docs/specs ]; then
  SPEC_JSON=$(find docs/specs -name '*.json' -type f -mtime -7 2>/dev/null | while read -r f; do
    echo "$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0) $f"
  done | sort -rn | head -1 | cut -d' ' -f2-)
fi

# No active spec — nothing to guard
[ -z "${SPEC_JSON:-}" ] || [ ! -f "$SPEC_JSON" ] && exit 0

# Use a session cache to avoid re-parsing the spec on every tool call.
# Cache key: spec file path + mtime.
CACHE_DIR="${TMPDIR:-/tmp}"
SPEC_MTIME=$(stat -f '%m' "$SPEC_JSON" 2>/dev/null || stat -c '%Y' "$SPEC_JSON" 2>/dev/null || echo "0")
CACHE_KEY=$(printf '%s-%s' "$SPEC_JSON" "$SPEC_MTIME" | cksum | cut -d' ' -f1)
CACHE_FILE="$CACHE_DIR/mtk-scope-cache-$CACHE_KEY"

if [ -f "$CACHE_FILE" ]; then
  ALLOWED_FILES=$(cat "$CACHE_FILE")
else
  # Extract all file paths from change_manifest and test_manifest.
  # Looks for "path": "..." patterns within those sections.
  ALLOWED_FILES=$(awk '
    /"(change_manifest|test_manifest)"/ { in_section=1 }
    in_section && /\]/ { in_section=0 }
    in_section {
      if (match($0, /"path"[[:space:]]*:[[:space:]]*"([^"]+)"/, a)) {
        print a[1]
      }
    }
  ' "$SPEC_JSON" 2>/dev/null || true)

  # If awk match with groups fails (older awk), fall back to grep
  if [ -z "$ALLOWED_FILES" ]; then
    ALLOWED_FILES=$(awk '/"(change_manifest|test_manifest)"/,/\]/' "$SPEC_JSON" \
      | grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | sed 's/.*: *"//;s/"$//' 2>/dev/null || true)
  fi

  # Always allow spec/plan/task files themselves
  ALLOWED_FILES="$ALLOWED_FILES
docs/specs/
docs/plans/
tasks/
.claude/"

  # Cache for the session
  printf '%s\n' "$ALLOWED_FILES" > "$CACHE_FILE"
fi

# No manifest entries found — spec might be empty or malformed, don't warn
[ -z "$ALLOWED_FILES" ] && exit 0

# Check if the relative path matches any allowed path (prefix or exact match)
MATCHED=0
while IFS= read -r allowed; do
  [ -z "$allowed" ] && continue
  case "$REL_PATH" in
    "$allowed"*) MATCHED=1; break ;;
    *"$allowed"*) MATCHED=1; break ;;
  esac
  case "$allowed" in
    *"$REL_PATH"*) MATCHED=1; break ;;
  esac
done <<< "$ALLOWED_FILES"

if [ "$MATCHED" -eq 0 ]; then
  SPEC_NAME=$(basename "$SPEC_JSON" .json)
  mtk_record_scope_guard_warning
  echo "SCOPE GUARD: ${REL_PATH} is not in the approved spec (${SPEC_NAME}). If this change is necessary, update the spec's change_manifest first. Undeclared file modifications are the #1 source of spec drift."
fi

exit 0
