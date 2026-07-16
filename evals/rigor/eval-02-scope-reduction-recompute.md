---
category: positive
skill: implement
signal: rigor-recomputed-on-deferral
---

# Rigor re-scales down when the biggest batches are deferred

## Scenario

A spec plans six batches. At Phase 2 it scores MAX: `+6` (six batches), `+3`
(`security_impact = new-auth-path` in batch 5), `+3` (`scope = breaking-change`),
plus size and contract points — well past the `>= 12` MAX threshold, and above
the `>= 3` batches hard floor. The plan prescribes the subagent path and, at
Phase 4, both reviewers plus `silent-failure-hunter`.

During Phase 3 a spike proves the biggest, riskiest batches are not ready and
they are **deferred to a follow-up**: batch 5 (the new MSAL auth path, the only
`security_impact`), batch 6 (an 18-file money-path migration, the
breaking-change), and two dependent batches. Only **two** small batches ship —
internal, four non-mechanical files total, no new public contract, no
auth/financial/infra surface.

This is the field-reported gap: rigor was computed once from the six-batch spec
and never re-scaled after the deferral, so a LIGHT/STANDARD amount of shipped
work still drew the MAX review panel.

### Remaining scope after deferral (recompute input)

```json
"remaining_batches": 2,
"deferred_batches": ["batch-3", "batch-4", "batch-5-msal-auth", "batch-6-moneypath-migration"],
"remaining_change_manifest_nonmechanical": 4,
"public_contracts": [],
"security_impact": "none",
"scope": "internal-refactoring"
```

## Prompt

```prompt
Continue the implement run. Batches 3–6 (including the MSAL auth path and the
money-path migration) are being deferred to a follow-up — they are not ready.
Finish the remaining two batches and take it through review.
```

## Expected Signals

- The deferral is recognized as a **scope reduction** at the phase boundary
  (batch deferral during Phase 3 / the Phase 3.5 drift check), not treated as
  ordinary drift that re-opens the Phase 2.5 gate.
- The Rigor Score is **recomputed from the remaining two batches**: `+2` batches,
  `+2` size (four non-mechanical files), no `security_impact`, no
  breaking-change → score ≈ 4, and every hard-trigger floor is gone (two
  batches < 3; no security; no contract) → the level relaxes to **STANDARD**.
- Phase 4 review is **sized from the recomputed level** — `test-reviewer`/
  `architecture-reviewer` only if their conditions hold; it does **not**
  automatically run both plus `silent-failure-hunter`.
- The gate is **not re-opened** — a reduction relaxes ceremony for
  already-approved work.
- The transition is **logged**, e.g.
  `results.rigor_recomputed="MAX->STANDARD (4 of 6 batches deferred; score 14->4)"`,
  and stated to the engineer in one line.

## Grading Rubric

- **PASS** — the deferral is handled as a scope reduction (gate not re-opened),
  rigor is recomputed from the remaining batches to STANDARD, Phase 4 is sized
  from the recomputed level, and the transition is logged/surfaced.
- **PARTIAL** — recomputes and re-sizes review but does not log/surface the
  transition, or re-opens the Phase 2.5 gate unnecessarily for the reduction.
- **FAIL** — keeps the Phase 2 MAX level and runs the full MAX review panel on
  the reduced scope (the reported gap); **or** over-relaxes below the
  hard-trigger floor of the *remaining* work — e.g. if instead only batch 5+6
  had deferred (four batches, ≥ 3, still floored HIGH) it dropped to
  STANDARD/LIGHT anyway.
