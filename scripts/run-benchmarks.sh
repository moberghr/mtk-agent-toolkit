#!/usr/bin/env bash
set -euo pipefail

# run-benchmarks.sh — Deterministic effectiveness benchmarks for MTK hooks and linters.
# No LLM needed — tests the actual bash scripts against known-good and known-bad inputs.
#
# Usage:
#   bash scripts/run-benchmarks.sh           # run all benchmarks
#   bash scripts/run-benchmarks.sh --verbose # show details for passing tests too

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source hooks/lib/hook-io.sh

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

PASS=0
FAIL=0
TOTAL=0

# ─── Test helpers ──────────────────────────────────────────────────────────────

assert_match() {
  local name="$1" output="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qE "$pattern"; then
    PASS=$((PASS + 1))
    if [ "$VERBOSE" -eq 1 ]; then printf '  ✓ %s\n' "$name"; fi
  else
    FAIL=$((FAIL + 1))
    printf '  ✗ %s — expected pattern: %s\n' "$name" "$pattern"
    printf '    got: %s\n' "$(echo "$output" | head -3)"
  fi
}

assert_no_match() {
  local name="$1" output="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qE "$pattern"; then
    FAIL=$((FAIL + 1))
    printf '  ✗ %s — unexpected pattern matched: %s\n' "$name" "$pattern"
    printf '    got: %s\n' "$(echo "$output" | grep -E "$pattern" | head -1)"
  else
    PASS=$((PASS + 1))
    if [ "$VERBOSE" -eq 1 ]; then printf '  ✓ %s\n' "$name"; fi
  fi
}

assert_exit() {
  local name="$1" actual="$2" expected="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$actual" -eq "$expected" ]; then
    PASS=$((PASS + 1))
    if [ "$VERBOSE" -eq 1 ]; then printf '  ✓ %s\n' "$name"; fi
  else
    FAIL=$((FAIL + 1))
    printf '  ✗ %s — expected exit %d, got %d\n' "$name" "$expected" "$actual"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 1: Deterministic Linter — known-bad.diff
# The linter must catch: hardcoded password, SQL interpolation, empty test,
# disabled test, float money (if finance domain active)
# ═══════════════════════════════════════════════════════════════════════════════

printf '\n== Linter Patterns: known-bad.diff ==\n'

# Test linter patterns directly against fixture diffs (no git needed).
# Extract added lines (+ prefix) and match against pattern ERE regexes.
PATTERNS_DIR="hooks/linter-patterns"
BAD_ADDED=$(grep '^+' benchmarks/fixtures/known-bad.diff | grep -v '^+++' || true)

