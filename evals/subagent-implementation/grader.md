# Grader: subagent-implementation (wave scheduling from `depends`)

You are grading whether the Phase 3 subagent path schedules batches into
**waves derived from the plan's `depends` edges** — running proven-independent
batches concurrently, never running two batches that share a file together,
and never exceeding the wave cap. Grade whichever signal the scenario names:

- **`waves-from-depends`** — batches at the same topological level (no
  ordering edge between them) are dispatched together in one wave; different
  levels run strictly in order; wave width never exceeds `MTK_BATCH_WAVE_MAX`
  (default 3); the schedule is stated before the first dispatch.
- **`shared-file-forces-edge`** — two batches whose `files` intersect but
  carry no `depends` edge are a `BLOCKING` plan-gap finding
  (`execution_order_issues`) and are **serialized** (edge added) before any
  dispatch; the orchestrator never "hand-serializes in the script" without
  fixing the plan, and never puts them in one wave.

## Grading Process

1. Parse the eval's `category` and `signal`.
2. Read the scenario's batch list and Expected Signals.
3. Verify from the actual output:
   - The stated schedule (e.g. `W0: B1 · W1: B2 B3 B4 · W2: B5 · W3: B6`)
     matches the topological levels of the given `depends` arrays.
   - No wave contains two batches whose `files` overlap.
   - No wave is wider than the cap (3 unless the scenario sets it).
   - For the shared-file scenario: the missing edge is surfaced as `BLOCKING`
     **before** dispatch and the plan sidecar is amended, not silently
     worked around.
   - `agent_dispatched` / `agent_returned` are recorded per batch (manual
     path) or replayed from `ts_dispatched` / `ts_returned` (workflow path).
4. Return PASS / PARTIAL / FAIL per the rubric in the eval.

## Output Format

```
VERDICT: PASS | PARTIAL | FAIL
EVIDENCE:
- <signal>: present | missing | wrong (<quote from output>)
RATIONALE: <one sentence>
```
