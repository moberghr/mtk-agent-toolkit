#!/usr/bin/env bash
set -euo pipefail

# Test: core/docdrift.txt linter pack (F5). Asserts each rule matches a seeded
# smell and that clean documentation does not trip any rule. Uses the same engine
# as hooks/pre-commit-linters.sh (grep -Ei).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACK="$REPO_ROOT/hooks/linter-patterns/core/docdrift.txt"

echo "=== Docdrift Pack Test (F5) ==="
[ -f "$PACK" ] || { echo "  FAIL  pack not found: $PACK" >&2; exit 1; }

# Engine mirror: returns 0 if the ERE matches the content (case-insensitive).
matches() { printf '%s' "$2" | grep -qEi -- "$1"; }

# Look up a rule's regex (field 3) by RULE_ID (field 1).
regex_for() { awk -F'\t' -v id="$1" '$1==id {print $3; exit}' "$PACK"; }

declare -a FAILS=()
check_match() {
  local id="$1" sample="$2" re; re="$(regex_for "$id")"
  if [ -z "$re" ]; then FAILS+=("$id: rule not found in pack"); return; fi
  if matches "$re" "$sample"; then echo "  PASS  $id matches seeded smell"; else FAILS+=("$id: did NOT match '$sample'"); fi
}

# --- Each rule matches a representative smell ---
echo ""; echo "--- positive matches ---"
check_match DOC-ABSOLUTE-CLAIM '/// This method always returns a non-null value.'
check_match DOC-EMPTY-CREF      '/// <see cref="" />'
check_match DOC-PLACEHOLDER     '## Overview\nLorem ipsum dolor sit amet.'
check_match DOC-EMPTY-LINK      'See the [setup guide](#) for details.'
check_match DOC-OBSOLETE-NOMSG  '[Obsolete]\npublic void Old() {}'

# --- Clean documentation trips nothing ---
echo ""; echo "--- negative control (clean docs) ---"
CLEAN='/// <summary>Returns the account balance; throws InvalidOperationException when the account is closed. See <see cref="Account.Balance"/>. Replaced by [Obsolete("Use BalanceV2")]. Read the [setup guide](./docs/setup.md).</summary>'
clean_hit=""
while IFS=$'\t' read -r id _sev re _rat _fix; do
  case "$id" in \#*|"") continue ;; esac
  if matches "$re" "$CLEAN"; then clean_hit="$clean_hit $id"; fi
done < "$PACK"
if [ -n "$clean_hit" ]; then
  FAILS+=("clean docs falsely matched:$clean_hit")
else
  echo "  PASS  clean documentation matched no rule"
fi

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — all F5 docdrift assertions green"
