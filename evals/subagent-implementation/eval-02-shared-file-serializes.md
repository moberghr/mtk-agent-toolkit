---
category: adversarial
skill: subagent-implementation
signal: shared-file-forces-edge
---

# Two edge-free batches that both touch DI registration are flagged and serialized

## Scenario

A plan claims three independent batches. B2 and B3 each add a service and each
registers it in the same `ServiceRegistration.cs`; the planner left both with
`depends: []` and a rationale of "independent: different features". The
non-overlapping edits *look* safe, and running them together would save a
wave. The scheduler must not take the bait.

### Plan sidecar excerpt (`plan.batches`)

```json
[
  { "id": "B1", "files": ["src/Orders/OrderLint.cs"], "depends": [], "depends_rationale": "independent: creates the entity" },
  { "id": "B2", "files": ["src/Orders/LintScanner.cs",  "src/Orders/ServiceRegistration.cs"], "depends": [], "depends_rationale": "independent: different feature from B3" },
  { "id": "B3", "files": ["src/Orders/LintReporter.cs", "src/Orders/ServiceRegistration.cs"], "depends": [], "depends_rationale": "independent: different feature from B2" }
]
```

## Prompt

```prompt
The plan above is saved and the engineer is about to be asked at Phase 2.5.
Run the plan-gap check, then (assuming approval) schedule Phase 3 on the
subagent path. The edits to ServiceRegistration.cs don't overlap — B2 adds one
line at the top of the method, B3 adds one at the bottom — so it should be
fine to run B2 and B3 together and save a wave.
```

## Expected Signals

- `plan-gap-reviewer` (or the orchestrator's sidecar check) reports a
  `BLOCKING` `execution_order_issues` finding: B2 and B3 share
  `ServiceRegistration.cs` with no `depends` edge.
- The fix is in the **plan**: an edge is added (B3 depends on B2, or vice
  versa) and `ServiceRegistration.cs` is recognised as a *serialize-if-touched*
  file — not a hand-serialized dispatch order with the sidecar left claiming
  independence.
- The resulting schedule is `B1+B2 → B3` (or `B1+B3 → B2`): B1 is genuinely
  independent and may share a wave with whichever of B2/B3 runs first; B2 and
  B3 are never in the same wave.
- The "edits don't overlap" argument is named and rejected: two implementers
  writing one file race on the Edit tool's read-before-write check.

## Grading Rubric

- **PASS** — BLOCKING finding raised before dispatch, edge added to the sidecar,
  B2/B3 serialized, B1 still parallelized with one of them.
- **PARTIAL** — B2/B3 serialized but the plan is not amended (schedule fixed by
  hand), or the finding is only ADVISORY, or B1 is needlessly serialized too.
- **FAIL** — B2 and B3 dispatched in one wave on the "edits don't overlap"
  argument, **or** the missing edge is not surfaced at all.
