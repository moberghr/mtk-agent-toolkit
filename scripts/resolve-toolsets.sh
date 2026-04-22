#!/usr/bin/env bash
# Resolve one or more toolset names into a flat, deduplicated allowed-tools list.
# Usage: scripts/resolve-toolsets.sh read-only git-safe
# Output: one tool spec per line (Read, Edit, Bash(git diff:*), ...)
# Exits non-zero if a toolset is missing or the extends graph has a cycle.
#
# Bash 3.2-compatible (macOS default): no associative arrays.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOLSET_DIR="$ROOT_DIR/.claude/toolsets"

[ -d "$TOOLSET_DIR" ] || { printf 'ERROR: %s missing\n' "$TOOLSET_DIR" >&2; exit 1; }

VISITED=""

resolve_one() {
  local name="$1"
  local depth="${2:-0}"
  [ "$depth" -lt 16 ] || { printf 'ERROR: toolset extends cycle or too deep at %s\n' "$name" >&2; exit 1; }

  case " $VISITED " in
    *" $name "*) return 0 ;;
  esac
  VISITED="$VISITED $name"

  local file="$TOOLSET_DIR/$name.yaml"
  [ -f "$file" ] || { printf 'ERROR: unknown toolset: %s (no %s)\n' "$name" "$file" >&2; exit 1; }

  local parent
  parent="$(grep -E '^extends:' "$file" | sed -E 's/^extends:[[:space:]]*//; s/[[:space:]]+$//' || true)"
  if [ -n "$parent" ]; then
    resolve_one "$parent" $((depth + 1))
  fi

  awk '
    /^tools:[[:space:]]*$/ { in_tools=1; next }
    in_tools && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      sub(/[[:space:]]+$/, "")
      print
      next
    }
    in_tools && /^[^[:space:]-]/ { in_tools=0 }
  ' "$file"
}

if [ "$#" -eq 0 ]; then
  printf 'Usage: %s <toolset-name> [<toolset-name>...]\n' "$0" >&2
  exit 2
fi

{
  for ts in "$@"; do
    resolve_one "$ts"
  done
} | awk 'NF && !seen[$0]++'
