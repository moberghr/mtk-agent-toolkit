# Superpowers Borrow — Release Notes / Plan

- **Date:** 2026-05-07
- **Slug:** superpowers-borrow
- **Source:** comparative analysis of `obra/superpowers` vs MTK
- **Version target:** 7.3.0
- **Scope:** 2 patterns adopted, 5 explicitly rejected

> **Non-goals.** No multi-harness distribution (Codex / Cursor / Gemini / Copilot /
> OpenCode / Droid). No removal of domain skills. No abandonment of the Phase 4
> structured-review architecture. No replacement of the JSON finding schema with
> prose. MTK stays a Claude-Code-only, opinionated, fintech-aware toolkit.

---

## What we borrowed

| # | Pattern from superpowers | Where it lands in MTK | Effort |
|---|---|---|---|
| 1 | Decision graphs (GraphViz `dot`) inside skills | `mtk/`, `fix/`, `spec-driven-development/` SKILL.md | S |
| 2 | Subagent-per-task implementation loop | New `subagent-implementation/` skill; `implement` Phase 3 fork | M |

### Why these two

- **Visual decision flow.** Superpowers' skills lead with a `digraph` showing the branch points an agent will hit. Models follow visual flow more reliably than equivalent prose, particularly at the routing edges where MTK has historically misrouted (router fix-vs-feature ambiguity, fix-skill scope-guard escalation, spec-skill skip-vs-write). Three skills, three graphs, ~zero infrastructure cost.
- **Per-batch context isolation.** Inline batched implementation (today's `incremental-implementation`) carries every prior batch's file reads forward into the next batch's reasoning. For a 6-batch feature the main context is ~50 file reads wide by batch 6. Superpowers' fresh-subagent-per-task pattern, adapted to MTK's batch granularity, keeps each batch's reasoning surface narrow and lets drift get caught earlier — without breaking MTK's Phase 4 structured-review pipeline.

## What we rejected

| Pattern | Why not |
|---|---|
| Multi-harness distribution | MTK's hook layer (`security-gate`, `scope-guard`, `verify-completion`, `pre-commit-linters`) is Claude-Code-specific. Targeting other harnesses would gut the deterministic enforcement that's MTK's main differentiator. |
| "No domain-specific skills" rule | Correct stance for superpowers (generic methodology). Wrong for MTK — the finance domain pack and stack-aware skills are MTK's reason to exist for the target audience. |
| Zero-deps stance | MTK ships an MCP server and depends on `node`, `shellcheck`, `jq`. Backporting to bash-only would cost the structured review schema and analytics. |
| Removing Phase 2.5 approval gate | Superpowers' "continuous execution, no check-ins" is right for solo experimentation. For a ~17-engineer fintech with audit requirements, the explicit approval moment is a feature, not friction. We borrow only the *post-approval* "don't ask should-I-continue" norm — codified in `subagent-implementation` Rule §3 and pressure test §2. |
| Prose reviewer outputs | MTK's confidence-scored JSON finding schema is what makes findings auditable, threshold-filterable, and false-positive-deflatable. Keep MTK's schema. |
| 94%-rejection PR theater | Adoption-blocking framing for a team toolkit. Borrow the substance (PR template rigor, prior-PR search, anti-fabrication clauses) when it lands; not in this release. |

---

## Changes shipped

### 1. Decision graphs inside three skills

**`.claude/skills/mtk/SKILL.md`** — routing decision tree as `digraph`. Encodes the order in which the route table is checked (empty → escalated → setup → review → health → fix → feature → status → claude-md), with explicit `ambig?` branch for "fix the auth feature"-style inputs. 4-row Red Flags table: pass-through discipline, ambig handling, redirect-vs-absorb for setup, no silent guessing on diamond ties.

**`.claude/skills/fix/SKILL.md`** — scope-guard escalation graph. Three red-tinted diamonds (4th file / new slice / re-planning) all feed a single "STOP → self-escalate" terminal node. Closes the build → green → report loop with an explicit "do NOT weaken the test" branch on red. Red Flags table targets "just one more file" and "I'll relax the assertion."

**`.claude/skills/spec-driven-development/SKILL.md`** — spec-vs-skip + security_impact-honesty graph. Includes the `ambig?` pre-draft gate (resolve clarifying questions via `AskUserQuestion` *before* drafting; the Phase 2.5 approval gate is a go/no-go on a fully-informed plan, not a Q&A). Red Flags target "I'll write the spec after I implement" and "security_impact is none, it's just a small change."

Anatomy preserved per S2.2 — graphs live inside existing `## Workflow` / Route Table sections, not new top-level sections.

### 2. `subagent-implementation/SKILL.md` (new)

A branch path for `implement/SKILL.md` Phase 3. Decision rule: dispatch to subagent-implementation when **any** of:
- `plan.batches.length >= 3`
- `change_manifest.length >= 6`
- `security_impact != "none"`

Otherwise stay on `incremental-implementation` (inline path; cheaper, fine for 1-2 batch features).

#### Loop shape

1. **Threshold gate.** Reads `docs/specs/<date>-<slug>.json`. Returns control to `implement` if not met.
2. **Pick implementer model — once.** `AskUserQuestion`: *"Implementer subagent model? Sonnet (faster, cheaper) | Opus (more capable)."* If `AskUserQuestion` is unavailable in the harness, default to Sonnet with a one-line notice.
3. **Per-batch dispatch.** Build a context bundle (spec excerpt, batch object, prior-batch summaries — never full diffs, change_manifest, out_of_scope). Dispatch `Agent(subagent_type=general-purpose, model=<chosen>, …)` with the implementer prompt template. Implementer must return JSON matching:
   ```json
   {
     "batch_id": "...",
     "actual_files": [...],
     "build":  { "ok": true|false, "evidence": "..." },
     "tests":  { "ok": true|false, "evidence": "..." },
     "behavioral_diff": "...",
     "deviations": [ ... ]
   }
   ```
4. **Build/test gate.** ≤2 retries on build/test failure. On exhaustion → halt and report. (Halt happens in autonomous mode too — the gate is structural, not interactive.)
5. **Drift micro-check (orchestrator-side, no agent call).**
   - `extra_files = actual_files − batch.files`, `missing_files = batch.files − actual_files`
   - **Clean** → persist.
   - **Drifted, auto-fixable** (in-package, no new public contract, no security_impact change) → orchestrator amends sidecar `change_manifest`, continues.
   - **Drifted, not auto-fixable** (cross-package, new public contract, security_impact escalated, `out_of_scope` violated) → re-open Phase 2.5; halt.
6. **Persist.** Append batch result to `sidecar.implement.completed_batches[]`; tick `tasks/todo.md`; run `validate-handoff.sh` if available.
7. **Cumulative churn check.** Mirror `incremental-implementation` thresholds (300 lines → early review, 500 lines → halt + `compliance-reviewer`).
8. **After all batches.** Aggregate `behavioral_diff`; hand back to Phase 3.5 (whole-feature drift) → Phase 4 (two-stage review). Both unchanged.

#### Hard rules (from skill body)

- Orchestrator never edits source files. Only sidecar / todo amendments.
- One implementer subagent per batch — never reuse across batches.
- Model is asked once, never per batch.
- No per-batch reviewer agent (deferred to v2; Phase 4 covers quality review).
- Implementer subagent does NOT call `Agent` (no recursion).

### 3. `implement/SKILL.md` Phase 3 fork

Phase 3 now reads the JSON sidecar and chooses subagent vs inline path based on the threshold above. Phase 1 explicitly delegates ambiguity resolution to the spec skill's pre-draft gate.

### 4. Pressure test

`tests/pressure-tests/subagent-implementation-pressure.md` — 10 adversarial scenarios:
1. "Faster if I just edit it myself" — inline shortcut bypass
2. "Confirm before each batch" — autonomous-mode confirmation creep
3. "One extra file, no big deal" — silent manifest amendment of cross-package leak
4. "Reuse the same subagent across batches" — context-isolation collapse
5. "Skip this failing batch" — partial-state poisoning
6. "Implementer reviews its own work" — drift detection laundering
7. "Re-ask model per batch" — model-prompt creep
8. "AskUserQuestion isn't available" — harness degradation panic
9. "Phase 4 is redundant now" — review skipping
10. "Threshold is AND not OR" — the 7-files-but-2-batches edge case

---

## Success criteria

| ID | Description | Verification |
|----|---|---|
| SC1 | `subagent-implementation/SKILL.md` exists with all S2.2 sections | `bash scripts/validate-toolkit.sh` |
| SC2 | Phase 3 of `implement` forks on threshold | Read `implement/SKILL.md` Phase 3 prose |
| SC3 | Decision graphs render valid `dot` syntax in 3 skills | `grep -c "digraph" .claude/skills/{mtk,fix,spec-driven-development}/SKILL.md` returns 1 each |
| SC4 | Pressure test covers ≥10 adversarial scenarios | Count `## Scenario` headers |
| SC5 | Manifest version ↔ plugin.json version ↔ marketplace.json version all 7.3.0 | C0.1 enforced by validator |
| SC6 | CHANGELOG entry exists with the two patterns and the rejected list | Read `CHANGELOG.md` `[7.3.0]` section |
| SC7 | README "What's New" + version badge + footer all show 7.3.0 | `grep "7\.3\.0" README.md` |

All seven met as of commit `397da5a` (skill + Phase 3 fork) and the v7.3.0 docs commits that follow.

---

## Out of scope (deferred)

- **Per-batch full reviewer agent.** Today's drift micro-check is orchestrator-side. v2 may dispatch `compliance-reviewer` in batch-mode if metrics show Phase 4 is repeatedly catching things batch-level should've flagged.
- **Bite-sized 2-5 min step granularity inside batches.** Cited in the analysis as a borrowable item from superpowers' `writing-plans/SKILL.md`. Deferred — finer than today's 2-4 file batches doubles dispatch overhead and isn't justified yet.
- **`using-mtk` first-message bootstrap.** Borrowable from superpowers' `using-superpowers`. Deferred — MTK already has aggressive routing via `/mtk` and the SessionStart hook; another bootstrap layer needs evidence first.
- **Anti-slop PR template.** Worthwhile but a separate change; not part of this release.
