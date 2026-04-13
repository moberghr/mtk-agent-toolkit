---
description: Full feature implementation loop using MTK skills for planning, batching, verification, and review. Run /mtk:setup-bootstrap once per repo first.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Task, AskUserQuestion
argument-hint: [--terse|--verbose] <feature description>
---

# MTK Implement — Full Feature Loop

You are a senior engineer on a fintech team. This command is the user-facing entry point for substantial work. Language and framework specifics come from the active tech stack skill.

The command itself is intentionally thin. The source of truth for workflow behavior is the skill layer:

- `.claude/skills/context-engineering/SKILL.md`
- `.claude/skills/spec-driven-development/SKILL.md`
- `.claude/skills/planning-and-task-breakdown/SKILL.md`
- `.claude/skills/incremental-implementation/SKILL.md`
- `.claude/skills/test-driven-development/SKILL.md`
- `.claude/skills/source-driven-development/SKILL.md`
- `.claude/skills/code-review-and-quality-fintech/SKILL.md`
- `.claude/skills/security-and-hardening-fintech/SKILL.md`
- `.claude/skills/verification-before-completion/SKILL.md`
- `.claude/skills/spec-drift-detection/SKILL.md`
- `.claude/skills/brainstorming/SKILL.md`
- `.claude/skills/code-simplification/SKILL.md`
- `.claude/skills/tech-stack-{stack}/SKILL.md` — loaded based on `.claude/tech-stack`

## Phase 0: Load Context (Progressive Disclosure)

Before doing anything else:

1. Follow `.claude/skills/context-engineering/SKILL.md`.
2. Read `CLAUDE.md`. If missing, stop and tell the engineer to run `/mtk:setup-bootstrap`.
3. **Load the active tech stack:** read `.claude/tech-stack` (plain text, single word like `dotnet` or `python`). Then read `.claude/skills/tech-stack-{stack}/SKILL.md`. This provides build/test commands, ORM guidance, framework patterns, and reference file paths used throughout the workflow. If `.claude/tech-stack` is missing, stop and tell the engineer to run `/mtk:setup-bootstrap`.
4. Read only the references needed for the **current phase**:
   - **Always (Phase 0):** the coding guidelines from the tech stack's `## Reference Files`, `.claude/references/architecture-principles.md` if present
   - **Defer to Phase 1 (spec):** `.claude/references/security-checklist.md` (only if scope touches auth/financial/infra), `.claude/references/testing-patterns.md`
   - **Defer to Phase 3 (implementation):** `.claude/references/performance-checklist.md`, plus stack-specific references from the tech stack's `## Reference Files` (e.g., ORM checklist, framework patterns)
   - **Defer to Phase 4 (review):** `.claude/references/pre-commit-review-list.md` if present
5. Resolve the lessons path using the main worktree if needed, then read relevant entries from `tasks/lessons.md`.
6. Detect `--terse` or `--verbose` for output intensity:
   - **`--terse`:** Minimal output. Skip explanations, rationale, and intermediate status. Report only: decisions, actions, findings, and evidence. No filler phrases. Aimed at senior engineers who read diffs.
   - **`--verbose`:** Full explanations. Include rationale for each decision, alternatives considered, references consulted, and step-by-step reasoning. Aimed at engineers learning the codebase or reviewing unfamiliar areas.
   - **Default (no flag):** Balanced output. Brief rationale for non-obvious decisions, standard reporting, no excess explanation.

**Progressive disclosure principle:** Load references at the phase where they are first needed, not all upfront. This preserves context budget for the actual code and decisions that matter in each phase. Re-anchor on references when switching phases.

## Phase 0.5: Brainstorm (When Needed)

If the approach is unclear, multiple designs are plausible, or the engineer asks "how should we..." — follow `.claude/skills/brainstorming/SKILL.md` before writing the spec.

Skip this phase when:
- The engineer already specified the approach
- The task is a straightforward addition following existing patterns
- The scope is narrow enough that only one viable design exists

## Phase 1: Produce The Executable Spec

Follow `.claude/skills/spec-driven-development/SKILL.md`.

The resulting plan must include:

- scope classification
- change manifest
- test manifest
- implementation batches
- assumptions and risks

**Persist the spec to disk before continuing.** Save to `docs/specs/YYYY-MM-DD-<feature-slug>.md` using today's date and a kebab-case slug. Create `docs/specs/` if missing. This is mandatory — the engineer must be able to read and edit the spec outside of chat.

## Phase 2: Write The Task Breakdown

Follow `.claude/skills/planning-and-task-breakdown/SKILL.md`.

Write **both** files (mandatory, not optional):

1. `tasks/todo.md` — checkable batches and post-implementation review items
2. `docs/plans/YYYY-MM-DD-<feature-slug>.md` — full plan alongside the spec, same date and slug as Phase 1

Create `docs/plans/` if missing.

## Phase 2.5: Approval Gate (STOP HERE)

**This phase is mandatory.** Always ask. Do not skip, abbreviate, or merge into Phase 3.

1. Print a short summary to the engineer:
   - Scope classification
   - Spec file path: `docs/specs/<filename>.md`
   - Plan file path: `docs/plans/<filename>.md`
   - Todo file path: `tasks/todo.md`
   - Number of batches and total files in the change manifest
