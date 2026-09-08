---
category: positive
skill: subagent-implementation
signal: waves-from-depends
---

# Four independent middle batches run as one wave, capped at three

## Scenario

An approved plan has six batches. B1 creates a shared entity; B2–B5 each add
one handler that reads that entity, in four different files, with no file in
common; B6 wires all four into the endpoint. Rigor is HIGH (6 batches), so
Phase 3 takes the subagent path.

### Plan sidecar excerpt (`plan.batches`)

```json
[
  { "id": "B1", "files": ["src/Orders/OrderLint.cs"],            "depends": [], "depends_rationale": "independent: first batch, creates the entity" },
  { "id": "B2", "files": ["src/Orders/LintOnCreateHandler.cs"],  "depends": ["B1"] },
  { "id": "B3", "files": ["src/Orders/LintOnUpdateHandler.cs"],  "depends": ["B1"] },
  { "id": "B4", "files": ["src/Orders/LintOnCancelHandler.cs"],  "depends": ["B1"] },
  { "id": "B5", "files": ["src/Orders/LintReportQuery.cs"],      "depends": ["B1"] },
  { "id": "B6", "files": ["src/Orders/OrdersEndpoints.cs"],      "depends": ["B2", "B3", "B4", "B5"] }
]
```

## Prompt

```prompt
Phase 2.5 answered "Approve & run until done". Run Phase 3 for the plan above
on the subagent path. Active tech stack: dotnet. MTK_BATCH_WAVE_MAX is unset.
```

## Expected Signals

- The schedule is stated before the first dispatch and matches the topological
  levels: B1 alone (level 0); B2, B3, B4, B5 at level 1; B6 at level 2.
- Level 1 has four batches but the cap is 3, so it is **split**: one wave of
  three, then a wave of one — `B1 → B2+B3+B4 → B5 → B6` (the order within the
  split may differ; the sizes 1/3/1/1 may not).
- Same-wave batches are dispatched in **one** message (one `Agent` call per
  batch, or one `parallel()` in the workflow script); the next wave starts only
  after every result in the current wave passed the build/test gate.
- Per-batch `agent_dispatched` / `agent_returned` land on the workflow artifact
  (directly, or replayed with `--ts` from the workflow results), so the receipt's
  per-batch timing is not `not recorded`.
- The drift micro-check runs once per wave over the union of the wave's files.

## Grading Rubric

- **PASS** — schedule stated and correct, level 1 split to honour the cap,
  waves dispatched concurrently and gated between, timing events recorded.
- **PARTIAL** — correct waves but level 1 run as a single wave of four, or
  waves run concurrently but no schedule stated, or timing events missing.
- **FAIL** — all six batches run sequentially despite the `depends` arrays
  proving B2–B5 independent, **or** B6 dispatched before every level-1 batch
  returned, **or** any two batches with a shared file placed in one wave.
