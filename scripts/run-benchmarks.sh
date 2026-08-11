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

# ─── Per-section attribution ───────────────────────────────────────────────────
# Global PASS/FAIL alone cannot answer "which capability regressed?". Sections give
# each benchmark block its own counts so benchmarks/results.json is diagnosable.
# Parallel indexed arrays, not associative — macOS bash 3.2 has no `declare -A`.
SECTION_NAMES=()
SECTION_PASS=()
SECTION_FAIL=()
CUR_NAME=""
CUR_PASS=0
CUR_FAIL=0

_flush_section() {
  [ -z "$CUR_NAME" ] && return 0
  SECTION_NAMES+=("$CUR_NAME")
  SECTION_PASS+=("$CUR_PASS")
  SECTION_FAIL+=("$CUR_FAIL")
  CUR_NAME=""; CUR_PASS=0; CUR_FAIL=0
}

# section <name> — close the previous section, open a new one, print its header.
section() {
  _flush_section
  CUR_NAME="$1"
  printf '\n== %s ==\n' "$CUR_NAME"
}

_tally_pass() { PASS=$(( PASS + 1 )); CUR_PASS=$(( CUR_PASS + 1 )); }
_tally_fail() { FAIL=$(( FAIL + 1 )); CUR_FAIL=$(( CUR_FAIL + 1 )); }

# ─── Publish measured results ──────────────────────────────────────────────────
# Numbers nobody can read are not published numbers. benchmarks/results.json is
# committed so "MTK's guards work" is checkable without re-running anything.
# python3 (not jq) — S3.3 keeps jq off the dependency list; python3 is baseline.
#
# Installed as an EXIT trap on purpose. Under `set -e` one failing helper aborts
# the run, and the previous script then printed no summary and recorded nothing —
# a silent hole exactly where the evidence belongs. A partial run still produced
# real measurements; publish them flagged run_complete:false rather than drop them.
RESULTS_JSON="benchmarks/results.json"
RUN_COMPLETED=0

print_summary() {
  printf '\n══════════════════════════════════════\n'
  if [ "$RUN_COMPLETED" -ne 1 ]; then
    printf 'BENCHMARKS ABORTED after %d assertions (%d passed, %d failed)\n' "$TOTAL" "$PASS" "$FAIL"
  elif [ "$FAIL" -eq 0 ]; then
    printf 'BENCHMARKS PASSED: %d/%d\n' "$PASS" "$TOTAL"
  else
    printf 'BENCHMARKS: %d passed, %d FAILED (of %d)\n' "$PASS" "$FAIL" "$TOTAL"
  fi
  printf '══════════════════════════════════════\n'
}

