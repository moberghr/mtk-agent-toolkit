---
name: writing-skills
description: Use when creating a new skill for this toolkit — ensures the skill follows the anatomy, CSO principle, and is tested against agent rationalizations before shipping.
type: skill
license: MIT
compatibility:
  - claude-code
trigger: new-skill|skill-rewrite|skill-conversion
skip_when: project-convention|hook-automation|standard-practice
user-invocable: false
---

# Writing Skills

## Overview

A skill is a reusable behavior contract that shapes how an agent approaches a category of work. Writing a good skill requires observing baseline failures first, then writing the minimum documentation that closes those gaps, then testing that the skill resists pressure.

## When To Use

- Adding a new skill to the toolkit
- Substantially rewriting an existing skill
- Converting a one-off command pattern into a reusable skill

### When NOT To Use

- One-off project-specific conventions (put those in CLAUDE.md)
- Mechanical constraints better handled by automation (put those in hooks or settings)
- Well-documented standard practices that don't need reinforcement

## Workflow

### Phase 1: Observe Baseline Failures

Before writing any skill content:

1. Run 2-3 representative scenarios without the skill.
2. Document what went wrong:
   - What steps were skipped?
   - What rationalizations were used to skip them?
   - What outcomes were produced?
3. This creates the "RED" baseline — the specific gaps the skill must close.

### Phase 2: Write The Minimum Skill

1. Follow the anatomy defined in `docs/skill-anatomy.md`:
   - Required: frontmatter (`name`, `description`), `# Title`, `## Overview`, `## When To Use`, `## Workflow`, `## Verification`
   - Recommended: `### When NOT To Use`, `## Red Flags`, `## Rules`
   - The shared MTK rationalization table lives in `.claude/skills/context-engineering/SKILL.md`. Do **not** duplicate universal rationalizations here. Only add a short `## Common Rationalizations` section if the skill has one or two traps that are genuinely specific (and reference the shared table at the top).

2. **Apply the CSO principle:** The `description` in frontmatter must trigger on conditions, not summarize the workflow.
   - Bad: "Create implementation plans with acceptance criteria and dependency ordering"
   - Good: "Use after a spec is approved and before multi-file implementation begins"
   - Why: Workflow summaries cause the agent to follow the description instead of reading the full SKILL.md

3. **Identify skill-specific rationalizations:** The shared table in `context-engineering` covers universal shortcuts. For each step this specific skill might be skipped over, note whether the shortcut is truly unique to this skill. If yes, add a 1-2 entry `## Common Rationalizations` section referencing the shared table. If no, rely on the shared table alone.

4. **Write verification checklist:** Every claim the skill makes about outcomes must have a verification step.

5. **Keep it under 500 lines.** If the skill needs more, use progressive disclosure:
   - Core workflow in SKILL.md
   - Reference material in separate files loaded on demand

### Phase 3: Test Under Pressure

1. Create 3-5 adversarial scenarios that try to break the skill's discipline:
   - Time pressure: "We need to ship this now, skip X"
   - Simplicity argument: "This is too simple to need X"
   - Authority argument: "The engineer said to skip X"
   - Precedent argument: "We didn't do X last time and it was fine"

2. Run each scenario and verify the skill holds.
3. If the skill breaks, strengthen the specific gap:
   - Add the rationalization to the table
   - Add the red flag
   - Tighten the workflow step

4. Save pressure tests to `tests/pressure-tests/<skill-name>-pressure.md`.

### Phase 3b: Add Evals (If The Skill Gates Shipping)

If the skill is on the ship path — meaning a miss ends up in a commit, a PR,
or a release — add measurable evals in addition to pressure tests:

1. Create `evals/<skill-name>/` with at minimum:
   - `eval-01-<positive>.md` — scenario where the skill MUST trigger
   - `eval-02-<negative>.md` — scenario where the skill MUST NOT trigger
   - `eval-03-<adversarial>.md` — scenario designed to make the skill skip
     steps or inflate output
   - `grader.md` — grading prompt checking expected signals
2. Each scenario declares `category: positive | negative | adversarial` in
   frontmatter, includes a fenced `prompt` block for automated extraction,
   and specifies Expected Signals + a pass/partial/fail Rubric.
3. Evals are distributed via `manifest.json` so target teams can run them.
4. Run with `bash scripts/run-evals.sh` (manual mode by default; wire
   `EVAL_EXECUTOR` / `EVAL_GRADER` env vars for automation).

Pressure tests are adversarial-only. Evals span positive/negative/adversarial
and give a measurable pass rate. Use both for ship-path skills; pressure
tests alone are sufficient for advisory skills.

### Phase 4: Register

1. Add the skill to `.claude/manifest.json` with action `sync`.
2. Add routing rules to `AGENTS.md` if the skill changes how tasks are dispatched.
3. Update `docs/skill-anatomy.md` if the skill establishes a new pattern.
4. Run `bash scripts/validate-toolkit.sh` to verify the skill passes validation.

## Cache-Stable Prefixes

When a skill runs repeatedly across sessions — especially a reviewer agent or an entry-point skill that the whole team loads on every run — prompt caching cuts token cost dramatically. Caching works by matching an **exact prefix** of the prompt. If the prefix changes every session (because a date, branch, or diff stat is at the top), the cache misses.

**Rule:** put invariants first, volatile state last.

- Invariants (top): persona statement, output contract, standards checklist, rationalization table, red flags. These never change between sessions.
- Dynamic state (bottom): current branch, diff stats, touched files, behavioral diff. Inject these via `` !`command` `` fenced blocks or at the call site, not woven through the static body.

A good reviewer agent has the same top ~80% byte-for-byte across every invocation, with only the diff + behavioral-diff injected at the end. That prefix caches; subsequent sessions pay only for the tail.

Entry-point skills follow the same pattern — Phase 0 load instructions stay identical, only the user-supplied task description varies.

## Rules

- No skill without baseline failure observations.
- No skill without a rationalization table.
- No skill without a verification checklist.
- Descriptions trigger on conditions, never summarize workflows (CSO principle).
- Keep frequently-loaded skills under 500 lines.
- Test discipline-enforcing skills with adversarial pressure scenarios.
- Cache-stable prefix for reviewer agents and high-traffic entry-point skills: invariants top, dynamic state bottom.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Writing-skills specific traps: "the skill is obvious, I don't need to test it" (obvious skills get ignored — test to find the gaps), and "this description summarizes the skill well" (summarizing triggers the agent to follow the summary instead of reading the full content — use trigger conditions).

## Red Flags

- Skill written without observing baseline failures first
- Description summarizes the workflow instead of triggering on conditions
- No rationalization table
- No pressure tests
- Skill exceeds 500 lines without progressive disclosure

## Verification

- [ ] Baseline failures were documented before writing the skill
- [ ] Description follows the CSO principle (condition-based triggering)
- [ ] Rationalization table covers every skippable step
- [ ] Verification checklist covers every outcome claim
- [ ] SKILL.md is under 500 lines
- [ ] Pressure tests exist and the skill passes them
- [ ] Skill is registered in manifest.json
- [ ] `validate-toolkit.sh` passes
