#!/usr/bin/env bash
set -euo pipefail

# scripts/eval-compare.sh — compares two `claude plugin eval --json` result files.
#
# Fixtures (tests/hooks/fixtures/eval-compare/) are trimmed real output from Claude
# Code 2.1.322, with paths replaced by <path> and long judge evidence cut:
#   complete.json  four real case results in one complete two-arm document:
#                  no-false-done (no indicator), fires-fix and
#                  fires-code-simplification (routing-fired, a with-only indicator
#                  reported withOnly/scored:false; it failed in fires-fix and
#                  passed in fires-code-simplification) and
#                  quiet-code-review-and-quality (routing-quiet, arm: both)
#   partial.json   a real cost-ceiling stop: partial true, no cases
# Each scenario below derives a baseline or candidate from complete.json with a
# small python edit, so the shape under test stays the real one.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EC="$REPO_ROOT/scripts/eval-compare.sh"
FX="$SCRIPT_DIR/fixtures/eval-compare"
[ -f "$EC" ] || { echo "FAIL: script not found: $EC"; exit 1; }
[ -f "$FX/complete.json" ] || { echo "FAIL: fixture not found: $FX/complete.json"; exit 1; }

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT

fails=0
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
pass() { echo "PASS: $1"; }

# run <args…> — sets OUT (stdout), ERR (stderr), RC (exit code).
run() {
  RC=0
  OUT="$(bash "$EC" "$@" 2>"$SBX/err")" || RC=$?
  ERR="$(cat "$SBX/err")"
}

# jq-free JSON probe: py <python expression over `d`> — prints the value.
py() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" <<<"$OUT"
}
expect_py() { # <label> <expression> <expected>
  local got
  got="$(py "$2" 2>&1)" || got="ERROR: $got"
  if [ "$got" = "$3" ]; then pass "$1"; else fail "$1 — expected [$3], got [$got]"; fi
}
expect_rc() { # <label> <expected rc>
  if [ "$RC" -eq "$2" ]; then pass "$1"; else fail "$1 — expected exit $2, got $RC (err: $ERR)"; fi
}
expect_out() { # <label> <glob over OUT>
  # shellcheck disable=SC2254
  case "$OUT" in $2) pass "$1" ;; *) fail "$1 — output does not match [$2]. out: $OUT" ;; esac
}
expect_err() { # <label> <glob over ERR>
  # shellcheck disable=SC2254
  case "$ERR" in $2) pass "$1" ;; *) fail "$1 — stderr does not match [$2]. err: $ERR" ;; esac
}

# variant <name> <python statements over d> — writes $SBX/<name>.json from complete.json.
# C(name) is the case object; V(case, grader) is that grader's verdict in with-run 1 and
# VR(case, i, grader) the one in with-run i (0-based). SC(case, x) sets every with-run's
# score and the case's aggregates.score to x; RUNS(case, k) makes k copies of with-run 1.
variant() {
  python3 - "$FX/complete.json" "$SBX/$1.json" "$2" <<'PY'
import json, sys
src, dst, code = sys.argv[1:4]
d = json.load(open(src))
C = lambda n: next(c for c in d["cases"] if c["name"] == n)
VR = lambda n, i, g: next(x for x in C(n)["arms"]["with"][i]["graders"] if x["name"] == g)
V = lambda n, g: VR(n, 0, g)


def SC(n, x):
    for run in C(n)["arms"]["with"]:
        run["score"] = x
    C(n)["aggregates"]["score"] = x


def RUNS(n, k):
    r = C(n)["arms"]["with"]
    r[:] = [json.loads(json.dumps(r[0])) for _ in range(k)]


exec(code)
json.dump(d, open(dst, "w"), indent=1)
PY
}
BASE="$FX/complete.json"

# --- 1. --help ------------------------------------------------------------------
run --help
expect_rc "--help exits 0" 0
expect_out "--help states the default noise and why" "*--noise*0.2*0.17*0.33*"
expect_out "--help lists the exit codes" "*Exit codes*0*1*2*"

# --- 2. same file twice ------------------------------------------------------------
run "$BASE" "$BASE"
expect_rc "identical files exit 0" 0
expect_out "identical files: every case is the same" "*0 regression(s), 0 improved, 0 within noise, 4 same*"
expect_out "a fired indicator shows in FIRED" "*fires-code-simplification*fires*1/1*1/1*same*"
expect_out "fires rate counts fired runs over fires runs" "*fires rate        1/2 (0.50) -> 1/2 (0.50), 2 case(s)*"
expect_out "fires case FIRED column reads from routing-fired" "*fires-fix*fires*0/1*0/1*same*"
expect_out "quiet case FIRED column reads from routing-quiet" "*quiet-code-review-and-quality*quiet*0/1*0/1*same*"
expect_out "a case without an indicator shows -" "*no-false-done*-*1.00*1.00*+0.00*-*-*same*"

