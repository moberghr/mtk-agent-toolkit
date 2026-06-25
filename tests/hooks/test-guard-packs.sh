#!/usr/bin/env bash
set -euo pipefail

# Test: enriched domain-finance and stack-dotnet guard packs (F7). Asserts each new
# rule matches a seeded smell and that clean code does not trip it. Same engine as
# hooks/pre-commit-linters.sh (grep -Ei).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIN="$REPO_ROOT/hooks/linter-patterns/domain-finance/patterns.txt"
DOTNET="$REPO_ROOT/hooks/linter-patterns/stack-dotnet/patterns.txt"

echo "=== Guard Packs Test (F7) ==="
[ -f "$FIN" ] && [ -f "$DOTNET" ] || { echo "  FAIL  pack file missing" >&2; exit 1; }

matches() { printf '%s' "$2" | grep -qEi -- "$1"; }
regex_for() { awk -F'\t' -v id="$1" '$1==id {print $3; exit}' "$2"; }
declare -a FAILS=()

pos() { # id packfile sample
  local re; re="$(regex_for "$1" "$2")"
  [ -n "$re" ] || { FAILS+=("$1: not found in pack"); return; }
  if matches "$re" "$3"; then echo "  PASS  $1 matches smell"; else FAILS+=("$1: did NOT match '$3'"); fi
}
neg() { # id packfile clean-sample
  local re; re="$(regex_for "$1" "$2")"
  [ -n "$re" ] || { FAILS+=("$1: not found in pack"); return; }
  if matches "$re" "$3"; then FAILS+=("$1: FALSE POSITIVE on '$3'"); else echo "  PASS  $1 clean control not matched"; fi
}

echo ""; echo "--- domain-finance ---"
pos FIN-ANON-ENDPOINT  "$FIN" '[AllowAnonymous] public IActionResult Pay() {}'
pos FIN-AUDITED-DELETE "$FIN" '_db.Transactions.Remove(tx);'
pos FIN-SENSITIVE-LOG  "$FIN" 'logger.LogInformation("iban={Iban}", iban);'
neg FIN-AUDITED-DELETE "$FIN" '_cache.Sessions.Remove(key);'
# \bpan\b must not match "Japan"/"panel"; clean log of a non-sensitive field
neg FIN-SENSITIVE-LOG  "$FIN" 'logger.LogInformation("Japan panel updated for {OrderId}", orderId);'

echo ""; echo "--- stack-dotnet ---"
pos NEW-HTTPCLIENT "$DOTNET" 'var c = new HttpClient();'
pos WEAK-HASH      "$DOTNET" 'using var h = MD5.Create();'
neg NEW-HTTPCLIENT "$DOTNET" '_factory.CreateClient("api");'
neg WEAK-HASH      "$DOTNET" 'using var h = SHA256.Create();'

echo ""
if [ ${#FAILS[@]} -gt 0 ]; then
  printf '  FAIL  %s\n' "${FAILS[@]}" >&2
  exit 1
fi
echo "========================================"
echo "TEST PASSED — all F7 guard-pack assertions green"
