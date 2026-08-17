#!/usr/bin/env bash
set -euo pipefail

# Fail-safe merge guards on spec-archive.sh: a delta.removes entry that
# matches nothing refuses the archive with a near-miss suggestion; a valid
# explicit remove goes through; a refused archive leaves baseline JSON, MD,
# and audit trail byte-identical (all-or-nothing).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCHIVE="$REPO_ROOT/scripts/spec-archive.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
command -v jq >/dev/null || { echo "SKIP: jq not available"; exit 0; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
git -C "$WORK" init -q
cd "$WORK"
mkdir -p docs/specs

spec() {
  # $1 slug, $2 removes JSON array
  cat > "docs/specs/2026-08-17-$1.json" <<EOF
{
  "slug": "$1",
  "date": "2026-08-17",
  "baseline_area": "payments",
  "change_manifest": [ { "path": "src/Pay.cs", "action": "modify", "purpose": "test" } ],
  "public_contracts": [ { "signature": "IPay.Charge(int)", "kind": "method", "change": "new" } ],
  "delta": { "removes": $2 }
}
EOF
  echo "docs/specs/2026-08-17-$1.json"
}

BASE_JSON="docs/specs/baseline/payments.json"
BASE_MD="docs/specs/baseline/payments.md"
AUDIT="docs/specs/baseline/payments.audit.jsonl"

# --- 1. seed a baseline through a normal archive -----------------------------

s1="$(spec seed '[]')"
CLAUDE_PROJECT_DIR="$WORK" bash "$ARCHIVE" "$s1" >/dev/null \
  || fail "plain archive must succeed"
jq -e '.contracts["IPay.Charge(int)"]' "$BASE_JSON" >/dev/null \
  || fail "contract must land in the baseline"
printf '  PASS  plain archive seeds the baseline\n'

# --- 2. unmatched remove refuses, with a near-miss suggestion ----------------

s2="$(spec typo-remove '["ipay.charge(int)"]')"
rc=0
out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$ARCHIVE" "$s2" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "typo'd remove must exit 2 (got $rc). Out: $out"
echo "$out" | grep -q 'match nothing' || fail "refusal must explain the unmatched remove. Got: $out"
echo "$out" | grep -qF 'did you mean: IPay.Charge(int)' \
  || fail "case-folded near-miss must be suggested. Got: $out"
printf '  PASS  unmatched remove refuses with near-miss suggestion\n'

# --- 3. refused archive is all-or-nothing ------------------------------------

json_before="$(cat "$BASE_JSON")"
md_before="$(cat "$BASE_MD")"
audit_lines_before="$(wc -l < "$AUDIT" | tr -d ' ')"
s3="$(spec ghost-remove '["NoSuchKey"]')"
CLAUDE_PROJECT_DIR="$WORK" bash "$ARCHIVE" "$s3" >/dev/null 2>&1 && fail "ghost remove must refuse"
[ "$(cat "$BASE_JSON")" = "$json_before" ] || fail "refused archive must not touch baseline JSON"
[ "$(cat "$BASE_MD")" = "$md_before" ] || fail "refused archive must not touch baseline MD"
[ "$(wc -l < "$AUDIT" | tr -d ' ')" = "$audit_lines_before" ] \
  || fail "refused archive must not append an audit record"
ls docs/specs/baseline/.payments.* 2>/dev/null && fail "no temp files may survive a refusal"
printf '  PASS  refused archive leaves baseline and audit untouched\n'

# --- 4. exact explicit remove goes through -----------------------------------

s4="$(spec real-remove '["IPay.Charge(int)"]')"
CLAUDE_PROJECT_DIR="$WORK" bash "$ARCHIVE" "$s4" >/dev/null \
  || fail "exact explicit remove must archive"
jq -e '.contracts["IPay.Charge(int)"] | not' "$BASE_JSON" >/dev/null 2>&1 \
  || fail "explicitly removed contract must be gone"
grep -q 'real-remove' "$AUDIT" || fail "successful archive must append its audit record"
printf '  PASS  exact explicit remove merges and audits\n'

# --- 5. malformed sidecar refuses before touching anything --------------------

cat > docs/specs/2026-08-17-malformed.json <<'EOF'
{ "slug": "malformed", "date": "2026-08-17", "baseline_area": "payments",
  "change_manifest": "not-an-array" }
EOF
rc=0
out="$(CLAUDE_PROJECT_DIR="$WORK" bash "$ARCHIVE" docs/specs/2026-08-17-malformed.json 2>&1)" || rc=$?
[ "$rc" -eq 2 ] || fail "malformed sidecar must exit 2 (got $rc)"
echo "$out" | grep -q 'malformed' || fail "refusal must name the malformation. Got: $out"
printf '  PASS  malformed sidecar refuses with a clear message\n'

# --- 6. baseline growth advisory fires without blocking -----------------------

s6="$(spec growth '[]')"
rc=0
out="$(CLAUDE_PROJECT_DIR="$WORK" MTK_BASELINE_MAX_LINES=1 bash "$ARCHIVE" "$s6" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "growth advisory must never block the archive (got exit $rc)"
# case-match, not `echo | grep -q`: grep exiting on first match SIGPIPEs the
# echo under pipefail and fails the assertion despite the match (S3.1 lesson).
case "$out" in
  *'ADVISORY: baseline'*) : ;;
  *) fail "over-budget baseline must print the growth advisory. Got: $out" ;;
esac
printf '  PASS  baseline growth advisory fires, never blocks\n'

printf '\nAll spec-archive merge-guard checks passed.\n'
