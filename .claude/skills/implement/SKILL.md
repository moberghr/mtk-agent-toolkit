---
name: implement
description: Full feature implementation loop orchestrating planning, batching, verification, and review skills
type: skill
user-invocable: false
---

# MTK Implement — Full Feature Loop

## MTK File Resolution

MTK skills and shared references live either in the project (local install) or the plugin cache (marketplace install). Resolve once:

1. If `$MTK_HELPER_ROOT` is set, prefix `.claude/skills/` and `.claude/references/` reads with it — a pinned checkout wins over every other source.
2. Otherwise, if `$CLAUDE_PLUGIN_ROOT` is set, prefix them with that.
3. Otherwise, if `.claude/skills/context-engineering/SKILL.md` exists locally → project-relative paths work as-is.
4. Otherwise, fall back to `find ~/.claude/plugins -maxdepth 8 -name "SKILL.md" -path "*/mtk/*/context-engineering/*" -type f 2>/dev/null | sort -V | tail -1 | sed 's|/.claude/skills/context-engineering/SKILL.md||'`. If empty, MTK skills are unavailable — warn the engineer and proceed with `CLAUDE.md` only.

Always project-relative (never prefixed): `CLAUDE.md`, `.claude/tech-stack`, `.claude/rules/`, `tasks/`, `docs/`, `.claude/references/architecture-principles.md`, `.claude/references/pre-commit-review-list.md`, `.mtk/` (workflow state). Resolve skills and scripts from the same root: a split (skills from a local dev checkout, scripts from the plugin cache) risks version drift — anchor both the same way.

---

You are a senior engineer building serious software. This skill is the user-facing entry point for substantial work. Language and framework specifics come from the active tech stack skill.

The skill itself is intentionally thin. The source of truth for workflow behavior is the skill layer:

- `.claude/skills/context-engineering/SKILL.md`
- `.claude/skills/workflow-artifacts/SKILL.md`
- `.claude/skills/spec-driven-development/SKILL.md`
- `.claude/skills/planning-and-task-breakdown/SKILL.md`
- `.claude/skills/incremental-implementation/SKILL.md`
- `.claude/skills/test-driven-development/SKILL.md`
- `.claude/skills/source-driven-development/SKILL.md`
- `.claude/skills/code-review-and-quality/SKILL.md`
- `.claude/skills/security-and-hardening/SKILL.md`
- `.claude/skills/verification-before-completion/SKILL.md`
- `.claude/skills/spec-drift-detection/SKILL.md`
- `.claude/skills/brainstorming/SKILL.md`
- `.claude/skills/code-simplification/SKILL.md`
- `.claude/skills/tech-stack-{stack}/SKILL.md` — loaded based on `.claude/tech-stack`

## Phase 0: Load Context (Progressive Disclosure)

Before doing anything else:

0. Init or resume a workflow artifact (`.claude/skills/workflow-artifacts/SKILL.md`).
   - **Resolve the helper once** — plugin-cache installs may not have it project-relative and `$CLAUDE_PLUGIN_ROOT` is sometimes unset, so a bare `scripts/workflow-artifact.sh` can fail. Resolve it `MTK_HELPER_ROOT`-first (a checkout you pin — see `CLAUDE.md`), then project, then plugin, and use `"$WFA"` for every `workflow-artifact.sh` call in this skill:
     ```bash
     WFA="$([ -n "${MTK_HELPER_ROOT:-}" ] && echo "$MTK_HELPER_ROOT/scripts/workflow-artifact.sh" || ([ -f scripts/workflow-artifact.sh ] && echo scripts/workflow-artifact.sh || echo "${CLAUDE_PLUGIN_ROOT:-.}/scripts/workflow-artifact.sh"))"
     ```
   - Run `"$WFA" list`.
   - If a single active `BUILD` workflow exists for this feature, ask via `AskUserQuestion` whether to resume that uuid or start a new one.
   - Otherwise: `MTK_WF_UUID=$("$WFA" init BUILD --goal "<one-line user goal>")` and remember the uuid for the rest of the session.
   - Emit the phase-0 marker immediately after init/resume — the phase goes in `--data`, not as a positional: `"$WFA" event "$MTK_WF_UUID" phase_started --data '{"phase":"phase-0"}'`.
