#!/usr/bin/env bash
set -euo pipefail

# scripts/eval-coverage.sh — offline eval coverage report.
#
# The script lists the skills under .claude/skills/ that no eval case under
# evals/ exercises. "Exercises" is a stated heuristic, checked from the case
# files only:
#   - the skill name is one of the case's tags (prompt.md frontmatter, else
#     case.yaml);
#   - the prompt invokes it: /<skill>, /mtk <skill> or /mtk:<skill>;
#   - a grader names its path skills/<skill>/, or is a `tool: Skill` grader
#     whose text names the skill.
# Prose mentions, other paths and look-alike commands (/mtk-doctor, /mtk:x for
# the router itself) do not count. evals/results/ and evals/mocks/ are not
# cases; nested cases under a non-case group directory are.
#
# The script reads no results (lift and run comparison live in each run's result
# and in scripts/eval-compare.sh), so this test feeds it none.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EL="$REPO_ROOT/scripts/eval-coverage.sh"
[ -f "$EL" ] || { echo "FAIL: script not found: $EL"; exit 1; }

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT

fails=0
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
pass() { echo "PASS: $1"; }

# run <args…> — sets OUT (stdout), ERR (stderr), RC (exit code).
run() {
  RC=0
  OUT="$(bash "$EL" "$@" 2>"$SBX/err")" || RC=$?
  ERR="$(cat "$SBX/err")"
}

# jq-free JSON probe: py <python expression over `d`> — prints the value.
py() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" <<<"$OUT"
}

# --- Fixture: skills ---------------------------------------------------------
SK="$SBX/skills"
for s in alpha beta gamma-x delta epsilon zeta mtk omega writing; do
  mkdir -p "$SK/$s"
  printf -- '---\nname: %s\n---\n' "$s" > "$SK/$s/SKILL.md"
done
mkdir -p "$SK/notaskill"                     # no SKILL.md: not a skill
printf 'scratch\n' > "$SK/notaskill/README.md"

# --- Fixture: eval cases -----------------------------------------------------
EV="$SBX/evals"
mkcase() { mkdir -p "$EV/$1/graders"; }
grader() { printf -- '---\ntype: regex\ntarget: last_message\npattern: ok\n---\n\nok\n' > "$EV/$1/graders/ok.md"; }

# 1. tag
mkcase tagged; grader tagged
cat > "$EV/tagged/prompt.md" <<'EOF'
---
description: covers alpha through its tags
tags: [core, alpha]
---

Do the thing.
EOF

# 2. router form: /mtk <skill>
mkcase router; grader router
cat > "$EV/router/prompt.md" <<'EOF'
---
tags: [smoke]
---

/mtk beta the off-by-one in counter.sh
EOF

# 3. namespaced form: /mtk:<skill> — the router itself is not invoked
mkcase colon; grader colon
cat > "$EV/colon/prompt.md" <<'EOF'
---
tags:
  - core
---

/mtk:gamma-x add a --verbose flag
EOF

# 4. case.yaml only, grader names the skill's path
mkcase yaml-only
cat > "$EV/yaml-only/case.yaml" <<'EOF'
schema_version: "1.1"
name: yaml-only-case
execution:
  prompt: Fix the bug please.
EOF
cat > "$EV/yaml-only/graders/routed.md" <<'EOF'
---
type: regex
target: trace
pattern: '"name":"Read","input":\{"file_path":"[^"]*/skills/delta/SKILL\.md"'
arm: with-only
---

Indicator only.
EOF

# 5. tool: Skill grader naming the skill
mkcase skilltool
printf -- '---\n---\n\nRun a review.\n' > "$EV/skilltool/prompt.md"
cat > "$EV/skilltool/graders/fired.md" <<'EOF'
---
type: tool_used
tool: Skill
input_match: '"skill":"(?:mtk:)?epsilon"'
arm: with-only
---
EOF

# 6. nested case under a non-case group directory
mkdir -p "$EV/group/nested/graders"
grader group/nested
printf -- '---\ntags: [core]\n---\n\n/zeta now\n' > "$EV/group/nested/prompt.md"

# 7. distractors only: prose, paths, look-alike commands — covers nothing
mkcase prose; grader prose
cat > "$EV/prose/prompt.md" <<'EOF'
---
tags: [smoke]
---

