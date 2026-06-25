---
name: brainstorming
description: Use before spec writing when the approach is unclear, multiple designs are plausible, or the engineer wants to explore alternatives before committing.
type: skill
license: MIT
compatibility:
  - claude-code
  - cursor
  - codex
trigger: unclear-approach|multiple-designs|architectural-decision|how-should-we
skip_when: approach-already-decided|narrow-scope|bug-fix
user-invocable: false
required-toolsets: [read-only]
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
   - Read `CLAUDE.md` and `.claude/references/architecture-principles.md` (if present)
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

## Divergence Mode (Isolated Parallel Exploration)

The default workflow above runs in one context — which means every approach is
generated under the same anchoring. For **architecture-shaping** decisions (a new
boundary, a public contract, a migration strategy) or when the engineer asks for
*wide* exploration, switch to divergence mode: generate approaches in **isolated
parallel subagents** so they don't converge on the first obvious idea, then judge
them with a separate critic pass.

**When to enter divergence mode:**
- The engineer explicitly asks for wide / divergent / "blue-sky" exploration, OR
- The decision is architecture-shaping (new bounded context, new persistence
  target, cross-slice contract, irreversible migration).
Otherwise stay on the default light path — divergence mode is more expensive and
overkill for a routine choice between two known patterns.

**Cost gate (ask first).** Divergence mode spends roughly **6–10 agent calls**
(one per divergent branch plus the critic deepening). Before running it, state
that cost in one line and confirm — *unless* the engineer already explicitly
asked for wide exploration, in which case proceed.

**Phase 1 — Diverge (parallel, isolated).**
1. Pick **3–5 frames** from `.claude/references/divergence-frames.md`. Always
   include at least one adversarial/fintech frame when the work touches money,
   auth, or audited state (`F-REG` regulator, `F-FRD` fraudster, `F-AUD`
   auditor). Vary the frame selection across sessions so you don't always view
   the problem the same way.
2. Spawn one subagent **per frame**, in a single message (parallel), each with
   **zero shared context** beyond the problem statement and its own frame's
   vantage prompt. Each subagent is instructed to: reason only from its frame,
   **ban the first three obvious answers**, and return **JSON only** (no prose):
   `{ "approach": "...", "how": "...", "load_bearing_assumption": "...", "risk": "..." }`.
   Branches must not see each other's output — isolation is the whole point.

**Phase 2 — Focus (critic pass, orchestrator-side).**
3. Collect the branch JSON. Run a **separate critic pass** (you, the orchestrator,
   with a deliberately skeptical lens — not the generators):
   - **Score** each approach on novelty / viability / fit (0–10 each).
   - **Cluster** approaches by underlying angle (not by keyword) so near-duplicates
     collapse.
   - **Flag traps**: approaches that are attractive but broken, each with a
     one-line reason. Carry any frame-specific traps noted in the frames file.
   - **Deepen** the top 2–3 survivors into full approach blocks (the structure
     from step 3 of the default workflow).
4. Present: the deepened survivors + recommendation (as in the default path) **plus
   a mandatory Trap Register** — the attractive-but-broken approaches and why,
   so the rejected space is durable knowledge, not lost.

**Trap register carries forward.** When this brainstorm proceeds to a spec, the
trap register becomes the spec's "Rejected alternatives" — `spec-driven-development`
reads it. Naming the seductive-but-wrong design is as valuable as naming the
chosen one.

## Rules

- No implementation during brainstorming. Not even "let me try something quick."
- Approaches must be concrete enough to compare, not hand-wavy.
- Tradeoffs must be honest. Do not soft-sell the recommended approach.
- Respect the engineer's choice even when you disagree.
- If only one approach is viable, say so and explain why alternatives don't work.
- Divergence mode: branches run isolated (zero shared context) and the critic is a
  separate pass — never let a generator grade its own idea.
- Divergence mode self-declares its ~6–10 call cost and confirms before running,
  unless wide exploration was explicitly requested.
- A divergence-mode result without a Trap Register is incomplete.

## Common Rationalizations

See `.claude/skills/context-engineering/SKILL.md` for the shared table. Brainstorming-specific traps: "there's really only one way to do this" (then present that one approach and explain why alternatives don't apply — the discipline still helps), and "let me prototype and then we'll decide" (prototyping creates sunk-cost bias — decide on the approach first, then build).

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