1. Follow `.claude/skills/context-engineering/SKILL.md`.
2. Read `CLAUDE.md`. If missing, stop and tell the engineer to run `/mtk-setup`.
3. **Load the active tech stack:** resolve it with `bash scripts/resolve-tech-stack.sh "$PWD"` (a single word like `dotnet` or `python`). The resolver is **polyglot-monorepo aware** — for a subproject under a differently-stacked root it returns the subproject's stack via a nested `.claude/tech-stack` or a root `.claude/tech-stack.map` glob, falling back to the repo-root `.claude/tech-stack`. When the change targets a specific subtree, pass a representative path from the `change_manifest` (e.g. `bash scripts/resolve-tech-stack.sh "src/web/spa"`) rather than `$PWD`, so the workflow loads the right stack for the files it will touch. Then read `.claude/skills/tech-stack-{stack}/SKILL.md`. This provides build/test commands, ORM guidance, framework patterns, and reference file paths used throughout the workflow. If it resolves empty, do not halt: run `bash scripts/setup-detect.sh --json` (read-only) to infer the stack, and load the matching `tech-stack-{stack}` skill if one exists for the inferred primary. If inference is empty or no matching skill exists, warn the engineer that the tech stack is unconfigured (suggest `/mtk-setup`) and proceed with `CLAUDE.md`-only context.
4. Read only the references needed for the **current phase**:
   - **Always (Phase 0):** the coding guidelines from the tech stack's `## Reference Files`, `.claude/references/architecture-principles.md` if present
   - **Defer to Phase 1 (spec):** `.claude/references/security-checklist.md` (only if scope touches auth/financial/infra), `.claude/references/testing-patterns.md`
   - **Defer to Phase 3 (implementation):** `.claude/references/performance-checklist.md`, plus stack-specific references from the tech stack's `## Reference Files` (e.g., ORM checklist, framework patterns)
   - **Defer to Phase 4 (review):** `.claude/references/pre-commit-review-list.md` if present
   - **Path-scoped auto-load (any phase):** references in `.claude/manifest.json` may declare an `applyTo` glob array. When the current phase has files in scope (from `change_manifest` or `git diff --name-only HEAD`), activate references whose globs match any touched file. Skip references whose globs match nothing for this task. See `context-engineering` skill for the match procedure.
5. Resolve the lessons path using the main worktree if needed, then read relevant entries from `tasks/lessons.md`.
6. Detect `--terse` or `--verbose` for output intensity:
   - **`--terse`:** Minimal output. Skip explanations, rationale, and intermediate status. Report only: decisions, actions, findings, and evidence. No filler phrases. Aimed at senior engineers who read diffs.
   - **`--verbose`:** Full explanations. Include rationale for each decision, alternatives considered, references consulted, and step-by-step reasoning. Aimed at engineers learning the codebase or reviewing unfamiliar areas.
   - **Default (no flag):** Balanced output. Brief rationale for non-obvious decisions, standard reporting, no excess explanation.
7. **Worktree pre-flight (capture only).** Run `git status --porcelain` and remember the set of already-modified and untracked paths — the *pre-existing dirty set*. This is a read-only snapshot, not a gate yet. It feeds two later checks: (a) the spec's dirty-worktree risk step (`spec-driven-development` step 4b, for **out-of-manifest** paths), and (b) the **Phase 2.9 worktree collision gate** (for **in-manifest** paths — the parallel-session case). Capturing it now, before any edit, is what lets the collision gate tell "already dirty when we started" apart from "dirty because this workflow touched it."

**Progressive disclosure principle:** Load references at the phase where they are first needed, not all upfront. This preserves context budget for the actual code and decisions that matter in each phase. Re-anchor on references when switching phases.

