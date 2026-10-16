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

# Line 1 is the verdict when --open/--findings add reason/reconcile lines after it.
verdict() { "$@" | sed -n '1p'; }
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["results"]["remediation"][sys.argv[2]]; print(json.dumps(d.get(sys.argv[3])))' ".mtk/workflows/$1.json" "$2" "$3"; }

# --- T8: --open stall (lower is better; no decrease ⇒ ESCALATE, reason stalled) ---
echo ""
echo "--- T8: --open 3 then --open 3 → ESCALATE (stalled) ---"
U=$(new_wf)
o1=$("$WF" remediation "$U" review --open 3)
o2=$("$WF" remediation "$U" review --open 3)
[ "$(printf '%s\n' "$o1" | sed -n '1p')" = "CONTINUE" ] || die "T8: first --open 3 expected CONTINUE, got: $o1"
[ "$(printf '%s\n' "$o2" | sed -n '1p')" = "ESCALATE" ] || die "T8: second --open 3 expected ESCALATE, got: $o2"
case "$o2" in *"reason: stalled"*) ;; *) die "T8: expected 'reason: stalled' line, got: $o2" ;; esac
[ "$(field "$U" review opens)" = "[3, 3]" ] || die "T8: opens series expected [3, 3], got $(field "$U" review opens)"
[ "$(field "$U" review stalled)" = "true" ] || die "T8: expected stalled: true"
grep -q '"reason":"stalled"' ".mtk/workflows/${U}.events.jsonl" \
  || die "T8: remediation_escalated event should carry reason stalled"
pass "non-decreasing open count escalates with reason stalled (series + event recorded)"

echo ""
echo "--- T9: --open 3 then --open 1 → CONTINUE ---"
U=$(new_wf)
d1=$(verdict "$WF" remediation "$U" review --open 3)
d2o=$("$WF" remediation "$U" review --open 1)
[ "$d1" = "CONTINUE" ] || die "T9: first --open 3 expected CONTINUE, got $d1"
[ "$d2o" = "CONTINUE" ] || die "T9: --open 3→1 expected exactly CONTINUE, got: $d2o"
[ "$(field "$U" review stalled)" = "false" ] || die "T9: expected stalled: false"
pass "decreasing open count continues"

echo ""
echo "--- T9b: --open 0 then --open 0 → CONTINUE (zero open is success, not a stall) ---"
U=$(new_wf)
z1=$(verdict "$WF" remediation "$U" review --open 0)
z2=$("$WF" remediation "$U" review --open 0)
[ "$z1" = "CONTINUE" ] || die "T9b: first --open 0 expected CONTINUE, got $z1"
[ "$z2" = "CONTINUE" ] || die "T9b: --open 0→0 expected exactly CONTINUE, got: $z2"
[ "$(field "$U" review stalled)" = "false" ] || die "T9b: expected stalled: false"
pass "two successive zero open counts do not stall"

# --- T10: --score series and plateau unchanged when --open is also used ---
echo ""
echo "--- T10: --score behaviour unchanged alongside --open ---"
U=$(new_wf)
s1=$(verdict "$WF" remediation "$U" review --score 5 --open 4)
s2=$(verdict "$WF" remediation "$U" review --score 7 --open 2)
[ "$s1" = "CONTINUE" ] && [ "$s2" = "CONTINUE" ] || die "T10: improving score + falling opens expected CONTINUE twice, got $s1/$s2"
[ "$(field "$U" review scores)" = "[5, 7]" ] || die "T10: scores expected [5, 7], got $(field "$U" review scores)"
[ "$(field "$U" review plateau)" = "false" ] || die "T10: plateau expected false"
s3=$("$WF" remediation "$U" review --score 7 --open 1)
[ "$(printf '%s\n' "$s3" | sed -n '1p')" = "ESCALATE" ] || die "T10: score 7→7 plateau expected ESCALATE, got: $s3"
case "$s3" in *"reason: stalled"*) die "T10: score plateau with falling opens must not claim stalled: $s3" ;; esac
[ "$(field "$U" review plateau)" = "true" ] || die "T10: plateau expected true after 7→7"
[ "$(field "$U" review opens)" = "[4, 2, 1]" ] || die "T10: opens expected [4, 2, 1], got $(field "$U" review opens)"
grep -q '"reason":"plateau"' ".mtk/workflows/${U}.events.jsonl" || die "T10: escalation reason should be plateau"
pass "score series + plateau independent of the opens series"

# --- T11: --findings reconcile FIXED / STILL_OPEN / NEW across two calls ---
echo ""
echo "--- T11: --findings reconcile ---"
U=$(new_wf)
cat > f1.json <<'JSON'
[{"file":"src/a.sh","line":10,"rule":"S3.4","rationale":"unbound   VAR under set -u"},
 {"file":"src/b.sh","line":3,"rule":"S3.17","rationale":"pipe into grep -q"}]
