# Deterministic Fixtures

Each `*.json` fixture in this directory describes a deterministic input → expected-outcome pair. The runner at `scripts/run-fixtures.sh` dispatches on the fixture's `fixture_type` and applies the strongest deterministic check possible for that type — it does not execute Claude.

These fixtures complement the markdown pressure tests in `tests/pressure-tests/`:

- **Pressure tests** are adversarial scenarios — read by humans or replayed against a live agent to verify rationalization resistance.
- **Fixtures** are deterministic state → outcome pairs — checked by `validate-toolkit.sh` so behavior cannot drift silently.

## What each fixture type validates

| `fixture_type` | Runner check | What it does NOT check |
|---|---|---|
| `router-decision` (default when `workflow_type` is present) | JSON shape; `workflow_type`, gate names, and `next_action` against the documented vocabularies; cross-rules (`abort` ⇒ `failure_stop_gate: fail`; `advance_phase` ⇒ a gate is recorded). | The `rationale` **text** (only its presence/length) — that stays human review. |
| `handoff-validation` | Runs `scripts/validate-handoff.sh` against the fixture and asserts its declared `expected_exit` (0 = accepted, 1 = rejected). | The full drift report body — only the exit code contract is asserted. |
| `router-mapping` | Each case's `expected_skill` has a directory under `.claude/skills/`, and each case is grounded: a `/mtk` route-table keyword for that skill appears in the prompt, or a `note` documents a boundary/hook-routed case. | Whether a **live** `/mtk` invocation actually routes the prompt there — that is a pressure test / eval, not a structural fixture. |

Reported markers: `OK` (router-decision, handoff), `OK (structural)` (router-mapping). No fixture is silently skipped.

## Router-decision fixture shape

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

## Handoff-validation fixture shape

Carries `"fixture_type": "handoff-validation"`, a `success_criteria` array (each entry may carry an `evidence_channel`), and a declared `"expected_exit"` (`0` = `validate-handoff.sh` must accept, `1` = must reject). The runner executes `scripts/validate-handoff.sh <fixture>` and fails unless the exit code matches `expected_exit`.

## Router-mapping fixture shape

Carries `"fixture_type": "router-mapping"` and a `cases` array. Each case is `{ "prompt": "...", "expected_skill": "<skill-dir>", "note": "optional" }`. The runner asserts the skill directory exists and the mapping is grounded in the `/mtk` route table (or a `note` documents a boundary / hook-routed case). It does not invoke the live router.

## How to add a fixture

1. Pick a real decision the orchestrator makes inside `/mtk implement`.
2. Write the input state in JSON. Keep `agent_outputs` minimal — only the fields that drive the decision.
3. State the `expected.next_action` and which gate (if any) flips.
4. Add a one-sentence `rationale` referencing the rule.
5. Run `bash scripts/run-fixtures.sh` and confirm it passes.

## When fixtures fail

If `run-fixtures.sh` fails after a refactor, the orchestrator's rules likely changed. Either the fixture is stale (update it) or the change is unintentional (revert). Do not silence failures — they are how this toolkit detects orchestrator drift.
