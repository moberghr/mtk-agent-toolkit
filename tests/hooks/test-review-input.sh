#!/usr/bin/env bash
set -euo pipefail

# workflow-artifact.sh review-input binds a review to the tree it read (R6).
# --record stores hook-io's mtk_tree_fingerprint; --check recomputes it against
# the recorded base and exits 0 unchanged, 1 changed, 2 nothing recorded or not
# computable. A tracked edit or a new untracked, non-ignored file is a change;
# a write under .mtk/ (MTK's own state) and committing the reviewed tree are not.
#
# Every case runs against a mktemp -d sandbox git repo: CLAUDE_PROJECT_DIR and
# TMPDIR point into it, so the real repo's tree and .mtk/ state are never read.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WF="$REPO_ROOT/scripts/workflow-artifact.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/proj" "$SANDBOX/tmp"
PROJ="$SANDBOX/proj"
export CLAUDE_PROJECT_DIR="$PROJ"
export TMPDIR="$SANDBOX/tmp"
unset CLAUDE_PLUGIN_ROOT 2>/dev/null || true
cd "$PROJ"

g() { git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@"; }
g init -q .
printf 'ignored.log\n' > .gitignore
printf 'one\n' > tracked.txt
mkdir -p src && printf 'echo hi\n' > src/app.sh
g add -A && g commit -q -m init

fails=0
pass() { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1" >&2; fails=$((fails + 1)); }

# check <expected-rc> <label>: run --check, compare its exit code.
check() {
  local want="$1" label="$2" rc=0 out
  out="$("$WF" review-input "$U" --check 2>&1)" || rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$label (exit $rc)"; else bad "$label: expected exit $want, got $rc — $out"; fi
  LAST_OUT="$out"
}

echo "=== review-input (R6) ==="
U="$("$WF" init BUILD --goal "review-input test" | tail -1)"

echo ""
echo "--- nothing recorded ---"
check 2 "--check before --record is uncheckable"

echo ""
echo "--- error paths exit 2, never 1 (1 means the tree changed) ---"
rc=0; out="$("$WF" review-input "wf-does-not-exist" --check 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && pass "missing artifact exits 2" || bad "missing artifact: expected exit 2, got $rc — $out"
UC="$("$WF" init BUILD --goal "corrupt artifact" | tail -1)"
"$WF" review-input "$UC" --record >/dev/null
printf '{not json' > ".mtk/workflows/$UC.json"
rc=0; out="$("$WF" review-input "$UC" --check 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && pass "corrupt artifact JSON exits 2 (--check)" || bad "corrupt artifact --check: expected exit 2, got $rc — $out"
rc=0; out="$("$WF" review-input "$UC" --record 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && pass "corrupt artifact JSON exits 2 (--record)" || bad "corrupt artifact --record: expected exit 2, got $rc — $out"

echo ""
echo "--- record then check ---"
rec="$("$WF" review-input "$U" --record)"
case "$rec" in "review-input: recorded "[0-9a-f]*" "[0-9a-f]*) pass "--record prints the fingerprint" ;; *) bad "--record output: $rec" ;; esac
python3 - ".mtk/workflows/$U.json" <<'PY' && pass "results.review.input_fingerprint + recorded_at stored" || bad "results.review not stored as '<base> <hash>' + recorded_at"
import json, re, sys
r = json.load(open(sys.argv[1]))["results"]["review"]
assert re.fullmatch(r"[0-9a-f]{40} [0-9a-f]{40}", r["input_fingerprint"]), r
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", r["recorded_at"]), r
PY
grep -q '"event":"review_input_recorded"' ".mtk/workflows/$U.events.jsonl" \
  && pass "review_input_recorded event logged" || bad "no review_input_recorded event"
check 0 "unchanged tree"

echo ""
echo "--- tracked edit ---"
printf 'two\n' > tracked.txt
check 1 "edit to a tracked file"
case "$LAST_OUT" in *"recorded="*"current="*) pass "changed output names recorded= and current=" ;; *) bad "changed output lacks recorded=/current=: $LAST_OUT" ;; esac
printf 'one\n' > tracked.txt
check 0 "edit reverted"

echo ""
echo "--- untracked files ---"
printf 'new\n' > src/new.sh
check 1 "new untracked, non-ignored file"
rm src/new.sh
printf 'noise\n' > ignored.log
check 0 "new gitignored file"

echo ""
echo "--- .mtk/ writes ---"
mkdir -p .mtk/other && printf 'state\n' > .mtk/other/x.json
"$WF" event "$U" phase_started --data '{"phase":"phase-4"}' >/dev/null
check 0 "write under .mtk/ (not gitignored here)"

echo ""
echo "--- commit of the reviewed tree ---"
printf 'reviewed change\n' >> src/app.sh
"$WF" review-input "$U" --record >/dev/null
g add -- . ':(exclude).mtk' && g commit -q -m "reviewed change"
check 0 "committing exactly the reviewed tree"
printf 'post-review edit\n' >> src/app.sh
check 1 "edit after that commit"
git checkout -q -- src/app.sh
check 0 "post-review edit reverted"

echo ""
echo "--- root agreement: cwd in a subdirectory ---"
(cd src && "$WF" review-input "$U" --check >/dev/null) \
  && pass "--check from a subdirectory resolves the same root" || bad "--check from src/ did not report unchanged"

echo ""
echo "--- not a git work tree ---"
mkdir -p "$SANDBOX/nogit"
rc=0
(export CLAUDE_PROJECT_DIR="$SANDBOX/nogit"; cd "$SANDBOX/nogit" \
  && U2="$("$WF" init BUILD | tail -1)" && "$WF" review-input "$U2" --record) >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "--record outside git exits 2" || bad "--record outside git: expected exit 2, got $rc"

echo ""
echo "--- hook-io.sh absent ---"
mkdir -p "$SANDBOX/lone/scripts"
cp "$WF" "$SANDBOX/lone/scripts/workflow-artifact.sh"
rc=0; out="$("$SANDBOX/lone/scripts/workflow-artifact.sh" review-input "$U" --record 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then
  case "$out" in *"hook-io.sh not found"*) pass "missing hook-io exits 2 with a clear message" ;; *) bad "missing hook-io message unclear: $out" ;; esac
else
  bad "missing hook-io: expected exit 2, got $rc — $out"
fi
"$SANDBOX/lone/scripts/workflow-artifact.sh" read "$U" >/dev/null \
  && pass "other subcommands do not depend on hook-io" || bad "read failed without hook-io"

echo ""
echo "--- bad usage ---"
rc=0; "$WF" review-input "$U" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "mode is required (exit 2)" || bad "review-input without a mode: expected exit 2, got $rc"

echo ""
echo "========================================"
if [ "$fails" -gt 0 ]; then
  echo "TEST FAILED — $fails review-input assertion(s) failed"
  exit 1
fi
echo "TEST PASSED — review-input binds the review to its tree"