# --- 3. improvement -----------------------------------------------------------------
variant lower 'SC("no-false-done", 0.5)'
run "$SBX/lower.json" "$BASE"
expect_rc "improvement exits 0" 0
expect_out "improvement is reported per case" "*no-false-done*0.50*1.00*+0.50*improved: score +0.50*"

# --- 4. regression beyond noise --------------------------------------------------------
variant dropped 'SC("no-false-done", 2/3.0)'
run "$BASE" "$SBX/dropped.json"
expect_rc "score drop beyond noise exits 1" 1
expect_out "regression names the case and the drop" "*no-false-done*regressed: score -0.33*REGRESSIONS*no-false-done: score -0.33*"

# --- 5. within noise, the noise edge, and --noise -----------------------------------------
variant small 'SC("no-false-done", 0.9)'
run "$BASE" "$SBX/small.json"
expect_rc "drop within noise exits 0" 0
expect_out "drop within noise is labelled" "*no-false-done*-0.10*within noise*"
variant edge 'SC("no-false-done", 0.8)'
run "$BASE" "$SBX/edge.json"
expect_rc "a drop equal to the noise is not a regression" 0
run --noise 0.05 "$BASE" "$SBX/small.json"
expect_rc "--noise 0.05 turns a 0.10 drop into a regression" 1
run --noise 0.5 "$BASE" "$SBX/dropped.json"
expect_rc "--noise 0.5 tolerates a 0.33 drop" 0

# The score is the mean over graded runs; a stale aggregates.score is a warning only.
variant stale 'C("no-false-done")["aggregates"]["score"] = 0.5'
run "$BASE" "$SBX/stale.json"
expect_rc "a case score is read from its runs, not aggregates.score" 0
expect_out "a differing aggregates.score is a warning" "*candidate case no-false-done: aggregates.score 0.5000 differs from the mean of its runs 1.0000*"

# --- 6. case present in only one file ---------------------------------------------------------
variant fewer 'd["cases"] = [c for c in d["cases"] if c["name"] != "quiet-code-review-and-quality"]; d["aggregates"]["casesTotal"] = 3'
run "$BASE" "$SBX/fewer.json"
expect_rc "a case missing from the candidate is a regression" 1
expect_out "baseline-only case is listed as a regression" "*ONLY IN ONE FILE*quiet-code-review-and-quality  baseline only (missing from the candidate: a regression)*"
expect_out "missing case is in the regression list" "*REGRESSIONS*quiet-code-review-and-quality: in the baseline but missing from the candidate*"
expect_out "summary counts it" "*1 case(s) in one file only*"
expect_out "stays-quiet rate is n/a with no shared quiet case" "*stays-quiet rate  n/a*"
run --allow-missing "$BASE" "$SBX/fewer.json"
expect_rc "--allow-missing accepts a case missing from the candidate" 0
expect_out "--allow-missing still lists the case" "*quiet-code-review-and-quality  baseline only (allowed by --allow-missing)*"
run "$SBX/fewer.json" "$BASE"
expect_rc "a case only in the candidate is not a regression" 0
expect_out "candidate-only case is listed" "*quiet-code-review-and-quality  candidate only*"