**Parallel loading:** Within a single phase, load independent references in parallel — issue multiple `Read` calls in one message. Same for independent `Glob`/`Grep` discovery. See `docs/parallelism-patterns.md`.

## Phase 0.5: Brainstorm (When Needed)

If the approach is unclear, multiple designs are plausible, or the engineer asks "how should we..." — follow `.claude/skills/brainstorming/SKILL.md` before writing the spec.

Skip this phase when:
- The engineer already specified the approach
- The task is a straightforward addition following existing patterns
- The scope is narrow enough that only one viable design exists

## Phase 0.7: Ingest a Supplied Plan or Spec (When Provided)

If the engineer supplied a spec or plan as the input — a path they handed you, or an existing `docs/specs/<…>.md` / `docs/plans/<…>.md` already on disk that this run is meant to execute — **adopt it as the source of truth instead of authoring a new one.** "User supplies the plan" is a first-class entry mode, not a path collision: never write a fresh spec/plan to a path the engineer's file already occupies, and never invent a `-impl` / `-v2` suffix just to dodge overwriting their input.

1. **Detect the input.** A supplied plan/spec is one the engineer names, points the run at, or an on-disk `docs/plans|specs/*.md` the request references. If none was supplied, skip this phase — Phases 1–2 author the artifacts normally.
2. **Adopt, don't recreate.** Record the supplied path on the workflow artifact (`"$WFA" set "$MTK_WF_UUID" results.plan_path=<path>` and/or `results.spec_path=<path>`). If a JSON sidecar exists beside it, validate it against `.claude/schemas/handoff.schema.json`; if only markdown exists, derive the sidecar (`change_manifest`, `plan.batches`, `success_criteria`) via `spec-driven-development` / `planning-and-task-breakdown` **without rewriting the engineer's markdown**. Phase 2's authoring write is skipped for any artifact adopted here.
3. **Reconcile against current code (mandatory).** A supplied plan may be stale — batches already implemented since it was written. Run `prior-work-check` in its *existing-plan reconciliation mode*: classify each batch `already-satisfied` / `partially-done` / `not-started` with `file:line` evidence. Mark `already-satisfied` batches complete in the sidecar and tick them in `tasks/todo.md` with a one-line note naming what was pruned; surface `partially-done` batches for the engineer to re-scope. **Do not re-implement done work**, and never edit source in this phase.
4. **Then continue to Phase 1/2 for whatever is missing.** A supplied spec still needs a plan if none was given (and vice versa); the ambiguity gate, prior-work check, and JSON sidecar all still apply to the not-yet-authored half.

Adopting the engineer's artifact does **not** skip the approval gate — Phase 2.5 still runs, on the adopted-plus-reconciled scope, exactly as it would on a freshly authored one.

## Phase 1: Produce The Executable Spec

Follow `.claude/skills/spec-driven-development/SKILL.md`.

**Resolve ambiguity before drafting, not at the approval gate.** The spec skill's ambiguity gate (step 6) is mandatory — if two or more plausible designs, undefined scope edges, or unresolved architectural choices exist, ask via `AskUserQuestion` *before* writing the spec. The Phase 2.5 approval gate is a go/no-go on a fully-informed plan, not a place to surface open questions for the first time.

The resulting plan must include:

- scope classification
- change manifest
- test manifest
- implementation batches
- assumptions and risks

**Persist the spec to disk before continuing.** Save to `docs/specs/YYYY-MM-DD-<feature-slug>.md` using today's date and a kebab-case slug. Create `docs/specs/` if missing. This is mandatory — the engineer must be able to read and edit the spec outside of chat.

After the spec lands, record its path on the workflow artifact:
`"$WFA" set "$MTK_WF_UUID" results.spec_path=docs/specs/<file>`

## Phase 2: Write The Task Breakdown

Follow `.claude/skills/planning-and-task-breakdown/SKILL.md`.

Write **both** files (mandatory, not optional):