publish_results() {
  local rc=$?
  trap - EXIT
  _flush_section
  print_summary
  {
    printf '%s\n%s\n%s\n%s\n' "$PASS" "$FAIL" "$TOTAL" "$RUN_COMPLETED"
    printf '%s\n' "${#SECTION_NAMES[@]}"
    local i=0
    while [ "$i" -lt "${#SECTION_NAMES[@]}" ]; do
      printf '%s\n%s\n%s\n' "${SECTION_NAMES[$i]}" "${SECTION_PASS[$i]}" "${SECTION_FAIL[$i]}"
      i=$((i + 1))
    done
  } | RESULTS_JSON="$RESULTS_JSON" python3 -c '
import json, os, subprocess, sys

lines = sys.stdin.read().splitlines()
p, f, t, complete = (int(lines[i]) for i in range(4))
n = int(lines[4])
sections, k = [], 5
for _ in range(n):
    sections.append({"name": lines[k], "passed": int(lines[k+1]), "failed": int(lines[k+2])})
    k += 3

def sh(*cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return None

# Section counts must reconcile with the totals, or the published number is a lie.
assert sum(s["passed"] for s in sections) == p, "section pass counts do not sum to total"
assert sum(s["failed"] for s in sections) == f, "section fail counts do not sum to total"

json.dump({
    "schema": "mtk.benchmarks.v1",
    "generated_at": sh("date", "-u", "+%Y-%m-%dT%H:%M:%SZ"),
    "commit": sh("git", "rev-parse", "--short", "HEAD"),
    "toolkit_version": json.load(open(".claude/manifest.json")).get("version"),
    "runner": "scripts/run-benchmarks.sh",
    "run_complete": bool(complete),
    "totals": {"passed": p, "failed": f, "total": t},
    "sections": sections,
    "measures":
        "Deterministic behaviour of MTK bash hooks, linter pattern packs, and the "
        "structural validator, executed against fixed in-repo fixtures. Every assertion "
        "is a real process invocation with a checked exit code or matched output — no "
        "LLM is involved in producing or grading these numbers.",
    "excludes": [
        "Model behaviour: whether an agent actually follows a skill is NOT measured here (see evals/).",
        "Cross-model coverage: results reflect one bash environment, not model-version differences.",
        "Real-world hit rate: linter sections measure pattern behaviour on curated known-good/known-bad fixtures, not prevalence in production diffs.",
        "False-negative rate: fixtures prove the patterns fire on seeded cases; they do not bound what the patterns miss.",
        "Timing and cost: no wall-clock or token measurements are collected.",
        "Environment coverage: one run on one host. run_complete:false means the run aborted early and the counts are partial.",
    ],
}, open(os.environ["RESULTS_JSON"], "w"), indent=2, sort_keys=False)
open(os.environ["RESULTS_JSON"], "a").write("\n")
' || printf 'WARN: results.json not written (python3 missing or totals failed to reconcile)\n' >&2

  [ -f "$RESULTS_JSON" ] && printf 'Published: %s (%d sections, run_complete=%d)\n' \
    "$RESULTS_JSON" "${#SECTION_NAMES[@]}" "$RUN_COMPLETED"

  mtk_record_benchmark_run "${PASS}/${TOTAL}" || true

  [ "$RUN_COMPLETED" -eq 1 ] && exit "$FAIL"
  exit "$rc"
}
trap publish_results EXIT


# ─── Test helpers ──────────────────────────────────────────────────────────────

assert_match() {
  local name="$1" output="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qE "$pattern"; then
    _tally_pass
    if [ "$VERBOSE" -eq 1 ]; then printf '  ✓ %s\n' "$name"; fi
  else
    _tally_fail
    printf '  ✗ %s — expected pattern: %s\n' "$name" "$pattern"
    printf '    got: %s\n' "$(echo "$output" | head -3)"
  fi
}

assert_no_match() {
  local name="$1" output="$2" pattern="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | grep -qE "$pattern"; then
    _tally_fail
    printf '  ✗ %s — unexpected pattern matched: %s\n' "$name" "$pattern"
    printf '    got: %s\n' "$(echo "$output" | grep -E "$pattern" | head -1)"
  else
    _tally_pass
    if [ "$VERBOSE" -eq 1 ]; then printf '  ✓ %s\n' "$name"; fi
  fi
}

assert_exit() {
  local name="$1" actual="$2" expected="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$actual" -eq "$expected" ]; then
    _tally_pass
    if [ "$VERBOSE" -eq 1 ]; then printf '  ✓ %s\n' "$name"; fi
  else
    _tally_fail
    printf '  ✗ %s — expected exit %d, got %d\n' "$name" "$expected" "$actual"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 1: Deterministic Linter — known-bad.diff
# The linter must catch: hardcoded password, SQL interpolation, empty test,
# disabled test, float money (if finance domain active)
# ═══════════════════════════════════════════════════════════════════════════════

section "Linter Patterns: known-bad.diff"

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
    _tally_pass
    [ "$VERBOSE" -eq 1 ] && printf '  ✓ secrets patterns catch hardcoded password (%d hits)\n' "$SECRETS_HIT"
  else
    _tally_fail
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
    _tally_pass
    [ "$VERBOSE" -eq 1 ] && printf '  ✓ slopwatch patterns catch disabled/empty test (%d hits)\n' "$SLOP_HIT"
  else
    _tally_fail
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
      _tally_pass
      [ "$VERBOSE" -eq 1 ] && printf '  ✓ dotnet patterns catch SQL interpolation (%d hits)\n' "$DOTNET_HIT"
    else
      _tally_fail
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
      _tally_pass
      [ "$VERBOSE" -eq 1 ] && printf '  ✓ finance patterns catch float money (%d hits)\n' "$FIN_HIT"
    else
      _tally_fail
      printf '  ✗ finance patterns missed float money\n'
    fi
  fi
else
  printf '  (skipped — linter-patterns dir not found)\n'
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 2: Linter Patterns — known-good.diff (no false positives)
# ═══════════════════════════════════════════════════════════════════════════════

section "Linter Patterns: known-good.diff"

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
# BENCHMARK 3: Rule Trigger — just-in-time rule delivery
# Deliberately placed early: later sections can abort the run, and a regression
# test that never executes is not a regression test.
# ═══════════════════════════════════════════════════════════════════════════════

section "Rule Trigger: just-in-time delivery"

RT_INDEX=".claude/rules/triggers.index"
RT_BAK="${TMPDIR:-/tmp}/mtk-bench-triggers.bak"
RT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

rt() { printf '%s' "$1" | bash hooks/rule-trigger.sh 2>&1 || true; }
rt_exit() { local rc=0; printf '%s' "$1" | bash hooks/rule-trigger.sh >/dev/null 2>&1 || rc=$?; echo "$rc"; }

if [ -f "$RT_INDEX" ]; then
  cp "$RT_INDEX" "$RT_BAK"

  # A Bash command matching a rule's pattern delivers that rule.
  RT_HIT=$(rt '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}')
  assert_match "matching Bash command delivers a rule" "$RT_HIT" "rule: git-workflow"

  # A non-matching command delivers nothing.
  RT_MISS=$(rt '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')
  assert_no_match "non-matching command is silent" "$RT_MISS" "rule:"

  # Path-scoped rules match on the repo-relative path.
  RT_PATH=$(rt "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/hooks/x.sh"}}' "$RT_ROOT")")
  assert_match "path-scoped rule matches hooks/" "$RT_PATH" "rule: hooks-and-scripts"

  RT_NOPATH=$(rt "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/README.md"}}' "$RT_ROOT")")
  assert_no_match "unrelated path is silent" "$RT_NOPATH" "rule:"

  # Lowercase repo root (macOS case-insensitive FS) must still match — the prefix
  # strip silently failing here would make every path rule a no-op.
  RT_CASE=$(rt "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/hooks/x.sh"}}' \
    "$(printf '%s' "$RT_ROOT" | tr '[:upper:]' '[:lower:]')")")
  assert_match "case-differing repo root still matches" "$RT_CASE" "rule: hooks-and-scripts"

  # Fail-open: a corrupt index must never block a tool call.
  printf 'garbage\tnot\ttabs\n' > "$RT_INDEX"
  assert_exit "corrupt index fails open (exit 0)" \
    "$(rt_exit '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}')" 0

  # Fail-open: a missing index must never block a tool call.
  rm -f "$RT_INDEX"
  assert_exit "missing index fails open (exit 0)" \
    "$(rt_exit '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}')" 0

  cp "$RT_BAK" "$RT_INDEX"
  rm -f "$RT_BAK"