JSON
cat > f2.json <<'JSON'
{"verdict":"NEEDS_CHANGES","findings":[
 {"file":"src/b.sh","line":30,"rule":"S3.17","rationale":"pipe into  grep -q"},
 {"file":"src/c.sh","line":1,"rule":"S3.1","rationale":"missing set -euo pipefail"}]}
JSON
r1=$("$WF" remediation "$U" review --findings f1.json)
r2=$("$WF" remediation "$U" review --findings f2.json)
[ "$(printf '%s\n' "$r1" | sed -n '1p')" = "CONTINUE" ] || die "T11: first call expected CONTINUE, got: $r1"
grep -q '^NEW 2 F-[0-9a-f]\{10\} F-[0-9a-f]\{10\}$' <<<"$r1" || die "T11: first call expected NEW 2 <uid> <uid>, got: $r1"
grep -q '^FIXED 0$' <<<"$r1" || die "T11: first call expected FIXED 0, got: $r1"
grep -q '^FIXED 1 F-' <<<"$r2" || die "T11: second call expected FIXED 1, got: $r2"
grep -q '^STILL_OPEN 1 F-' <<<"$r2" || die "T11: second call expected STILL_OPEN 1 (b.sh moved lines only), got: $r2"
grep -q '^NEW 1 F-' <<<"$r2" || die "T11: second call expected NEW 1, got: $r2"
# The STILL_OPEN uid is the b.sh finding from the first call; FIXED is a.sh's.
b_uid=$(printf '%s\n' "$r2" | sed -n 's/^STILL_OPEN 1 //p')
grep -q "$b_uid" <<<"$r1" || die "T11: STILL_OPEN uid $b_uid was not in the first call's NEW set"
[ "$(field "$U" review opens)" = "[2, 2]" ] || die "T11: --findings should feed opens [2, 2], got $(field "$U" review opens)"
case "$r2" in ESCALATE*"reason: stalled"*) ;; *) die "T11: 2→2 open findings should stall, got: $r2" ;; esac
python3 - ".mtk/workflows/$U.json" "$b_uid" <<'PY' || die "T11: stored findings block wrong"
import json, sys
f = json.load(open(sys.argv[1]))["results"]["remediation"]["review"]["findings"]
assert len(f["open"]) == 2 and sys.argv[2] in f["open"], f
assert f["last"]["STILL_OPEN"] == [sys.argv[2]], f
assert len(f["last"]["FIXED"]) == 1 and len(f["last"]["NEW"]) == 1, f
PY
pass "FIXED/STILL_OPEN/NEW reconciled, stored, and open count fed into opens"

# --- T12: UID stable across line moves, changes with the snippet ---
echo ""
echo "--- T12: UID stability ---"
uid_of() {
  local u
  u=$(new_wf)
  printf '%s\n' "$1" > uid.json
  "$WF" remediation "$u" review --findings uid.json | sed -n 's/^NEW 1 //p'
}
u_a=$(uid_of '[{"file":"x.sh","line":5,"rule":"R1","snippet":"foo  bar\n baz"}]')
u_b=$(uid_of '[{"file":"x.sh","line":99,"rule":"R1","snippet":"foo bar baz"}]')
u_c=$(uid_of '[{"file":"x.sh","line":5,"rule":"R1","snippet":"foo bar qux"}]')
[ -n "$u_a" ] || die "T12: no uid printed"
[ "$u_a" = "$u_b" ] || die "T12: UID changed when only line/whitespace moved ($u_a vs $u_b)"
[ "$u_a" != "$u_c" ] || die "T12: UID did not change with the snippet ($u_a)"
pass "UID ignores line number + whitespace, follows the snippet"

# --- T13: --findings error paths ---
echo ""
echo "--- T13: unparseable --findings → exit 2; --open with --findings → error ---"
U=$(new_wf)
printf 'not json' > bad.json
rc=0; "$WF" remediation "$U" review --findings bad.json >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || die "T13: unparseable findings expected exit 2, got $rc"
printf '{"verdict":"PASS"}' > nofind.json
rc=0; "$WF" remediation "$U" review --findings nofind.json >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || die "T13: object without findings[] expected exit 2, got $rc"
rc=0; "$WF" remediation "$U" review --findings missing.json >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || die "T13: missing findings file expected exit 2, got $rc"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["results"].get("remediation", {}).get("review"))' ".mtk/workflows/$U.json")" = "None" ] \
  || die "T13: a rejected --findings call must not count an iteration"
if "$WF" remediation "$U" review --open 2 --findings f1.json >/dev/null 2>&1; then
  die "T13: --open together with --findings should fail"
fi
if "$WF" remediation "$U" review --open x >/dev/null 2>&1; then
  die "T13: non-integer --open should fail"
fi
pass "bad findings exit 2 without recording; --open + --findings rejected"

echo ""
echo "========================================"
echo "TEST PASSED — all F3 remediation assertions green"
