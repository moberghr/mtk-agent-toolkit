#!/usr/bin/env bash
set -euo pipefail

# constitution-digest.sh — Emit the project "constitution" as a compact, citable list.
#
# Constitution pattern: make the project's governing rules an explicit *cited*
# input to the spec and plan phases rather than ambient context. The spec's
# Constitution Check section and each plan
# batch's `Governing constraints:` line cite ids from this digest.
#
# Sources (all project-relative, per MTK file resolution):
#   - CLAUDE.md Critical Rules        (lines like "- **C0.1** ...")
#   - .claude/references/architecture-principles.md tagged principles
#                                     ([EXTRACTED] / [INFERRED:x] / [AMBIGUOUS])
#
# Degrades gracefully: missing principles file → Critical Rules only.
# Read-only. Never edits CLAUDE.md (C0.7).
#
# Usage:
#   bash scripts/constitution-digest.sh            # human-readable digest
#   bash scripts/constitution-digest.sh --quiet    # ids + one-line only (for prompts)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

CLAUDE_MD="CLAUDE.md"
PRINCIPLES=".claude/references/architecture-principles.md"

crit_count=0
prin_count=0

emit_section() { [ "$QUIET" -eq 1 ] || echo "$1"; }

emit_section "# Constitution Digest"
emit_section ""
emit_section "Cite these ids in the spec Constitution Check and each plan batch's"
emit_section "\`Governing constraints:\` line. This is the authoritative governing set."
emit_section ""

# --- Critical Rules from CLAUDE.md ---
if [ -f "$CLAUDE_MD" ]; then
  emit_section "## Critical Rules (CLAUDE.md)"
  while IFS= read -r line; do
    crit_count=$((crit_count + 1))
    # Collapse to a single trimmed line.
    echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]+/ /g'
  done < <(grep -E '^\s*-\s*\*\*C[0-9]' "$CLAUDE_MD" || true)
  emit_section ""
fi

# --- Tagged architecture principles ---
if [ -f "$PRINCIPLES" ]; then
  emit_section "## Architecture Principles (tagged)"
  while IFS= read -r line; do
    prin_count=$((prin_count + 1))
    echo "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]+/ /g'
  done < <(grep -E '\[(EXTRACTED|INFERRED:[0-9.]+|AMBIGUOUS)\]' "$PRINCIPLES" || true)
  emit_section ""
else
  emit_section "_(architecture-principles.md absent — Critical Rules only. Run \`/mtk-setup --audit\` to generate principles.)_"
  emit_section ""
fi

emit_section "Totals: ${crit_count} Critical Rules, ${prin_count} tagged principles."

# Non-zero exit only if NOTHING was found (no constitution to cite).
if [ "$crit_count" -eq 0 ] && [ "$prin_count" -eq 0 ]; then
  echo "ERROR: no Critical Rules or principles found — is this an MTK-bootstrapped repo?" >&2
  exit 1
fi
