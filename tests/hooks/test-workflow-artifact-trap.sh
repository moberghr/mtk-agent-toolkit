#!/usr/bin/env bash
set -euo pipefail

# workflow-artifact.sh `trap add` / `trap list` — the carried trap list.
#
# WHY. A 2026-09 six-phase field run found that a written list of gotchas,
# hand-carried from each phase's report into the next brief, was the one
# mechanism that demonstrably worked (zero repair cycles in the final phase) —
# and that it survived only because the driver remembered to paste it. Persisted
# on the workflow artifact it survives compaction, crash, and handoff.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WFA="$REPO_ROOT/scripts/workflow-artifact.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'PASS: %s\n' "$1"; }

PROJ="$(mktemp -d -t mtk-trap-XXXXXX)"
trap 'rm -rf "$PROJ"' EXIT
( cd "$PROJ" && git init -q . )
export CLAUDE_PROJECT_DIR="$PROJ"

( cd "$PROJ" && bash "$WFA" init BUILD --goal "trap test" >/dev/null )
UUID="$(basename "$(ls "$PROJ"/.mtk/workflows/*.json | head -1)" .json)"
[ -n "$UUID" ] || fail "init produced no artifact"

# 1. add → id printed, persisted, event logged.
tid="$(cd "$PROJ" && bash "$WFA" trap add "$UUID" --title "OpenAPI spec goes stale" --body "Regenerate from a running API each phase" --phase phase-1 --severity high)"
[ "$tid" = "trap-001" ] || fail "first trap id should be trap-001, got $tid"
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
t=d["results"]["trap_list"]
assert len(t)==1 and t[0]["title"]=="OpenAPI spec goes stale" and t[0]["severity"]=="high" and t[0]["phase"]=="phase-1", t
' "$PROJ/.mtk/workflows/$UUID.json" || fail "trap not persisted in results.trap_list"
grep -q '"type": *"trap_added"' "$PROJ/.mtk/workflows/$UUID.events.jsonl" || grep -q 'trap_added' "$PROJ/.mtk/workflows/$UUID.events.jsonl" || fail "no trap_added event logged"
ok "trap add persists the trap and logs trap_added"

# 2. list renders severity, title, phase, body.
out="$(cd "$PROJ" && bash "$WFA" trap list "$UUID")"
grep -q '^- \[HIGH\] OpenAPI spec goes stale (from phase-1)$' <<<"$out" || fail "list line wrong: $out"
grep -q '^  Regenerate from a running API each phase$' <<<"$out" || fail "list body missing: $out"
ok "trap list renders the carried list"

# 3. Same title again → refreshed in place, not duplicated; id stable.
tid2="$(cd "$PROJ" && bash "$WFA" trap add "$UUID" --title "OpenAPI spec goes stale" --body "updated body" --severity warn)"
[ "$tid2" = "trap-001" ] || fail "re-adding same title should return trap-001, got $tid2"
n="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["results"]["trap_list"]))' "$PROJ/.mtk/workflows/$UUID.json")"
[ "$n" -eq 1 ] || fail "duplicate title stacked a second entry ($n)"
grep -q 'updated body' "$PROJ/.mtk/workflows/$UUID.json" || fail "re-add did not refresh the body"
ok "trap add is idempotent by title"

# 4. Validation: missing title and bad severity fail non-zero.
( cd "$PROJ" && bash "$WFA" trap add "$UUID" --body "no title" >/dev/null 2>&1 ) && fail "missing --title accepted"
( cd "$PROJ" && bash "$WFA" trap add "$UUID" --title "x" --severity critical >/dev/null 2>&1 ) && fail "bad severity accepted"
( cd "$PROJ" && bash "$WFA" trap bogus "$UUID" >/dev/null 2>&1 ) && fail "unknown trap action accepted"
ok "trap add validates title, severity, and action"

# 5. Batch ride-along: trap add as one op beside an event, in one call.
( cd "$PROJ" && bash "$WFA" batch "$UUID" trap add --title "SQLite decimal is TEXT" --severity warn -- event phase_completed --data '{"phase":"phase-1"}' >/dev/null ) \
  || fail "batch with a trap op exited non-zero"
n="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["results"]["trap_list"]))' "$PROJ/.mtk/workflows/$UUID.json")"
[ "$n" -eq 2 ] || fail "batch trap op did not add the second trap ($n)"
grep -q 'phase_completed' "$PROJ/.mtk/workflows/$UUID.events.jsonl" || fail "batch sibling event not logged"
out="$(cd "$PROJ" && bash "$WFA" trap list "$UUID")"
grep -q 'SQLite decimal is TEXT' <<<"$out" || fail "second trap missing from list"
ok "trap add rides along in a batch call"

# 6. Empty list is explicit, not blank.
( cd "$PROJ" && bash "$WFA" init BUILD --goal "empty" >/dev/null )
U2="$(basename "$(ls -t "$PROJ"/.mtk/workflows/*.json | head -1)" .json)"
out="$(cd "$PROJ" && bash "$WFA" trap list "$U2")"
[ "$out" = "(no traps recorded)" ] || fail "empty list should say so, got: $out"
ok "empty trap list is explicit"

echo "test-workflow-artifact-trap: all checks passed"