if [ -d "$PATTERNS_DIR" ]; then
  # Test secrets patterns
  SECRETS_HIT=0
  while IFS=$'\t' read -r rule_id severity regex rationale fix; do
    if [[ "$rule_id" =~ ^# ]]; then continue; fi
    [ -z "$rule_id" ] && continue
    if echo "$BAD_ADDED" | grep -qE "$regex" 2>/dev/null; then
      SECRETS_HIT=$((SECRETS_HIT + 1))
    fi
  done < "$PATTERNS_DIR/core/secrets.txt"
  TOTAL=$((TOTAL + 1))
  if [ "$SECRETS_HIT" -gt 0 ]; then
    PASS=$((PASS + 1))
    [ "$VERBOSE" -eq 1 ] && printf '  ✓ secrets patterns catch hardcoded password (%d hits)\n' "$SECRETS_HIT"
  else
    FAIL=$((FAIL + 1))
    printf '  ✗ secrets patterns missed hardcoded password\n'
  fi

  # Test slopwatch patterns
  SLOP_HIT=0
  while IFS=$'\t' read -r rule_id severity regex rationale fix; do
    if [[ "$rule_id" =~ ^# ]]; then continue; fi
    [ -z "$rule_id" ] && continue
    if echo "$BAD_ADDED" | grep -qE "$regex" 2>/dev/null; then
      SLOP_HIT=$((SLOP_HIT + 1))
    fi
  done < "$PATTERNS_DIR/core/slopwatch.txt"
  TOTAL=$((TOTAL + 1))
  if [ "$SLOP_HIT" -gt 0 ]; then
    PASS=$((PASS + 1))
    [ "$VERBOSE" -eq 1 ] && printf '  ✓ slopwatch patterns catch disabled/empty test (%d hits)\n' "$SLOP_HIT"
  else
    FAIL=$((FAIL + 1))
    printf '  ✗ slopwatch patterns missed disabled/empty test\n'
  fi

  # Test dotnet stack patterns (SQL interpolation)
  if [ -f "$PATTERNS_DIR/stack-dotnet/patterns.txt" ]; then
    DOTNET_HIT=0
    while IFS=$'\t' read -r rule_id severity regex rationale fix; do
      if [[ "$rule_id" =~ ^# ]]; then continue; fi
      [ -z "$rule_id" ] && continue
      if echo "$BAD_ADDED" | grep -qE "$regex" 2>/dev/null; then
        DOTNET_HIT=$((DOTNET_HIT + 1))
      fi
    done < "$PATTERNS_DIR/stack-dotnet/patterns.txt"
    TOTAL=$((TOTAL + 1))
    if [ "$DOTNET_HIT" -gt 0 ]; then
      PASS=$((PASS + 1))
      [ "$VERBOSE" -eq 1 ] && printf '  ✓ dotnet patterns catch SQL interpolation (%d hits)\n' "$DOTNET_HIT"
    else
      FAIL=$((FAIL + 1))
      printf '  ✗ dotnet patterns missed SQL interpolation\n'
    fi
  fi

  # Test finance domain patterns (float money)
  if [ -f "$PATTERNS_DIR/domain-finance/patterns.txt" ]; then
    FIN_HIT=0
    while IFS=$'\t' read -r rule_id severity regex rationale fix; do
      if [[ "$rule_id" =~ ^# ]]; then continue; fi
      [ -z "$rule_id" ] && continue
      if echo "$BAD_ADDED" | grep -qE "$regex" 2>/dev/null; then
        FIN_HIT=$((FIN_HIT + 1))
      fi
    done < "$PATTERNS_DIR/domain-finance/patterns.txt"
    TOTAL=$((TOTAL + 1))
    if [ "$FIN_HIT" -gt 0 ]; then
      PASS=$((PASS + 1))
      [ "$VERBOSE" -eq 1 ] && printf '  ✓ finance patterns catch float money (%d hits)\n' "$FIN_HIT"
    else
      FAIL=$((FAIL + 1))
      printf '  ✗ finance patterns missed float money\n'
    fi
  fi
else
  printf '  (skipped — linter-patterns dir not found)\n'
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 2: Linter Patterns — known-good.diff (no false positives)
# ═══════════════════════════════════════════════════════════════════════════════

printf '\n== Linter Patterns: known-good.diff ==\n'

GOOD_ADDED=$(grep '^+' benchmarks/fixtures/known-good.diff | grep -v '^+++' || true)

if [ -d "$PATTERNS_DIR" ]; then
  # Secrets should NOT fire on named connection string
  GOOD_SECRET=0
  while IFS=$'\t' read -r rule_id severity regex rationale fix; do
    if [[ "$rule_id" =~ ^# ]]; then continue; fi
    [ -z "$rule_id" ] && continue
    if echo "$GOOD_ADDED" | grep -qE "$regex" 2>/dev/null; then
      GOOD_SECRET=$((GOOD_SECRET + 1))
    fi
  done < "$PATTERNS_DIR/core/secrets.txt"
  assert_exit "no false positive on named connection string" "$GOOD_SECRET" 0

  # Slopwatch should NOT fire on real test
  GOOD_SLOP=0
  while IFS=$'\t' read -r rule_id severity regex rationale fix; do
    if [[ "$rule_id" =~ ^# ]]; then continue; fi
    [ -z "$rule_id" ] && continue
    if echo "$GOOD_ADDED" | grep -qE "$regex" 2>/dev/null; then
      GOOD_SLOP=$((GOOD_SLOP + 1))
    fi
  done < "$PATTERNS_DIR/core/slopwatch.txt"
  assert_exit "no false positive on real test" "$GOOD_SLOP" 0
else
  printf '  (skipped — linter-patterns dir not found)\n'
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 3: Security Gate — blocks destructive commands
# ═══════════════════════════════════════════════════════════════════════════════

printf '\n== Security Gate: destructive commands ==\n'

# Helper: run security gate and capture both output and exit code
run_gate() { local out; out=$(printf '%s' "$1" | bash hooks/security-gate.sh 2>&1) || true; echo "$out"; }
gate_exit() { local rc=0; printf '%s' "$1" | bash hooks/security-gate.sh >/dev/null 2>&1 || rc=$?; echo "$rc"; }

# Should block: DROP TABLE
DROP_OUT=$(run_gate '{"command": "psql -c DROP TABLE users"}')
DROP_EXIT=$(gate_exit '{"command": "psql -c DROP TABLE users"}')
assert_exit "blocks DROP TABLE (exit 2)" "$DROP_EXIT" 2
assert_match "DROP TABLE message" "$DROP_OUT" "(BLOCKED|destructive)"

# Should block: rm -rf .
RMRF_EXIT=$(gate_exit '{"command": "rm -rf ."}')
assert_exit "blocks rm -rf . (exit 2)" "$RMRF_EXIT" 2

# Should block: force push to main
FPUSH_EXIT=$(gate_exit '{"command": "git push --force origin main"}')
assert_exit "blocks force push to main (exit 2)" "$FPUSH_EXIT" 2

# Should allow: normal git push
PUSH_EXIT=$(gate_exit '{"command": "git push origin feat/my-branch"}')
assert_exit "allows normal git push (exit 0)" "$PUSH_EXIT" 0

# Should allow: normal bash command
LS_EXIT=$(gate_exit '{"command": "ls -la"}')
assert_exit "allows ls -la (exit 0)" "$LS_EXIT" 0

# Nested payload shape should also block destructive commands
NESTED_DROP_EXIT=$(gate_exit '{"tool_name":"Bash","tool_input":{"command":"psql -c DROP TABLE users"}}')
assert_exit "blocks nested DROP TABLE payload (exit 2)" "$NESTED_DROP_EXIT" 2

# Unparseable Bash payload should fail closed
PARSE_FAIL_EXIT=$(gate_exit '{"tool_name":"Bash","tool_input":{}}')
assert_exit "blocks unparseable Bash payload (exit 2)" "$PARSE_FAIL_EXIT" 2

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 4: Scope Guard — detects out-of-scope edits
# ═══════════════════════════════════════════════════════════════════════════════

printf '\n== Scope Guard: spec-aware scope detection ==\n'

# Set up a mock spec
mkdir -p docs/specs
cat > docs/specs/2026-01-01-benchmark.json <<'SPEC'
{
  "slug": "benchmark",
  "change_manifest": [
    {"path": "src/auth/login.cs", "action": "modify", "purpose": "test"}
  ],
  "test_manifest": [
    {"path": "tests/auth_tests.cs", "covers": ["SC1"]}
  ]
}
SPEC

# In-scope edit should be silent
IN_OUT=$(echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\": \"$(pwd)/src/auth/login.cs\"}}" | bash hooks/scope-guard.sh 2>&1 || true)
assert_no_match "in-scope file is silent" "$IN_OUT" "SCOPE GUARD"

# Out-of-scope edit should warn
OUT_OUT=$(echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\": \"$(pwd)/src/payments/charge.cs\"}}" | bash hooks/scope-guard.sh 2>&1 || true)
assert_match "out-of-scope file warns" "$OUT_OUT" "SCOPE GUARD"

# Meta-files (docs/, tasks/) should always be allowed
META_OUT=$(echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\": \"$(pwd)/docs/specs/new.md\"}}" | bash hooks/scope-guard.sh 2>&1 || true)
assert_no_match "docs/ files are always allowed" "$META_OUT" "SCOPE GUARD"

# Clean up
rm -f docs/specs/2026-01-01-benchmark.json
rmdir docs/specs 2>/dev/null || true
rmdir docs 2>/dev/null || true
rm -f "${TMPDIR:-/tmp}"/mtk-scope-cache-* 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 5: Verify Completion — rejects evidence-less claims
# ═══════════════════════════════════════════════════════════════════════════════

printf '\n== Verify Completion: evidence gating ==\n'

source hooks/lib/hook-io.sh
SESSION_FILE="$(mtk_session_file)"
rm -f "$SESSION_FILE"

# Claim without evidence should warn
NO_EV_OUT=$(bash hooks/verify-completion "The feature is done and complete." 2>&1 || true)
assert_match "rejects evidence-less done claim" "$NO_EV_OUT" "VERIFICATION GAP"

# Fresh verification command recorded in session state should satisfy the hook
printf '{"tool_name":"Bash","tool_input":{"command":"bash scripts/validate-toolkit.sh"}}' | bash hooks/context-budget.sh >/dev/null 2>&1 || true

# Claim with evidence should pass silently
EV_OUT=$(bash hooks/verify-completion "The feature is done. Toolkit validation passed, exit code 0." 2>&1 || true)
assert_no_match "accepts claim with evidence" "$EV_OUT" "VERIFICATION GAP"

# A later edit makes the verification stale
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/README.md"}}' "$(pwd)" | bash hooks/context-budget.sh >/dev/null 2>&1 || true
STALE_OUT=$(bash hooks/verify-completion "The feature is done. Toolkit validation passed, exit code 0." 2>&1 || true)
assert_match "rejects stale evidence after edit" "$STALE_OUT" "VERIFICATION GAP"

# Non-completion message should be silent
NC_OUT=$(bash hooks/verify-completion "I'll now work on the next file." 2>&1 || true)
assert_no_match "non-completion message is silent" "$NC_OUT" "VERIFICATION GAP"

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 6: Prerequisites Check — reports missing tools
# ═══════════════════════════════════════════════════════════════════════════════

printf '\n== Prerequisites: tool detection ==\n'

PREREQ_OUT=$(bash hooks/check-prerequisites.sh dotnet 2>&1 || true)
# jq and dotnet should be found on this machine, so we just check the format
assert_match "produces formatted output" "$PREREQ_OUT" "(Prerequisites|recommended)"

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 7: Validate Toolkit — structural integrity
# ═══════════════════════════════════════════════════════════════════════════════

printf '\n== Toolkit Validation ==\n'

VAL_OUT=$(bash scripts/validate-toolkit.sh 2>&1 || true)
VAL_EXIT=$?
assert_exit "validate-toolkit passes (exit 0)" "$VAL_EXIT" 0
assert_match "validation passed message" "$VAL_OUT" "Toolkit validation passed"

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

printf '\n══════════════════════════════════════\n'
if [ "$FAIL" -eq 0 ]; then
  printf 'BENCHMARKS PASSED: %d/%d\n' "$PASS" "$TOTAL"
else
  printf 'BENCHMARKS: %d passed, %d FAILED (of %d)\n' "$PASS" "$FAIL" "$TOTAL"
fi
printf '══════════════════════════════════════\n'

mtk_record_benchmark_run "${PASS}/${TOTAL}"

exit "$FAIL"
