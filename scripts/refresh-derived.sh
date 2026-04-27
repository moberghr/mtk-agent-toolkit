#!/usr/bin/env bash
# refresh-derived.sh — single entry point that rebuilds derived artifacts.
#
# Usage:
#   refresh-derived.sh <reason> [<reason>...]
#
# Reasons:
#   references   rebuild .claude/references.index from frontmatter
#   manifest     run validator quick-check
#   triggers     rebuild .claude/triggers.index from skill frontmatter
#
# Output: silent on no-op; one line per rebuild on actual work.
# Exit:   0 on success or no-op; non-zero only if a requested rebuild failed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "$#" -eq 0 ]; then
  exit 0
fi

rc=0
for reason in "$@"; do
  case "$reason" in
    references)
      if bash scripts/build-references-index.sh >/dev/null 2>&1; then
        printf 'mtk-refresh: rebuilt .claude/references.index (references)\n'
      else
        printf 'mtk-refresh: FAILED to rebuild references.index\n' >&2
        rc=1
      fi
      ;;
    triggers)
      if [ -x scripts/build-triggers-index.sh ]; then
        if bash scripts/build-triggers-index.sh >/dev/null 2>&1; then
          printf 'mtk-refresh: rebuilt .claude/triggers.index (triggers)\n'
        else
          printf 'mtk-refresh: FAILED to rebuild triggers.index\n' >&2
          rc=1
        fi
      fi
      ;;
    manifest)
      if bash scripts/validate-toolkit.sh --quick >/dev/null 2>&1 || \
         bash scripts/validate-toolkit.sh >/dev/null 2>&1; then
        printf 'mtk-refresh: validated toolkit (manifest)\n'
      else
        printf 'mtk-refresh: validator failed — see scripts/validate-toolkit.sh\n' >&2
        rc=1
      fi
      ;;
    *)
      printf 'mtk-refresh: unknown reason: %s\n' "$reason" >&2
      ;;
  esac
done

exit "$rc"
