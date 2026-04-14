---
name: brainstorming
description: Use before spec writing when the approach is unclear, multiple designs are plausible, or the engineer wants to explore alternatives before committing.
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: unclear-approach|multiple-designs|architectural-decision|how-should-we
skip_when: approach-already-decided|narrow-scope|bug-fix
user-invocable: false
---

# Brainstorming

## Overview

Explore the design space before committing to a single approach. Brainstorming produces 2-3 concrete alternatives with explicit tradeoffs, then converges on an approved direction. This phase prevents the most expensive mistake: building the wrong thing correctly.

## When To Use

- The engineer says "how should we..." or "what's the best way to..."
- Multiple implementation approaches are plausible
- The task involves architectural decisions with long-term consequences
- The scope or requirements are ambiguous
- Before spec-driven-development when the design direction is not obvious

### When NOT To Use

- The approach is already clear and agreed upon
- The task is a bug fix, config change, or narrow refactor
- The engineer explicitly says "just do it this way"

## Workflow

1. **Explore context** before proposing anything:
   - Read `CLAUDE.md` and relevant architecture-principles
   - Read existing code in the affected area
   - Check recent git history for relevant decisions or attempts
   - Understand current constraints (tech stack, patterns, conventions)

2. **Ask clarifying questions** one at a time:
   - Focus on constraints that would eliminate approaches
   - Ask about non-functional requirements (performance, compatibility, timeline)
   - Ask about user/caller expectations
   - Stop asking when you have enough to differentiate approaches

3. **Propose 2-3 concrete approaches** with this structure for each:
   - **Approach name** — one-line summary
   - **How it works** — concrete description with file/component names
   - **Pros** — specific advantages for this codebase
   - **Cons** — specific risks, costs, or limitations
   - **Effort** — relative complexity (files touched, new abstractions needed)
   - **Fits when** — the conditions under which this approach is the best choice

4. **Present a recommendation** with reasoning:
   - Which approach you'd pick and why
   - What would change your recommendation
   - Risks of the recommended approach and how to mitigate them

5. **Get approval** on the direction before proceeding:
   - Wait for the engineer to confirm, modify, or redirect
   - If the engineer picks a different approach, acknowledge and adapt
   - Do not start implementation without explicit approval

6. **Persist the decision** if the work will continue to spec:
   - Save to `docs/specs/YYYY-MM-DD-<topic>-brainstorm.md` if `docs/specs/` exists
   - Include: approaches considered, decision rationale, and constraints that drove the choice
   - This enables session recovery and future reference for why the design was chosen

## Rules

- No implementation during brainstorming. Not even "let me try something quick."
- Approaches must be concrete enough to compare, not hand-wavy.
- Tradeoffs must be honest. Do not soft-sell the recommended approach.
- Respect the engineer's choice even when you disagree.
- If only one approach is viable, say so and explain why alternatives don't work.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "The right approach is obvious, skip brainstorming" | Obvious to whom? The engineer asked for options because the choice is not clear to them. |
| "I'll just start and adjust if it's wrong" | Adjusting a wrong architecture costs 10x more than spending 5 minutes on alternatives. |
| "There's really only one way to do this" | Then present that one approach and explain why alternatives don't apply. The discipline still helps. |
| "Let me prototype and then we'll decide" | Prototyping creates sunk-cost bias. Decide on the approach, then build. |

## Red Flags

- Implementation started before the approach was approved
- Only one approach presented when multiple are viable
- Tradeoffs described vaguely instead of concretely
- Engineer's choice overridden silently
- Brainstorming used to stall instead of converge

## Verification

- [ ] Context was explored before proposing approaches
- [ ] At least 2 approaches were presented (or a clear argument for only one)
- [ ] Each approach has concrete pros, cons, and effort
- [ ] A recommendation was stated with reasoning
- [ ] The engineer approved a direction before any implementation