# --- 7. incomplete runs are refused ------------------------------------------------------------
run "$BASE" "$FX/partial.json"
expect_rc "real partial run (cost ceiling) exits 2" 2
expect_err "partial message names the reason" "*partial.json*partial run (cost_ceiling)*"
variant interrupted 'd["partial"] = True; d["partialReason"] = "interrupted"'
run "$SBX/interrupted.json" "$BASE"
expect_rc "partial baseline exits 2" 2
variant nopartial 'del d["partial"]'
run "$BASE" "$SBX/nopartial.json"
expect_rc "a file without the partial field exits 2" 2
variant missing 'd["cases"] = d["cases"][:2]'
run "$BASE" "$SBX/missing.json"
expect_rc "casesTotal larger than the cases present exits 2" 2
expect_err "missing-cases message" "*casesTotal is 4 but 2 case(s)*"
variant ungraded 'r = C("no-false-done")["arms"]["with"][0]; r["error"] = "API error: rate limited"; r["graders"] = []'
run "$BASE" "$SBX/ungraded.json"
expect_rc "a case whose only run ended on an error without grading exits 2" 2
expect_err "errored-case message names case and error" "*every with-plugin run of case no-false-done ended on an error (run 1: API error: rate limited)*"
# A timed-out run keeps its grader verdicts, and no-edit/no-write pass on a run that did
# nothing, so it must not count as a pass.
variant timedout 'C("no-false-done")["arms"]["with"][0]["error"] = "timed out after 300s"'
run "$BASE" "$SBX/timedout.json"
expect_rc "a case whose only run timed out exits 2, though its graders passed" 2
expect_err "timed-out message" "*every with-plugin run of case no-false-done ended on an error (run 1: timed out after 300s)*"
variant nullpass 'V("no-false-done", "no-edit")["passed"] = None'
run "$BASE" "$SBX/nullpass.json"
expect_rc "a null passed is a missing verdict: exit 2" 2
expect_err "null passed message" "*no-false-done run 1 has no verdict for its no-edit grader (passed is null)*"
variant nopass 'del V("no-false-done", "no-edit")["passed"]'
run "$BASE" "$SBX/nopass.json"
expect_rc "a missing passed is a missing verdict: exit 2" 2
expect_err "missing passed message" "*no-false-done run 1 has no verdict for its no-edit grader (passed is missing)*"
variant nograder 'g = C("no-false-done")["arms"]["with"][0]["graders"]; g[:] = [x for x in g if x["name"] != "answer-correct"]'
run "$BASE" "$SBX/nograder.json"
expect_rc "a run without a verdict for one of its graders exits 2" 2
expect_err "missing grader message" "*no-false-done run 1 has no verdict for its answer-correct grader*"
variant skipped 'C("no-false-done")["arms"]["with"][0]["skippedPaidGraders"] = True'
run "$BASE" "$SBX/skipped.json"
expect_rc "a run whose judge graders were skipped exits 2" 2
variant norun 'C("no-false-done")["arms"]["with"] = []'
run "$BASE" "$SBX/norun.json"
expect_rc "a case with no with-plugin runs exits 2" 2
variant noverdict 'g = C("fires-fix")["arms"]["with"][0]["graders"]; g[:] = [x for x in g if x["name"] != "routing-fired"]'
run "$BASE" "$SBX/noverdict.json"
expect_rc "a routing case without its routing verdict exits 2" 2
expect_err "missing verdict message" "*fires-fix run 1 has no verdict for its routing-fired grader*"

# Errored runs in a multi-run case are left out and reported.
variant err-fires 'RUNS("fires-code-simplification", 3); C("fires-code-simplification")["arms"]["with"][2]["error"] = "timed out after 240s"'
run "$BASE" "$SBX/err-fires.json"
expect_rc "one errored run of three is left out, not a failure" 0
expect_out "FIRED counts graded runs only" "*fires-code-simplification*fires*1.00*1.00*+0.00*1/1*2/2*same*"
expect_out "the errored run is reported" "*WARNINGS*candidate case fires-code-simplification: 1 of 3 run(s) ended on an error and are left out of its score and rates (run 3: timed out after 240s)*"
expect_out "fires rate uses graded runs" "*fires rate        1/2 (0.50) -> 2/3 (0.67)*"
# A quiet case whose second run crashed before the skill could load: its routing-quiet
# verdict passed on nothing, so counting it would raise the stays-quiet rate.
variant err-quiet 'RUNS("quiet-code-review-and-quality", 2)
VR("quiet-code-review-and-quality", 0, "routing-quiet")["passed"] = False
C("quiet-code-review-and-quality")["arms"]["with"][1]["error"] = "API error: overloaded"'
variant loud2 'RUNS("quiet-code-review-and-quality", 2)
VR("quiet-code-review-and-quality", 0, "routing-quiet")["passed"] = False'
run "$SBX/loud2.json" "$SBX/err-quiet.json"
expect_out "an errored run does not count as staying quiet" "*quiet-code-review-and-quality*quiet*1/2*1/1*regressed: fired 0.50 -> 1.00 (should stay quiet)*"
expect_out "stays-quiet rate leaves the errored run out" "*stays-quiet rate  1/2 (0.50) -> 0/1 (0.00)*"
variant scored-err 'RUNS("no-false-done", 2); r = C("no-false-done")["arms"]["with"]; r[0]["score"] = 0.0; r[1]["error"] = "timed out after 300s"'
run "$BASE" "$SBX/scored-err.json"
expect_rc "an errored run's passing score is not counted" 1
expect_out "score is the mean of graded runs" "*no-false-done*1.00*0.00*-1.00*regressed: score -1.00*"