2. **Ask via the `AskUserQuestion` tool — nothing else counts.**
   - **Question:** "Plan and todo are written. How would you like to proceed?"
   - **Options (tool labels, not prose):**
     - `Approve & run until done` — autonomous mode. Proceed through Phases 3-7 without asking further questions. Make best-effort decisions on minor ambiguities; only stop for blocking issues (build failures that need design input, security findings the spec did not anticipate, or scope expansion beyond the manifest). Set internal flag `autonomous = true` for the rest of the session.
     - `Approve (interactive)` — proceed to Phase 3, but ask follow-up questions during implementation/review when ambiguities arise.
     - `Edit first` — pause so the engineer can edit the spec/plan/todo files. Stop and wait for their next message.
     - `Revise` — describe what to change in the spec/plan; Claude rewrites Phase 1/2 (overwrites the same file paths) and returns to this gate.
   - **You MUST invoke the `AskUserQuestion` tool.** Do not render the options as a numbered/lettered list (no "A. Approve…", no "1) Approve…"), do not ask the question as plain prose, do not wait for a free-text reply. The TUI prompt is the only acceptable form.
   - If `AskUserQuestion` is deferred in this session (schema not loaded), call `ToolSearch` with `select:AskUserQuestion` first to load it, then invoke it.
   - If the harness genuinely does not expose `AskUserQuestion` (e.g., Cursor, Copilot CLI, Gemini CLI), STOP. Print one line: "Approval gate requires the AskUserQuestion TUI tool, which is unavailable in this harness. Tell me which option to take: Approve & run until done / Approve (interactive) / Edit first / Revise." Then wait. Do not fabricate an A/B/C/D prompt and do not proceed.
3. Do not call any Edit/Write on source code, do not start Phase 3, and do not use Bash for anything beyond read-only inspection until the engineer answers.
4. Honor the chosen mode for the rest of the session:
   - **Autonomous:** in Phases 3-7, never call `AskUserQuestion`. If a blocking issue surfaces, stop and report it instead of asking. Resume only after the engineer responds.
   - **Interactive:** ask focused questions when a decision materially affects the implementation. Do not ask for trivial confirmations.
5. Only proceed to Phase 3 after `Approve & run until done` or `Approve (interactive)`.

Note: this approval gate controls when *Claude* asks questions. The harness's tool-permission prompts (file write/Bash approvals) are a separate layer controlled by the engineer's permission mode (Shift+Tab to toggle accept-edits). Autonomous mode does not bypass the harness.

## Phase 3: Implement In Batches

Follow `.claude/skills/incremental-implementation/SKILL.md`.
Also follow:

- `.claude/skills/test-driven-development/SKILL.md`
- `.claude/skills/source-driven-development/SKILL.md` when framework or SDK behavior is uncertain
- `.claude/skills/security-and-hardening-fintech/SKILL.md` when the scope touches auth, financial state, secrets, or infra

For every batch:

1. implement only in-manifest files
2. add or update tests in the same batch
3. run the batch checkpoint using the build/test commands from the active tech stack skill
4. run the pre-commit review list if present
5. check the batch off in `tasks/todo.md`

After all batches:

- run the full test command from the active tech stack skill
- write an explicit behavioral diff

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
4. Do NOT proceed to review until drift is clean.

Silent drift repair is forbidden — every change to scope goes through the
approval gate.

## Phase 4: Review (Two-Stage)

Follow `.claude/skills/code-review-and-quality-fintech/SKILL.md`.
Follow `.claude/skills/verification-before-completion/SKILL.md` before starting review.

Reviews are **sequential, not parallel**. Spec compliance comes first because if the implementation doesn't match the spec, code quality review is wasted effort.

### Stage 1: Spec Compliance

Run `compliance-reviewer` with:

- `git diff HEAD`
- the behavioral diff
- the scope classification
- the change manifest summary

The compliance reviewer checks: does the implementation match the approved spec? Are security, architecture, and coding standards met? If **Critical** issues are found, fix them before proceeding to Stage 2.

### Stage 2: Quality and Coverage

Only after Stage 1 passes (no Critical issues):

- run `test-reviewer` when the change introduces or changes public behavior
- run `architecture-reviewer` when the change introduces new slices, boundaries, handlers, or cross-project interactions

Provide Stage 2 reviewers with the same diff and behavioral diff.

## Phase 5: Fix Review Findings

Fix every critical issue and every reasonable warning, then:

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

6. **State the compound.** In the final report, include a "What compounded" section listing what future sessions will benefit from.

## Final Report

Report:

- scope
- files changed
- tests added or updated
- review agents used and stage (1 or 2)
- review iterations
- cleanup summary
- **what compounded** — lessons captured, rules promoted, pre-commit-review items added
- whether `CLAUDE.md` changed

## Red Flags

- Code started before the spec existed
- Spec or plan not written to `docs/specs/` and `docs/plans/`
- Phase 2.5 approval gate skipped or merged into Phase 3
- Phase 3 started without an explicit approval answer from the engineer
- Approval gate rendered as plain-text A/B/C/D prose instead of invoking the `AskUserQuestion` TUI tool
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
6. **The Phase 2.5 approval gate is always mandatory.** Spec, plan, and todo must all be written to disk before the gate. Ask via the `AskUserQuestion` TUI tool — never by printing the options as prose (no "A. Approve… / B. Approve (interactive)… / C. Edit first… / D. Revise…"). If the tool is deferred, load it with `ToolSearch` first; if the harness does not expose it at all, stop and say so rather than faking a text prompt. Never assume approval, never infer it from the original request, never proceed silently to Phase 3. The engineer chooses interactive vs autonomous mode at the gate, not via a flag.