Explain omega and the writing in lib/omega/x.sh and docs/skills-omega/.
Also try /mtk-doctor, /omegax and /mtk:writing-guide.
EOF
cat > "$EV/prose/graders/prose.md" <<'EOF'
---
type: llm
---

PASS if the answer mentions alpha, beta, omega and the writing skill.
EOF

# Not cases: results and suite-wide mocks
mkdir -p "$EV/results/2026-01-01-000000" "$EV/mocks/tracker"
printf -- '---\ntags: [omega]\n---\n\n/omega\n' > "$EV/results/2026-01-01-000000/prompt.md"
printf -- '---\ntags: [writing]\n---\n\n/writing\n' > "$EV/mocks/tracker/prompt.md"

ARGS=(--skills-dir "$SK" --evals-dir "$EV")

# --- 1. --help states the rule ----------------------------------------------
run --help
if [ "$RC" -eq 0 ]; then pass "--help exits 0"; else fail "--help exits 0 (rc=$RC)"; fi
case "$OUT" in
  *heuristic*"/mtk:<skill>"*"skills/<skill>/"*) pass "--help states the coverage rule" ;;
  *) fail "--help must state the coverage rule. out: $OUT" ;;
esac

# --- 2. human report -----------------------------------------------------------
run "${ARGS[@]}"
if [ "$RC" -eq 0 ]; then pass "human report exits 0"; else fail "human report exits 0 (rc=$RC, err: $ERR)"; fi
case "$OUT" in
  *heuristic*) pass "human header carries the heuristic rule" ;;
  *) fail "human header must carry the rule. out: $OUT" ;;
esac
case "$OUT" in
  *"9 skills, 7 cases"*) pass "header counts 9 skills and 7 cases (results/, mocks/, notaskill/ excluded)" ;;
  *) fail "expected '9 skills, 7 cases' in header. out: $OUT" ;;
esac
UNCOV="$(awk '/^UNCOVERED/{f=1; next} f && /^  /{sub(/^  +/, ""); print; next} {f=0}' <<<"$OUT")"
if [ "$UNCOV" = "$(printf 'omega\nwriting')" ]; then
  pass "uncovered list is exactly omega, writing (sorted)"
else
  fail "uncovered list must be exactly omega, writing. got: [$UNCOV]"
fi
case "$OUT" in
  *"summary: 7/9 skills covered, 2 uncovered"*) pass "summary line counts" ;;
  *) fail "expected summary line. out: $OUT" ;;
esac
COV_BETA="$(awk '$1=="beta"' <<<"$OUT")"
case "$COV_BETA" in
  *router*) pass "covered row names the covering case" ;;
  *) fail "beta row must name the router case. got: [$COV_BETA]" ;;
esac

# --- 3. --json -------------------------------------------------------------------
run "${ARGS[@]}" --json
if [ "$RC" -eq 0 ] && py 'True' >/dev/null 2>&1; then pass "--json exits 0 and is valid JSON"; else fail "--json must be valid JSON (rc=$RC). out: $OUT"; fi
expect_py() { # <label> <expression> <expected>
  local got
  got="$(py "$2" 2>&1)" || got="ERROR: $got"
  if [ "$got" = "$3" ]; then pass "$1"; else fail "$1 — expected [$3], got [$got]"; fi
}
expect_py "json: skills_total"            'd["skills_total"]' "9"
expect_py "json: cases_total"             'd["cases_total"]' "7"
expect_py "json: uncovered"               '",".join(d["uncovered"])' "omega,writing"
expect_py "json: rule present"            '"heuristic" in d["rule"]' "True"
expect_py "json: covered keys sorted"     '",".join(d["covered"])' "alpha,beta,delta,epsilon,gamma-x,mtk,zeta"
expect_py "json: tag covers alpha"        '",".join(d["covered"]["alpha"])' "tagged"
expect_py "json: /mtk <skill> covers mtk and beta" \
  '",".join(next(c for c in d["cases"] if c["name"]=="router")["skills"])' "beta,mtk"
expect_py "json: /mtk:<skill> covers only that skill, not the router" \
  '",".join(next(c for c in d["cases"] if c["name"]=="colon")["skills"])' "gamma-x"
expect_py "json: case.yaml name is used" \
  '",".join(c["name"] for c in d["cases"] if c["path"]=="yaml-only")' "yaml-only-case"