1. `tasks/todo.md` — checkable batches and post-implementation review items
2. `docs/plans/YYYY-MM-DD-<feature-slug>.md` — full plan alongside the spec, same date and slug as Phase 1

Create `docs/plans/` if missing. Then record both paths on the workflow artifact:
`"$WFA" set "$MTK_WF_UUID" results.plan_path=docs/plans/<file> results.todo_path=tasks/todo.md`

## Rigor Score (Continuous Ceremony Scaling)

Compute after Phase 2 from the JSON sidecar at `docs/specs/<date>-<slug>.json`;
recompute when the approved scope **shrinks**. Ceremony scales with blast radius.

| Score | Level | Phase 3 path | Stage 2 reviewers | `MTK_AUTO_PROCEED` |
|---|---|---|---|---|
| ≤ 3 | LIGHT | inline | conditional | eligible |
| 4–7 | STANDARD | inline | conditional | eligible |
| 8–11 | HIGH | subagent | `test-reviewer` always; `architecture-reviewer` on boundary/slice | no |
| ≥ 12 | MAX | subagent | both + `silent-failure-hunter` | no |

**Hard-trigger floor — overrides the score:** `batches >= 3`, `>= 6` non-mechanical
`change_manifest` entries, or `security_impact != "none"` forces **at least HIGH**.

**The Phase 3 dial names a path, not a guarantee.** Whether this session can
dispatch is probed at Phase 2.9. When it cannot, HIGH/MAX runs the *inline-MAX
profile* — it never silently becomes a STANDARD-shaped inline run, and the level
does not drop.

State the score and level in one line at the Phase 2.5 gate, e.g.
`Rigor: HIGH (score 9 — 3 batches, 8 files, security_impact=new-auth-path)`.

**Read `.claude/references/implement-rigor-scoring.md`** for the signal→points
table, the external vs internal-tooling contract-surface rule, the mechanical
definition and per-batch exception, and the scope-reduction recompute guardrails.
## Phase 2.4: Manifest Pre-Flight (Destinations)

Phase 0.7's reconciliation checks *cited anchors* — existing code the change attaches to. This phase checks the other half: the **destinations** the manifest proposes. A manifest can name a directory that does not exist, a file that lives somewhere else, or a filename shape no sibling uses, and none of that surfaces until Phase 3.5 records it as drift — after an implementer has already built against the wrong path.

Run it on the sidecar Phase 2.5 is about to seal, whether the manifest was authored in Phase 1-2 or adopted in Phase 0.7:

```bash
bash scripts/manifest-preflight.sh --human docs/specs/<date>-<slug>.json
```

- **Critical findings (MP001/MP002) block the gate.** A `modify` entry pointing at a path that does not exist is not a typo to fix later: the implementer will either create the file in the wrong place or invent a directory around it. Repoint the entry at the real path — MP002 names it when the file is tracked elsewhere — and re-run.
- **Warnings (MP003-MP006) are answered, not waived.** MP004 in particular ("the pattern this path presumes may not be used in this codebase at all") means read how the codebase does this today before sealing. If the pattern really is absent and you still want it, that is a design decision that belongs in the spec, stated — not a directory that appears silently in Phase 3.
- Record the outcome, so a later drift record can be told apart from an unchecked manifest:
  `"$WFA" event "$MTK_WF_UUID" manifest_preflight --data '{"critical":<n>,"warning":<n>}'`

A manifest corrected here costs one edit. The same correction found in Phase 3.5 costs a drift record, an amended sidecar, and a wasted batch.

## Phase 2.5: Approval Gate (STOP HERE)

Mandatory. Before Phase 3, ask via `AskUserQuestion`.

**Render the plan and todo inline in the terminal first** — print the content, do
not just cite paths: a scope/batch-count/rigor header line, the full
`tasks/todo.md`, a per-batch breakdown (title, files, acceptance criteria,
boundary), a `Gate sequence:` line, then the spec/plan/todo paths as bare
repo-relative paths.

Options: `Approve & run until done` · `Approve (interactive)` · `Edit first` ·
`Revise` · `Show full plan & spec in terminal`.

