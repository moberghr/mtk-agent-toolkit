# Grader: rigor (implement Rigor Score)

You are grading whether `implement`'s Rigor Score sizes ceremony *proportionally*.
Two behaviors are covered by this eval set — grade whichever the scenario targets
(read its `signal`):

- **`mechanical-discount-applied`** — ceremony is sized from the count of
  **non-mechanical** `change_manifest` entries, so a batch of purely mechanical
  edits (renames, formatting, generated, no-behavioral-change) is not
  force-escalated to HIGH, while an entry that touches a public contract is never
  discounted.
- **`rigor-recomputed-on-deferral`** — when the approved batch set shrinks
  mid-run (a batch is deferred/dropped), the level is **recomputed from the
  remaining batches** and Phase 4 review is sized from the recomputed level; the
  recompute only relaxes, never below the hard-trigger floor of the remaining
  work, and a reduction does not re-open the Phase 2.5 gate.

## Grading Process

1. Parse the eval's `category`.
2. Read the scenario and its Expected Signals.
3. Verify from the actual output:
   - Each rename-only entry (no logic, no public contract) is tagged
     `mechanical: true`.
   - The **non-mechanical** entry count drives the `>= 6` hard-trigger floor —
     an all-mechanical six-file batch does NOT fire the floor.
   - The size score adds +1 per 3 *non-mechanical* files, so an all-mechanical
     batch contributes +0 and the level stays LIGHT/STANDARD.
   - The Phase 2.5 gate line surfaces the mechanical split
     (e.g. `... — 6 files, 6 mechanical`).
   - The mechanical edits are still implemented and verified.
4. Return PASS / PARTIAL / FAIL per the rubric in the eval.

## Output Format

```
VERDICT: PASS | PARTIAL | FAIL
EVIDENCE:
- <signal>: present | missing | wrong (<quote from output>)
RATIONALE: <one sentence>
```

## Key Signals

- **False floor** — force-escalating to HIGH on the raw six-file count instead of
  the non-mechanical count → FAIL.
- **Silent discount** — applying the mechanical discount without surfacing the
  split on the gate line (the engineer must be able to veto it) → PARTIAL.
- **Over-discount** — tagging an entry `mechanical: true` when it renames or
  otherwise changes a public contract (endpoint, handler, method, event, CLI
  flag) → FAIL. An entry touching any public contract is never mechanical.

Partial credit when the floor is correctly avoided but the mechanical split is
not surfaced, or fewer than all mechanical entries are tagged.

For `rigor-recomputed-on-deferral` scenarios:

- **Stale level** — keeping the Phase 2 level and running its full review panel
  on the reduced scope (never recomputing) → FAIL.
- **Over-relaxation** — dropping below the hard-trigger floor of the *remaining*
  batches (e.g. LIGHT/STANDARD while ≥ 3 batches still remain) → FAIL.
- **Gate churn** — re-opening the Phase 2.5 gate for a pure reduction → PARTIAL.
- **Silent re-score** — recomputing and re-sizing review but not logging/
  surfacing the transition → PARTIAL.