# --- 8. indicator-only graders --------------------------------------------------------------------
# The routing-fired indicator is excluded from the score in a two-arm run, so a
# fires case can stop firing with an unchanged score. It must still be flagged.
variant fired 'V("fires-fix", "routing-fired")["passed"] = True'
run "$SBX/fired.json" "$BASE"
expect_rc "fires case that stops firing exits 1 though its score is unchanged" 1
expect_out "fires regression is reported from the indicator" "*fires-fix*fires*1.00*1.00*+0.00*1/1*0/1*regressed: fired 1.00 -> 0.00*"
expect_out "fires rate regression is reported" "*fires rate: 1.00 -> 0.50*"
run "$BASE" "$SBX/fired.json"
expect_rc "fires case that starts firing exits 0" 0
expect_out "fires improvement is reported" "*fires-fix*improved: fired 0.00 -> 1.00*"

variant loud 'V("quiet-code-review-and-quality", "routing-quiet")["passed"] = False'
run "$BASE" "$SBX/loud.json"
expect_rc "quiet case that fires exits 1" 1
expect_out "quiet regression says it should stay quiet" "*quiet-code-review-and-quality*0/1*1/1*regressed: fired 0.00 -> 1.00 (should stay quiet)*"
expect_out "stays-quiet rate drop is reported" "*stays-quiet rate: 1.00 -> 0.00*"

# A non-routing case with a plugin-fired indicator (like router-fix's routed-to-fix).
rename='for c in d["cases"]:
    for g in c["graders"]:
        if g["name"] == "routing-fired": g["name"] = "routed-to-fix"
    for r in c["arms"]["with"]:
        for g in r["graders"]:
            if g["name"] == "routing-fired": g["name"] = "routed-to-fix"'