**Until the engineer answers: read-only Bash only — no Edit/Write on source, no
Phase 3.** In autonomous mode, never re-ask for Phases 3–7 — stop and report.

On approval, record the gate and **seal the approved scope** so a later edit
cannot silently keep the approval:

```bash
"$WFA" gate "$MTK_WF_UUID" plan_trust_gate pass --reason "<approve mode>"
"$WFA" seal "$MTK_WF_UUID"
```

`MTK_AUTO_PROCEED=1` may default the recommended option **only** when the spec has
zero open decisions and zero `[ASSUMED]` claims, no BLOCKING plan-gap findings, no
open package-legitimacy checkpoint, `skill_precedence_gate` is `pass`, the scope is
neither breaking-change nor high `security_impact`, and the level is LIGHT or
STANDARD. Any condition failing ⇒ fall back to `AskUserQuestion`.

**Read `.claude/references/implement-approval-gate.md`** for the full rendering
spec, the complete AUTO_PROCEED precondition list, harness fallbacks when
`AskUserQuestion` is unavailable, multi-spec `gate_scope` and standing-approval
expiry, and why `results.todo_path` is excluded from the seal.
## Phase 2.9: Pre-Flight (Collision, Dispatch, Baseline)

Runs after approval, before the first edit. Three checks:

1. **Collision** — is another run or a dirty tree already touching the manifest?
2. **Dispatch capability** — probe whether this session can actually dispatch
   implementer subagents; record the answer as `dispatch_capability`. HIGH/MAX with
   no dispatch runs the **inline-MAX profile** (compensations C1–C3), which keeps
   the rigor level and names what replaces isolation. `MTK_SUBAGENT_DISPATCH=0`
   declares the capability absent up front.
3. **Baseline evidence** — capture build/test/typecheck state at the base commit
   *before* the first edit, so a failure found at batch 3 is attributable. On by
   default at HIGH/MAX; `MTK_BASELINE_CAPTURE=1`/`=0` forces or skips. **If no
   baseline exists, every later checkpoint must say so** rather than implying one.

**Read `.claude/references/implement-preflight.md`** for the dispatch probe
procedure, the inline-MAX compensations in full, and the baseline capture and
reporting rules.
## Phase 3: Implement In Batches

**Fork — pick the implementation path from the JSON sidecar at `docs/specs/<date>-<slug>.json`:**

- **Subagent path** (`.claude/skills/subagent-implementation/SKILL.md`) — when the rigor level is HIGH or MAX (any hard trigger — `plan.batches.length >= 3`, non-mechanical `change_manifest` entries >= 6, `security_impact != "none"` — or score ≥ 8; see Rigor Score). Dispatches one fresh implementer subagent per batch with orchestrator-side drift micro-checks. In interactive mode it asks once which model (Sonnet/Opus) to use for the implementer; in autonomous mode it does **not** ask — the Sonnet policy default applies (Opus for plan-flagged novel/tricky batches), consistent with the autonomous "never ask in Phases 3-7" rule. Prefers the native dynamic-workflow runtime when the `Workflow` tool is available (drift/persistence/Phase-4 stay orchestrator-side), falling back to a manual Agent-per-batch loop otherwise.
- **Inline path** (`.claude/skills/incremental-implementation/SKILL.md`) — for everything below threshold. Smaller features stay in the main context.

Always also follow:

- `.claude/skills/test-driven-development/SKILL.md`
- `.claude/skills/source-driven-development/SKILL.md` when framework or SDK behavior is uncertain
- `.claude/skills/research-context/SKILL.md` when a choice is version-sensitive or depends on current external best-practice (returns a cited brief; does not edit code)
- `.claude/skills/security-and-hardening/SKILL.md` when the scope touches auth, financial state, secrets, or infra

Whichever path runs, every batch must:

1. implement only in-manifest files
2. add or update tests in the same batch
3. run the batch checkpoint using the build/test commands from the active tech stack skill
4. run the pre-commit review list if present
5. check the batch off in `tasks/todo.md`

