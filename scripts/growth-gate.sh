#!/usr/bin/env bash
set -euo pipefail

# growth-gate.sh — relative-growth check for machine-proposed text rewrites.
#
# Absolute budgets (line caps, description budgets) catch a file that got too
# big; nothing catches a file that gets 5% bigger on every suggest-only pass
# (lesson-refresh, claude-md-capture, promote-lesson) until the absolute cap
# finally trips. This gate refuses a proposed rewrite that grows the artifact
# by more than --max-pct relative to the current version — always-loaded
# context should stay flat, not ratchet.
#
# A brand-new file (no old version) passes: growth-from-nothing is creation,
# not a ratchet. Shrinking always passes (shrink-guard covers the other
# direction). Exit 0 = within budget, exit 1 = growth exceeded, exit 2 = usage.
#
# Usage: bash scripts/growth-gate.sh <current-file> <proposed-file> [--max-pct N]

MAX_PCT=15
OLD=""
NEW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --max-pct) MAX_PCT="${2:?--max-pct needs a value}"; shift 2 ;;
    -*) echo "growth-gate: unknown flag $1" >&2; exit 2 ;;
    *) if [ -z "$OLD" ]; then OLD="$1"; elif [ -z "$NEW" ]; then NEW="$1"; else exit 2; fi; shift ;;
  esac
done
[ -n "$OLD" ] && [ -n "$NEW" ] || { echo "Usage: growth-gate.sh <current-file> <proposed-file> [--max-pct N]" >&2; exit 2; }
[ -f "$NEW" ] || { echo "growth-gate: proposed file not found: $NEW" >&2; exit 2; }

if [ ! -f "$OLD" ] || [ ! -s "$OLD" ]; then
  echo "growth-gate: no current version — creation, not growth. PASS."
  exit 0
fi

old_bytes=$(wc -c < "$OLD" | tr -d ' ')
new_bytes=$(wc -c < "$NEW" | tr -d ' ')

if [ "$new_bytes" -le "$old_bytes" ]; then
  echo "growth-gate: ${old_bytes} -> ${new_bytes} bytes (no growth). PASS."
  exit 0
fi

growth_pct=$(( (new_bytes - old_bytes) * 100 / old_bytes ))
if [ "$growth_pct" -gt "$MAX_PCT" ]; then
  echo "growth-gate: REFUSED — ${old_bytes} -> ${new_bytes} bytes (+${growth_pct}%, budget ${MAX_PCT}%)." >&2
  echo "  A rewrite that grows the artifact this much should supersede content, not append to it." >&2
  echo "  Tighten the proposal, or raise deliberately with --max-pct." >&2
  exit 1
fi
echo "growth-gate: ${old_bytes} -> ${new_bytes} bytes (+${growth_pct}%, budget ${MAX_PCT}%). PASS."
exit 0