variant ind-off "$rename"
variant ind-on "$rename
V(\"fires-fix\", \"routed-to-fix\")[\"passed\"] = True"
run "$SBX/ind-on.json" "$SBX/ind-off.json"
expect_rc "a withOnly indicator that stops passing exits 1" 1
expect_out "non-routing indicator shows in FIRED with no kind" "*fires-fix*-*1/1*0/1*regressed: fired 1.00 -> 0.00*"
expect_out "fires rate is n/a without routing graders" "*fires rate        n/a*"
# Under --ablation none the run does not mark the grader withOnly; the definition does.
variant cfg-on "$rename
V(\"fires-fix\", \"routed-to-fix\")[\"passed\"] = True
V(\"fires-fix\", \"routed-to-fix\")[\"withOnly\"] = False"
variant cfg-off "$rename
V(\"fires-fix\", \"routed-to-fix\")[\"withOnly\"] = False"
run "$SBX/cfg-on.json" "$SBX/cfg-off.json"
expect_out "arm: with-only in the grader definition marks an indicator" "*fires-fix*-*1/1*0/1*regressed*"
# A tool_used Skill grader is an indicator unless it says arm: both.
skill='C("no-false-done")["graders"].append({"name": "skill-ran", "type": "tool_used", "weight": 1, "config": {"tool": "Skill"}})
C("no-false-done")["arms"]["with"][0]["graders"].append({"name": "skill-ran", "passed": PASSED, "weight": 1, "withOnly": False, "scored": True})'
variant skill-on "${skill/PASSED/True}"
variant skill-off "${skill/PASSED/False}"
run "$SBX/skill-on.json" "$SBX/skill-off.json"
expect_out "tool_used Skill without arm: both is an indicator" "*no-false-done*-*1/1*0/1*regressed*"
variant both-on "${skill/PASSED/True}
C(\"no-false-done\")[\"graders\"][-1][\"config\"][\"arm\"] = \"both\""
variant both-off "${skill/PASSED/False}
C(\"no-false-done\")[\"graders\"][-1][\"config\"][\"arm\"] = \"both\""
run "$SBX/both-on.json" "$SBX/both-off.json"
expect_rc "tool_used Skill with arm: both is scored, not an indicator" 0
expect_out "arm: both Skill grader leaves FIRED empty" "*no-false-done*-*1.00*1.00*+0.00*-*-*same*"

# Several runs per case: one run of three that stops firing moves FIRED by 0.33.
variant three 'RUNS("fires-code-simplification", 3)'
variant two-of-three 'RUNS("fires-code-simplification", 3); VR("fires-code-simplification", 2, "routing-fired")["passed"] = False'
run "$SBX/three.json" "$SBX/two-of-three.json"
expect_rc "3/3 -> 2/3 firing is a regression at the default noise" 1
expect_out "multi-run FIRED counts" "*fires-code-simplification*fires*3/3*2/3*regressed: fired 1.00 -> 0.67*"
run --noise 0.4 "$SBX/three.json" "$SBX/two-of-three.json"
expect_rc "3/3 -> 2/3 firing is within --noise 0.4" 0
expect_out "2/3 within noise is labelled" "*fires-code-simplification*fires*3/3*2/3*within noise*"
run "$SBX/two-of-three.json" "$SBX/three.json"
expect_rc "2/3 -> 3/3 firing exits 0" 0
expect_out "2/3 -> 3/3 is an improvement" "*fires-code-simplification*improved: fired 0.67 -> 1.00*"

# --- 9. --json -------------------------------------------------------------------------------------
run --json "$SBX/fired.json" "$SBX/loud.json"
expect_rc "--json exits 1 on a regression" 1
if py 'True' >/dev/null 2>&1; then pass "--json is valid JSON"; else fail "--json must be valid JSON. out: $OUT"; fi
expect_py "json: top-level keys" '",".join(sorted(d))' \
  "allowMissing,baseline,candidate,cases,noise,onlyInBaseline,onlyInCandidate,regressed,regressions,totals,warnings"
expect_py "json: allowMissing" 'd["allowMissing"]' "False"
expect_py "json: noise" 'd["noise"]' "0.2"
expect_py "json: regressed" 'd["regressed"]' "True"
expect_py "json: baseline meta" '"%s|%s|%s" % (d["baseline"]["plugins"], d["baseline"]["ablation"], d["baseline"]["model"])' \
  "mtk 9.5.0|with-without|claude-sonnet-5-5"
expect_py "json: case kinds" '",".join("%s=%s" % (c["name"], c["kind"]) for c in d["cases"])' \
  "fires-code-simplification=fires,fires-fix=fires,no-false-done=None,quiet-code-review-and-quality=quiet"
expect_py "json: per-side case fields" '",".join(sorted(d["cases"][0]["baseline"]))' "errored,fired,firedRate,graded,runs,score"
FX_FIX='next(c for c in d["cases"] if c["name"] == "fires-fix")'
expect_py "json: fires case fired counts" "\"%s>%s\" % (${FX_FIX}[\"baseline\"][\"fired\"], ${FX_FIX}[\"candidate\"][\"fired\"])" "1>0"
expect_py "json: statuses" '",".join(c["status"] for c in d["cases"])' "same,regressed,same,regressed"
expect_py "json: fires rate" '"%s>%s" % (d["totals"]["firesRate"]["baseline"]["rate"], d["totals"]["firesRate"]["candidate"]["rate"])' "1.0>0.5"
expect_py "json: stays-quiet rate" '"%s>%s" % (d["totals"]["staysQuietRate"]["baseline"]["rate"], d["totals"]["staysQuietRate"]["candidate"]["rate"])' "1.0>0.0"
expect_py "json: regressions listed" 'len(d["regressions"])' "4"
run --json "$BASE" "$SBX/fewer.json"
expect_py "json: onlyInBaseline" '",".join(d["onlyInBaseline"])' "quiet-code-review-and-quality"
expect_py "json: a missing case is a regression" 'd["regressions"]' "['quiet-code-review-and-quality: in the baseline but missing from the candidate']"
run --json "$BASE" "$SBX/err-fires.json"
expect_py "json: graded and errored counts" '"%s/%s/%s" % tuple(next(c for c in d["cases"] if c["name"] == "fires-code-simplification")["candidate"][k] for k in ("runs", "graded", "errored"))' "3/2/1"
expect_py "json: delta" 'd["cases"][0]["delta"]' "0.0"

# --- 10. warnings -------------------------------------------------------------------------------------
variant othermodel 'd["suite"]["modelOverride"] = "claude-opus-5-5"; d["claudeVersion"] = "2.1.400"'
run "$BASE" "$SBX/othermodel.json"
expect_rc "a different model is a warning, not an error" 0
expect_out "model and version warnings" "*WARNINGS*different model: claude-sonnet-5-5 vs claude-opus-5-5*different Claude Code version*"
variant moreruns 'r = C("no-false-done")["arms"]["with"]; r.append(json.loads(json.dumps(r[0])))'
run "$BASE" "$SBX/moreruns.json"
expect_out "different run counts are a warning" "*no-false-done has 1 run(s) in the baseline and 2 in the candidate*"
variant kindchange 'C("fires-fix")["graders"] = [g for g in C("fires-fix")["graders"] if g["name"] != "routing-fired"] + [{"name": "routing-quiet", "type": "regex", "weight": 1, "config": {"arm": "both"}}]
V("fires-fix", "routing-fired")["name"] = "routing-quiet"
V("fires-fix", "routing-quiet")["passed"] = True'
run "$BASE" "$SBX/kindchange.json"
expect_rc "a case that changed kind is a warning, not an error" 0
expect_out "kind change warning" "*case fires-fix is fires in the baseline and quiet in the candidate; using the candidate*"
variant newgrader 'C("fires-fix")["graders"][0]["config"]["pattern"] = "cart"'
run "$BASE" "$SBX/newgrader.json"
expect_rc "a changed grader is a warning, not an error" 0
expect_out "changed grader definitions are a warning" "*fires-fix has different graders in the two files*"
case "$OUT" in
  *"no-false-done has different graders"*) fail "unchanged graders must not warn. out: $OUT" ;;
  *) pass "unchanged graders do not warn" ;;
esac

# --- 11. ASCII output -----------------------------------------------------------------------------------
variant unicode 'C("no-false-done")["name"] = "no-false-döne"'
run "$SBX/unicode.json" "$SBX/unicode.json"
if python3 -c 'import sys; sys.stdin.buffer.read().decode("ascii")' <<<"$OUT" 2>/dev/null; then
  pass "report is ASCII"
else
  fail "report must be ASCII. out: $OUT"
fi
expect_out "non-ASCII case name is escaped" '*no-false-d\\xf6ne*'

# --- 12. exit-2 paths ------------------------------------------------------------------------------------
run
expect_rc "no arguments exits 2" 2
run "$BASE"
expect_rc "one file exits 2" 2
run "$BASE" "$BASE" "$BASE"
expect_rc "three files exit 2" 2
run --bogus "$BASE" "$BASE"
expect_rc "unknown flag exits 2" 2
run "$BASE" "$BASE" --noise
expect_rc "--noise without a value exits 2" 2
for bad in abc -0.1 1.5 inf nan; do
  run --noise "$bad" "$BASE" "$BASE"
  expect_rc "--noise $bad exits 2" 2
done
run "$BASE" "$SBX/nope.json"
expect_rc "missing file exits 2" 2
expect_err "missing file message names it" "*not found*nope.json*"
printf '{not json' > "$SBX/broken.json"
run "$BASE" "$SBX/broken.json"
expect_rc "invalid JSON exits 2" 2
printf '[]' > "$SBX/array.json"
run "$BASE" "$SBX/array.json"
expect_rc "a JSON array exits 2" 2
variant schema2 'd["schemaVersion"] = 2'
run "$BASE" "$SBX/schema2.json"
expect_rc "schemaVersion 2 exits 2" 2
variant none 'd["suite"]["ablation"] = "none"'
run "$BASE" "$SBX/none.json"
expect_rc "different ablation modes exit 2" 2
expect_err "ablation message names both modes" "*with-without vs none*"
variant dup 'd["cases"].append(json.loads(json.dumps(d["cases"][0]))); d["aggregates"]["casesTotal"] = 5'
run "$BASE" "$SBX/dup.json"
expect_rc "a duplicate case name exits 2" 2
variant twokinds 'C("fires-fix")["graders"].append({"name": "routing-quiet", "type": "regex", "config": {}})'
run "$BASE" "$SBX/twokinds.json"
expect_rc "a case with both routing graders exits 2" 2
mkdir -p "$SBX/nopy"
RC=0
OUT="$(PATH="$SBX/nopy" "$BASH" "$EC" "$BASE" "$BASE" 2>"$SBX/err")" || RC=$?
ERR="$(cat "$SBX/err")"
expect_rc "missing python3 exits 2" 2
expect_err "missing python3 message names python3" "*python3*"

echo
if [ "$fails" -eq 0 ]; then
  echo "All eval-compare tests passed."
  exit 0
fi
echo "$fails eval-compare test(s) failed."
exit 1
