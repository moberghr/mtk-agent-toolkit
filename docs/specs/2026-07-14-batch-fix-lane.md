# Spec — Batch-Fix Workflow Lane

Date: 2026-07-14
Slug: batch-fix-lane
Scope: **new workflow lane + router wiring** (no breaking changes; additive)

> This documents the feature for the record. It is **not** the runtime spec stub
> the `batch-fix` skill produces — that stub is a short findings list written per
> invocation under `docs/specs/<date>-<slug>-batch.md`.

## Problem

There is a gap between the two existing corrective lanes:

- **`fix`** — 1-3 files, one coherent change, no formal spec. Self-escalates when
  scope grows.
- **`implement`** — new behavior / public contract / architecture, with the full
  apparatus: executable spec + JSON sidecar, `docs/plans/` plan, `tasks/todo.md`,
  a mandatory Phase 2.5 approval gate, and (at HIGH/MAX rigor) subagent-per-batch
  implementation with drift checks.

A **corrective batch** — "apply these 5 review findings", "fix these things" —
is several small, INDEPENDENT fixes that exceed `fix` (>3 files or multiple
distinct fixes) but introduce NO new public contract and need NO architectural
re-planning. Today such a batch falls through to `implement` and inherits its
full ceremony. `implement/SKILL.md` Critical Rule 6 makes the spec/plan/approval
apparatus mandatory at every rigor level, so a lightweight mode **cannot** live
inside `implement` — it has to be a sibling lane.

## Design (approved)

A new sibling skill `.claude/skills/batch-fix/SKILL.md` (`user-invocable: false`,
routed by `/mtk`), shaped like `fix` but allowing N independent findings. Fixed
lightness — proportional to a batch, not a feature:

| Dimension | batch-fix | (vs implement) |
|---|---|---|
| Spec | short findings-list **stub** (enumerated findings + one-line scope note) | full executable spec + JSON sidecar |
| Plan | none | `docs/plans/<date>-<slug>.md` |
| Todo | `tasks/todo.md` (one item per finding) | `tasks/todo.md` |
| Approval | **one** gate on the list; `MTK_AUTO_PROCEED`-eligible | Phase 2.5 gate |
| Execution | inline, per finding | inline or subagent-per-batch by rigor |
| TDD | per behavioral finding; skip mechanical | per behavior |
| Review | proportional — `pre-commit-review` always; specialized reviewers only when a finding crosses a boundary | two-stage, rigor-scaled |
| Verify | build + targeted tests before completion | full verification + drift + compound |

**Per-finding Scope Guard.** Any finding that needs a new slice/contract/
re-planning escalates THAT finding to `implement` (mirrors `fix`'s Scope Guard).
If most findings need contracts, the whole batch escalates. If the batch
collapses to one coherent 1-3 file change, it de-escalates to `fix`.

## Router wiring

Five edits to `.claude/skills/mtk/SKILL.md`:

1. **Route Table** — new row: `batch fix`, `apply findings`, `apply review
   findings`, `corrective batch`, `several fixes`, `multiple fixes` →
   `batch-fix`, placed between the `fix` and `implement` rows. Plus a new
   internal-marker row `escalated from fix (batch)` → `batch-fix` (above the
   implement-escalation row, which now also catches `escalated from batch-fix`).
2. **Routing Decision Graph** — a `bfixv` diamond ("multiple independent small
   fixes / corrective batch, no new contract?") between the `fix` and
   `feature/implement` branches → `batch-fix` before falling through to
   implement; a `bfesc` node for the `escalated from fix (batch)` marker; the
   `ask` clarifying node gains a batch option.
3. **Route Disambiguation** — batch-fix NOT `fix` (>3 files / multiple distinct
   fixes) and NOT `implement` (no new public contract, no architecture).
4. **Routing Rules** — Rule 3 routes by marker most-specific-first
   (`escalated from fix (batch)` → batch-fix; `escalated from fix` /
   `escalated from batch-fix` → implement); Rule 4's clarifying question gains
   "or a batch of small independent fixes?".
5. **Help Output** — a `/mtk apply these findings` line for the batch-fix lane.

**`fix` Scope Guard** (`fix/SKILL.md`) now forks: growth that is several
independent trivial fixes with no new contract → `escalated from fix (batch)` →
batch-fix; genuine new-slice/contract/re-planning growth → `escalated from fix`
→ implement (unchanged). Marker ordering matters — `escalated from fix (batch)`
contains the substring `escalated from fix`, so the batch marker is checked
first (first-match-wins, top-to-bottom).

## Boundaries: fix ↔ batch-fix ↔ implement

| Signal | fix | batch-fix | implement |
|---|---|---|---|
| Files | 1-3 | >3 (or multiple distinct fixes) | any |
| Distinct changes | one coherent change | multiple INDEPENDENT fixes | one feature (may be multi-part) |
| New public contract | no | no | yes (or breaking change) |
| Architecture / new slice | no | no (a finding that needs one escalates) | yes |
| Spec | none | short findings stub | full executable spec + sidecar |
| Plan file | none | none | `docs/plans/` |
| Approval gate | none | one, on the list | Phase 2.5 (mandatory) |
| Escalates to | batch-fix / implement | implement (per finding) | — |

## Files added

- `.claude/skills/batch-fix/SKILL.md`
- `tests/fixtures/router-batch-fix.json`
- `tests/pressure-tests/batch-fix.md`
- `evals/batch-fix/eval-01-corrective-batch.md`
- `evals/batch-fix/grader.md`
- `docs/specs/2026-07-14-batch-fix-lane.md` (this file)

## Files edited

- `.claude/skills/mtk/SKILL.md` — router wiring (5 edits + a red-flag row)
- `.claude/skills/fix/SKILL.md` — Scope Guard fork to batch-fix

## Security and compliance impact

None. This is workflow routing and skill authoring — markdown + a JSON fixture.
No change to auth, secrets, financial-state surfaces, or audit trails. batch-fix
inherits `security-and-hardening` for any finding that touches a security surface.

## Verification

- `bash scripts/run-fixtures.sh` — `router-batch-fix.json` passes (skills exist +
  every case grounded by a route-table keyword or a note).
- `bash scripts/validate-toolkit.sh` — after manifest entries are added for the
  new files, must print "Toolkit validation passed" (manifest reconciliation is
  handled by the release orchestrator, not this change).
- Manual: the four `router-batch-fix.json` cases route as declared; a `fix`
  Scope Guard batch escalation emits `escalated from fix (batch)` and lands in
  batch-fix.
