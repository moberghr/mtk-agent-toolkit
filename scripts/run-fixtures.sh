#!/usr/bin/env bash

set -euo pipefail

# run-fixtures.sh — validate router-decision fixtures under tests/fixtures/.
#
# This is a structural validator, not an agent runner. It asserts:
#   1. Each fixture parses as JSON and matches the documented shape.
#   2. workflow_type is BUILD|DEBUG|REVIEW|PLAN|FIX.
#   3. Every gate name in input.gates and expected.gate_to_record is one of the
#      five gates from .claude/references/orchestration-gates.md.
#   4. expected.next_action is one of the documented actions.
#   5. Cross-rules: if next_action=="advance_phase", a gate must be recorded;
#      if next_action=="abort", failure_stop_gate must be the recorded gate.
#
# It does NOT run Claude or check rationale text — that is human review.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIX_DIR="${ROOT_DIR}/tests/fixtures"

fail() {
  printf 'run-fixtures: FAIL: %s\n' "$1" >&2
  exit 1
}

# Skip if no fixtures yet (for forward compat in target repos).
if ! ls "${FIX_DIR}"/*.json >/dev/null 2>&1; then
  printf 'run-fixtures: no fixtures under %s — skipping.\n' "${FIX_DIR}"
  exit 0
fi

count=0
for f in "${FIX_DIR}"/*.json; do
  count=$((count + 1))
  python3 - "$f" <<'PY' || exit 1
import json, sys, pathlib

VALID_GATES = {
    "plan_trust_gate", "phase_exit_gate", "failure_stop_gate",
    "memory_sync_gate", "skill_precedence_gate"
}
VALID_ACTIONS = {
    "advance_phase", "remediate", "block", "request_engineer",
    "resume_existing", "abort"
}
VALID_TYPES = {"BUILD", "DEBUG", "REVIEW", "PLAN", "FIX"}
VALID_GATE_RESULTS = {"pending", "pass", "fail"}

path = pathlib.Path(sys.argv[1])
stem = path.stem

try:
    with open(path) as fh:
        doc = json.load(fh)
except json.JSONDecodeError as e:
    print(f"FAIL: {path}: invalid JSON: {e}", file=sys.stderr); sys.exit(1)

# id must match filename stem
if doc.get("id") != stem:
    print(f"FAIL: {path}: id={doc.get('id')!r} must match filename stem {stem!r}", file=sys.stderr); sys.exit(1)

wt = doc.get("workflow_type")
if wt not in VALID_TYPES:
    print(f"FAIL: {path}: workflow_type={wt!r} not in {sorted(VALID_TYPES)}", file=sys.stderr); sys.exit(1)

for required in ("description", "input", "expected"):
    if required not in doc:
        print(f"FAIL: {path}: missing top-level field '{required}'", file=sys.stderr); sys.exit(1)

inp = doc["input"]
if "gates" in inp:
    for gate, result in inp["gates"].items():
        if gate not in VALID_GATES:
            print(f"FAIL: {path}: input.gates has unknown gate {gate!r}", file=sys.stderr); sys.exit(1)
        if result not in VALID_GATE_RESULTS:
            print(f"FAIL: {path}: input.gates.{gate}={result!r} not in {sorted(VALID_GATE_RESULTS)}", file=sys.stderr); sys.exit(1)

exp = doc["expected"]
action = exp.get("next_action")
if action not in VALID_ACTIONS:
    print(f"FAIL: {path}: expected.next_action={action!r} not in {sorted(VALID_ACTIONS)}", file=sys.stderr); sys.exit(1)

# Gate-to-record format: "<gate_name>: pass|fail" or null
g2r = exp.get("gate_to_record", None)
if g2r is not None:
    if not isinstance(g2r, str) or ":" not in g2r:
        print(f"FAIL: {path}: expected.gate_to_record must be 'gate: pass|fail' or null, got {g2r!r}", file=sys.stderr); sys.exit(1)
    gate_name, _, result = g2r.partition(":")
    gate_name = gate_name.strip()
    result = result.strip()
    if gate_name not in VALID_GATES:
        print(f"FAIL: {path}: expected.gate_to_record names unknown gate {gate_name!r}", file=sys.stderr); sys.exit(1)
    if result not in {"pass", "fail"}:
        print(f"FAIL: {path}: expected.gate_to_record result {result!r} must be pass or fail", file=sys.stderr); sys.exit(1)

# Cross-rule: abort must be paired with failure_stop_gate fail
if action == "abort":
    if g2r != "failure_stop_gate: fail":
        print(f"FAIL: {path}: next_action=abort requires gate_to_record='failure_stop_gate: fail', got {g2r!r}", file=sys.stderr); sys.exit(1)

# Cross-rule: rationale must be present and non-trivial
rationale = exp.get("rationale", "")
if not isinstance(rationale, str) or len(rationale) < 20:
    print(f"FAIL: {path}: expected.rationale must be a non-trivial sentence", file=sys.stderr); sys.exit(1)

print(f"OK   {path.name}")
PY
done

printf 'run-fixtures: %d fixtures OK.\n' "$count"
