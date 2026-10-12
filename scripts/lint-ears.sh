#!/usr/bin/env bash
set -euo pipefail
# scripts/lint-ears.sh — structural lint for spec Requirements sections.
#
# Enforces:
#   1. EARS phrasing: every requirement bullet uses Ubiquitous / Event-driven /
#      State-driven / Optional / Unwanted templates.
#   2. ANT (Anti-Null-Tautology): rejects requirements that cannot be falsified.
#
# Usage:  bash scripts/lint-ears.sh <spec.md> [<spec.md> ...]
# Exit:   0 = clean, 1 = violations found, 2 = usage error.
# Scope:  only lines under "## Requirements" (and EARS subsections) are checked;
#         code blocks are skipped.

# No cd: this linter resolves the spec paths it is handed against the caller's
# CWD (the target repo). cd-ing to a script-derived root breaks repo-relative
# args when MTK runs from a separate checkout — the paths would resolve there.

[ $# -ge 1 ] || { printf 'usage: lint-ears.sh <spec.md>...\n' >&2; exit 2; }

# EARS keyword anchors. A requirement bullet must contain at least one of:
#   - "shall"        (ubiquitous, event-driven, state-driven)
#   - "should"       (acceptable variant)
#   - "may"          (optional)
#   - "shall not"    (unwanted) — already matched by "shall"
EARS_VERBS_RE='\b(shall|should|may)\b'

# EARS clause anchors (at least one required for non-Ubiquitous):
#   - "When ... the system shall ..." (event-driven)
#   - "While ... the system shall ..." (state-driven)
#   - "Where ... the system may ..." (optional)
#   - "If ... then the system shall ..." (unwanted)
# Pure ubiquitous form has no leading clause but still uses "shall".

# ANT (tautology) phrases — case-insensitive contains check.
ANT_PATTERNS=(
  "be reliable"
  "be performant"
  "be scalable"
  "be secure"
  "be robust"
  "be clean"
  "be high quality"
  "be high-quality"
  "be efficient"
  "be modern"
  "be user-friendly"
  "be intuitive"
  "be maintainable"
  "follow best practices"
  "be production[- ]ready"
  "as needed"
  "where appropriate"
  "if necessary"
)

violations=0

check_file() {
  local file="$1"
  [ -f "$file" ] || { printf 'lint-ears: missing file %s\n' "$file" >&2; exit 2; }

  local in_req=0 in_code=0 lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Track fenced code blocks
    case "$line" in
      '```'*) in_code=$((1 - in_code)); continue ;;
    esac
    [ $in_code -eq 1 ] && continue

    # Section tracking
    case "$line" in
      '## Requirements'*|'## Requirements (EARS)'*) in_req=1; continue ;;
      '## '*) in_req=0; continue ;;
    esac

    [ $in_req -eq 1 ] || continue

    # Only check bullet lines that look like requirements.
    case "$line" in
      "- "*|"* "*) : ;;
      *) continue ;;
    esac

    # Skip subsection headers presented as bold bullets (e.g., "- **Event-driven**")
    case "$line" in
      *"**"*"**"*) continue ;;
    esac

    # Skip the ANT-check meta-bullet itself (which talks ABOUT requirements)
    case "$line" in
      *"ANT"*|*"falsifiable"*|*"counter-example"*) continue ;;
    esac

    # EARS verb check
    if ! printf '%s' "$line" | grep -Eqi "$EARS_VERBS_RE"; then
      printf '%s:%d: EARS — bullet has no shall/should/may verb: %s\n' \
        "$file" "$lineno" "$line" >&2
      violations=$((violations + 1))
      continue
    fi

    # ANT tautology check
    local lower; lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    for pat in "${ANT_PATTERNS[@]}"; do
      if printf '%s' "$lower" | grep -Eq "$pat"; then
        printf '%s:%d: ANT — tautological/unfalsifiable phrasing (%s): %s\n' \
          "$file" "$lineno" "$pat" "$line" >&2
        violations=$((violations + 1))
        break
      fi
    done
  done < "$file"
}

for f in "$@"; do
  check_file "$f"
done

if [ "$violations" -gt 0 ]; then
  printf 'lint-ears: %d violation(s)\n' "$violations" >&2
  exit 1
fi

printf 'lint-ears: clean\n'
exit 0
