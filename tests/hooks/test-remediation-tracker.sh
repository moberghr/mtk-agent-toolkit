#!/usr/bin/env bash
set -euo pipefail

# Test: workflow-artifact.sh remediation subcommand (F3 — circuit-breaker + plateau).
# Verifies the ESCALATE decision fires on the iteration cap and on score plateau,
# and CONTINUE otherwise. Isolated in a temp cwd so it never touches live .mtk state.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WF="$REPO_ROOT/scripts/workflow-artifact.sh"

echo "=== Remediation Tracker Test (F3) ==="

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

new_wf() { "$WF" init BUILD --goal "test" | tail -1; }
decision() { "$@" | tail -1; }

pass() { echo "  PASS  $1"; }
die()  { echo "  FAIL  $1" >&2; exit 1; }

# --- T1: iteration cap (default 3) ---
echo ""
echo "--- T1: escalates at MTK_MAX_REMEDIATION_ITERS (default 3) ---"
U=$(new_wf)
d1=$(decision "$WF" remediation "$U" build_failure)
d2=$(decision "$WF" remediation "$U" build_failure)
d3=$(decision "$WF" remediation "$U" build_failure)
[ "$d1" = "CONTINUE" ] || die "T1: iter1 expected CONTINUE, got $d1"
[ "$d2" = "CONTINUE" ] || die "T1: iter2 expected CONTINUE, got $d2"
[ "$d3" = "ESCALATE" ] || die "T1: iter3 expected ESCALATE, got $d3"
pass "iter1/2 CONTINUE, iter3 ESCALATE"

# --- T2: plateau on non-improving score (before cap) ---
echo ""
echo "--- T2: escalates on score plateau ---"
U=$(new_wf)
p1=$(decision "$WF" remediation "$U" review_correctness --score 5)
p2=$(decision "$WF" remediation "$U" review_correctness --score 5)
[ "$p1" = "CONTINUE" ] || die "T2: score 5 (iter1) expected CONTINUE, got $p1"
[ "$p2" = "ESCALATE" ] || die "T2: score 5→5 plateau (iter2) expected ESCALATE, got $p2"
pass "non-improving score escalates before the cap"

# --- T2b: strictly decreasing score also escalates (regression is the worse signal) ---
echo ""
echo "--- T2b: escalates on decreasing score ---"
U=$(new_wf)
q1=$(decision "$WF" remediation "$U" review_perf --score 7)
q2=$(decision "$WF" remediation "$U" review_perf --score 5)
[ "$q1" = "CONTINUE" ] || die "T2b: score 7 (iter1) expected CONTINUE, got $q1"
[ "$q2" = "ESCALATE" ] || die "T2b: score 7→5 regression (iter2) expected ESCALATE, got $q2"
pass "decreasing score escalates"

# --- T3: improving score keeps going ---
echo ""
echo "--- T3: improving score does NOT escalate ---"
U=$(new_wf)
i1=$(decision "$WF" remediation "$U" review_security --score 5)
i2=$(decision "$WF" remediation "$U" review_security --score 7)
[ "$i1" = "CONTINUE" ] || die "T3: iter1 expected CONTINUE, got $i1"
[ "$i2" = "CONTINUE" ] || die "T3: improving 5→7 expected CONTINUE, got $i2"
pass "improving score continues"

# --- T4: env override of the cap ---
echo ""
echo "--- T4: MTK_MAX_REMEDIATION_ITERS override ---"
U=$(new_wf)
e1=$(MTK_MAX_REMEDIATION_ITERS=2 decision "$WF" remediation "$U" flaky)
e2=$(MTK_MAX_REMEDIATION_ITERS=2 decision "$WF" remediation "$U" flaky)
[ "$e1" = "CONTINUE" ] || die "T4: iter1 expected CONTINUE, got $e1"
[ "$e2" = "ESCALATE" ] || die "T4: iter2 with cap=2 expected ESCALATE, got $e2"
pass "cap override honored"

# --- T5: ESCALATE decision returned AND escalation recorded as an event ---
echo ""
echo "--- T5: ESCALATE returned + remediation_escalated event written ---"
U=$(new_wf)
d5=$(MTK_MAX_REMEDIATION_ITERS=1 decision "$WF" remediation "$U" boom)
[ "$d5" = "ESCALATE" ] || die "T5: cap=1 first call expected ESCALATE, got $d5"
if grep -q '"remediation_escalated"' ".mtk/workflows/${U}.events.jsonl"; then
  pass "ESCALATE returned and remediation_escalated event present"
else
  die "T5: expected remediation_escalated event in events.jsonl"
fi

# --- T6: --score with no value fails cleanly (not an opaque set -e crash) ---
echo ""
echo "--- T6: --score with no value → clean failure ---"
U=$(new_wf)
if "$WF" remediation "$U" trig --score >/dev/null 2>&1; then
  die "T6: expected non-zero exit when --score has no value"
else
  pass "--score with no value fails cleanly"
fi

# --- T7: non-integer --score is rejected ---
echo ""
echo "--- T7: non-integer --score rejected ---"
U=$(new_wf)
if "$WF" remediation "$U" trig --score abc >/dev/null 2>&1; then
  die "T7: expected non-zero exit for non-integer score"
else
  pass "non-integer --score rejected"
fi

echo ""
echo "========================================"
echo "TEST PASSED — all F3 remediation assertions green"