else
  printf '  (skipped — %s not generated; run scripts/build-rule-index.sh)\n' "$RT_INDEX"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 4: Security Gate — blocks destructive commands
# ═══════════════════════════════════════════════════════════════════════════════

section "Security Gate: destructive commands"

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

# Destructive command hidden behind JSON-escaped quotes — previous regex parser
# truncated at the first \" and let this slip past.
ESCAPED_DROP_EXIT=$(gate_exit '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"msg\" && psql -c DROP TABLE users"}}')
assert_exit "blocks DROP TABLE after escaped quotes (exit 2)" "$ESCAPED_DROP_EXIT" 2

ESCAPED_RMRF_EXIT=$(gate_exit '{"tool_name":"Bash","tool_input":{"command":"echo \"hi\" && rm -rf /"}}')
assert_exit "blocks rm -rf / after escaped quotes (exit 2)" "$ESCAPED_RMRF_EXIT" 2

# Benign command with escaped quotes must still be allowed (no over-blocking)
ESCAPED_ECHO_EXIT=$(gate_exit '{"tool_name":"Bash","tool_input":{"command":"echo \"hello world\""}}')
assert_exit "allows benign echo with escaped quotes (exit 0)" "$ESCAPED_ECHO_EXIT" 0

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 4: Scope Guard — detects out-of-scope edits
# ═══════════════════════════════════════════════════════════════════════════════

section "Scope Guard: spec-aware scope detection"

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

section "Verify Completion: evidence gating"

source hooks/lib/hook-io.sh
SESSION_FILE="$(mtk_session_file)"
rm -f "$SESSION_FILE"

# verify-completion reads the Stop event from stdin and derives the claim from
# the transcript's last assistant message (there is no argv substitution for
# hooks). Wrap that contract: write a one-message transcript, then pipe a Stop
# payload pointing at it. A gap is emitted as a decision:block whose `reason`
# still contains "VERIFICATION GAP", so the assertions below are unchanged.
vc() {
  local msg="$1" tr pl
  tr="${TMPDIR:-/tmp}/mtk-bench-vc-transcript.jsonl"
  python3 - "$tr" "$msg" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({"type": "assistant", "message": {"role": "assistant",
    "content": [{"type": "text", "text": sys.argv[2]}]}}) + "\n")