After all batches:

- run the full test command from the active tech stack skill
- write an explicit behavioral diff
- emit the final `phase_exit_gate pass` (or `fail` and stop) on the workflow artifact (per-batch gate decisions are already recorded by the implementation skill)

Record per-batch progress:
`"$WFA" set "$MTK_WF_UUID" results.batches_completed=<n>`

## Phase 3.5: Spec-Drift Check

Before review, follow `.claude/skills/spec-drift-detection/SKILL.md`.

Compare the implementation against the spec's JSON sidecar at
`docs/specs/<date>-<slug>.json`:

- Files touched vs `change_manifest`
- Public contracts vs `public_contracts`
- `security_impact` vs actually-touched security-surface files
- `out_of_scope` items vs what was delivered

If critical drift is found:

1. Decide: is the implementation wrong, or was the spec incomplete?
2. If implementation wrong → fix within the manifest and re-run drift check.
3. If spec incomplete → amend the spec + JSON sidecar via
   `spec-driven-development`, re-open the Phase 2.5 approval gate for the
   scope change, then re-run drift check.
4. If the drift is a **scope reduction** — batches deferred, dropped, or split
   to a follow-up, with no new file, contract, or security surface — this is
   the one drift class that does **not** re-open the gate. Recompute the Rigor
   Score from the remaining batches (see *Rigor Score → Recompute on scope
   reduction*), record the transition on the workflow artifact, and continue at
   the recomputed level. Relaxing ceremony for work already approved needs no
   new approval; only *added* scope does.
5. Do NOT proceed to review until drift is clean.

Silent drift repair is forbidden. Every *increase* in scope goes through the
approval gate; a *reduction* is recorded and re-scores rigor (item 4) but does
not re-open it.

## Phase 4: Review (Two-Stage)

**Stage 1 — Spec compliance.** `compliance-reviewer` against the sealed spec.
Re-check the seal with `verify-seal`; a STALE seal **refuses completion**.

**Stage 2 — Quality and coverage.** Reviewer set is dictated by the rigor level
(see the Rigor Score table): conditional at LIGHT/STANDARD, `test-reviewer` always
at HIGH (plus `architecture-reviewer` on a boundary/slice condition), both plus
`silent-failure-hunter` at MAX.

**A reviewer is a pass to perform, not a dispatch mechanism.** When the Agent tool
is unavailable or forbidden, read the agent's own `.md` and apply its checklist
inline. That costs context isolation, never coverage — and the Final Report must
say which lanes ran inline.

Scope every lane to this run's changed files, excluding the pre-existing dirty
baseline, or reviewers attribute someone else's edits to this run.

**Read `.claude/references/implement-review-lanes.md`** for each stage's full
procedure and the lane-accounting rules.
## Phase 5: Fix Review Findings

Fix every critical issue and every warning unless you record a one-line waiver with a reason, then:

- run the build and test commands from the active tech stack skill
- run the pre-commit review list if present
- re-run the necessary reviewer(s)

Maximum 3 review iterations.

## Phase 6: Cleanup

Follow `.claude/skills/code-simplification/SKILL.md`.

If cleanup changes code, re-run the build and test commands from the active tech stack skill.

## Phase 7: Compound (Learn And Strengthen)

This phase is not optional cleanup — it is how the toolkit gets smarter over time.

1. **What was learned?** Answer explicitly:
   - Did any assumption from the spec turn out to be wrong?
   - Did any framework/SDK behavior surprise you?
   - Did any review finding reveal a gap in the standards?
   - Did you receive any corrections from the engineer during this session?

2. **Capture lessons.** For each learning, append to `tasks/lessons.md`:
   - What happened
   - The rule to follow next time
   - Why it matters
   - When it applies

3. **Check for promotion.** If a lesson matches an existing pattern in `tasks/lessons.md` (3+ similar entries), propose adding it as a rule in `CLAUDE.md`.

