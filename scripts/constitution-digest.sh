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
#   - CLAUDE.md Critical Rules        (bullet lines opening with a bold rule id:
#                                      "- **C0.1** …", "- **§0.1** …", "- **S1.2** …",
#                                      "- **R-12** …" — any short bold token that
#                                      contains a digit. Override the shape with
#                                      MTK_RULE_ID_PATTERN=<grep -E regex> when a
#                                      project uses something else, e.g. "[RULE-7]")
#   - .claude/references/architecture-principles.md tagged principles
#                                     ([EXTRACTED] / [INFERRED:x] / [AMBIGUOUS])
#
# Degrades gracefully: missing principles file → Critical Rules only.
# Read-only. Never edits CLAUDE.md (C0.7).
#
# Usage:
#   bash scripts/constitution-digest.sh            # human-readable digest
#   bash scripts/constitution-digest.sh --quiet    # ids + one-line only (for prompts)

# Resolve the PROJECT root, not the script's own parent. This script ships in
# the plugin cache as well as in target repos; anchoring on `dirname $0` made a
# plugin-cache invocation digest the plugin's own CLAUDE.md instead of the
# project's (observed in a 2026-09 field run). Same resolution as
# build-rule-index.sh / lesson-anchors.sh: $CLAUDE_PROJECT_DIR, then the git
# top level of the cwd, then the cwd itself.
ROOT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT_DIR"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

CLAUDE_MD="CLAUDE.md"
PRINCIPLES=".claude/references/architecture-principles.md"

# Rule-id shape. The toolkit's own rules look like `- **C0.1**`, but a target
# repo owns its CLAUDE.md and may number rules any way it likes — a 2026-09 field
# run used `- **§0.1**` and got an empty digest with no hint why. Default: a bullet
# whose first token is a short bold id (≤16 chars, no spaces) containing a digit,
# which admits C0.1 / §0.1 / S1.2 / R-12 / 0.1 / ARCH-3 and rejects bold prose
# such as `**Never**` or `**Decision rule for /mtk:**`. `**2 files**` is rejected
# by the no-space rule. Projects with a non-bold scheme set MTK_RULE_ID_PATTERN.
# (Assigned in two steps: a `}` inside `${VAR:-default}` would end the expansion.)
DEFAULT_RULE_ID_PATTERN='^[[:space:]]*-[[:space:]]*\*\*[^*[:space:]]{0,15}[0-9][^*[:space:]]{0,15}\*\*'
RULE_ID_PATTERN="${MTK_RULE_ID_PATTERN:-$DEFAULT_RULE_ID_PATTERN}"

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
  done < <(grep -E "$RULE_ID_PATTERN" "$CLAUDE_MD" || true)
  # A present section with zero recognised ids is the silent-failure case: say so
  # on stderr (stdout stays the digest) and name the knob that fixes it.
  if [ "$crit_count" -eq 0 ] && grep -qiE '^##+[[:space:]]+Critical Rules' "$CLAUDE_MD"; then
    printf 'constitution-digest: CLAUDE.md has a Critical Rules section but no line matched the rule-id pattern. Number rules with a bold id (`- **C0.1** …`, `- **§0.1** …`) or set MTK_RULE_ID_PATTERN to the grep -E shape this project uses.\n' >&2
  fi
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
