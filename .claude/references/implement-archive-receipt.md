---
description: Phase 7.5 archive detail for implement — delta sync-back procedure and the opt-in tracked run receipt field list
globs: []
alwaysApply: false
---
# Phase 7.5 Archive — delta sync-back and the opt-in run receipt

> Extracted from `.claude/skills/implement/SKILL.md` (S2.26: a SKILL.md is a
> navigation layer, not a payload). The skill keeps the decision — when this
> fires, what it outputs, and what stops the run. This file holds the detail,
> and is read **only** when that phase is actually reached.

---

## Phase 7.5: Archive (Delta Sync-Back)

If the spec sidecar declares a `baseline_area`, sync the delta back into its
baseline now — but **only** if Phase 3.5 drift returned a clean PASS and Phase 4
review found no open Critical issues. This produces the auditable
specified-vs-built trail (see `.claude/references/delta-spec-model.md`).

```bash
bash scripts/spec-archive.sh docs/specs/<date>-<slug>.json --verdict PASS
```

- Merges the change manifest / public contracts (or explicit `delta`) into
  `docs/specs/baseline/<area>.json`, regenerates `<area>.md`, and appends one
  record to `<area>.audit.jsonl`.
- If `CODE_INDEX.md` exists at the repo root, the archive also appends newly
  shipped public contracts to its auto-generated "Recently Shipped" section —
  the capability index stays current without a separate audit pass.
- Idempotent — safe to re-run on resume.
- Skip (with a one-line note) when the spec has no `baseline_area`, or when drift
  did not pass. Never archive drifted work.

### Run receipt (opt-in, tracked)

The workflow artifact and its evidence logs live under `.mtk/`, which is
gitignored: after the session, the only tracked residue of a run is whatever
landed in `tasks/lessons.md` and the spec itself. That is fine for most runs and
wrong for the ones someone will ask about later — an audited change, a release, a
run whose numbers end up in a report.

When `MTK_RUN_RECEIPT=1`, write `docs/specs/<date>-<slug>.receipt.md` — a tracked
sibling of the spec — containing only facts already recorded on the artifact:

- base commit and the Phase 2.9 `baseline` (with `known_failures` named as inherited)
- the final evidence figures, **as a delta against that baseline**
- every gate and its recorded reason, including any standing approval and its `gate_scope`
- `dispatch_capability`, the Phase 3 path actually taken, and any compensations applied
- ceremony reductions, each with its reason — and whether Phase 7 escalated a repeat
- Phase 3.5 drift verdict, coverage-claim re-greps, fired `conditional_descopes`, collateral verdict
- reviewer lanes with one outcome each (`PASS` / `NEEDS_CHANGES` / `ABSTAINED` / `NO_RESPONSE`)

Copy figures from the recorded evidence; never re-derive a number by counting at
write time. A receipt that quietly disagrees with the logs it summarises is worse
than none, so if a field was never recorded, write `not recorded` rather than
reconstructing it.
