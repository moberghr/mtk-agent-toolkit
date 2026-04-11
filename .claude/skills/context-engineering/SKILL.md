---
name: context-engineering
description: Use when starting a session, switching between planning/implementation/review phases, entering unfamiliar code, or when output drifts from project norms.
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: session-start|phase-switch|unfamiliar-code|output-drift
skip_when: single-command|trivial-lookup
---

# Context Engineering

## Overview

Good output depends on good context. Load the minimum relevant context needed to act correctly, then refresh it when the task shifts.

## When To Use

- Starting a new session
- Switching from planning to implementation or implementation to review
- Entering an unfamiliar area of the codebase
- When the model starts making assumptions or drifting from project norms

### When NOT To Use

- As an excuse to endlessly read without acting

## Workflow

1. Start with `CLAUDE.md` when present.
2. Load only the shared references relevant to the task.
3. Read the exact file to be changed and 2-3 neighboring files that establish local patterns.
4. Separate trusted local standards from untrusted external inputs.
5. Before a new phase, summarize what matters now:
   - current goal
   - files in scope
   - governing rules
   - open risks
6. Refresh context when the scope or failure mode changes.

## Context Budget Tracking

Track the cumulative context loaded in the session. Research shows LLMs reliably follow ~150 instructions, with degradation starting as more are loaded.

**Budget guidelines:**
- CLAUDE.md: target under 200 lines (~50 instructions)
- Rules files: each under 120 lines
- Each skill loaded: 60-120 lines
- Reference files: vary, load only relevant sections

**When to check the budget:**
- After loading 3+ skills in a single session, pause and assess: are all still relevant?
- If output quality drops or instructions are being ignored, context may be over-budget
- Before loading a new reference, check if an earlier one can be released

**Warning signals:**
- 5+ skills loaded simultaneously — prune to the 2-3 most relevant
- Full reference files loaded when only a section is needed
- Same context loaded multiple times (after compaction recovery)

## Rules

- Read before writing.
- Prefer targeted context over broad dumping.
- Re-anchor on the local codebase pattern before introducing new structures.
- If confidence drops, gather better context before guessing.
- Track context budget: fewer, more relevant instructions beat more, diluted ones.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "I'll just start coding and adjust later" | Early wrong assumptions produce the most expensive rework. |
| "More context is always better" | No. Irrelevant context crowds out the rules that actually matter. |
| "I already read a similar file in another project" | Local codebase patterns win over generic memory. |

## Red Flags

- Editing without reading the target file and neighbors
- Repeating generic patterns that the local codebase does not use
- Loading many files with no clear reason

## Verification

- [ ] Governing standards were loaded first
- [ ] Local pattern files were read before editing or reviewing
- [ ] Context matches the current phase and task scope
- [ ] No more than 3 skills loaded simultaneously unless justified
- [ ] Reference files loaded by section, not in full, when possible
