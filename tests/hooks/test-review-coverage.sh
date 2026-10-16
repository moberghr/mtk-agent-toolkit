#!/usr/bin/env bash
set -euo pipefail

# review-coverage.sh: a lane result must account for every changed file
# (no_issues U skipped U findings == changed set) and, when candidates are
# passed, dispose of each one with outcome, reason and cited file:line.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COV="$REPO_ROOT/scripts/review-coverage.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
cd "$SANDBOX"

printf 'a.sh\nb.sh\n\nc.md\n' > changed.txt

fail() { echo "FAIL: $1" >&2; exit 1; }

# run <expected-exit> <label> <args...>; output lands in $OUT
OUT=""
run() {
  local want="$1" label="$2" rc=0
  shift 2
  OUT="$(bash "$COV" "$@" 2>&1)" || rc=$?
  [ "$rc" -eq "$want" ] || fail "$label: expected exit $want, got $rc ($OUT)"
}
expect_out() {
  case "$OUT" in
    *"$2"*) ;;
    *) fail "$1: output missing '$2' ($OUT)" ;;
  esac
}

cat > complete.json <<'EOF'
{"verdict":"PASS","coverage":{"no_issues":["a.sh","b.sh"],"skipped":[{"file":"c.md","reason":"docs only"}]},"findings":[]}
EOF
run 0 "complete" complete.json changed.txt

cat > missing.json <<'EOF'
{"verdict":"PASS","coverage":{"no_issues":["a.sh"],"skipped":[{"file":"c.md","reason":"docs"}]},"findings":[]}
EOF
run 1 "missing file" missing.json changed.txt
expect_out "missing file" "b.sh"

cat > extra.json <<'EOF'
{"verdict":"PASS","coverage":{"no_issues":["a.sh","b.sh","zzz.sh"],"skipped":[{"file":"c.md","reason":"docs"}]},"findings":[]}
EOF
run 1 "extra file" extra.json changed.txt
expect_out "extra file" "zzz.sh"

cat > findings.json <<'EOF'
{"verdict":"NEEDS_CHANGES","coverage":{"no_issues":["a.sh"],"skipped":[{"file":"c.md","reason":"docs"}]},"findings":[{"id":"F001","file":"b.sh","line":3}]}
EOF
run 0 "file covered by a finding" findings.json changed.txt

cat > noreason.json <<'EOF'
{"verdict":"PASS","coverage":{"no_issues":["a.sh","b.sh"],"skipped":[{"file":"c.md","reason":""}]},"findings":[]}
EOF
run 1 "skipped without reason" noreason.json changed.txt

cat > nocov.json <<'EOF'
{"verdict":"PASS","findings":[]}
EOF
run 1 "coverage missing" nocov.json changed.txt
expect_out "coverage missing" "coverage"

printf '{not json' > bad.json
run 2 "unparseable" bad.json changed.txt

run 2 "usage" complete.json

cat > abstained.json <<'EOF'
{"verdict":"ABSTAINED","abstention":{"reason":"incomplete: x","stage":"review","checked":[]}}
EOF
run 0 "abstained" abstained.json changed.txt
expect_out "abstained" "ABSTAINED"

cat > cands.json <<'EOF'
[{"candidate_id":"C1","file":"a.sh","line":1,"source":"linter","rule":"R","message":"m"},
 {"candidate_id":"C2","file":"b.sh","line":2,"source":"secret-scan","rule":"R","message":"m"}]
EOF
cat > disposed.json <<'EOF'
{"verdict":"PASS","coverage":{"no_issues":["a.sh","b.sh","c.md"],"skipped":[]},"findings":[],
 "candidates_disposed":[
  {"candidate_id":"C1","outcome":"dropped","reason":"test fixture","cited":"a.sh:1"},
  {"candidate_id":"C2","outcome":"raised","reason":"real","cited":"b.sh:2"}]}
EOF
run 0 "candidates disposed" disposed.json changed.txt --candidates cands.json

cat > undisposed.json <<'EOF'
{"verdict":"PASS","coverage":{"no_issues":["a.sh","b.sh","c.md"],"skipped":[]},"findings":[],
 "candidates_disposed":[{"candidate_id":"C1","outcome":"dropped","reason":"fixture","cited":"a.sh:1"}]}
EOF
run 1 "candidate missing" undisposed.json changed.txt --candidates cands.json
expect_out "candidate missing" "C2"

cat > nocited.json <<'EOF'
{"verdict":"PASS","coverage":{"no_issues":["a.sh","b.sh","c.md"],"skipped":[]},"findings":[],
 "candidates_disposed":[
  {"candidate_id":"C1","outcome":"dropped","reason":"fixture"},
  {"candidate_id":"C2","outcome":"raised","reason":"real","cited":"b.sh:2"}]}
EOF
run 1 "disposition without cited" nocited.json changed.txt --candidates cands.json
expect_out "disposition without cited" "C1"

echo "review-coverage tests passed"