4. **Check CLAUDE.md for drift.** If the work added new stable patterns (naming, structure, conventions), propose updates to `CLAUDE.md`. Do not silently modify it.

5. **Update pre-commit-review-list.** If a security or compliance issue was found during review, add it to `.claude/references/pre-commit-review-list.md` so it's caught earlier next time.

6. **Escalate a repeat reduction.** If this run recorded a ceremony reduction — a Phase 3 path,
   a reviewer lane, a gate — for a reason a previous run in this repo already recorded (check
   `tasks/lessons.md` and prior workflow artifacts), stop logging it a third time. A reduction
   that recurs is not bad luck; it is the contract describing a path this environment does not
   have. Propose the durable fix instead — the env declaration that makes it explicit
   (`MTK_SUBAGENT_DISPATCH=0`), or a lesson naming the constraint — and say which in the final
   report. Honest bookkeeping repeated three times is still an unfixed contract.

7. **State the compound.** In the final report, include a "What compounded" section listing what future sessions will benefit from.

## Phase 7.5: Archive (Delta Sync-Back)

Archive the run's spec/plan delta back to the durable store, then optionally write
a **tracked** run receipt.

`MTK_RUN_RECEIPT=1` writes `docs/specs/<date>-<slug>.receipt.md` — a tracked
sibling of the spec holding baseline vs final figures, gates and their reasons,
dispatch path and compensations, ceremony reductions, drift/coverage/collateral
verdicts, and reviewer lane outcomes. The `.mtk/` workflow artifact is gitignored,
so without the receipt the only tracked residue of a run is `tasks/lessons.md` and
the spec. **Fields never recorded are written as `not recorded` — never
reconstructed.**

**Read `.claude/references/implement-archive-receipt.md`** for the sync-back
procedure and the receipt's full field list.
## Final Report

Close the workflow artifact:
```bash
"$WFA" gate "$MTK_WF_UUID" memory_sync_gate pass --reason "lessons captured"
"$WFA" set "$MTK_WF_UUID" status=completed
"$WFA" event "$MTK_WF_UUID" workflow_completed --data '{"summary":"<short>"}'
```

Report:

- scope
- files changed
- tests added or updated — **as a delta against the Phase 2.9 baseline**, not a hand count
  (`702 -> 762`); if no baseline was captured, say so instead of implying one
- Phase 3 path actually taken (`subagent` / `inline-MAX` + compensations), and
  `dispatch_capability` if it was anything other than `available`
- review agents used and stage (1 or 2)
- review iterations
- pre-existing failures carried from the baseline, named — a test red before this run began is
  reported as inherited, never as passing and never as this run's regression
- collateral churn: the `hooks/collateral-guard.sh` verdict, and what was reverted
- cleanup summary
- **what compounded** — lessons captured, rules promoted, pre-commit-review items added
- whether `CLAUDE.md` changed

## Red Flags

- Code started before the spec existed
- Spec or plan not written to `docs/specs/` and `docs/plans/`
- Phase 2.5 approval gate skipped or merged into Phase 3
- Phase 3 started without an explicit approval answer from the engineer
- Approval gate answered by prose prompt instead of `AskUserQuestion`
- Spec drafted with material ambiguity unresolved (open questions deferred to "Open questions" section instead of asked via `AskUserQuestion` before drafting)
- Files touched outside the change manifest
- Checkpoints skipped
- No behavioral diff before review
- Review omitted for substantial work

## Critical Rules

1. Never skip planning for substantial work.
2. Skills are the workflow source of truth; do not silently replace them with ad hoc behavior.
3. Every touched file must appear in the plan.
4. New public behavior must be tested.
5. Review is mandatory for substantial work.
6. **The Phase 2.5 approval gate is always mandatory.** Spec, plan, and todo all written to disk before the gate. Ask via `AskUserQuestion` (load with `ToolSearch` if deferred; stop and say so if the harness doesn't expose it). Never assume or infer approval from the original request. The engineer chooses interactive vs autonomous at the gate, not via a flag.
