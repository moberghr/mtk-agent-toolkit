---
description: Phase 2.9 pre-flight detail for implement — collision check, dispatch-capability probe, inline-MAX compensations, and baseline evidence capture
globs: []
alwaysApply: false
---
# Phase 2.9 Pre-Flight — collision, dispatch capability, baseline evidence

> Extracted from `.claude/skills/implement/SKILL.md` (S2.26: a SKILL.md is a
> navigation layer, not a payload). The skill keeps the decision — when this
> fires, what it outputs, and what stops the run. This file holds the detail,
> and is read **only** when that phase is actually reached.

---

## Phase 2.9: Pre-Flight (Collision, Dispatch, Baseline)

**Before dispatching the first batch**, confirm no other work is already editing files this run is about to touch. A parallel session — or forgotten uncommitted local work — editing an in-scope file is the collision the per-batch drift check only catches *after* an implementer has already started. This gate catches it first, before any edit.

1. Re-run `git status --porcelain` and collect the currently modified/untracked paths.
2. Compute the **collision set**: paths that are (a) in the plan's `change_manifest[].path` or any batch's `files`, AND (b) currently modified/untracked, AND (c) present in the Phase 0 *pre-existing dirty set* (dirty *before* this workflow ran — so this workflow's own spec/plan/todo writes never self-trip the gate).
3. **No collision** → emit the phase-3 marker (`"$WFA" event "$MTK_WF_UUID" phase_started --data '{"phase":"phase-3"}'`) and proceed.
4. **Collision found** → almost always a parallel session or forgotten local edit on an in-scope file. Do **not** start editing.
   - **Interactive mode:** halt and ask via `AskUserQuestion` — options: `Stop (let me resolve the other work first)` (recommended), `Proceed anyway (I understand these files are already modified)`, `Re-scope (drop the colliding files from this run)`. Act on the answer; on `Stop`, leave the workflow active and report.
   - **Autonomous mode:** do not ask — stop and report the collision set (autonomous mode halts on scope/safety conditions, and a parallel editor on an in-scope file is one). Record `failure_stop_gate fail` only once the engineer confirms stopping; otherwise leave it pending for their decision.
5. Record the check either way so the decision is auditable: `"$WFA" event "$MTK_WF_UUID" worktree_preflight --data '{"collisions":<n>}'`.

This gate does not replace the per-batch drift micro-check (which catches drift an implementer *introduces*); it catches drift that already exists *before* the first edit.

### Dispatch capability — probe the path before promising it

The Rigor Score table says HIGH/MAX runs Phase 3 through one fresh implementer subagent per batch. Whether that path *can* run is a property of the **session**, not of the change: the harness may not expose `Agent`/`Workflow`, or a standing instruction may forbid subagents that the engineer did not ask for. Probe once, here, and record the verdict:

`"$WFA" set "$MTK_WF_UUID" results.dispatch_capability=available|forbidden|unavailable`

- **`available`** — run the path the rigor level dictates.
- **`unavailable`** — the harness exposes neither `Workflow` nor `Agent`.
- **`forbidden`** — the tools exist, but a standing instruction or session policy forbids unrequested subagents. `MTK_SUBAGENT_DISPATCH=0` declares this up front so a repo that always runs this way stops rediscovering it once per run.

On `forbidden` or `unavailable` at HIGH/MAX, do **not** drop quietly to a bare inline run. Adopt the inline-MAX profile below and state it in one line before the first batch. A path chosen at the pre-flight is a decision; the same path taken at Phase 3 without a word is a degradation.

### The inline-MAX profile

The subagent path buys exactly one thing: a fresh context per batch, so batch N's reasoning cannot contaminate batch N+1. When it is unavailable, MAX ceremony is still reachable — but only if what it bought is replaced explicitly rather than assumed away:

| # | Compensation | Replaces |
|---|---|---|
| C1 | Re-read the sealed spec, the plan, and this batch's own manifest entries at the start of every batch, before any edit. | The dispatched implementer's fresh read of its bundle |
| C2 | State the batch's file boundary before editing, and treat any file outside it as drift rather than convenience. | A subagent's inability to see out-of-scope files at all |
| C3 | Run Phase 4's reviewer lanes as **sequential fresh passes**, each opened by re-reading the diff from `git diff` rather than from the memory of having written it, and each carrying the anti-anchoring instruction from its agent definition. | Reviewer context isolation |

Record the profile and report it:
`"$WFA" set "$MTK_WF_UUID" results.phase3_path="inline-MAX (dispatch forbidden; C1-C3 applied)"`

### Baseline evidence — capture before the first edit

At rigor HIGH or MAX, capture the suite's state *before* any edit, so a failure found later is attributable. Without it, a red test at batch 3 is indistinguishable from a test that was already red, and telling them apart costs a throwaway worktree and an archaeology detour at the worst possible moment.

1. Run the active tech stack skill's build, test, and typecheck commands at the current base commit.
2. Record the counts **verbatim from the runner** — never an intention — on the artifact:
   `"$WFA" set "$MTK_WF_UUID" results.baseline='{"commit":"<sha>","build":"0 warnings 0 errors","tests":"702/702","e2e":"160 passed / 3 failed (export-csv)"}'`
3. **A pre-existing failure is not this run's to fix.** Name it here, and later checkpoints compare against the baseline instead of asserting an absolute. A test red at the base commit and still red is not a regression; a test that was green and is now red is — and only the baseline separates them.
4. Skip only when the artifact already holds a baseline for the same base commit, or when the level is LIGHT/STANDARD. `MTK_BASELINE_CAPTURE=1` forces capture at any level; `=0` opts out — and then every later checkpoint must say that no baseline exists rather than implying one.

Delta claims in the final report ("+60 backend tests") are **derived from this record**, not counted by hand.