expect_py "json: grader skills/<skill>/ path covers delta" \
  '",".join(next(c for c in d["cases"] if c["path"]=="yaml-only")["skills"])' "delta"
expect_py "json: evidence names the rule (grader)" \
  '",".join(next(c for c in d["cases"] if c["path"]=="yaml-only")["evidence"]["delta"])' "grader"
expect_py "json: tool: Skill grader covers epsilon" \
  '",".join(next(c for c in d["cases"] if c["name"]=="skilltool")["skills"])' "epsilon"
expect_py "json: nested case found under a group dir" \
  '",".join(c["path"] for c in d["cases"] if c["name"]=="nested")' "group/nested"
expect_py "json: nested /<skill> covers zeta" \
  '",".join(next(c for c in d["cases"] if c["name"]=="nested")["skills"])' "zeta"
expect_py "json: prose, paths and look-alike commands cover nothing" \
  'len(next(c for c in d["cases"] if c["name"]=="prose")["skills"])' "0"
expect_py "json: results/ and mocks/ are not cases" \
  'any(c["path"].startswith(("results","mocks")) for c in d["cases"])' "False"

# --- 4. exit-2 paths ---------------------------------------------------------------
run --skills-dir "$SBX/nope" --evals-dir "$EV"
if [ "$RC" -eq 2 ]; then pass "missing skills dir exits 2"; else fail "missing skills dir must exit 2 (rc=$RC)"; fi
case "$ERR" in *"$SBX/nope"*) pass "missing skills dir message names the path" ;; *) fail "message must name the path. err: $ERR" ;; esac

run --skills-dir "$SK" --evals-dir "$SBX/nope"
if [ "$RC" -eq 2 ]; then pass "missing evals dir exits 2"; else fail "missing evals dir must exit 2 (rc=$RC)"; fi

mkdir -p "$SBX/empty-evals"
run --skills-dir "$SK" --evals-dir "$SBX/empty-evals"
if [ "$RC" -eq 2 ]; then pass "evals dir with no cases exits 2"; else fail "evals dir with no cases must exit 2 (rc=$RC)"; fi

run --bogus
if [ "$RC" -eq 2 ]; then pass "unknown argument exits 2"; else fail "unknown argument must exit 2 (rc=$RC)"; fi

run --skills-dir
if [ "$RC" -eq 2 ]; then pass "flag without a value exits 2"; else fail "flag without a value must exit 2 (rc=$RC)"; fi

mkdir -p "$SBX/nopy"
RC=0
OUT="$(PATH="$SBX/nopy" "$BASH" "$EL" "${ARGS[@]}" 2>"$SBX/err")" || RC=$?
ERR="$(cat "$SBX/err")"
if [ "$RC" -eq 2 ]; then pass "missing python3 exits 2"; else fail "missing python3 must exit 2 (rc=$RC, err: $ERR)"; fi
case "$ERR" in *python3*) pass "missing python3 message names python3" ;; *) fail "message must name python3. err: $ERR" ;; esac

# --- 5. real repo: deterministic run over the tracked evals/ and skills ------------
# Reads only tracked files (evals/<case>/, .claude/skills/), never the
# gitignored evals/results/, so it runs the same locally and in CI.
RC=0
OUT="$(cd "$REPO_ROOT" && bash "$EL" --json 2>"$SBX/err")" || RC=$?
ERR="$(cat "$SBX/err")"
if [ "$RC" -eq 0 ]; then pass "real repo run exits 0"; else fail "real repo run must exit 0 (rc=$RC, err: $ERR)"; fi
real_skills=0
for f in "$REPO_ROOT"/.claude/skills/*/SKILL.md; do [ -f "$f" ] && real_skills=$((real_skills + 1)); done
expect_py "real repo: skills_total matches .claude/skills/*/SKILL.md" 'd["skills_total"]' "$real_skills"
expect_py "real repo: covered + uncovered = all skills" 'len(d["covered"]) + len(d["uncovered"]) == d["skills_total"]' "True"
expect_py "real repo: at least one case" 'd["cases_total"] > 0' "True"

echo
if [ "$fails" -eq 0 ]; then
  echo "All eval-coverage tests passed."
  exit 0
fi
echo "$fails eval-coverage coverage test(s) failed."
exit 1
