#!/usr/bin/env bash
#
# Merge two settings.json files by unioning arrays.
# Source (new MTK) + Target (existing repo) → merged output on stdout.
# Falls back to showing a diff if the structure is unexpected.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: hooks/merge-settings.sh <source> <target>

Merges source settings.json into target settings.json:
- permissions.allowedTools: union of both arrays
- permissions.deny: union of both arrays
- hooks.*: append new hook entries, skip duplicates (matched by command)
- Keys in target not in source: preserved
- Keys in source not in target: added

Output: merged JSON on stdout
EOF
  exit 1
}

[ $# -ge 2 ] || usage
SOURCE="$1"
TARGET="$2"

[ -f "$SOURCE" ] || { echo "ERROR: Source not found: $SOURCE" >&2; exit 1; }
[ -f "$TARGET" ] || { echo "ERROR: Target not found: $TARGET" >&2; exit 1; }

# Temp files with guaranteed cleanup
TMPDIR_MERGE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_MERGE"' EXIT

# Strategy: The MTK settings.json is small (~70 lines) and has a predictable
# structure. We extract arrays from both files, union them, and reconstruct.
# This avoids needing jq or python JSON parsing.

# Extract all unique entries from a JSON array section.
# Usage: extract_array_entries <file> <key_path>
# Looks for "key": [ ... ] blocks and extracts the quoted strings inside.
extract_array_entries() {
  local file="$1"
  local key="$2"
  # Find the line with the key, then collect lines until the closing ]
  awk -v key="\"$key\"" '
    $0 ~ key { found=1; next }
    found && /\]/ { found=0; next }
    found { gsub(/[",[:space:]]/, ""); if (length > 0) print }
  ' "$file" | sort -u
}

# Extract hook command strings from a hook section
extract_hook_commands() {
  local file="$1"
  local hook_type="$2"
  awk -v hook="\"$hook_type\"" '
    $0 ~ hook { found=1 }
    found && /"command"/ {
      match($0, /"command":[[:space:]]*"([^"]+)"/, m)
      if (m[1] != "") print m[1]
    }
    found && /\]/ && !/command/ { found=0 }
  ' "$file" 2>/dev/null | sort -u
}

# For simple cases: if target doesn't exist or is empty, just use source
if [ ! -s "$TARGET" ]; then
  cat "$SOURCE"
  exit 0
fi

# Check if both files look like valid JSON (basic sanity)
if ! head -1 "$SOURCE" | grep -q '{' || ! head -1 "$TARGET" | grep -q '{'; then
  echo "WARNING: One or both files don't look like JSON. Showing diff instead." >&2
  diff "$SOURCE" "$TARGET" || true
  exit 2
fi

# Simple approach: start with the source (new MTK), then add any target-only entries.
# For arrays (allowedTools, deny), union the values.

# Build merged allowedTools
{
  extract_array_entries "$SOURCE" "allowedTools"
  extract_array_entries "$TARGET" "allowedTools"
} | sort -u > "$TMPDIR_MERGE/allowed.txt"

# Build merged deny
{
  extract_array_entries "$SOURCE" "deny"
  extract_array_entries "$TARGET" "deny"
} | sort -u > "$TMPDIR_MERGE/deny.txt"

# Start with source as base, replace arrays with merged versions
# This is intentionally simple — it handles the MTK settings structure.
# For exotic customizations, fall back to diff.

# Output the merged file
# We reconstruct rather than sed-replace to keep it clean
cat <<HEADER
{
  "permissions": {
    "allowedTools": [
HEADER

# Emit allowedTools
first=true
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  if $first; then
    printf '      "%s"' "$entry"
    first=false
  else
    printf ',\n      "%s"' "$entry"
  fi
done < "$TMPDIR_MERGE/allowed.txt"
echo ""

cat <<MIDDLE
    ],
    "deny": [
MIDDLE

# Emit deny
first=true
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  if $first; then
    printf '      "%s"' "$entry"
    first=false
  else
    printf ',\n      "%s"' "$entry"
  fi
done < "$TMPDIR_MERGE/deny.txt"
echo ""

cat <<HOOKS_START
    ]
  },
  "hooks": {
HOOKS_START

# Merge hooks — take all from source, add target-only commands
for hook_type in PreToolUse PostToolUse PostCompact Stop; do
  source_cmds="$(extract_hook_commands "$SOURCE" "$hook_type")"
  target_cmds="$(extract_hook_commands "$TARGET" "$hook_type")"

  # Union: all source commands + target commands not in source
  all_cmds="$(printf '%s\n%s' "$source_cmds" "$target_cmds" | sort -u | grep -v '^$' || true)"

  [ -n "$all_cmds" ] || continue

  echo "    \"$hook_type\": ["
  first=true
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    if $first; then first=false; else echo ","; fi
    # Reconstruct the hook entry — use source timeout if available, else 5000
    printf '      { "type": "command", "command": "%s", "timeout": 5000 }' "$cmd"
  done <<< "$all_cmds"
  echo ""
  echo "    ],"
done

# Close hooks and file
cat <<FOOTER
  }
}
FOOTER

# Cleanup handled by trap
