#!/usr/bin/env bash

set -euo pipefail

# run-fixtures.sh — validate the deterministic fixtures under tests/fixtures/.
#
# Each fixture carries a fixture_type. This runner dispatches on it and applies
# the strongest deterministic check possible for that type — no fixture is
# silently skipped:
#
#   router-decision  (default when workflow_type present) — structural + rule check:
#     1. Parses as JSON and matches the documented shape.
#     2. workflow_type is BUILD|DEBUG|REVIEW|PLAN|FIX.
#     3. Every gate in input.gates / expected.gate_to_record is one of the four
#        gates from .claude/references/orchestration-gates.md (input.gates may
#        also carry the dropped skill_precedence_gate, as old artifacts do).
#     4. expected.next_action is one of the documented actions.
#     5. Cross-rules:
#        - next_action=="abort"          → gate_to_record=="failure_stop_gate: fail".
#        - next_action=="advance_phase"  → a gate MUST be recorded (gate_to_record
#                                          non-null).
#        - input.env.MTK_AUTO_PROCEED=="1" at phase-2 → the canonical AUTO_PROCEED
#          preconditions are evaluated from agent_outputs (missing input fails
#          closed): all hold ⇒ advance_phase + plan_trust_gate pass; else no advance.
#     6. Once per run: the AUTO_PROCEED list in implement-approval-gate.md has as
#        many bullets as the evaluator has conditions, none of them the dropped
#        skill_precedence_gate, and orchestration-gates.md keeps no second list.
#
#   handoff-validation — behavioral check: actually runs scripts/validate-handoff.sh
#     against the fixture and asserts its declared expected_exit (0 accept / 1 reject).
#
#   router-mapping — structural check: every case's expected_skill has a skill
#     directory under .claude/skills/, and each case is grounded in the /mtk route
#     table (a route-table keyword appears in the prompt) or documented as a
#     boundary/hook-routed case via a `note`.
#
# It does NOT run Claude or grade rationale text — that is human review.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIX_DIR="${ROOT_DIR}/tests/fixtures"

failures=0

