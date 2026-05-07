# Router-Decision Fixtures

Each `*.json` fixture in this directory describes a deterministic input → expected-action pair for the `/mtk implement` orchestrator. The runner at `scripts/run-fixtures.sh` validates structure and asserts the orchestrator's documented decision rules — it does not execute Claude.

These fixtures complement the markdown pressure tests in `tests/pressure-tests/`:

- **Pressure tests** are adversarial scenarios — read by humans or replayed against a live agent to verify rationalization resistance.
- **Fixtures** are deterministic state → decision pairs — checked by `validate-toolkit.sh` so orchestrator rules cannot drift silently.

## Fixture shape

```json
{
  "id": "string — unique per file, matches the filename stem",
  "description": "one-line human summary",
  "workflow_type": "BUILD | DEBUG | REVIEW | PLAN | FIX",
  "input": {
    "phase_cursor": "phase-N",
    "gates": { "<gate_name>": "pending|pass|fail" },
    "agent_outputs": { },
    "engineer_choice": "approve_autonomous | approve_interactive | revise | edit_first | null"
  },
  "expected": {
    "next_action": "advance_phase | remediate | block | request_engineer | resume_existing | abort",
    "gate_to_record": "<gate_name>: pass|fail|null",
    "phase_cursor_after": "phase-N",
    "rationale": "one sentence — must match a rule in implement/SKILL.md or orchestration-gates.md"
  }
}
```

A fixture is **valid** if every `gate_to_record` names a real gate from `.claude/references/orchestration-gates.md` and the `phase_cursor_after` is consistent with `next_action`. Validation does NOT verify the rationale text — that is human review territory.

## How to add a fixture

1. Pick a real decision the orchestrator makes inside `/mtk implement`.
2. Write the input state in JSON. Keep `agent_outputs` minimal — only the fields that drive the decision.
3. State the `expected.next_action` and which gate (if any) flips.
4. Add a one-sentence `rationale` referencing the rule.
5. Run `bash scripts/run-fixtures.sh` and confirm it passes.

## When fixtures fail

If `run-fixtures.sh` fails after a refactor, the orchestrator's rules likely changed. Either the fixture is stale (update it) or the change is unintentional (revert). Do not silence failures — they are how this toolkit detects orchestrator drift.