PY
  pl="$(python3 - "$tr" <<'PY'
import json, sys
print(json.dumps({"hook_event_name": "Stop", "transcript_path": sys.argv[1], "stop_hook_active": False}))
PY
)"
  printf '%s' "$pl" | bash hooks/verify-completion
}

# Claim without evidence should warn
NO_EV_OUT=$(vc "All done. Task complete." 2>&1 || true)
assert_match "rejects evidence-less done claim" "$NO_EV_OUT" "VERIFICATION GAP"

# Fresh verification command recorded in session state should satisfy the hook
printf '{"tool_name":"Bash","tool_input":{"command":"bash scripts/validate-toolkit.sh"}}' | bash hooks/context-budget.sh >/dev/null 2>&1 || true

# Claim with evidence should pass silently
EV_OUT=$(vc "All done. Toolkit validation passed, exit code 0." 2>&1 || true)
assert_no_match "accepts claim with evidence" "$EV_OUT" "VERIFICATION GAP"

# A later edit makes the verification stale
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/README.md"}}' "$(pwd)" | bash hooks/context-budget.sh >/dev/null 2>&1 || true
STALE_OUT=$(vc "All done. Toolkit validation passed, exit code 0." 2>&1 || true)
assert_match "rejects stale evidence after edit" "$STALE_OUT" "VERIFICATION GAP"

# Non-completion message should be silent
NC_OUT=$(vc "I'll now work on the next file." 2>&1 || true)
assert_no_match "non-completion message is silent" "$NC_OUT" "VERIFICATION GAP"

# Descriptive phrases like "the migration is complete" must NOT trigger the
# completion-claim gate — they describe state, not task completion.
DESCR_OUT=$(vc "The migration is complete in the DB, now I'll wire up the UI." 2>&1 || true)
assert_no_match "descriptive 'is complete' phrase is silent" "$DESCR_OUT" "VERIFICATION GAP"

# Verification command behind a prefix (cd && ...) must register as verification
rm -f "$SESSION_FILE"
printf '{"tool_name":"Bash","tool_input":{"command":"cd services/api && dotnet test"}}' | bash hooks/context-budget.sh >/dev/null 2>&1 || true
PREFIX_OUT=$(vc "All done. Build succeeded, 42 tests passed, exit code 0." 2>&1 || true)
assert_no_match "accepts cd && dotnet test as verification" "$PREFIX_OUT" "VERIFICATION GAP"

# Single-quoted arg in a verification command must round-trip through session
# state without corruption (previous save wrote bare single quotes).
rm -f "$SESSION_FILE"
printf '{"tool_name":"Bash","tool_input":{"command":"pytest -k %snot slow%s -x"}}' "'" "'" | bash hooks/context-budget.sh >/dev/null 2>&1 || true
# Re-source session file in a subshell and verify the command survived.
ROUND_TRIP=$(bash -c "set -euo pipefail; . '$SESSION_FILE'; printf '%s' \"\$last_verification_command\"")
assert_match "single-quoted pytest arg survives state round-trip" "$ROUND_TRIP" "pytest -k 'not slow' -x"

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 6: Prerequisites Check — reports missing tools
# ═══════════════════════════════════════════════════════════════════════════════

section "Prerequisites: tool detection"

PREREQ_OUT=$(bash hooks/check-prerequisites.sh dotnet 2>&1 || true)
# jq and dotnet should be found on this machine, so we just check the format
assert_match "produces formatted output" "$PREREQ_OUT" "(Prerequisites|recommended)"

# ═══════════════════════════════════════════════════════════════════════════════
# BENCHMARK 7: Validate Toolkit — structural integrity
# ═══════════════════════════════════════════════════════════════════════════════

section "Toolkit Validation"

# `VAL_EXIT=$?` after `VAL_OUT=$(... || true)` read the *assignment's* status, which
# `|| true` pins to 0 — so this assertion could never fail. Capture the real exit
# code instead; a benchmark that cannot fail is worse than no benchmark, and this
# one is published in results.json.
VAL_EXIT=0
VAL_OUT=$(bash scripts/validate-toolkit.sh 2>&1) || VAL_EXIT=$?
assert_exit "validate-toolkit passes (exit 0)" "$VAL_EXIT" 0
assert_match "validation passed message" "$VAL_OUT" "Toolkit validation passed"

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

RUN_COMPLETED=1
# The EXIT trap installed at the top of this script prints the summary and writes
# benchmarks/results.json. Nothing else to do here.