# Skip if no fixtures yet (for forward compat in target repos).
if ! ls "${FIX_DIR}"/*.json >/dev/null 2>&1; then
  printf 'run-fixtures: no fixtures under %s — skipping.\n' "${FIX_DIR}"
  exit 0
fi

fixture_type() {
  python3 - "$1" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    print("__unparseable__"); sys.exit(0)
ft = doc.get("fixture_type")
if ft is None:
    ft = "router-decision" if "workflow_type" in doc else "__unknown__"
print(ft)
PY
}

check_router_decision() {
  python3 - "$1" <<'PY'
import json, sys, pathlib

VALID_GATES = {
    "plan_trust_gate", "phase_exit_gate", "failure_stop_gate",
    "memory_sync_gate"
}
# Dropped gate: still accepted in input.gates (old artifacts carry it), never
# as a gate to record.
LEGACY_GATES = {"skill_precedence_gate"}
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
        if gate not in VALID_GATES | LEGACY_GATES:
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

# Cross-rule: advance_phase must record a gate (header rule 5).
if action == "advance_phase":
    if g2r is None:
        print(f"FAIL: {path}: next_action=advance_phase requires a recorded gate (expected.gate_to_record must not be null)", file=sys.stderr); sys.exit(1)

# Cross-rule: MTK_AUTO_PROCEED at the Phase 2.5 approval gate. Evaluates the
# canonical precondition list (.claude/references/implement-approval-gate.md)
# against agent_outputs; a missing input fails closed. All hold => the gate is
# defaulted (advance_phase + plan_trust_gate pass); any fails => never advance.
env = inp.get("env") or {}
if env.get("MTK_AUTO_PROCEED") == "1" and inp.get("phase_cursor") == "phase-2":
    ao = inp.get("agent_outputs") or {}
    def num(section, key):
        v = (ao.get(section) or {}).get(key)
        return v if isinstance(v, int) and not isinstance(v, bool) else None
    cls = ao.get("classification") or {}
    conditions = [
        num("spec_check", "open_decisions_count") == 0,
        num("spec_check", "assumed_count") == 0,
        num("plan_gap_reviewer", "blocking_count") == 0,
        num("planning", "package_checkpoints_open") == 0,
        cls.get("scope") not in (None, "breaking-change") and cls.get("security_impact") not in (None, "high"),
        cls.get("rigor_level") in ("LIGHT", "STANDARD"),
    ]
    if all(conditions):
        if action != "advance_phase" or g2r != "plan_trust_gate: pass":
            print(f"FAIL: {path}: every AUTO_PROCEED precondition holds, so expected advance_phase + 'plan_trust_gate: pass', got {action!r} / {g2r!r}", file=sys.stderr); sys.exit(1)
    elif action == "advance_phase":
        failed = [i + 1 for i, c in enumerate(conditions) if not c]
        print(f"FAIL: {path}: AUTO_PROCEED precondition(s) {failed} do not hold, so the gate must not advance", file=sys.stderr); sys.exit(1)

# Cross-rule: rationale must be present and non-trivial
rationale = exp.get("rationale", "")
if not isinstance(rationale, str) or len(rationale) < 20:
    print(f"FAIL: {path}: expected.rationale must be a non-trivial sentence", file=sys.stderr); sys.exit(1)

print(f"OK   {path.name}")
PY
}

check_handoff() {
  local f="$1"
  local name; name="$(basename "$f")"
  local want
  want="$(python3 - "$f" <<'PY'
import sys; sys.stdout.reconfigure(newline="\n")  # LF even on Windows python3: bash parses this output
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"__err__:{e}"); sys.exit(0)
ev = doc.get("expected_exit")
print(ev if ev is not None else "__missing__")
PY
)"
  case "$want" in
    0|1) : ;;
    __missing__) printf 'FAIL: %s: handoff-validation fixture must declare expected_exit (0 or 1)\n' "$name" >&2; return 1 ;;
    *) printf 'FAIL: %s: expected_exit must be 0 or 1, got %s\n' "$name" "$want" >&2; return 1 ;;
  esac

  local got=0
  bash "${ROOT_DIR}/scripts/validate-handoff.sh" "$f" >/dev/null 2>&1 || got=$?
  if [ "$got" -ne "$want" ]; then
    printf 'FAIL: %s: validate-handoff.sh exited %s, fixture declares expected_exit=%s\n' "$name" "$got" "$want" >&2
    return 1
  fi
  printf 'OK   %s (handoff-validation, exit %s)\n' "$name" "$got"
}

check_router_mapping() {
  python3 - "$1" "$ROOT_DIR" <<'PY'
import json, os, re, sys

path, root = sys.argv[1], sys.argv[2]
name = os.path.basename(path)
stem = os.path.splitext(name)[0]

try:
    doc = json.load(open(path))
except json.JSONDecodeError as e:
    print(f"FAIL: {name}: invalid JSON: {e}", file=sys.stderr); sys.exit(1)

if doc.get("id") != stem:
    print(f"FAIL: {name}: id={doc.get('id')!r} must match filename stem {stem!r}", file=sys.stderr); sys.exit(1)

cases = doc.get("cases")
if not isinstance(cases, list) or not cases:
    print(f"FAIL: {name}: router-mapping fixture must carry a non-empty 'cases' array", file=sys.stderr); sys.exit(1)

skills_dir = os.path.join(root, ".claude", "skills")

# Parse the /mtk route table: rows whose target column names a skill path.
# Build skill -> set of backtick-quoted keyword phrases from the pattern column.
route_targets = {}
ordered_rows = []  # (skill, [kw,...]) in route-table order, for first-match-wins precedence
mtk_path = os.path.join(skills_dir, "mtk", "SKILL.md")
try:
    mtk = open(mtk_path).read()
except OSError as e:
    print(f"FAIL: {name}: cannot read {mtk_path}: {e}", file=sys.stderr); sys.exit(1)

for line in mtk.splitlines():
    s = line.strip()
    if not s.startswith("|"):
        continue
    m = re.search(r"\.claude/skills/([a-z0-9-]+)/SKILL\.md", line)
    if not m:
        continue
    cols = [c.strip() for c in s.strip("|").split("|")]
    skill = m.group(1)
    kws = re.findall(r"`([^`]+)`", cols[0]) if cols else []
    kws_l = [k.lower() for k in kws]
    route_targets.setdefault(skill, set()).update(kws_l)
    ordered_rows.append((skill, kws_l))

errs = []
for c in cases:
    prompt = c.get("prompt", "")
    exp = c.get("expected_skill")
    note = c.get("note")
    if not exp:
        errs.append(f"case {prompt!r}: missing expected_skill")
        continue
    # A) target skill directory must exist.
    if not os.path.isdir(os.path.join(skills_dir, exp)):
        errs.append(f"case {prompt!r}: expected_skill {exp!r} has no directory under .claude/skills/")
        continue
    # B) routing claim must survive first-match-wins precedence, not just keyword membership.
    pl = prompt.lower()
    if exp in route_targets:
        actual = next((sk for sk, kws in ordered_rows if any(kw in pl for kw in kws)), None)
        if actual == exp:
            pass  # correct: the expected skill is the first route-table row that matches
        elif note:
            pass  # documented boundary the router resolves via disambiguation/ask — grounded by note
        else:
            hint = f"; first-match row routes to {actual!r}" if actual and actual != exp else ""
            errs.append(
                f"case {prompt!r}: claims route to {exp} but first-match-wins precedence "
                f"does not select it{hint} — reorder the route table or add a 'note'"
            )
    else:
        # Not a /mtk route target (e.g. hook-routed skill like correction-capture).
        # Require a note documenting why the mapping holds.
        if not note:
            errs.append(
                f"case {prompt!r}: {exp} is not a /mtk route target and no 'note' "
                f"documents the mapping"
            )

if errs:
    for e in errs:
        print(f"FAIL: {name}: {e}", file=sys.stderr)
    sys.exit(1)

print(f"OK (structural)   {name} (router-mapping, {len(cases)} cases: skills exist + grounded)")
PY
}

# The evaluator in check_router_decision and the canonical prose list must not
# drift apart: same number of preconditions, and no dropped gate in either doc.
check_auto_proceed_contract() {
  python3 - "$ROOT_DIR" <<'PY'
import os, re, sys
root = sys.argv[1]
EVALUATOR_CONDITIONS = 6
ref = os.path.join(root, ".claude", "references", "implement-approval-gate.md")
try:
    text = open(ref).read()
except OSError as e:
    print(f"FAIL: auto-proceed contract: cannot read {ref}: {e}", file=sys.stderr); sys.exit(1)
m = re.search(r"only when ALL of the following hold:\n\n((?:- .*\n)+)", text)
if not m:
    print("FAIL: auto-proceed contract: no 'only when ALL of the following hold:' bullet list in implement-approval-gate.md", file=sys.stderr); sys.exit(1)
bullets = [l for l in m.group(1).splitlines() if l.startswith("- ")]
if len(bullets) != EVALUATOR_CONDITIONS:
    print(f"FAIL: auto-proceed contract: implement-approval-gate.md lists {len(bullets)} preconditions, run-fixtures evaluates {EVALUATOR_CONDITIONS}", file=sys.stderr); sys.exit(1)
if any("skill_precedence_gate" in l for l in bullets):
    print("FAIL: auto-proceed contract: implement-approval-gate.md still lists skill_precedence_gate as a precondition", file=sys.stderr); sys.exit(1)
og = open(os.path.join(root, ".claude", "references", "orchestration-gates.md")).read()
sec = og.split("## Interaction with `MTK_AUTO_PROCEED`", 1)
if len(sec) == 2 and re.search(r"^- ", sec[1].split("\n## ", 1)[0], re.M):
    print("FAIL: auto-proceed contract: orchestration-gates.md keeps its own precondition list; point to implement-approval-gate.md instead", file=sys.stderr); sys.exit(1)
print(f"OK   auto-proceed contract ({EVALUATOR_CONDITIONS} preconditions, canonical list in implement-approval-gate.md)")
PY
}

check_auto_proceed_contract || failures=$((failures + 1))

for f in "${FIX_DIR}"/*.json; do
  ft="$(fixture_type "$f")"
  case "$ft" in
    handoff-validation)
      check_handoff "$f" || failures=$((failures + 1)) ;;
    router-mapping)
      check_router_mapping "$f" || failures=$((failures + 1)) ;;
    router-decision)
      check_router_decision "$f" || failures=$((failures + 1)) ;;
    __unparseable__)
      printf 'FAIL: %s: not valid JSON\n' "$(basename "$f")" >&2
      failures=$((failures + 1)) ;;
    *)
      printf 'FAIL: %s: unknown fixture_type %s — add a handler in run-fixtures.sh\n' "$(basename "$f")" "$ft" >&2
      failures=$((failures + 1)) ;;
  esac
done

if [ "$failures" -ne 0 ]; then
  printf 'run-fixtures: %d fixture(s) FAILED.\n' "$failures" >&2
  exit 1
fi

printf 'run-fixtures: all fixtures OK.\n'
